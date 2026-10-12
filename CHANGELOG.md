# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Rootless `podman` in the image, and `RUNNER_PODMAN=1 setup.sh install` to run a runner that can
  build and start images without a Docker socket (label `linux-podman`).
- The Linux runner image is published to GHCR (`ghcr.io/y-marui/actions-runner`, linux/amd64
  and linux/arm64); `setup.sh pull` fetches it.
- `setup.sh`, the image and the entrypoint moved here from the dotfiles repository.
- dev-charter (full) adopted: CI with a `gate` job, charter checks, issue and PR templates.

### Changed

- The runner binaries are no longer copied into every volume. Each volume holds only the
  registration and work files (tens of KB), and a volume made earlier is slimmed down on its first
  start. A host with 24 runners no longer needs ~11 GB for them. The working directory of the
  image is now `/opt/runner`. The work folder is the absolute path on the volume (existing
  registrations are rewritten), because `actions/checkout` fails to fetch from a workspace reached
  through a symlink.
- `setup.sh uninstall` stops the container gracefully (`docker stop -t 30`) instead of
  `docker rm -f`.
