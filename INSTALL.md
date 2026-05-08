# Installing HaMBridge

Preferred installation is via **distro packages** (RPM/DEB), so systemd units, sysusers/tmpfiles, and udev templates land in the right places.

## Fedora / RHEL-family (RPM)

- **Build RPM from source checkout**:

```bash
make fedora-rpm
```

- Install the resulting RPM from `build/rpmbuild/RPMS/…`, then follow `packaging/README.md` if you need to customize udev rules or config placement.

## Debian / Raspberry Pi OS (DEB)

See `packaging/raspbian/README.md` for the up-to-date Debian build flow.

## Manual install (not preferred)

If you are not using distro packages, follow the ordered checklist in `packaging/README.md`:

- install the `hambridge` binary
- install sysusers/tmpfiles snippets (user + state dir)
- install a **narrow** udev rule for only the intended input devices
- install `/etc/hambridge/bridge.json` and `/etc/hambridge/devices.json`
- enable and start `hambridge.service`

