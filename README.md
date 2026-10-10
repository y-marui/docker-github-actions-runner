# docker-github-actions-runner

> **This is the reference (English) version.**
> The canonical (Japanese) version is [README-jp.md](README-jp.md).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/ci.yml)
[![Charter Check](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/dev-charter-check.yml/badge.svg)](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/dev-charter-check.yml)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/y-marui?style=social)](https://github.com/sponsors/y-marui)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-donate-yellow.svg)](https://www.buymeacoffee.com/y.marui)

Linux self-hosted GitHub Actions runner as a Docker image, plus the script that registers it.
The image is published to GHCR for linux/amd64 and linux/arm64 (Raspberry Pi), so a new host
only needs Docker and `gh`; nothing is built locally.

~~~text
ghcr.io/y-marui/actions-runner:latest
~~~

The image is Ubuntu 24.04 with the runner, `git`, `gh`, `curl`, `jq`, `zip`, python (`pip`, `uv`),
node, `shellcheck`, `gitleaks`, `swiftlint`, and the shared libraries Qt tests load. It contains
no secrets: the registration token is passed at run time. It does not mount the Docker socket,
and the runner user has no sudo. Rootless `podman` is included for building images in jobs.

## Runners per OS

| OS | How | Registration |
|---|---|---|
| macOS | native (LaunchDaemon) | dotfiles `macos/setup_actions_runner.sh` |
| Windows | native (Windows service) | dotfiles `windows/setup_actions_runner.ps1` |
| Linux | Docker, one container per repository | `setup.sh` in this repository |

## Security: never register a runner on a public repository

A self-hosted runner executes whatever the workflows of its repository say. On a public
repository, a pull request from a fork can run arbitrary code on your machine. `setup.sh install`
refuses public repositories. Register runners only on private repositories whose workflows only
you can edit.

## Adding a host

Requirements: Docker, and `gh` authenticated with admin access to the repositories.

~~~sh
git clone https://github.com/y-marui/docker-github-actions-runner
cd docker-github-actions-runner
bash setup.sh pull
bash setup.sh install OWNER/REPO...      # add --dry-run to preview
bash setup.sh status OWNER/REPO...
~~~

Runners are registered per repository (a personal account has no account-level runners). Each
container is named `ar-<repo>` and keeps its registration in the Docker volume `ar-<repo>`.
Workflows select the runner with `runs-on: [self-hosted, linux-sh]`.

Environment variables for `setup.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `RUNNER_LABEL` | `linux-sh` | label added to the runner |
| `RUNNER_HOST` | `hostname -s` | prefix of the runner name |
| `RUNNER_IMAGE` | `ghcr.io/y-marui/actions-runner:latest` | image to run |
| `RUNNER_CPUS` / `RUNNER_MEMORY` | unset | per-container limits, e.g. `2` / `4g` |
| `RUNNER_PODMAN` | `0` | `1` enables building images in jobs (see below) and adds the label `linux-podman` |

## Building images in jobs (rootless podman)

The image contains rootless `podman`, so a job can `podman build` a `Dockerfile` and
`podman run` the result without a Docker socket. This needs user namespaces and mounts, which
Docker's default capabilities, seccomp and AppArmor profiles block, so it is opt-in per runner:

~~~sh
RUNNER_PODMAN=1 bash setup.sh install OWNER/REPO
~~~

That container is started with `--device /dev/fuse`, `--cap-add SYS_ADMIN` and
`seccomp=unconfined`/`apparmor=unconfined` (not `--privileged`, and still without the socket) and gets the extra label `linux-podman`; runners
installed without the option are unchanged. Select it with
`runs-on: [self-hosted, linux-sh, linux-podman]`. Image storage lives in the runner's own
volume, so layers are cached across jobs.

~~~sh
podman build -t app:ci .
podman run -d --name app app:ci
podman healthcheck run app   # needs HEALTHCHECK in the Dockerfile and `podman build --format docker`
~~~

## Updating the image on a host

~~~sh
bash setup.sh pull
docker stop -t 30 ar-<repo>
docker rm ar-<repo>
bash setup.sh install OWNER/REPO
~~~

Do not use `docker rm -f`: stop the container first so the runner can finish its job. The
registration lives in the volume, so a re-created container does not need a new token.
The runner may log "A session for this runner already exists" for a couple of minutes while GitHub
expires the old session; it then reconnects on its own.

## Removing a runner

~~~sh
bash setup.sh uninstall OWNER/REPO
~~~

This deregisters the runner from GitHub, stops and removes the container, and deletes its volume.

## Publishing

`.github/workflows/publish.yml` builds and pushes the image to GHCR (`latest` and the runner
version) on changes to `Dockerfile` / `entrypoint.sh` on `main`, and weekly to pick up Ubuntu
updates. Pull requests only check that it builds.

The first push creates the package as private. Set it to public once under
*Packages > actions-runner > Package settings* so hosts can pull it without logging in.

## Versions

- `RUNNER_VERSION` in the `Dockerfile` pins the runner. The runner also updates itself at run
  time, so a stale pin is harmless; bump it now and then.
- Dependabot (`.github/dependabot.yml`) updates the Docker base image and the GitHub Actions
  used by the workflow. `SWIFTLINT_VERSION`, `GITLEAKS_VERSION` and `RUNNER_VERSION` are plain
  build arguments and are bumped by hand.

## License

[MIT](LICENSE)

---
*This document has a Japanese canonical version [README-jp.md](README-jp.md). Update both in the same commit when editing.*
