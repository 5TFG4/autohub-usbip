# AutoHub – Windows Installation Guide

This guide turns a Windows workstation into the AutoHub USB/IP client that listens for Pi events and keeps USB attachments in sync.

## 1. Prerequisites

1. Install the Windows USB/IP driver + CLI (`usbip.exe`). Use a recent, signed build compatible with your Windows edition.
2. Confirm `usbip.exe` is in the `PATH` by running `usbip.exe help` from an elevated PowerShell session.
3. Decide on a working directory (examples assume `C:\Autohub`).

## 2. Directory Layout and Allow-list

Create `C:\Autohub` and copy:

- `windows/listener.ps1`
- `windows/sync.ps1`
- `windows/update-firewall.ps1`
- `windows/autohub.config.sample` → `C:\Autohub\autohub.config`
- `windows/examples/clients.allow.sample` → `C:\Autohub\clients.allow`

Edit the two config files:

```text
C:\Autohub\autohub.config
PI_HOST=192.168.1.2
LISTENER_PORT=59876
LISTENER_PATH=/usb-event/
ALLOW_LIST_PATH=C:\Autohub\clients.allow
```

```text
C:\Autohub\clients.allow
# One IPv4 or CIDR per line, at least include the Pi's IP.
192.168.1.2
```

All PowerShell scripts read `autohub.config` automatically (you can point them at another path with `-ConfigPath` if needed), so avoid hard-coding hostnames or ports in scheduled tasks.

## 3. HTTP Listener (Port 59876)

`listener.ps1` reads `autohub.config`, builds the prefix `http://+:<LISTENER_PORT><LISTENER_PATH>`, and then:

- Revalidates the clients allow-list on every request.
- Accepts POST bodies with `action=add/remove` and `busid=<busid>`.
- Calls `usbip attach` or `usbip detach` based on the desired state.
- Rejects non-POST or non-whitelisted sources.

Manual run (uses the default `C:\Autohub\autohub.config`):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Autohub\listener.ps1
```

## 4. URLACL + Firewall Rule

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Autohub\update-firewall.ps1
```

## 5. Sync Script

`sync.ps1` reads `autohub.config` (to discover `PI_HOST`) and continuously aligns local `usbip` attachments with whatever the Pi exports:

1. Runs `usbip list -r <PI_IP>` to capture exported bus IDs.
2. Attaches any missing device.
3. Detaches local ports referencing bus IDs that are no longer exported.

Manual test run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Autohub\sync.ps1
```

## 6. Scheduled Tasks

Create **two** scheduled tasks per user (highest privileges recommended):

```powershell
$listenerAction = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Autohub\listener.ps1"
$listenerTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Autohub-Listener" -Action $listenerAction -Trigger $listenerTrigger `
  -Description "USB/IP event listener" -RunLevel Highest

$syncAction = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Autohub\sync.ps1"
$syncTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Autohub-Sync" -Action $syncAction -Trigger $syncTrigger `
  -Description "USB/IP sync at logon" -RunLevel Highest
```

In Task Scheduler, add an extra trigger to **Autohub-Sync** for "On workstation unlock" to guarantee re-attachment after resume/unlock events.

## 7. Validation Checklist

- `usbip list -r <PI_IP>` shows exported devices; `sync.ps1` attaches them.
- `usbip port` lists locally attached ports with matching bus IDs.
- `Get-NetTCPConnection -LocalPort 59876` reveals the listener bound and accepting connections only from allow-listed IPs.
- When you hot-plug a USB device into the Pi, Windows receives the HTTP POST within ≈1s and attaches it automatically.

## Maintenance

- Update `C:\Autohub\clients.allow` whenever client IPs change, then re-run `update-firewall.ps1` (which re-reads `autohub.config`).
- Monitor the listener console or `Microsoft-Windows-PowerShell/Operational` log for errors (e.g., URLACL conflicts, usbip failures).
- Keep your USB/IP driver up to date; the scripts rely on the stock CLI output format (`usbip list -r` and `usbip port`). Adjust the regex in `sync.ps1` if your version differs.
