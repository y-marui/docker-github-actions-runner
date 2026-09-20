# docker-github-actions-runner

Docker setup for a self-hosted GitHub Actions runner. It builds on the official
[`ghcr.io/actions/actions-runner`](https://github.com/actions/runner) image (linux/amd64 and
linux/arm64), adds the GitHub CLI, and registers itself on first start. The same setup runs
on an Apple Silicon Mac and on a 64-bit Raspberry Pi.

The image bundles `git`, `curl`, `jq`, `python3` and `gh`. It does not mount the Docker socket
and drops privilege escalation (`no-new-privileges`), so a job can only reach what is inside
the container.

## Security: never register a runner on a public repository

A self-hosted runner executes whatever the workflows of its repository say. On a public
repository, a pull request from a fork can run arbitrary code on your machine. Register runners
only on private repositories whose workflows only you can edit.

The registration state of the runner is stored in a Docker volume, not in this repository.
Keep `.env` files out of Git (they are gitignored).

## Requirements

- Docker with Compose v2
- Admin access to the repository the runner will serve (needed to obtain tokens)

## Usage

Runners are registered per repository (a personal account has no account-level runners).

1. Create an env file and fill it in.

   ~~~sh
   cp .env.example .env
   ~~~

   - `REPO_URL`: the repository the runner serves
   - `RUNNER_LABELS`: an extra label such as `my-label`; workflows select the runner with
     `runs-on: [self-hosted, my-label]`
   - `RUNNER_TOKEN`: a registration token (expires after 1 hour)

   ~~~sh
   gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token
   ~~~

2. Build and start.

   ~~~sh
   docker compose up -d --build
   ~~~

3. Check that the runner is online under *Settings > Actions > Runners* of the repository.
   Then delete `RUNNER_TOKEN` from the env file. It is only used on the first start; the
   registration is kept in the `runner-data` volume and survives restarts and re-creation.

### Several runners on one host

Use one Compose project and one env file per repository:

~~~sh
docker compose -p runner-a --env-file .env.a up -d --build
docker compose -p runner-b --env-file .env.b up -d --build
~~~

## Deregistering

Deregister the runner from GitHub and clear its local state:

~~~sh
TOKEN=$(gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token)
RUNNER_TOKEN=$TOKEN docker compose run --rm runner remove
docker compose down
~~~

If the container is already gone, delete the runner on the repository's Runners page instead.

## Moving to another host

1. Deregister on the old host (above) and stop it.
2. Clone this repository on the new host, create the env file and start it (Usage).

Workflows that select the runner by label need no change.

## Updating

The base image tag is pinned in the `Dockerfile` (`RUNNER_VERSION`). Bump it and rebuild:

~~~sh
docker compose build --pull && docker compose up -d
~~~

The runner also updates itself at run time; a re-created container starts from the pinned
version again and self-updates.

## License

[MIT](LICENSE)
