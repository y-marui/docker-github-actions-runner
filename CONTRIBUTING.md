# Contributing

## How to Contribute

Use GitHub Issues for proposals and tasks. For large changes (new image contents, changes to
how `setup.sh` registers runners), open an issue before submitting a PR. Small fixes and typos
can be submitted directly as a PR.

## Development Setup

See [README.md](README.md) for host setup, and [DEVELOPING.md](DEVELOPING.md) for
verification and conventions.

## Code Style

Follow [docs/dev-charter/CODE_STYLE.md](docs/dev-charter/CODE_STYLE.md). Shell scripts must pass
ShellCheck (run by pre-commit).

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) format
(e.g. `fix: ...`, `feat: ...`).

## Pull Request Checklist

See [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) for the current
checklist. Pull requests must not bypass hooks or checks.
