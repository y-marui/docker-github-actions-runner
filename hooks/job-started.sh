#!/usr/bin/env bash
# Runner job-started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED).
#
# pre-commit/action keys its actions/cache entry on ${{ env.pythonLocation }}. That expression only
# sees variables set in workflow files or written to $GITHUB_ENV, never the container's own
# environment, and only actions/setup-python sets it. Without it the key carries no environment
# identity, so a ~/.cache/pre-commit saved by an older image (virtualenvs whose python needs a
# libpython this image lacks) is restored and every hook install fails. Derive a value from the OS
# release, Python version and architecture so an image upgrade starts a fresh cache.
# actions/setup-python writes its own value later in the job, which then takes precedence.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"

# shellcheck disable=SC1091
os_release="$(. /etc/os-release && echo "${ID}${VERSION_ID}")"
py_version="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
arch="$(dpkg --print-architecture)"
echo "pythonLocation=/usr-${os_release}-py${py_version}-${arch}" >> "${GITHUB_ENV}"
