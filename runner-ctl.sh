#!/usr/bin/env bash
# アイドルの runner コンテナを止め、ジョブが待っているときだけ起動する。
# 副ホスト（常時稼働でない小さな Linux ホスト）では全コンテナが対象。主ホストでは
# RUNNER_CTL_KEEP_PRIMARY=1 にして、1 つ目（ar-<repo>）を常時起動のまま、追加レプリカ
# （ar-<repo>-2 以降。setup.sh の RUNNER_REPLICAS）だけを対象にする。
# setup.sh が作った ar-<repo>、ar-<repo>-N コンテナだけを扱い、削除はしない（登録は volume に残る）。
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
#   RUNNER_CTL_MAX_RUNNING  このスクリプトが管理するコンテナ（KEEP_PRIMARY なら追加レプリカだけ）の同時起動数の上限（既定: 4）
#   RUNNER_CTL_KEEPALIVE_DAYS 停止したままこの日数たったコンテナを、ジョブがなくても一度起動する（既定: 7。0 で無効）。
#                           GitHub は 14 日接続のない runner の登録を自動で削除するため、その手前で接続し直す
#   RUNNER_CTL_KEEP_PRIMARY 1 にすると、ar-<repo>（1 つ目）を止めも起動もしない（主ホスト用。既定: 0）
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
KEEP_PRIMARY="${RUNNER_CTL_KEEP_PRIMARY:-0}"
KEEPALIVE_DAYS="${RUNNER_CTL_KEEPALIVE_DAYS:-7}"
SNAP=""
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

# docker の一覧（"名前 状態" の行）。tick の最初に 1 回だけ取る
snapshot() {
  docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null || true
}

# repo のコンテナ（"名前 状態" の行）を番号順に出す。KEEP_PRIMARY=1 なら 1 つ目を除く
managed_containers() {
  local base
  base="$(container_name "$1")"
  printf '%s\n' "${SNAP}" | awk -v b="${base}" -v keep="${KEEP_PRIMARY}" '
    $1 == b { if (keep != 1) print 1, $1, $2; next }
    index($1, b "-") == 1 { n = substr($1, length(b) + 2); if (n ~ /^[0-9]+$/) print n, $1, $2 }' |
    sort -n | cut -d' ' -f2-
}

# このホストが引き受けられる、${START_DELAY} 秒以上キューに残ったジョブの数（limit 件で数えるのをやめる）
count_waiting_jobs() {
  local repo="$1" limit="$2" host_labels runs run_id n total=0
  host_labels="$(jq -cn --arg l "${RUNNER_LABEL}" --arg a "$(host_arch_label)" '["self-hosted","linux",$a,($l|ascii_downcase)]')"
  runs="$(api_get "repos/${repo}/actions/runs?status=queued&per_page=20")" || {
    printf '0'
    return 0
  }
  for run_id in $(jq -r '.workflow_runs[].id' <<<"${runs}"); do
    n="$(api_get "repos/${repo}/actions/runs/${run_id}/jobs?per_page=100" |
      jq --argjson host "${host_labels}" --argjson now "$(now)" --argjson delay "${START_DELAY}" '
        [.jobs[]
         | select(.status == "queued")
         | select((.labels | map(ascii_downcase)) - $host | length == 0)
         | select(($now - (.created_at | fromdateiso8601)) >= $delay)]
        | length')" || continue
    total=$((total + n))
    ((total >= limit)) && break
  done
  printf '%s' "${total}"
}

# 停止中コンテナの最後の接続の代わり（最後に止まった時刻。一度も起動していなければ作成時刻）を "名前 epoch" で出す
last_seen() {
  docker inspect -f '{{.Name}} {{.State.FinishedAt}} {{.Created}}' "$@" 2>/dev/null |
    jq -rR 'split(" ") as $p
      | ($p[1] | sub("\\.[0-9]+"; "")) as $f
      | ($p[2] | sub("\\.[0-9]+"; "")) as $c
      | "\($p[0] | ltrimstr("/")) \((if ($f | startswith("0001")) then $c else $f end) | fromdateiso8601)"' || true
}

is_busy() {
  docker exec "$1" pgrep -f Runner.Worker >/dev/null 2>&1
}

cmd_tick() {
  local repo cname state active last idle_s running=0 idle_running waiting starts i
  local -a repos=() stopped=() leftover=()
  while IFS= read -r repo; do
    repos+=("${repo}")
  done < <(load_repos)
  prepare_state
  SNAP="$(snapshot)"

  for repo in ${repos[@]+"${repos[@]}"}; do
    while read -r cname state; do
      [[ "${state}" == "running" ]] && running=$((running + 1))
    done < <(managed_containers "${repo}")
  done

  for repo in ${repos[@]+"${repos[@]}"}; do
    stopped=()
    idle_running=0
    while read -r cname state; do
      [[ -n "${cname}" ]] || continue
      active="${STATE_DIR}/${cname}.active"
      case "${state}" in
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
          else
            idle_running=$((idle_running + 1))
          fi
          ;;
        exited | created) stopped+=("${cname}") ;;
        *) ;; # paused/restarting など。触らない
      esac
    done < <(managed_containers "${repo}")

    if ((${#stopped[@]} > 0 && running < MAX_RUNNING)); then
      waiting="$(count_waiting_jobs "${repo}" $((${#stopped[@]} + idle_running)))"
      # すでに動いていて空いているコンテナは、待っているジョブを数秒で取る
      starts=$((waiting - idle_running))
      ((starts > ${#stopped[@]})) && starts=${#stopped[@]}
      for ((i = 0; i < starts && running < MAX_RUNNING; i++)); do
        cname="${stopped[i]}"
        log "start ${cname}: ${waiting} job(s) queued for at least ${START_DELAY}s"
        act docker start "${cname}" >/dev/null
        now >"${STATE_DIR}/${cname}.active"
        running=$((running + 1))
      done
      stopped=(${stopped[@]+"${stopped[@]:i}"})
    fi
    for ((i = 0; i < ${#stopped[@]}; i++)); do
      leftover+=("${stopped[i]}")
    done
  done

  keepalive "${running}" ${leftover[@]+"${leftover[@]}"}
}

# 長く止まったままのコンテナを、古いものから、上限の範囲で起動する（14 日の失効を避ける）
keepalive() {
  local running="$1" cname epoch
  shift
  ((KEEPALIVE_DAYS > 0 && $# > 0)) || return 0
  while read -r cname epoch; do
    ((running < MAX_RUNNING)) || break
    ((($(now) - epoch) >= KEEPALIVE_DAYS * 86400)) || break
    log "start ${cname}: keepalive, not connected for $((($(now) - epoch) / 86400)) days"
    act docker start "${cname}" >/dev/null
    now >"${STATE_DIR}/${cname}.active"
    running=$((running + 1))
  done < <(last_seen "$@" | sort -k2 -n)
}

cmd_status() {
  local repo cname state active last
  local -a repos=()
  while IFS= read -r repo; do
    repos+=("${repo}")
  done < <(load_repos)
  SNAP="$(snapshot)"
  for repo in ${repos[@]+"${repos[@]}"}; do
    while read -r cname state; do
      [[ -n "${cname}" ]] || continue
      active="${STATE_DIR}/${cname}.active"
      last="-"
      if [[ "${state}" == "running" && -f "${active}" ]]; then
        last="$((($(now) - $(cat "${active}")) / 60))m"
      fi
      printf '%-40s %-10s idle=%s\n' "${cname}" "${state}" "${last}"
    done < <(managed_containers "${repo}")
  done
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
