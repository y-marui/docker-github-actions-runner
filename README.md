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

The image is Ubuntu 25.10 with the runner, `git`, `gh`, `curl`, `jq`, `zip`, python (`pip`, `uv`),
node, `shellcheck`, `gitleaks`, `swiftlint`, and the shared libraries Qt tests load. It contains
no secrets: the registration token is passed at run time. It does not mount the Docker socket,
and the runner user has no sudo. Rootless `podman` is included for building images in jobs.

## Runners per OS

| OS | How | Registration |
|---|---|---|
| macOS | native (LaunchDaemon) | dotfiles `macos/setup_actions_runner.sh` |
| Windows | native (Windows service) | dotfiles `windows/setup_actions_runner.ps1` |
| Linux | Docker, one or more containers per repository | `setup.sh` in this repository |

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
The volume holds only the registration and the job workspace; the runner itself is the one in the
image, so 24 runners on a host do not need 24 copies of it (~450 MB each).
Workflows select the runner with `runs-on: [self-hosted, linux-sh]`.

Environment variables for `setup.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `RUNNER_LABEL` | `linux-sh` | label added to the runner |
| `RUNNER_HOST` | `hostname -s` | prefix of the runner name |
| `RUNNER_IMAGE` | `ghcr.io/y-marui/actions-runner:latest` | image to run |
| `RUNNER_CPUS` / `RUNNER_MEMORY` | unset | per-container limits, e.g. `2` / `4g` |
| `RUNNER_REPLICAS` | `1` | containers per repository (see below) |
| `RUNNER_PODMAN` | `0` | `1` enables building images in jobs (see below) and adds the label `linux-podman` |

### More than one runner per repository

A runner handles one job at a time, so a repository's concurrency equals the number of runners
registered for it across all hosts. For a repository whose CI queues behind a few runners, raise
`RUNNER_REPLICAS` on the main host:

~~~sh
RUNNER_REPLICAS=3 bash setup.sh install OWNER/REPO
~~~

The first container keeps the name `ar-<repo>`; the others are `ar-<repo>-2`, `ar-<repo>-3` (the
runner names get the same suffix), each with its own volume. `install` skips containers that
already exist, so raising the count on an installed repository only adds the new ones, and
`status` and `uninstall` cover all replicas. `runner-ctl.sh` (see "Idle stop and on-demand start") stops idle containers, starts them when
jobs queue up, and on the primary host can leave `ar-<repo>` running and manage only the extras.
Avoid repository names that end in `-<number>` (`foo` with
replicas and `foo-2` would share a container name).

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
A volume made before the runner was shared still holds a full copy of it; the first start with the
new image deletes that copy and keeps the registration.
A normal stop (`docker stop`) lets the runner close its session, so the new container is online
within seconds. After a crash or a kill, the runner may log "A session for this runner already
exists" for a couple of minutes while GitHub expires the old session; it then reconnects on its own.

## Idle stop and on-demand start

Optional. When one always-on host and smaller hosts (such as Raspberry Pis) register the same
repositories, GitHub gives a job to any idle runner with the label, so the small hosts take jobs
at random and every container keeps a listener running. `runner-ctl.sh` keeps the small hosts
quiet. On the primary host, set `RUNNER_CTL_KEEP_PRIMARY=1`: the first container of each repository
(`ar-<repo>`) stays up, and only the extra replicas (`ar-<repo>-2`, ... from `RUNNER_REPLICAS`) are
stopped when idle and started when jobs queue up.

- **Stop**: a running `ar-*` container with no job for `RUNNER_CTL_IDLE_MINUTES` is stopped with
  `docker stop -t 30`. Containers are never removed; the registration stays in the volume.
- **Start**: a stopped container is started when a job for its repository that this host can run
  (labels `self-hosted`, `linux`, the architecture, `RUNNER_LABEL`) has been queued for at least
  `RUNNER_CTL_START_DELAY` seconds, up to `RUNNER_CTL_MAX_RUNNING` running containers. One stopped
  container is started per waiting job, so a single job does not wake every replica.
- **Keepalive**: GitHub deletes the registration of a non-ephemeral runner that has not connected for
  14 days. A container stopped for `RUNNER_CTL_KEEPALIVE_DAYS` (default 7) is started even with no
  job, oldest first and within `RUNNER_CTL_MAX_RUNNING`; the idle stop then stops it again. The
  last connection is taken from the container's last stop time (its creation time if it never ran),
  so it needs no state file.
- **Priority**: give each host a different `RUNNER_CTL_START_DELAY` (for example 60 and 120
  seconds, or a few seconds on the primary host's extra replicas). A delay shorter than the timer
  interval has no effect, because a start is only decided at a tick. The primary host takes a job at once; the host with the shorter delay is the next
  choice; the other starts a runner only if nobody took the job.

It touches only the `ar-*` containers of the repositories you list, and checks the queue with
conditional requests (a `304` does not count against the rate limit).

~~~sh
sudo apt-get install -y jq curl                  # docker is already there
mkdir -p ~/.config/runner-ctl
cp systemd/runner-ctl.env.example ~/.config/runner-ctl/env     # edit the paths and numbers
printf '%s\n' OWNER/REPO ... > ~/.config/runner-ctl/repos     # the repositories of this host
install -m 600 /dev/null ~/.config/runner-ctl/token            # then paste the token into it
bash runner-ctl.sh status
bash runner-ctl.sh tick --dry-run                              # prints what it would do
~~~

The token is a fine-grained personal access token with read-only *Actions* permission on those
repositories. Keep it, the repository list and the env file outside any repository. To run it every
minute, copy `systemd/runner-ctl.service` and `systemd/runner-ctl.timer` to `~/.config/systemd/user/`,
fix the path in the service, then:

~~~sh
systemctl --user daemon-reload && systemctl --user enable --now runner-ctl.timer
loginctl enable-linger "$USER"                    # keep the timer running without a login
~~~

| Variable | Default | Meaning |
|---|---|---|
| `RUNNER_CTL_REPOS_FILE` / `RUNNER_CTL_REPOS` | required | repositories (`OWNER/REPO`), one per line in the file, or space-separated |
| `RUNNER_CTL_TOKEN_FILE` | required | file with the token (mode 600) |
| `RUNNER_CTL_IDLE_MINUTES` | `15` | stop a runner after this many idle minutes |
| `RUNNER_CTL_START_DELAY` | `60` | start a runner for a job queued at least this many seconds |
| `RUNNER_CTL_MAX_RUNNING` | `4` | upper bound on running containers that this script manages |
| `RUNNER_CTL_KEEPALIVE_DAYS` | `7` | start a container stopped this long even with no job (`0` disables) |
| `RUNNER_CTL_KEEP_PRIMARY` | `0` | `1` leaves `ar-<repo>` (the first container) alone; for the primary host |
| `RUNNER_CTL_STATE_DIR` | `~/.local/state/runner-ctl` | state and API cache |
| `RUNNER_LABEL` | `linux-sh` | the label of this host's runners (as for `setup.sh`) |

A stopped runner is offline, so a job waits for it. After a normal stop the runner is online again
within seconds of the start (see "A session for this runner already exists" above for the case of
a crash or a kill).

### Tuning the delays

GitHub gives a queued job to any idle runner with the label and does not tell you which one; the
only way to prefer a host is to keep the others from starting early. A measured example (11 jobs per
run, one repository, 4 replicas on an amd64 primary host, two Raspberry Pis as overflow):

- A Pi start delay of 60 s let a Raspberry Pi pick up a job that the primary host would have
  finished in about 35 s; it took 206 s there, and the Pi stayed online for its idle time and also
  took the next job. The run took 496 s instead of about 100 s.
- With the Pi delay at 240 s and its idle stop at 5 minutes, every job ran on the primary host and
  the run took 89 to 101 s.

So: keep the delay of the slower hosts well above the cold start of the faster host's extra
replicas (roughly 20 to 60 s with a 20 s timer), and a short idle stop on the slower hosts. For the
extra replicas of the primary host, a short delay (a few seconds) and a longer idle stop (about 10
minutes; an idle runner is about 90 MiB) keep them warm for bursts of pushes; a cold start adds
roughly 15 to 60 s to the first job. Run the timer more often on the primary host (for example every
20 s) than on the secondary hosts.

## Removing a runner

~~~sh
bash setup.sh uninstall OWNER/REPO
~~~

This deregisters the runners from GitHub (every replica, starting a stopped container first), stops
and removes the containers, and deletes their volumes. To drop only the extra replicas of a
repository, deregister each one by hand and keep `ar-<repo>`:

~~~sh
token=$(gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token)
docker start ar-<repo>-2 && sleep 3
docker exec ar-<repo>-2 ./config.sh remove --token "$token"
docker stop -t 30 ar-<repo>-2 && docker rm ar-<repo>-2 && docker volume rm ar-<repo>-2
~~~

If you only stop `runner-ctl` instead, the stopped extras are harmless; GitHub deletes their
registration after 14 days.

## Publishing

`.github/workflows/publish.yml` builds and pushes the image to GHCR (`latest` and the runner
version) on changes to `Dockerfile` / `entrypoint.sh` on `main`, and weekly to pick up Ubuntu
updates. Pull requests only check that it builds.

The first push creates the package as private. Set it to public once under
*Packages > actions-runner > Package settings* so hosts can pull it without logging in.

## Versions

- `RUNNER_VERSION` in the `Dockerfile` pins the runner. The runner also updates itself at run
  time, so a stale pin is harmless; bump it now and then. A self-update is written to the container
  layer (~450 MB per container), which re-creating the container with a fresh image discards.
- Dependabot (`.github/dependabot.yml`) updates the Docker base image and the GitHub Actions
  used by the workflow. `SWIFTLINT_VERSION`, `GITLEAKS_VERSION` and `RUNNER_VERSION` are plain
  build arguments and are bumped by hand.

## License

[MIT](LICENSE)

---
*This document has a Japanese canonical version [README-jp.md](README-jp.md). Update both in the same commit when editing.*
