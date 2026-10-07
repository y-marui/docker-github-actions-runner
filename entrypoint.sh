#!/usr/bin/env bash
# Register (first start only) and run a GitHub Actions runner for one repository.
# Registration state is kept in the volume mounted at RUNNER_DIR, so restarts and
# container re-creation reuse it. REG_TOKEN is only needed for the first start.
#
# Environment:
#   REPO_URL       https://github.com/OWNER/REPO (required)
#   RUNNER_NAME    runner name (required)
#   RUNNER_LABELS  comma-separated labels (default: linux-sh)
#   REG_TOKEN      one-time registration token (required until registered)
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-/runner/actions-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-linux-sh}"
: "${REPO_URL:?REPO_URL is required}"
if [[ ! "${REPO_URL}" =~ ^https://[^/]+/[^/]+/[^/]+$ ]]; then
  echo "error: REPO_URL must look like https://github.com/OWNER/REPO (got: ${REPO_URL})" >&2
  exit 1
fi
: "${RUNNER_NAME:?RUNNER_NAME is required}"

mkdir -p "${RUNNER_DIR}"
cd "${RUNNER_DIR}"

# Refresh runner binaries when the image ships a different version (config files stay).
if [[ "$(cat .image-version 2>/dev/null || true)" != "$(cat /opt/runner/.image-version)" ]]; then
  cp -a /opt/runner/. "${RUNNER_DIR}/"
fi

if [[ ! -f .runner ]]; then
  : "${REG_TOKEN:?REG_TOKEN is required for the first start}"
  ./config.sh --unattended --replace \
    --url "${REPO_URL}" --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --work _work
fi

# exec so SIGTERM from `docker stop` reaches the listener. No deregistration on stop.
exec ./run.sh
