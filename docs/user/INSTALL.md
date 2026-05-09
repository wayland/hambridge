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
- install configuration under **`/etc/hambridge/config/`**: **`hambridge.yaml`** (**`bridge`**,
  **`device_mappings`**, **`buses`**, **`devices`**, **`evdev`**) plus **`mappings/visca.yaml`**
  (or the path set in **`device_mappings.visca`**). Use the **`*.example`** files under **`config/`** in the source
  tree as templates only; installed paths match **`/etc/…`**, not the checkout. The shipped **`hambridge.service`**
  passes **`--config /etc/hambridge/config/hambridge.yaml`**. For runs from a source tree without installing,
  use **`--config`** or **`BRIDGE_CONFIG`** (see **[ConfigurationGuide.md](ConfigurationGuide.md)** in this folder).
- enable and start `hambridge.service`

