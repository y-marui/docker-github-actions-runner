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

- `setup.sh uninstall` stops the container gracefully (`docker stop -t 30`) instead of
  `docker rm -f`.
