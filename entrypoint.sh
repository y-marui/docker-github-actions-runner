#!/usr/bin/env bash
# Register (first start only) and run a GitHub Actions runner for one repository.
# The runner binaries live in the image (/opt/runner) and are used in place. Registration and
# work files live in the volume mounted at RUNNER_DIR, so restarts and container re-creation reuse
# the registration. REG_TOKEN is only needed for the first start.
#
# Environment:
#   REPO_URL       https://github.com/OWNER/REPO (required)
#   RUNNER_NAME    runner name (required)
#   RUNNER_LABELS  comma-separated labels (default: linux-sh)
#   REG_TOKEN      one-time registration token (required until registered)
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-/runner/actions-runner}"
RUNNER_HOME="${RUNNER_HOME:-/opt/runner}"
RUNNER_LABELS="${RUNNER_LABELS:-linux-sh}"
: "${REPO_URL:?REPO_URL is required}"
if [[ ! "${REPO_URL}" =~ ^https://[^/]+/[^/]+/[^/]+$ ]]; then
  echo "error: REPO_URL must look like https://github.com/OWNER/REPO (got: ${REPO_URL})" >&2
  exit 1
fi
: "${RUNNER_NAME:?RUNNER_NAME is required}"

mkdir -p "${RUNNER_DIR}"

# Volumes created before the binaries were shared hold a full copy of them (~450 MB each).
# Drop it; the registration and work files stay.
for f in bin externals config.sh env.sh run.sh run-helper.sh run-helper.cmd.template \
  run-helper.sh.template safe_sleep.sh svc.sh .image-version; do
  rm -rf "${RUNNER_DIR:?}/${f}"
done

# Link the registration files into the runner directory. Only files that exist are linked: the
# runner fails on a dangling link, and writes real files while registering. A real file the
# runner wrote (or replaced a link with) is moved to the volume first.
link_state() {
  local f
  for f in .runner .credentials .credentials_rsaparams .env .path; do
    if [[ -f "${RUNNER_HOME}/${f}" && ! -L "${RUNNER_HOME}/${f}" ]]; then
      mv -f "${RUNNER_HOME}/${f}" "${RUNNER_DIR}/${f}"
    fi
    if [[ -f "${RUNNER_DIR}/${f}" ]]; then
      ln -sfn "${RUNNER_DIR}/${f}" "${RUNNER_HOME}/${f}"
    else
      rm -f "${RUNNER_HOME}/${f}"
    fi
  done
  mkdir -p "${RUNNER_DIR}/_diag"
  ln -sfn "${RUNNER_DIR}/_diag" "${RUNNER_HOME}/_diag"
}

# The work folder must be the real path on the volume, not a link into it: actions/checkout
# stores git credentials under includeIf "gitdir:<workspace>/.git", and git matches that against
# the resolved path, so a workspace reached through a symlink gets no credentials.
WORK_DIR="${RUNNER_DIR}/_work"
mkdir -p "${WORK_DIR}"
rm -f "${RUNNER_HOME}/_work"
if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  sed -i "s#\"workFolder\": *\"[^\"]*\"#\"workFolder\": \"${WORK_DIR}\"#" "${RUNNER_DIR}/.runner"
fi

cd "${RUNNER_HOME}"
link_state

if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
  : "${REG_TOKEN:?REG_TOKEN is required for the first start}"
  ./config.sh --unattended --replace \
    --url "${REPO_URL}" --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --work "${WORK_DIR}"
  link_state
fi

# run.sh does not pass SIGTERM on to the listener, so `docker stop` would wait for its timeout and
# then SIGKILL it, leaving the runner's session on GitHub (the next start waits for it to expire).
# Run it as a child and signal the listener directly. No deregistration on stop.
./run.sh &
run_pid=$!
trap 'pkill -TERM -f "${RUNNER_HOME}/bin/Runner.Listener" || true' TERM INT
status=0
while kill -0 "${run_pid}" 2>/dev/null; do
  status=0
  wait "${run_pid}" || status=$?
done
exit "${status}"
