# HaMBridge — `packaging/`

**HaMBridge** (Hardware-MQTT Bridge) is the product name for this daemon. Install the `hambridge`
binary to `/usr/local/bin` (or another path on `PATH`); config paths here follow the HaMBridge
layout under `/etc/hambridge/`.

This directory holds **systemd**, **sysusers**, **tmpfiles**, and **udev** templates for
installing the service on Linux; they are not compiled into the binary.

Contents:

| Path | Purpose |
|------|---------|
| [systemd/hambridge.service](systemd/hambridge.service) | systemd unit: runs the bridge after network, restarts on failure |
| [systemd/sysusers.d/hambridge.conf](systemd/sysusers.d/hambridge.conf) | Declares unprivileged `hambridge` user and group |
| [systemd/tmpfiles.d/hambridge.conf](systemd/tmpfiles.d/hambridge.conf) | State directory `/var/lib/hambridge` |
| [udev/70-hambridge-input.rules](udev/70-hambridge-input.rules) | **Template** udev rules so `hambridge` can open specific `/dev/input/event*` nodes |

Install order (summary):

1. Build or install the binary (see [DEVELOPING.md](../DEVELOPING.md)); symlink or copy to
   `/usr/local/bin/hambridge` or adjust `ExecStart=` in the unit file.
2. `sudo cp systemd/sysusers.d/hambridge.conf /usr/lib/sysusers.d/` then
   `sudo systemd-sysusers` (or reboot) to create `hambridge:hambridge`.
3. `sudo cp systemd/tmpfiles.d/hambridge.conf /usr/lib/tmpfiles.d/` then
   `sudo systemd-tmpfiles --create` for `/var/lib/hambridge`.
4. Copy and edit [udev/70-hambridge-input.rules](udev/70-hambridge-input.rules) into
   `/etc/udev/rules.d/`, **customise the match** for your hardware, then reload udev.
5. Install `bridge.json` and `devices.json` under `/etc/hambridge/` (see examples in repo root).
6. `sudo cp systemd/hambridge.service /etc/systemd/system/` → `sudo systemctl daemon-reload` →
   `sudo systemctl enable --now hambridge.service`.

Distro packages may install these files directly under `/usr/lib/…` or `/etc/…` and adjust paths.
