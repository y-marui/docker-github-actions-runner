# docker-github-actions-runner

Linux self-hosted GitHub Actions runner as a Docker image, plus the script that registers it.
The image is published to GHCR for linux/amd64 and linux/arm64 (Raspberry Pi), so a new host
only needs Docker and `gh`; nothing is built locally.

~~~text
ghcr.io/y-marui/actions-runner:latest
~~~

The image is Ubuntu 24.04 with the runner, `git`, `gh`, `curl`, `jq`, `zip`, python (`pip`, `uv`),
node, `shellcheck`, `gitleaks`, `swiftlint`, and the shared libraries Qt tests load. It contains
no secrets: the registration token is passed at run time. It does not mount the Docker socket,
and the runner user has no sudo.

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

## Updating the image on a host

~~~sh
bash setup.sh pull
docker stop -t 30 ar-<repo>
docker rm ar-<repo>
bash setup.sh install OWNER/REPO
~~~

Do not use `docker rm -f`: stop the container first so the runner can finish its job. The
registration lives in the volume, so a re-created container does not need a new token.

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
