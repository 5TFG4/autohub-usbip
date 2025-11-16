# AutoHub Design Notes

This document explains the rationale behind key design decisions so you can adapt or extend AutoHub safely.

## 1. Separation of Concerns

- **udev vs. systemd**: udev timeouts if a rule performs long or network-heavy work. Instead, the rule only tags the event and asks systemd to run a templated service. This ensures that USB hotplug handling never blocks the kernel event pipeline.
- **Stateless services**: Every action derives from the current device bus ID and allow-list files. There is no local database to corrupt, making recovery as simple as retriggering udev.

## 2. Security Model

- **Trusted LAN assumption**: USB/IP (TCP 3240) is plain text without authentication or integrity. AutoHub adds defense-in-depth (nftables + Windows Firewall + app-level allow-lists) but still assumes all participants reside on a trusted LAN or VPN.
- **IPv4-only binding**: Restricting `usbipd` to IPv4 avoids accidental exposure on IPv6 interfaces that might bypass firewall policies.
- **Allow-lists**: Using repo-local text files (`config/clients.allow` on the Pi and `C:\Autohub\clients.allow` on Windows) keeps automation simple and auditable—changes can be version-controlled or distributed with config management.
- **Minimal exposure**: TCP 59876 (listener) rejects everything except allow-listed sources and only accepts POSTs to `/usb-event/`. The Pi similarly drops all 3240 traffic unless sourced from the list.

## 3. Performance Goals

- **≤1s hotplug**: By executing the HTTP POST immediately after binding, Windows can attach almost in real time. The scripts avoid subshell loops and keep curl timeouts tight (1 second) so failures are logged quickly.
- **≤10s recovery**: The Windows sync task runs on logon/unlock. It re-reads the server exports and reconciles attachments, so even if events were missed during sleep, recovery happens in seconds.

## 4. Extensibility

- **Multiple clients**: Add more IPv4 entries to `${AUT0HUB_ROOT}/config/clients.allow` (Pi) and duplicate the Windows setup. Each listener only reacts to posts coming from the Pi.
- **Alternate transports**: Swap the HTTP POST for MQTT, AMQP, or SignalR by editing `autobind.sh` and `listener.ps1`; the rest of the pipeline remains unchanged.
- **Advanced security**: Place both hosts behind WireGuard/IPsec, then keep the same allow-lists but point them at the tunnel IPs. Mutual TLS is also possible by replacing `curl` with `openssl s_client` plus custom listeners.

## 5. Limitations

- **No multi-user arbitration**: Only one Windows machine should attach a given device at a time. usbipd does not handle concurrent attachments gracefully.
- **Driver quirks**: Some USB classes (isochronous audio, certain HID devices) perform poorly over USB/IP due to timing constraints.
- **Regex fragility**: PowerShell scripts parse the human-readable `usbip` CLI output; future client releases may require regex tweaks.

## 6. Future Enhancements

1. **systemd timer** to periodically re-run `usbip-allow-sync` even if the allow-list file did not change (catches manual nftables edits).
2. **Event signing** using a pre-shared key to prevent spoofed HTTP posts.
3. **Telemetry hooks** that push stats (attach latency, error counts) into Prometheus or Windows Event Log for alerting.

Understanding these trade-offs should help you customize AutoHub without reintroducing the pitfalls (long-running udev jobs, unaudited firewall openings, or silent attachment drift).
