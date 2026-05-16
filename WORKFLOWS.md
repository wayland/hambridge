# Developer workflows — PR and release process

This file is the **human process** contributors and maintainers follow: what to run locally, how to
open a PR, and how to cut a release. The **normative build and CI description** (hosted runners,
Docker, Fedora/RPM, ARM, job order, artifact names, **`release-pins.json`**) is in
**`docs/developers/Specification.md`** — **§10.6**.

---

## Before you open a PR

1. **Build:** from the repo root, **`make`** (first run may need network for the pinned MQTT client zip).
2. **Test:** **`make test`** — **must pass** before you consider the branch ready for review (same gate
   CI will enforce; see Specification §10.4–§10.6).
3. **Sanity:** run the bridge against a local example config if you touched runtime behaviour
   (**`./build/hambridge --config ./config/hambridge.yaml.example`** or your own `hambridge.yaml`).

Install build dependencies as in **`docs/user/INSTALL.md`** and **`packaging/raspbian/README.md`**
so your machine matches what CI installs (FPC including **FPCUnit** / **fcl-fpcunit**, `libevdev-dev`,
`make`, `curl`, `unzip`, …). If **`make test`** errors that **fcl-fpcunit** was not found, install the
full distro **`fpc`** package set (not a minimal `fpc` metapackage that omits FPCUnit).

---

## Opening and landing a PR

1. Push your branch and open a **pull request** against the protected branch (e.g. **`main`**).
2. Wait for **GitHub Actions** (once **`.github/workflows/ci.yml`** exists per §10.6): the workflow
   **must** run **`make`** then **`make test`** as the primary gate.
3. Fix failures and push updates until checks are **green**.
4. Request review; respond to feedback.
5. **Merge** only after required checks pass (repository **branch protection** should require the
   **`build-and-test`** job or equivalent — configure in GitHub **Settings → Branches**).

Draft PRs: you may open a draft before tests pass, but **do not mark ready for merge** until
**`make test`** passes locally and in CI.

---

## Cutting a release (maintainer)

1. **Version alignment** — bump **`AppVersion`** in **`src/hambridge.lpr`**, **`RPM_VER`** in **`Makefile`**,
   **`Version`** in **`packaging/Redhat/hambridge.spec`**, add a stanza to **`packaging/debian/changelog`**,
   and update **`CHANGELOG.md`** (and **`ROADMAP.md`** if a milestone closes).
2. **Commit** the version bump on the release branch (usually **`main`**).
3. **Tag** — create an annotated tag **`vX.Y.Z`** matching **`AppVersion`** (e.g. app **`0.5.2`** → tag
   **`v0.5.2`** if that is your convention; the release workflow in §10.6.5 verifies tag vs files).
4. **Push the tag** — **`git push origin vX.Y.Z`** — to trigger the **release** workflow when it exists.
5. **Verify** the **GitHub Release** assets (tarball, **`SHA256SUMS`**, optional `.deb` / `.rpm`) and
   release notes.

If **`release-pins.json`** is in use, update any pins there when bumping bundled dependencies so CI
stays aligned (Specification §10.6.6).

---

## Where the automation is defined

| Topic | Location |
|--------|----------|
| Test layout, **`make test`**, fixtures, golden I/O | Specification **§10** |
| GitHub Actions: runners, Docker, ARM, PR/release jobs, artifacts, pins | Specification **§10.6** |
| Backlog / version milestones | **`ROADMAP.md`** |
| Workflow YAML (when added) | **`.github/workflows/*.yml`** |

---

## Related

- **`docs/developers/DEVELOPING.md`** — day-to-day clone, build, run.
- **`docs/user/INSTALL.md`** — dependencies.
