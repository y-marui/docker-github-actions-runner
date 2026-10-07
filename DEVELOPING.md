# Developing

## Verify a Change

~~~sh
pre-commit run --all-files                      # ShellCheck, gitleaks, charter checks
docker build -t actions-runner:dev .            # image builds (linux/amd64 on an amd64 host)
bash setup.sh install --dry-run OWNER/REPO      # show what install would do, without running it
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
- Registration state lives in the volume mounted at `/runner/actions-runner`; the token is
  needed only for the first start and is never written to a file.
- `setup.sh` refuses public repositories. Keep that check.
- No comments that restate what the code does; comments explain non-obvious *why* only (see
  [docs/dev-charter/CODE_STYLE.md](docs/dev-charter/CODE_STYLE.md)).

## Updating dev-charter

Run `curl -fsSL https://raw.githubusercontent.com/y-marui/dev-charter/main/scripts/install.sh | bash`
(it detects the existing install and updates it with `git subtree pull`).
