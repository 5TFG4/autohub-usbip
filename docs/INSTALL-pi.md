# AutoHub – Pi Installation Guide

This guide keeps every Pi-specific artifact under `pi/` in the repository. Clone once, `cd pi`, and work entirely from that folder; the only files outside the repo are `/etc` glue (udev/systemd and `/etc/autohub-usbip.conf`).

All commands assume a sudo-capable shell on the Pi.

## Fast install via `install.sh`

Run this when you prefer a guided setup that captures the Windows listener details and allow-list for you:

```bash
cd autohub-usbip/pi
chmod +x install.sh   # first run only, if needed
sudo ./install.sh
```

The script will:

- Optionally `apt-get install usbip nftables curl`.
- Force `usbipd` into IPv4-only mode via a systemd drop-in.
- Prompt for `WIN_HOST`, `WIN_PORT`, `WIN_PATH`, `CURL_TIMEOUT`, and write both `config/autohub.env` and `/etc/autohub-usbip.conf`.
- Ask for the IPv4/CIDR allow-list and write `config/clients.allow`.
- Ensure `bin/usbip-allow-sync` and `bin/autobind.sh` are executable before they are invoked (covers filesystems that drop exec bits).
- Install all udev/systemd assets from this folder and run the initial `usbip-allow-sync`.

You can re-run the script anytime to update config or re-install the units; it keeps the repo-owned files under your regular user while writing `/etc` files as root. Continue with the sections below if you prefer to perform each step manually or need to audit what the script is doing.

## 1. Packages and IPv4-only usbipd

```bash
sudo apt update
sudo apt install -y usbip nftables curl

# Start + enable usbipd. Ignore the error if the service already exists.
sudo systemctl enable --now usbipd.service 2>/dev/null || true

# Force usbipd to listen on IPv4 only (once-off override)

```

Insert the override snippet when the editor opens:

```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/usbipd -4
```

Apply the change and verify TCP 3240:

```bash
sudo systemctl daemon-reload
sudo systemctl restart usbipd.service
ss -lntp | grep 3240 || sudo netstat -lntp | grep 3240
```

## 2. Clone the repo and declare `AUT0HUB_ROOT`

```bash
git clone https://github.com/<you>/autohub-usbip.git
cd autohub-usbip/pi
echo "AUT0HUB_ROOT=$(pwd)" | sudo tee /etc/autohub-usbip.conf
```

Append optional listener overrides (values shown are defaults):

```bash
sudo tee -a /etc/autohub-usbip.conf <<'EOF'
WIN_HOST=192.168.1.2
WIN_PORT=59876
WIN_PATH=/usb-event/
CURL_TIMEOUT=1
EOF
```

> `/etc/autohub-usbip.conf` should always point at the `pi/` directory. Every service expands `${AUT0HUB_ROOT}/bin` and `${AUT0HUB_ROOT}/config` based on this value.

## 3. Seed repo-local config

Still inside `autohub-usbip/pi`:

```bash
cp config/autohub.env.sample config/autohub.env           # optional runtime overrides
cp config/clients.allow.sample config/clients.allow       # IPv4/CIDR allow-list
```

`bin/autobind.sh` automatically sources `config/autohub.env` (if present) before using `/etc/autohub-usbip.conf`, so you can keep per-clone overrides out of `/etc`.

## 4. Install udev + systemd units

```bash
sudo install -m 0644 99-usbip-autohub.rules /etc/udev/rules.d/99-usbip-autohub.rules
sudo install -m 0644 usbip-autohub@.service /etc/systemd/system/usbip-autohub@.service
sudo install -m 0644 usbip-retrigger.service /etc/systemd/system/usbip-retrigger.service
sudo systemctl daemon-reload
sudo systemctl enable --now usbip-retrigger.service
```

The udev rule triggers `usbip-autohub@add-%k.service` or `usbip-autohub@remove-%k.service`, which in turn run `${AUT0HUB_ROOT}/bin/autobind.sh %I`.

## 5. nftables allow-list from repo files

`bin/usbip-allow-sync` reads `${AUT0HUB_ROOT}/config/clients.allow` and writes `${AUT0HUB_ROOT}/nft/usbip-allow.nft`. Deploy the service + path units so nftables refreshes automatically whenever you edit the allow-list:

```bash
sudo install -m 0644 usbip-allow-sync.service /etc/systemd/system/usbip-allow-sync.service
sed "s|{{AUTOHUB_ROOT}}|${AUT0HUB_ROOT}|g" usbip-allow-sync.path | \
  sudo tee /etc/systemd/system/usbip-allow-sync.path
sudo systemctl daemon-reload
sudo systemctl enable --now usbip-allow-sync.service usbip-allow-sync.path
```

Run an initial sync (writes `nft/usbip-allow.nft` and loads it):

```bash
AUT0HUB_ROOT=$(grep AUT0HUB_ROOT /etc/autohub-usbip.conf | cut -d= -f2-)
chmod +x ${AUT0HUB_ROOT}/bin/usbip-allow-sync            # required if clone lost exec bits
chmod +x ${AUT0HUB_ROOT}/bin/autobind.sh
sudo AUT0HUB_ROOT="$AUT0HUB_ROOT" ${AUT0HUB_ROOT}/bin/usbip-allow-sync
```

## 6. Verification Checklist

- `journalctl -u usbip-autohub@* -f` shows binds/unbinds when you plug in non-hub devices.
- `curl` requests reach the Windows listener referenced by `WIN_HOST/WIN_PORT`.
- `sudo nft list table inet usbipguard` matches the addresses inside `${AUT0HUB_ROOT}/config/clients.allow`.

## Maintenance Tips

- Update `${AUT0HUB_ROOT}/config/clients.allow` whenever Windows client IPs change; the path unit reapplies nftables instantly.
- Keep `/etc/autohub-usbip.conf` in sync when you relocate the repo or rename directories.
- `${AUT0HUB_ROOT}/bin/autobind.sh` skips hubs via `bDeviceClass == 0x09`. Review `journalctl -t usbip-autohub` if a device fails to bind.
- Consider wrapping TCP 3240 inside a VPN (WireGuard/IPsec) if the LAN is not fully trusted.
3. Deploy the service + path units:
