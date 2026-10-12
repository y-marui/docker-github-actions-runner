#!/usr/bin/env bash
# 副ホスト（常時稼働でない小さな Linux ホスト）で、アイドルの runner コンテナを止め、
# ジョブが待っているときだけ起動する。主ホストでは動かさない（runner は常時起動のまま）。
# setup.sh が作った ar-<repo> コンテナだけを対象にし、削除はしない（登録は volume に残る）。
#
# 使い方（docker と curl と jq が要る。cron か systemd timer で 1 分ごとに tick を実行する）:
#   bash runner-ctl.sh tick [--dry-run]
#   bash runner-ctl.sh status
#
# 設定（環境変数。RUNNER_CTL_CONFIG のファイルに書いてもよい。既定: ~/.config/runner-ctl/env）:
#   RUNNER_CTL_REPOS_FILE   OWNER/REPO を 1 行ずつ書いたファイル（リポジトリ名はここに持たせない）
#   RUNNER_CTL_REPOS        OWNER/REPO を空白区切りで（FILE の代わり）
#   RUNNER_CTL_TOKEN_FILE   GitHub トークンのファイル（fine-grained PAT: Actions の Read）。権限は 600
#   RUNNER_CTL_IDLE_MINUTES アイドルがこの分数続いたら止める（既定: 15）
#   RUNNER_CTL_START_DELAY  ジョブがこの秒数キューに残ったら起動する（既定: 60）。ホストごとにずらすと優先順位になる
#   RUNNER_CTL_MAX_RUNNING  同時に動かすコンテナの上限（既定: 4）
#   RUNNER_CTL_STATE_DIR    状態とキャッシュの置き場（既定: ~/.local/state/runner-ctl）
#   RUNNER_LABEL            このホストの runner のラベル（setup.sh と同じ。既定: linux-sh）
#
# 方針と条件は README の "Idle stop and on-demand start" を参照する。トークンは引数に出さない
# （curl のヘッダーファイルで渡す）。

set -euo pipefail

CONFIG="${RUNNER_CTL_CONFIG:-${HOME}/.config/runner-ctl/env}"
if [[ -f "${CONFIG}" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${CONFIG}"
  set +a
fi

IDLE_MINUTES="${RUNNER_CTL_IDLE_MINUTES:-15}"
START_DELAY="${RUNNER_CTL_START_DELAY:-60}"
MAX_RUNNING="${RUNNER_CTL_MAX_RUNNING:-4}"
STATE_DIR="${RUNNER_CTL_STATE_DIR:-${HOME}/.local/state/runner-ctl}"
RUNNER_LABEL="${RUNNER_LABEL:-linux-sh}"
API="${RUNNER_CTL_API:-https://api.github.com}"
DRY_RUN=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

now() {
  printf '%s' "${RUNNER_CTL_NOW:-$(date +%s)}"
}

# docker の変更系は dry-run では表示だけにする
act() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "dry-run: $*"
    return 0
  fi
  "$@"
}

container_name() {
  printf 'ar-%s' "${1#*/}"
}

host_arch_label() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) printf '%s' "$(uname -m)" ;;
  esac
}

load_repos() {
  local line
  if [[ -n "${RUNNER_CTL_REPOS_FILE:-}" ]]; then
    [[ -f "${RUNNER_CTL_REPOS_FILE}" ]] || die "RUNNER_CTL_REPOS_FILE が見つかりません: ${RUNNER_CTL_REPOS_FILE}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -n "${line}" ]] && printf '%s\n' "${line}"
    done <"${RUNNER_CTL_REPOS_FILE}"
  elif [[ -n "${RUNNER_CTL_REPOS:-}" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' ${RUNNER_CTL_REPOS}
  else
    die "RUNNER_CTL_REPOS_FILE か RUNNER_CTL_REPOS を設定してください"
  fi
}

# 条件付きリクエスト（ETag）で GitHub API を GET し、本文を出力する。304 は本文をキャッシュから返す
# （認証済みの 304 はレート制限に数えられない）。
api_get() {
  local url="$1" key etag_file body_file hdr_out tmp code etag
  key="$(printf '%s' "${url}" | cksum | cut -d' ' -f1)"
  etag_file="${STATE_DIR}/cache/${key}.etag"
  body_file="${STATE_DIR}/cache/${key}.json"
  hdr_out="${STATE_DIR}/cache/${key}.hdr"
  tmp="${STATE_DIR}/cache/${key}.tmp"

  local args=(-sS -D "${hdr_out}" -o "${tmp}" -w '%{http_code}' -H "@${STATE_DIR}/auth.hdr")
  if [[ -f "${etag_file}" && -f "${body_file}" ]]; then
    args+=(-H "If-None-Match: $(cat "${etag_file}")")
  fi
  code="$(curl "${args[@]}" "${API}/${url}")" || {
    log "curl が失敗しました: ${url}"
    return 1
  }
  case "${code}" in
    200)
      mv -f "${tmp}" "${body_file}"
      etag="$(grep -i '^etag:' "${hdr_out}" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r')"
      if [[ -n "${etag}" ]]; then
        printf '%s' "${etag}" >"${etag_file}"
      else
        rm -f "${etag_file}"
      fi
      ;;
    304) rm -f "${tmp}" ;;
    *)
      log "GitHub API が ${code} を返しました: ${url}"
      rm -f "${tmp}"
      return 1
      ;;
  esac
  cat "${body_file}"
}

prepare_state() {
  mkdir -p "${STATE_DIR}/cache"
  chmod 700 "${STATE_DIR}"
  [[ -n "${RUNNER_CTL_TOKEN_FILE:-}" ]] || die "RUNNER_CTL_TOKEN_FILE を設定してください"
  [[ -f "${RUNNER_CTL_TOKEN_FILE}" ]] || die "トークンのファイルが見つかりません: ${RUNNER_CTL_TOKEN_FILE}"
  (
    umask 077
    {
      printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' <"${RUNNER_CTL_TOKEN_FILE}")"
      printf 'Accept: application/vnd.github+json\n'
      printf 'X-GitHub-Api-Version: 2022-11-28\n'
    } >"${STATE_DIR}/auth.hdr"
  )
}

# このホストが引き受けられる、${START_DELAY} 秒以上キューに残ったジョブがあるか
has_waiting_job() {
  local repo="$1" host_labels runs run_id
  host_labels="$(jq -cn --arg l "${RUNNER_LABEL}" --arg a "$(host_arch_label)" '["self-hosted","linux",$a,($l|ascii_downcase)]')"
  runs="$(api_get "repos/${repo}/actions/runs?status=queued&per_page=20")" || return 1
  for run_id in $(jq -r '.workflow_runs[].id' <<<"${runs}"); do
    api_get "repos/${repo}/actions/runs/${run_id}/jobs?per_page=100" |
      jq -e --argjson host "${host_labels}" --argjson now "$(now)" --argjson delay "${START_DELAY}" '
        [.jobs[]
         | select(.status == "queued")
         | select((.labels | map(ascii_downcase)) - $host | length == 0)
         | select(($now - (.created_at | fromdateiso8601)) >= $delay)]
        | length > 0' >/dev/null && return 0
  done
  return 1
}

container_status() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

is_busy() {
  docker exec "$1" pgrep -f Runner.Worker >/dev/null 2>&1
}

cmd_tick() {
  local repo cname status active last idle_s running=0
  local -a repos=()
  while IFS= read -r repo; do
    repos+=("${repo}")
  done < <(load_repos)
  prepare_state

  for repo in "${repos[@]}"; do
    [[ "$(container_status "$(container_name "${repo}")")" == "running" ]] && running=$((running + 1))
  done

  for repo in "${repos[@]}"; do
    cname="$(container_name "${repo}")"
    status="$(container_status "${cname}")"
    active="${STATE_DIR}/${cname}.active"
    case "${status}" in
      running)
        if is_busy "${cname}"; then
          now >"${active}"
          continue
        fi
        [[ -f "${active}" ]] || now >"${active}"
        last="$(cat "${active}")"
        idle_s=$(($(now) - last))
        if ((idle_s >= IDLE_MINUTES * 60)); then
          log "stop ${cname}: idle ${idle_s}s"
          act docker stop -t 30 "${cname}" >/dev/null
          running=$((running - 1))
        fi
        ;;
      exited | created)
        if ((running >= MAX_RUNNING)); then
          continue
        fi
        if has_waiting_job "${repo}"; then
          log "start ${cname}: a job has been queued for at least ${START_DELAY}s"
          act docker start "${cname}" >/dev/null
          now >"${active}"
          running=$((running + 1))
        fi
        ;;
      *) ;; # コンテナなし、または paused/restarting など。触らない
    esac
  done
}

cmd_status() {
  local repo cname status active last
  while IFS= read -r repo; do
    cname="$(container_name "${repo}")"
    status="$(container_status "${cname}")"
    active="${STATE_DIR}/${cname}.active"
    last="-"
    if [[ "${status}" == "running" && -f "${active}" ]]; then
      last="$((($(now) - $(cat "${active}")) / 60))m"
    fi
    printf '%-40s %-10s idle=%s\n' "${cname}" "${status:-none}" "${last}"
  done < <(load_repos)
}

main() {
  local sub="${1:-}"
  [[ -n "${sub}" ]] || die "usage: $0 tick [--dry-run] | status"
  shift
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
  fi
  case "${sub}" in
    tick) cmd_tick ;;
    status) cmd_status ;;
    *) die "unknown subcommand: ${sub}" ;;
  esac
}

main "$@"
