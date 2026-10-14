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
  ps)
    cut -d' ' -f1,2 "${FAKE_DIR}/containers"
    ;;
  inspect)
    if [[ "$3" == *FinishedAt* ]]; then
      # keepalive: "名前 FinishedAt Created"。FAKE_DIR/finished に "名前 ISO" があればそれ、なければ 1 時間前
      shift 3
      for n in "$@"; do
        f="$(grep "^${n} " "${FAKE_DIR}/finished" 2>/dev/null | cut -d' ' -f2)"
        f="${f:-$(date -u -r $((FAKE_NOW - 3600)) +%Y-%m-%dT%H:%M:%S.123456789Z 2>/dev/null || date -u -d @$((FAKE_NOW - 3600)) +%Y-%m-%dT%H:%M:%S.123456789Z)}"
        echo "/${n} ${f} 2026-01-01T00:00:00.000000000Z"
      done
      exit 0
    fi
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
  : >"${FAKE_DIR}/finished"
  printf 'o/a\no/b\n' >"${FAKE_DIR}/repos"
  printf 'test-token\n' >"${FAKE_DIR}/token"
  export FAKE_DIR FAKE_ARCH=aarch64 FAKE_NOW="${NOW}"
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

stopped_since() { # name days_ago
  local t=$((NOW - $2 * 86400))
  echo "$1 $(date -u -r "${t}" +%Y-%m-%dT%H:%M:%S.5Z 2>/dev/null || date -u -d "@${t}" +%Y-%m-%dT%H:%M:%S.5Z)" >>"${FAKE_DIR}/finished"
}

tick() {
  env PATH="${TMP}/bin:${PATH}" RUNNER_CTL_CONFIG=/dev/null RUNNER_CTL_NOW="${NOW}" \
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

echo "replicas"
new_case 119; container ar-a exited; container ar-a-2 exited; container ar-a-3 exited
queued_job o/a 600 self-hosted linux-sh; tick
check "one queued job starts one replica" has_call "start ar-a"
check "the other replicas stay stopped" no_call "start ar-a-2"

new_case 20; container ar-a running; container ar-a-2 exited; queued_job o/a 600 self-hosted linux-sh
active_at ar-a 60; tick
check "an idle running replica is expected to take the job" no_calls

new_case 21; container ar-a running busy; container ar-a-2 exited; container ar-a-3 exited
queued_job o/a 600 self-hosted linux-sh; tick
check "a busy replica does not prevent starting another" has_call "start ar-a-2"
check "only one is started for one job" no_call "start ar-a-3"

new_case 22; container ar-a exited; container ar-a-2 exited; container ar-a-3 exited
queued_job o/a 600 self-hosted linux-sh
jq -c '.jobs += .jobs + .jobs' "${FAKE_DIR}/api/repos_o_a_actions_runs_11_jobs_per_page_100.json" >"${TMP}/j" && mv "${TMP}/j" "${FAKE_DIR}/api/repos_o_a_actions_runs_11_jobs_per_page_100.json"
tick
check "three queued jobs start three replicas" has_call "start ar-a-3"

new_case 23; container ar-a exited; container ar-a-2 exited; container ar-a-3 exited
queued_job o/a 600 self-hosted linux-sh
jq -c '.jobs += .jobs + .jobs' "${FAKE_DIR}/api/repos_o_a_actions_runs_11_jobs_per_page_100.json" >"${TMP}/j" && mv "${TMP}/j" "${FAKE_DIR}/api/repos_o_a_actions_runs_11_jobs_per_page_100.json"
EXTRA_ENV=(RUNNER_CTL_MAX_RUNNING=2); tick
check "the running cap limits replicas started at once" file_lines "${FAKE_DIR}/calls.log" "^start" 2

echo "keep primary"
new_case 24; container ar-a running; active_at ar-a $((60 * 60)); EXTRA_ENV=(RUNNER_CTL_KEEP_PRIMARY=1); tick
check "the primary is never stopped" no_calls

new_case 25; container ar-a exited; queued_job o/a 600 self-hosted linux-sh; EXTRA_ENV=(RUNNER_CTL_KEEP_PRIMARY=1); tick
check "the primary is never started" no_calls

new_case 26; container ar-a running; container ar-a-2 running; container ar-a-3 exited
active_at ar-a-2 $((4 * 60)); queued_job o/a 600 self-hosted linux-sh
EXTRA_ENV=(RUNNER_CTL_KEEP_PRIMARY=1 RUNNER_CTL_IDLE_MINUTES=3); tick
check "an idle extra replica is stopped" has_call "stop ar-a-2"
check "the primary does not count against the cap" has_call "start ar-a-3"

new_case 27; container ar-a running busy; container ar-a-2 exited; container ar-a-3 exited
queued_job o/a 600 self-hosted linux-sh; EXTRA_ENV=(RUNNER_CTL_KEEP_PRIMARY=1); tick
check "an extra replica starts when the primary is busy" has_call "start ar-a-2"

new_case 28; container ar-a exited; container ar-a-2 exited; container ar-a-20 exited
queued_job o/a 600 self-hosted linux-sh; EXTRA_ENV=(RUNNER_CTL_KEEP_PRIMARY=1); tick
check "replicas are started in numeric order" has_call "start ar-a-2"

echo "keepalive"
new_case 29; container ar-a exited; stopped_since ar-a 8; tick
check "a container stopped for 8 days is started without a job" has_call "start ar-a"

new_case 30; container ar-a exited; stopped_since ar-a 5; tick
check "a container stopped for 5 days is left alone" no_calls

new_case 31; container ar-a exited; stopped_since ar-a 30; EXTRA_ENV=(RUNNER_CTL_KEEPALIVE_DAYS=0); tick
check "keepalive 0 disables it" no_calls

new_case 32; container ar-a exited; container ar-b exited; stopped_since ar-a 9; stopped_since ar-b 20
EXTRA_ENV=(RUNNER_CTL_MAX_RUNNING=1); tick
check "the oldest is started first" has_call "start ar-b"
check "the cap limits keepalive starts" no_call "start ar-a"

new_case 33; container ar-a exited; container ar-a-2 exited; stopped_since ar-a-2 10; queued_job o/a 600 self-hosted linux-sh
tick
check "a job start and a keepalive start are independent" file_lines "${FAKE_DIR}/calls.log" "^start" 2

new_case 34; container ar-a exited; stopped_since ar-a 10; tick --dry-run
check "dry-run does not start for keepalive" no_calls

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
