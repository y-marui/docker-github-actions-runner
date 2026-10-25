# Developing

## Verify a Change

~~~sh
pre-commit run --all-files                      # ShellCheck, gitleaks, charter checks
docker build -t actions-runner:dev .            # image builds (linux/amd64 on an amd64 host)
bash setup.sh install --dry-run OWNER/REPO      # show what install would do, without running it
bash tests/runner-ctl-test.sh                   # runner-ctl.sh decisions, with fake docker/curl (needs jq)
~~~

CI builds the image for linux/amd64 on pull requests that touch the image. The multi-arch
(amd64 and arm64) build and the push to GHCR run only on `main`
([publish.yml](.github/workflows/publish.yml)).

## Requirements

- [pre-commit](https://pre-commit.com/) for the hooks in
  [.pre-commit-config.yaml](.pre-commit-config.yaml)
- Docker, and an authenticated `gh` with admin access to a private repository, to try `setup.sh`

## Conventions

- `entrypoint.sh` runs inside the container as the non-root `runner` user. It must not need
  sudo, and the image must not mount the Docker socket.
- The runner runs from `/opt/runner` in the image. Registration state and work files live in the
  volume mounted at `/runner/actions-runner`; the entrypoint links the registration files into
  `/opt/runner` (only existing files: the runner crashes on a dangling link). The work folder is
  the absolute path on the volume, never a symlink: `actions/checkout` keys its git credentials on
  the workspace path, and git matches the resolved path, so a symlinked workspace fails to fetch. Do not copy the runner into the
  volume again (~450 MB per runner). The registration token is needed only for the first start
  and is never written to a file.
- `hooks/job-started.sh` (runner job-started hook) writes `pythonLocation` to `GITHUB_ENV` from the OS release,
  Python version and architecture. `pre-commit/action` keys its cache on `${{ env.pythonLocation }}`,
  which does not see the container environment, and without it a `~/.cache/pre-commit` saved by an older
  image is restored into a newer one. Keep it changing whenever the image's Python changes.
- `setup.sh` refuses public repositories. Keep that check.
- No comments that restate what the code does; comments explain non-obvious *why* only (see
  [docs/dev-charter/CODE_STYLE.md](docs/dev-charter/CODE_STYLE.md)).

## Updating dev-charter

Run `curl -fsSL https://raw.githubusercontent.com/y-marui/dev-charter/main/scripts/install.sh | bash`
(it detects the existing install and updates it with `git subtree pull`).
