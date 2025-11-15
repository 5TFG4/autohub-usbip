# AutoHub USB/IP

AutoHub pairs a Raspberry Pi (USB/IP server) with a Windows client to mimic a "plugged-in" USB experience across the LAN. Newly attached USB devices are exported from the Pi, white-listed Windows hosts receive HTTP events, and `usbip` attaches or detaches devices with zero manual steps.

> **Scope & Safety**
>
> * Only deploy on a trusted LAN: the USB/IP protocol offers **no encryption or authentication**, and traffic is sent in plain text. Use at your own risk.
> * Firewall rules and IP allow-lists reduce exposure but cannot compensate for an untrusted network.
> * This project does **not guarantee compatibility with every USB/IP implementation or every Windows release**; validate with your hardware before depending on it.

## Highlights

- **Sub-second auto attach**: udev + systemd on the Pi detect devices, bind them to `usbipd`, and POST events to Windows within ~1s.
- **Auto heal on login/unlock**: Windows scheduled tasks run `sync.ps1` to re-attach exported devices, keeping ports in sync after user transitions.
- **Layered allow-lists**: nftables on the Pi and Windows Firewall + application checks enforce IPv4 white-lists for TCP 3240 and 59876.
- **Udev-safe design**: network calls happen in systemd services, never directly inside udev rules, satisfying udev best practices.
- **Stateless scripts**: everything is config-file driven (`clients.allow` and script parameters) for easy customization.

## Repository Layout

```
autohub-usbip/
├── README.md
├── LICENSE
├── docs/
│   ├── INSTALL-pi.md
│   ├── INSTALL-win.md
│   ├── TROUBLESHOOT.md
│   └── DESIGN-notes.md
├── pi/
│   ├── autobind.sh
│   ├── 99-usbip-autobind.rules
│   ├── usbip-retrigger.service
│   ├── usbip-allow-sync
│   ├── usbip-allow-sync.service
│   ├── usbip-allow-sync.path
│   └── examples/
│       └── clients.allow.sample
└── windows/
    ├── listener.ps1
    ├── sync.ps1
    ├── update-firewall.ps1
    └── examples/
        └── clients.allow.sample
```

## Quick Start

1. **Pi setup**: follow `docs/INSTALL-pi.md` to install usbip/nftables, drop the scripts in `/usr/local`, enable the systemd units, and seed the allow-list.
2. **Windows setup**: follow `docs/INSTALL-win.md` to install USB/IP drivers, register the event listener + firewall rules, and configure scheduled tasks.
3. **Allow-lists**: keep `/etc/usbip-autohub/clients.allow` (Pi) and `C:\Autohub\clients.allow` (Windows) in sync with the real client/server IPs.
4. **Validation**: use the "Verification & Daily Ops" sections in both install guides to confirm event delivery and automatic attach/detach flows.

## Documentation Map

- `docs/INSTALL-pi.md`: step-by-step provisioning on Raspberry Pi OS/Debian, including nftables enforcement.
- `docs/INSTALL-win.md`: Windows client automation covering HttpListener, URLACL, firewall, and scheduled tasks.
- `docs/TROUBLESHOOT.md`: checklist for the most common failure modes (firewalls, udev, parsing).
- `docs/DESIGN-notes.md`: reasoning behind architecture selections, security assumptions, and extensibility ideas.

## Contributing & License

Issues and pull requests are welcome—please focus on reproducibility and security implications. This repository is licensed under the MIT License (see `LICENSE`).
