#!/usr/bin/env bash
# runner-ctl.sh のテスト。docker・curl・uname を偽物に差し替えて、停止・起動の判断だけを確かめる。
# 使い方: bash tests/runner-ctl-test.sh   （jq が要る）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/runner-ctl.sh"
NOW=1000000
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- 偽物 ----------------------------------------------------------------------------------
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
# containers: "name status busy" の行。変更系の呼び出しは calls.log に残す
case "$1" in
  inspect)
    name="${@: -1}"
    line="$(grep "^${name} " "${FAKE_DIR}/containers" || true)"
    [[ -n "${line}" ]] || exit 1
    echo "${line}" | cut -d' ' -f2
    ;;
  exec)
    line="$(grep "^$2 " "${FAKE_DIR}/containers" || true)"
    [[ "$(echo "${line}" | cut -d' ' -f3)" == "busy" ]]
    ;;
  stop | start)
    echo "$1 ${@: -1}" >>"${FAKE_DIR}/calls.log"
    ;;
esac
FAKE_DOCKER
cat >"${TMP}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
# -D <headers> -o <body> -w <fmt> -H <header> <url>: URL に対応する fixture を返す。fixture が無ければ 404。
# If-None-Match が付いていれば 304（本文なし）を返す。引数は全て curl.log に残す
echo "$*" >>"${FAKE_DIR}/curl.log"
hdr="" out="" url="" inm=""
while (($#)); do
  case "$1" in
    -D) hdr="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    -H) [[ "$2" == If-None-Match:* ]] && inm=1; shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
key="$(echo "${url#*://*/}" | tr '/?&=' '____')"
f="${FAKE_DIR}/api/${key}.json"
if [[ -f "${f}" && -n "${inm}" ]]; then
  : >"${hdr}"
  : >"${out}"
  printf '304'
elif [[ -f "${f}" ]]; then
  printf 'HTTP/2 200\r\netag: "fake"\r\n\r\n' >"${hdr}"
  cp "${f}" "${out}"
  printf '200'
else
  : >"${hdr}"
  : >"${out}"
  printf '404'
fi
FAKE_CURL
cat >"${TMP}/bin/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
echo "${FAKE_ARCH:-aarch64}"
FAKE_UNAME
chmod +x "${TMP}/bin/"*

# --- 補助 ----------------------------------------------------------------------------------
pass() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
}
check() { # description command...
  local d="$1"
  shift
  if "$@"; then pass "${d}"; else fail "${d}"; fi
}
file_equals() { [[ "$(cat "$1")" == "$2" ]]; }
file_mode_600() { [[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" == "600" ]]; }
file_lacks() { ! grep -q "$2" "$1"; }
file_has() { grep -q "$2" "$1"; }
file_lines() { [[ "$(grep -c "$2" "$1")" == "$3" ]]; }
has_call() { grep -qx "$1" "${FAKE_DIR}/calls.log"; }
no_call() { ! has_call "$1"; }
no_calls() { [[ ! -s "${FAKE_DIR}/calls.log" ]]; }

new_case() {
  FAKE_DIR="${TMP}/case-$1"
  rm -rf "${FAKE_DIR}"
  mkdir -p "${FAKE_DIR}/api" "${FAKE_DIR}/state"
  : >"${FAKE_DIR}/containers"
  : >"${FAKE_DIR}/calls.log"
  printf 'o/a\no/b\n' >"${FAKE_DIR}/repos"
  printf 'test-token\n' >"${FAKE_DIR}/token"
  export FAKE_DIR FAKE_ARCH=aarch64
  EXTRA_ENV=()
}

container() { # name status [busy]
  echo "$1 $2 ${3:-idle}" >>"${FAKE_DIR}/containers"
}

active_at() { # name seconds_ago
  echo $((NOW - $2)) >"${FAKE_DIR}/state/$1.active"
}

queued_job() { # repo age_seconds label... ; ジョブは queued
  local repo="$1" age="$2" labels created
  shift 2
  labels="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  created="$(jq -rn --argjson t $((NOW - age)) '$t | todate')"
  echo '{"workflow_runs":[{"id":11}]}' >"${FAKE_DIR}/api/repos_${repo/\//_}_actions_runs_status_queued_per_page_20.json"
  jq -nc --arg c "${created}" --argjson l "${labels}" \
    '{jobs:[{status:"queued",created_at:$c,labels:$l}]}' \
    >"${FAKE_DIR}/api/repos_${repo/\//_}_actions_runs_11_jobs_per_page_100.json"
}

tick() {
  PATH="${TMP}/bin:${PATH}" RUNNER_CTL_CONFIG=/dev/null RUNNER_CTL_NOW="${NOW}" \
    RUNNER_CTL_REPOS_FILE="${FAKE_DIR}/repos" RUNNER_CTL_TOKEN_FILE="${FAKE_DIR}/token" \
    RUNNER_CTL_STATE_DIR="${FAKE_DIR}/state" RUNNER_CTL_API="http://api.test" \
    RUNNER_CTL_IDLE_MINUTES=15 RUNNER_CTL_START_DELAY=60 RUNNER_CTL_MAX_RUNNING=4 \
    "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" bash "${SCRIPT}" tick "$@" 2>"${FAKE_DIR}/stderr"
}

# --- ケース --------------------------------------------------------------------------------
echo "stop"
new_case 1; container ar-a running; container ar-b exited; active_at ar-a $((16 * 60)); tick
check "idle for 16 min is stopped" has_call "stop ar-a"

new_case 2; container ar-a running busy; active_at ar-a $((60 * 60)); tick
check "a busy runner is not stopped" no_calls
check "busy refreshes the activity time" file_equals "${FAKE_DIR}/state/ar-a.active" "${NOW}"

new_case 3; container ar-a running; active_at ar-a $((5 * 60)); tick
check "idle for 5 min is kept" no_calls

new_case 4; container ar-a running; tick
check "no activity record yet: not stopped" no_calls
check "the idle clock starts now" file_equals "${FAKE_DIR}/state/ar-a.active" "${NOW}"

new_case 5; container ar-a running; active_at ar-a $((16 * 60)); tick --dry-run
check "dry-run does not stop" no_calls
check "dry-run says what it would do" file_has "${FAKE_DIR}/stderr" "dry-run: docker stop"

echo "start"
new_case 6; container ar-a exited; queued_job o/a 120 self-hosted linux-sh; tick
check "a job queued for 120 s starts the runner" has_call "start ar-a"

new_case 7; container ar-a exited; queued_job o/a 30 self-hosted linux-sh; tick
check "a job queued for 30 s waits for the primary host" no_calls

new_case 8; container ar-a exited; queued_job o/a 600 ubuntu-latest; tick
check "a GitHub-hosted job is ignored" no_calls

new_case 9; container ar-a exited; queued_job o/a 600 self-hosted linux-sh X64; tick
check "an X64 job is not taken on an arm64 host" no_calls

new_case 10; container ar-a exited; queued_job o/a 600 self-hosted linux-sh X64; FAKE_ARCH=x86_64 tick
check "an X64 job is taken on an x64 host" has_call "start ar-a"

new_case 11; container ar-a exited; queued_job o/a 600 self-hosted linux-sh ARM64; tick
check "an ARM64 job is taken on an arm64 host" has_call "start ar-a"

new_case 12; container ar-a exited; queued_job o/a 600 self-hosted linux-sh; tick --dry-run
check "dry-run does not start" no_calls

new_case 13; container ar-a running; container ar-b exited; active_at ar-a 60; queued_job o/b 600 self-hosted linux-sh
EXTRA_ENV=(RUNNER_CTL_MAX_RUNNING=1); tick
check "the running cap blocks a start" no_calls

new_case 14; container ar-a exited; queued_job o/a 600 self-hosted linux-sh
sed -i.bak 's/"status":"queued"/"status":"in_progress"/' "${FAKE_DIR}/api/repos_o_a_actions_runs_11_jobs_per_page_100.json"; tick
check "a job that is already running does not start another runner" no_calls

new_case 15; tick
check "repositories without a container are skipped" no_calls

new_case 16; container ar-a running; container ar-b exited; active_at ar-a 60; queued_job o/b 600 self-hosted linux-sh; tick
check "start works while another runner is running" has_call "start ar-b"
check "the running one is not stopped" no_call "stop ar-a"

echo "token and cache"
new_case 17; container ar-a exited; tick
check "the auth header file is 600" file_mode_600 "${FAKE_DIR}/state/auth.hdr"
check "the token never appears in curl arguments" file_lacks "${FAKE_DIR}/curl.log" "test-token"
check "curl reads the credentials from a header file" file_has "${FAKE_DIR}/curl.log" "@${FAKE_DIR}/state/auth.hdr"

new_case 18; container ar-a exited; queued_job o/a 600 self-hosted linux-sh; tick
: >"${FAKE_DIR}/calls.log"; tick
check "a 304 answer is served from the cache" has_call "start ar-a"
check "the second pass sent If-None-Match" file_lines "${FAKE_DIR}/curl.log" "If-None-Match" 2

new_case 19; container ar-a exited; tick
check "an API error does not start anything" no_calls

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
