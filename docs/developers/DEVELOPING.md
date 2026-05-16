# Developing HaMBridge (Hardware-MQTT Bridge)

This document is for **building from source** and contributor-oriented setup. For what the
project does, see [README.md](../../README.md). Installation/deployment is in [INSTALL.md](../user/INSTALL.md).
End-user configuration is in [ConfigurationGuide.md](../user/ConfigurationGuide.md). **Release notes:**
[CHANGELOG.md](../../CHANGELOG.md). **Backlog / upcoming minors:** [ROADMAP.md](../../ROADMAP.md). For full
architecture and protocol contracts (implementers), see [Specification.md](Specification.md).

The product name is **HaMBridge**; the v0.1 build produces the `hambridge` binary.

## Toolchain (v0.1)

- **Linux** (v0.1 is Linux-only because of `libevdev`).
- **Free Pascal Compiler** 3.2.x or newer (`fpc`).
- **GNU Make** (`make`).
- **`curl`** and **`unzip`** — used once per clean tree to fetch the MQTT client zip.
- **MQTT client**: [prof7bit/fpc-mqtt-client](https://github.com/prof7bit/fpc-mqtt-client) is
  **downloaded when you run `make`**: the Makefile fetches a pinned release zip into
  `build/deps/`, checks **SHA256**, and unpacks it. The first build needs **network access**,
  `curl`, and `unzip`. Bump the tag and checksum in the `Makefile` when you intentionally
  upgrade the client.
- **`libevdev` shared library** (`libevdev.so.2`) in a standard library directory so the
  Makefile can link against it:

  - Debian / Ubuntu: `sudo apt install libevdev2` (runtime; enough to **build** and run)
  - Fedora: `sudo dnf install libevdev`
  - Arch: `sudo pacman -S libevdev`

  The Makefile passes `-l:libevdev.so.2` (no unversioned `libevdev.so` symlink required). Optional
  **development** packages (`libevdev-dev` / `libevdev-devel`) are only needed if you change the
  C binding or use other tooling that expects headers.

- An **MQTT broker** for local testing (e.g. Mosquitto).

## Build

From the repository root:

```bash
make            # builds ./build/hambridge
make test       # FPCUnit: builds ./build/hambridge_tests and runs all tests (needs fcl-fpcunit from your FPC install)
make clean      # removes ./build/
make run        # seeds config/*.yaml from *.example if missing; runs with explicit --config ./config/hambridge.yaml
```

**Fedora RPM (optional)** — on a Fedora/RHEL-family host with `rpm-build`, `git`, and the same
build deps as `make`:

```bash
make fedora-rpm    # git archive + rpmbuild into build/rpmbuild/{SOURCES,SRPMS,RPMS}
make fedora-test   # builds the RPM then smoke-tests (requires, paths, hambridge --version via rpm2cpio)
```

`make clean` removes `build/` including that rpmbuild tree. Bump `RPM_VER` in the `Makefile` when
you bump `AppVersion` in `src/hambridge.lpr` and `Version` in `packaging/Redhat/hambridge.spec`.

The Makefile invokes `fpc` with `-k-L<libdir> -k-l:libevdev.so.2` when it finds that shared
library under `/usr/lib64` or `/usr/lib/x86_64-linux-gnu`. Compiler flags and repository layout are
described in `Specification.md`.

**Fully offline builds:** after a successful `make` on a networked machine, the zip under
`build/deps/fpc-mqtt-client-*.zip` matches the `FPC_MQTT_SHA256` line in the `Makefile`. You can
copy that zip into the same path on an air-gapped tree (before `make`) so `curl` is never
invoked; `sha256sum` still validates the file before unzip.

## Source layout (v0.1)

See `Specification.md` for a high-level architecture and MQTT surface.

## Configuration (development copies)

Copy the committed YAML templates and edit:

```bash
cp config/hambridge.yaml.example config/hambridge.yaml
mkdir -p config/mappings
cp config/mappings/visca.yaml.example config/mappings/visca.yaml
```

**Discovery does not** look under **`./config/`** or the repo root: you **must** pass **`--config`**
(with a path, often **`./config/hambridge.yaml`**) or set **`BRIDGE_CONFIG`** to that path. Field
meanings and the full discovery list: **`ConfigurationGuide.md`**.

## Run (from a dev build)

Use an explicit config path (same as **`make run`**):

```bash
./build/hambridge --config ./config/hambridge.yaml
```

The **Pascal loader** must implement **`hambridge.yaml`** discovery and parsing as in
**`Specification.md`** and **`ConfigurationGuide.md`**; until that lands, the command above may fail
at startup when the binary still expects a different on-disk format.

## systemd / udev (production-style)

For the expected **systemd** deployment, unprivileged user **`hambridge`**, and **udev** rules
shipped as templates, follow [packaging/README.md](packaging/README.md).

## Manual / interactive use

If you run the binary as your own user (not via systemd), you still need access to the event
nodes. Options:

- Add your user to the **`input`** group (broad — readable access to many input devices):

  ```bash
  sudo usermod -aG input "$USER"
  # log out and back in for the new group to take effect
  ```

- Or use the same **udev** approach as production: a rule scoped to your device, with
  `GROUP=` set to a group your user belongs to.

## Input device permissions

The bridge must be able to read `/dev/input/event*`. See [README.md](../../README.md) for interactive
use vs systemd + `packaging/udev/`.

## License

Same as the project: GPL-3.0-or-later. See [LICENSE](../../LICENSE).
