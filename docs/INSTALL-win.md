# AutoHub – Windows Installation Guide

This guide turns a Windows workstation into the AutoHub USB/IP client that listens for Pi events and keeps USB attachments in sync.

## Recommended installation (quick start)

> Run all commands from an elevated PowerShell session (**Run as administrator**) so the installer can reserve HTTP prefixes, add firewall rules, and register scheduled tasks.

1. Install the Windows USB/IP driver + CLI (`usbip.exe`) and confirm `usbip.exe help` works from an elevated shell.
2. Fetch the project and run the Windows installer:

```powershell
git clone https://github.com/5TFG4/autohub-usbip.git
Set-Location autohub-usbip\windows
.\install.ps1
```

The installer:

- Ensures `autohub.config` and `clients.allow` exist next to the scripts (copying the `.sample` files if needed).
- Registers the HTTP URLACL for `LISTENER_PORT` + `LISTENER_PATH` using your signed-in account.
- Creates/updates the firewall rule for the listener port, then runs `update-firewall.ps1` so only addresses listed in `clients.allow` are allowed inbound.
- Registers the scheduled tasks **Autohub Listener** (logon) and **Autohub Sync On Logon** (logon + workstation unlock) that call `listener.ps1` and `sync.ps1` with your configuration.

Edit `autohub.config` and `clients.allow` inside the `windows` folder to reflect your Pi's address, listener settings, and allowed clients. Re-run `install.ps1` any time you change ports or need to reapply the scheduled tasks/firewall.

## Manual / Advanced installation (not recommended for most users)

Only follow these steps if you prefer to manage the Windows configuration yourself. The scripts assume they live in the repository's `windows` directory and default to config files that sit alongside them.

### 1. Prerequisites

1. Install the Windows USB/IP driver + CLI (`usbip.exe`). Use a recent, signed build compatible with your Windows edition.
2. Confirm `usbip.exe` is in the `PATH` by running `usbip.exe help` from an elevated PowerShell session.
3. Clone or unpack the repository, then work from `autohub-usbip\windows`. All paths below assume you're inside that folder; override locations with `-ConfigPath` if you move the files elsewhere.

### 2. Directory layout and allow-list

The Windows scripts automatically read `autohub.config` that lives next to them. The installer (or you) should ensure these files exist:

- `windows/autohub.config.sample` → `windows/autohub.config`
- `windows/clients.allow.sample` → `windows/clients.allow`

Example configuration (`windows/autohub.config`):

```text
PI_HOST=192.168.1.2
LISTENER_PORT=59876
LISTENER_PATH=/usb-event/
ALLOW_LIST_PATH=clients.allow
```

Example allow-list (`windows/clients.allow`):

```text
# One IPv4 or CIDR per line, at least include the Pi's IP.
192.168.1.2
```

All PowerShell scripts read `autohub.config` automatically, so avoid hard-coding hostnames or ports in scheduled tasks.

### 3. HTTP listener (port 59876)

`listener.ps1` reads `autohub.config`, builds the prefix `http://+:<LISTENER_PORT><LISTENER_PATH>`, and then:

- Revalidates the clients allow-list on every request.
- Accepts POST bodies with `action=add/remove` and `busid=<busid>`.
- Calls `usbip attach` or `usbip detach` based on the desired state.
- Rejects non-POST or non-whitelisted sources.

Manual run (assumes `Set-Location autohub-usbip\windows`):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\listener.ps1
```

### 4. URLACL + firewall rule

Run these commands **as Administrator** to reserve the prefix and lock down the firewall:

```powershell
$me = "$env:USERDOMAIN\$env:USERNAME"
netsh http add urlacl url=http://+:59876/usb-event/ user="$me"

New-NetFirewallRule -DisplayName "Autohub listener 59876" `
  -Direction Inbound -LocalPort 59876 -Protocol TCP -Action Allow -RemoteAddress 192.168.1.2
```

> Adjust the port/path/IP in the commands above if `LISTENER_PORT`, `LISTENER_PATH`, or the Pi address differ in `autohub.config`.

After editing `clients.allow`, apply the addresses to the firewall rule:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\update-firewall.ps1
```

### 5. Sync script

`sync.ps1` reads `autohub.config` (to discover `PI_HOST`) and continuously aligns local `usbip` attachments with whatever the Pi exports:

1. Runs `usbip list -r <PI_IP>` to capture exported bus IDs.
2. Attaches any missing device.
3. Detaches local ports referencing bus IDs that are no longer exported.

Manual test run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\sync.ps1
```

### 6. Scheduled tasks

Create **two** scheduled tasks per user (highest privileges recommended):

```powershell
$listenerAction = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PWD\listener.ps1`""
$listenerTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Autohub Listener" -Action $listenerAction -Trigger $listenerTrigger `
  -Description "USB/IP event listener" -RunLevel Highest

$syncAction = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PWD\sync.ps1`""
$syncTriggers = @(
  New-ScheduledTaskTrigger -AtLogOn,
  New-ScheduledTaskTrigger -AtUnlock
)
Register-ScheduledTask -TaskName "Autohub Sync On Logon" -Action $syncAction -Trigger $syncTriggers `
  -Description "USB/IP sync at logon and unlock" -RunLevel Highest
```

### 7. Validation checklist

- `usbip list -r <PI_IP>` shows exported devices; `sync.ps1` attaches them.
- `usbip port` lists locally attached ports with matching bus IDs.
- `Get-NetTCPConnection -LocalPort 59876` reveals the listener bound and accepting connections only from allow-listed IPs.
- When you hot-plug a USB device into the Pi, Windows receives the HTTP POST within ≈1s and attaches it automatically.

## Maintenance

- Update `windows\clients.allow` whenever client IPs change, then re-run `update-firewall.ps1` (which re-reads `autohub.config`).
- Monitor the listener console or `Microsoft-Windows-PowerShell/Operational` log for errors (e.g., URLACL conflicts, usbip failures).
- Keep your USB/IP driver up to date; the scripts rely on the stock CLI output format (`usbip list -r` and `usbip port`). Adjust the regex in `sync.ps1` if your version differs.
