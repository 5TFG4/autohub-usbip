# AutoHub Troubleshooting

Common issues and quick checks when AutoHub does not behave like a true plug-and-play USB cable.

## 1. No Connection / Attach Fails

- **Symptom**: `usbip attach` returns connection errors or times out.
- **Checks**:
  - `ss -lntp | grep 3240` on the Pi ensures `usbipd` is listening.
  - `sudo nft list table inet usbipguard` verifies the allow-set contains the Windows client.
  - `Test-NetConnection <PI_IP> -Port 3240` from Windows confirms TCP reachability.
  - Confirm VPNs or VLAN ACLs are not blocking 3240.

## 2. Listener Never Sees Events

- **Symptom**: `listener.ps1` shows no activity when plugging USB devices.
- **Checks**:
  - `journalctl -u usbip-autohub@* -f` on the Pi should show `curl` status; failures imply name/IP issues or Windows firewall blocks.
  - Verify URLACL: `netsh http show urlacl | Select-String 59876` should display the registered prefix.
  - Run `Get-NetFirewallRule -DisplayName "Autohub listener 59876" | Get-NetFirewallAddressFilter` to ensure the Pi IP is allowed.

## 3. Devices Attach Slowly (>1s)

- **Symptom**: Windows attaches only after several seconds.
- **Checks**:
  - Inspect Pi logs for repeated retries (`notify ... failed`). Network latency to Windows should be <1s.
  - Ensure DNS lookups are not delaying the POST; prefer static IPs for `WIN_HOST`.
  - Confirm the Windows listener is already running (scheduled task status = Ready/Running).

## 4. Sync Script Does Nothing

- **Symptom**: `sync.ps1` logs no attachments even though `usbip list -r` shows devices.
- **Checks**:
  - Run `usbip list -r <PI_IP>` manually; if output format differs, tweak the regex in `sync.ps1` (`'^\s*-\s*busid\s+([0-9\.-]+)\s+\('`).
  - Verify the CLI returns exit code 0; otherwise capture the stderr for driver-specific errors.
  - `usbip port` output should list `busid = ...`; if formatting changed, adjust the regex in `Detach-Busid` and cleanup loops.

## 5. Pi Exports USB Hubs

- **Symptom**: USB hubs themselves show up as devices.
- **Checks**:
  - Confirm `/sys/bus/usb/devices/<BUSID>/bDeviceClass` equals `09` for hubs; `autobind.sh` skips them by design.
  - If hubs still bind, ensure the script path in `usbip-autohub@.service` points to the updated version.

## 6. nftables Rule Fails to Apply

- **Symptom**: `usbip-allow-sync` exits non-zero.
- **Checks**:
  - Run `bash -x /usr/local/sbin/usbip-allow-sync` to see the generated file path.
  - Validate `clients.allow` has one token per line; no IPv6 entries are supported.
  - Make sure `/etc/nftables.d` exists and is writable.

## 7. Listener Misreports Source IP

- **Symptom**: Windows rejects requests with `403` even for the Pi.
- **Checks**:
  - A proxy or NAT may alter the source IP—ensure the Pi connects directly.
  - Use packet capture (`pktmon` / Wireshark) to confirm the source address.
  - Update `clients.allow` to include any intermediate IPs if unavoidable (e.g., VPN tunnel endpoints).

## 8. After Reboot Nothing Attaches

- **Symptom**: After Pi reboot, Windows never receives events.
- **Checks**:
  - `systemctl status usbip-retrigger.service` must show success; rerun `udevadm trigger --subsystem-match=usb --action=add` manually.
  - Ensure `usbip-autohub@add-*.service` units exist in `systemctl list-units` after the trigger.
  - On Windows, confirm the scheduled listener task ran (Task Scheduler History enabled).

## 9. Serial Devices Need Precise Timing

- **Symptom**: Some USB-to-serial adapters misbehave due to latency.
- **Resolution**: Bypass USB/IP for those cases and use RFC2217 (`pyserial`'s `rfc2217_server.py` on the Pi, and `serial_for_url("rfc2217://<PI>:7000")` on Windows). See `docs/DESIGN-notes.md` for rationale.

## Still Stuck?

- Capture logs: `journalctl -u usbip-autohub@*`, `Get-WinEvent Microsoft-Windows-PowerShell/Operational -MaxEvents 20`, and `usbip port` output.
- Validate network path with `traceroute`/`Test-NetConnection`.
- Consider enabling debug logging inside the scripts (e.g., set `set -x` in `autobind.sh`, or use `Start-Transcript` in PowerShell) temporarily.
