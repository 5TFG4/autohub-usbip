# AutoHub – Pi Installation Guide

This document turns a Raspberry Pi (or any Debian-based USB/IP host) into the automated USB exporter for AutoHub. The goals are:

- Every newly attached **non-hub** USB device binds to `usbipd` and notifies Windows in ≤1s.
- Removal events unbind the device and notify Windows.
- A boot-time retrigger replays `add` events to restore bindings after reboots.
- TCP 3240 only accepts IPv4 clients listed in `/etc/usbip-autohub/clients.allow` via nftables.

All commands assume a sudo-capable shell on the Pi.

## 1. Packages and IPv4-only usbipd

```bash
sudo apt update
sudo apt install -y usbip nftables curl

# Start + enable usbipd. Ignore the error if the service already exists.
sudo systemctl enable --now usbipd.service 2>/dev/null || true

# Force usbipd to listen on IPv4 only (once-off override)
sudo systemctl edit usbipd.service
```

Insert the override snippet when the editor opens:

```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/usbipd -4
```

Apply the change:

```bash
sudo systemctl daemon-reload
sudo systemctl restart usbipd.service
```

Verify TCP 3240 is bound on IPv4:

```bash
ss -lntp | grep 3240 || sudo netstat -lntp | grep 3240
```

## 2. Autobind + Notify Script

Install `pi/autobind.sh` as `/usr/local/bin/usbip-autohub.sh` (or keep the default name—just update the unit files accordingly). The script takes an `ACTION-BUSID` argument (`add-1-1.3`) and performs USB bind/unbind plus HTTP notifications to the Windows listener.

Set `WIN_HOST` and `WIN_PORT` near the top of the script before deploying. Avoid DNS names unless your Pi can resolve them during early boot.

```bash
sudo install -m 0755 pi/autobind.sh /usr/local/bin/usbip-autohub.sh
```

## 3. udev Rule → systemd Onesot

Copy `pi/99-usbip-autobind.rules` to `/etc/udev/rules.d/99-usbip-autohub.rules`.

```bash
sudo install -m 0644 pi/99-usbip-autobind.rules /etc/udev/rules.d/99-usbip-autohub.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=usb --action=add
```

The rule adds `TAG+="systemd"` and sets `SYSTEMD_WANTS=usbip-autohub@<ACTION>-<BUSID>.service`, ensuring udev returns quickly while systemd runs the heavy work.

## 4. systemd Template

Copy `pi/usbip-autohub@.service` (embedded in `pi/autobind.sh` comments) or create the template manually:

```ini
[Unit]
Description=USB/IP autobind + notify (%I)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usbip-autohub.sh %I
```

Save as `/etc/systemd/system/usbip-autohub@.service` and reload systemd:

```bash
sudo systemctl daemon-reload
```

## 5. Boot Retrigger

Install `pi/usbip-retrigger.service` to replay USB `add` events after boot:

```bash
sudo install -m 0644 pi/usbip-retrigger.service /etc/systemd/system/usbip-retrigger.service
sudo systemctl daemon-reload
sudo systemctl enable --now usbip-retrigger.service
```

## 6. nftables Allow-list for TCP 3240

1. Copy the sample allow-list and edit it:
   ```bash
   sudo install -m 0644 pi/examples/clients.allow.sample /etc/usbip-autohub/clients.allow
   ```
2. Review `pi/usbip-allow-sync`, update paths if needed, and install it:
   ```bash
   sudo install -m 0755 pi/usbip-allow-sync /usr/local/sbin/usbip-allow-sync
   sudo mkdir -p /etc/nftables.d
   sudo /usr/local/sbin/usbip-allow-sync
   ```
3. Deploy the service + path units:
   ```bash
   sudo install -m 0644 pi/usbip-allow-sync.service /etc/systemd/system/usbip-allow-sync.service
   sudo install -m 0644 pi/usbip-allow-sync.path /etc/systemd/system/usbip-allow-sync.path
   sudo systemctl daemon-reload
   sudo systemctl enable --now usbip-allow-sync.service usbip-allow-sync.path
   ```

The generated `/etc/nftables.d/usbip-allow.nft` contains a dedicated `inet usbipguard` table that only filters TCP 3240, leaving other firewall rules untouched.

## 7. Verification Checklist

- `ss -lntp | grep 3240` shows `usbipd` listening on IPv4.
- `usbip list -l` lists local devices; new non-hub devices trigger systemd units and log entries under `usbip-autohub` in `journalctl -t usbip-autohub -f`.
- From Windows, `usbip list -r <PI_IP>` shows exported devices immediately after attachment.

## Maintenance Tips

- Update `/etc/usbip-autohub/clients.allow` whenever you add/remove Windows clients—`usbip-allow-sync.path` applies nftables changes automatically.
- Keep an eye on `journalctl -u usbip-autohub@* -u usbip-allow-sync.service` for failures (network timeouts, nftables syntax errors, etc.).
- Consider wrapping TCP 3240 inside a VPN (WireGuard/IPsec) if the LAN is not fully trusted.
