#!/usr/bin/env bash
# Register the runner on first start, then run it.
#
# Environment:
#   REPO_URL       Repository the runner serves, e.g. https://github.com/OWNER/REPO
#   RUNNER_TOKEN   Registration token (first start only) or removal token (`remove`)
#   RUNNER_NAME    Runner name shown on GitHub (default: container hostname)
#   RUNNER_LABELS  Extra comma-separated labels (default: none)
#
# Usage:
#   entrypoint.sh          register if needed, then run
#   entrypoint.sh remove   deregister from GitHub and drop the local state
set -euo pipefail

DATA_DIR=/data
STATE_FILES=(.runner .credentials .credentials_rsaparams)

cd /home/runner

link_state() {
  local f
  for f in "${STATE_FILES[@]}"; do
    [ -e "${DATA_DIR}/${f}" ] && ln -sf "${DATA_DIR}/${f}" "$f"
  done
  return 0
}

if [ "${1:-}" = "remove" ]; then
  [ -f "${DATA_DIR}/.runner" ] || { echo "error: runner is not registered" >&2; exit 1; }
  : "${RUNNER_TOKEN:?RUNNER_TOKEN (removal token) is required}"
  link_state
  ./config.sh remove --token "$RUNNER_TOKEN"
  rm -f "${DATA_DIR}/.runner" "${DATA_DIR}/.credentials" "${DATA_DIR}/.credentials_rsaparams"
  exit 0
fi

if [ ! -f "${DATA_DIR}/.runner" ]; then
  : "${REPO_URL:?REPO_URL is required}"
  if [[ ! "$REPO_URL" =~ ^https://[^/]+/[^/]+/[^/]+$ ]]; then
    echo "error: REPO_URL must look like https://github.com/OWNER/REPO (got: ${REPO_URL})" >&2
    exit 1
  fi
  : "${RUNNER_TOKEN:?RUNNER_TOKEN (registration token) is required on first start}"
  args=(--unattended --url "$REPO_URL" --token "$RUNNER_TOKEN" --name "${RUNNER_NAME:-$(hostname)}" --replace)
  [ -n "${RUNNER_LABELS:-}" ] && args+=(--labels "$RUNNER_LABELS")
  ./config.sh "${args[@]}"
  for f in "${STATE_FILES[@]}"; do
    [ -e "$f" ] && mv "$f" "${DATA_DIR}/${f}"
  done
fi

link_state
exec ./run.sh
