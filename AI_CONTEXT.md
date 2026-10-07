## Reference Order

AI reads the following in order at the start of a task:

1. `README.md` (overview, host setup)
2. `DEVELOPING.md` (build, verification, conventions)

Read as needed:
- `CONTRIBUTING.md` (PR/Issue rules)
- `docs/dev-charter/CHARTER_INDEX.md` (find the relevant charter topic, then read only that file)

## Project Overview

Docker image for a Linux self-hosted GitHub Actions runner, and `setup.sh`, which registers
one container per repository. The image is published to GHCR as
`ghcr.io/y-marui/actions-runner` (linux/amd64 and linux/arm64). This repository is the
source of truth for the image and the script; the macOS and Windows runners are native and
live in the dotfiles repository.

### Technology Stack

- Docker (Ubuntu 24.04 base, GitHub Actions runner), Bash (`setup.sh`, `entrypoint.sh`)
- GitHub Actions (`ci.yml`, `publish.yml`, `dev-charter-check.yml`, `auto-assign-self.yml`)

### Main Directories

| Path | Role |
|---|---|
| `Dockerfile` | The runner image |
| `entrypoint.sh` | Registers the runner on first start, then runs it |
| `setup.sh` | Host-side install / status / uninstall of runner containers |
| `docs/dev-charter/` | Shared dev-charter (`git subtree`, see below) |

## Applied Charter Principles

- Charter reference: use `docs/dev-charter/CHARTER_INDEX.md` to find the relevant topic, then read only that file
- YAGNI, minimal diff scope, reuse existing patterns before adding new ones — `docs/dev-charter/PRINCIPLES.md`
- Secrets and pre-commit security gates — `docs/dev-charter/SECURITY_POLICY.md`
- CI structure, `gate` job, Ruleset — `docs/dev-charter/topics/CI_POLICY.md`
- Public-facing text (README, commit/PR text) is English; `README-jp.md` is the canonical Japanese version — `docs/dev-charter/LANGUAGE_POLICY.md`
- Do not directly edit files under `docs/dev-charter/`; changes go through an Issue in the dev-charter repository and `git subtree pull`

## Document Sync Rule

When a spec, rule, or structural change happens, update the related documentation
in the same piece of work. This includes files under `docs/` as well as root files
such as `AI_CONTEXT.md` and `README.md` (and its pair `README-jp.md`).

## Project-Specific Rules

- This repository is public. Never register a runner on a public repository, and never set the
  `LINUX_RUNNER` variable here: CI runs on GitHub-hosted runners.
- The image must not contain secrets. The registration token is passed at run time only.
- A pushed workflow that uses a non-`actions/*` action needs that action in the repository's
  Actions allow list first (`docs/dev-charter/topics/GITHUB_SETTINGS.md`); otherwise the run
  fails with `startup_failure`.
- Runner versions (`RUNNER_VERSION`, `GITLEAKS_VERSION`, `SWIFTLINT_VERSION`) are build arguments
  bumped by hand. Dependabot updates only the Docker base image and GitHub Actions.
- Ubuntu base major upgrades are not a plain bump (package names such as `libicu74` change).
  Dependabot ignores the 26.04 major update; do it by hand together with the SwiftLint image.
- Changing `setup.sh` behavior or the image's contents: update `README.md` and `README-jp.md`
  in the same change.

## AI Tool Assignments

- **Tools in use**: Claude Code, Codex, GitHub Copilot, Gemini CLI
- **Canonical responsibilities**: `docs/dev-charter/AI_COLLABORATION_RULES.md`, "AI Tool Responsibilities" and "Rules for Multi-AI Usage"
- **Project-specific overrides**: none

## Prohibited Actions

- Committing secrets or credentials (registration tokens included)
- Registering a self-hosted runner on a public repository
- Direct edits under `docs/dev-charter/`
