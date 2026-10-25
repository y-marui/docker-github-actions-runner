# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- `pythonLocation` is derived from the OS release, Python version and architecture at start, so
  `pre-commit/action` no longer restores a `~/.cache/pre-commit` saved by an older image (its
  virtualenvs failed with `libpython3.14.so.1.0: cannot open shared object file`).

### Added

- Shared libraries and Liberation fonts for headless Chromium tests, allowing jobs to install
  their pinned Playwright browser without sudo.

- README: "Tuning the delays", with measured results of start delays and idle stops.
- `runner-ctl.sh` keepalive (`RUNNER_CTL_KEEPALIVE_DAYS`, default 7): starts a container that has been
  stopped for that long so GitHub does not delete its registration after 14 days without a connection.
  `setup.sh uninstall` now starts a stopped container before deregistering it.
- `runner-ctl.sh` handles replicas (`ar-<repo>-N`), starts one per waiting job, and with
  `RUNNER_CTL_KEEP_PRIMARY=1` runs on the primary host, managing only the extra replicas.
- `RUNNER_REPLICAS` for `setup.sh`: run several runner containers per repository (`ar-<repo>`,
  `ar-<repo>-2`, ...) to raise a heavy repository's concurrency on the main host.
- `runner-ctl.sh` for secondary hosts: stops runner containers that have been idle and starts
  stopped ones when a job has been queued, with a per-host start delay as priority and a cap on
  running containers. systemd units and a settings example are in `systemd/`.
- Rootless `podman` in the image, and `RUNNER_PODMAN=1 setup.sh install` to run a runner that can
  build and start images without a Docker socket (label `linux-podman`).
- The Linux runner image is published to GHCR (`ghcr.io/y-marui/actions-runner`, linux/amd64
  and linux/arm64); `setup.sh pull` fetches it.
- `setup.sh`, the image and the entrypoint moved here from the dotfiles repository.
- dev-charter (full) adopted: CI with a `gate` job, charter checks, issue and PR templates.

### Fixed

- Bundle SwiftLint's libxml2/ICU compatibility libraries on Ubuntu 26.04. Verify exported images
  and both native architectures before promoting published tags.

- `docker stop` now stops the runner gracefully (about 1 s, exit code 0) instead of waiting for the
  timeout and killing it (31 s, exit code 137). A killed runner left its session on GitHub, so a
  restart waited about two minutes ("A session for this runner already exists"); after a graceful
  stop it is online again in seconds. The entrypoint runs `run.sh` as a child and sends SIGTERM to
  the listener directly, because `run.sh` does not pass it on.

### Changed

- The base image is now Ubuntu 26.04 LTS (was 24.04); `libicu74` is now `libicu78`. Dependabot skips
  Ubuntu versions newer than 26.04, so interim releases such as 25.10 are not proposed.
- The runner binaries are no longer copied into every volume. Each volume holds only the
  registration and work files (tens of KB), and a volume made earlier is slimmed down on its first
  start. A host with 24 runners no longer needs ~11 GB for them. The working directory of the
  image is now `/opt/runner`. The work folder is the absolute path on the volume (existing
  registrations are rewritten), because `actions/checkout` fails to fetch from a workspace reached
  through a symlink.
- `setup.sh uninstall` stops the container gracefully (`docker stop -t 30`) instead of
  `docker rm -f`.
