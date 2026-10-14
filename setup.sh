#!/usr/bin/env bash
# private リポジトリ向けの Linux self-hosted runner（Docker コンテナ）を作る・消す。
# リポジトリごとにコンテナ（既定 1、RUNNER_REPLICAS で増やせる。個人アカウントにはアカウント単位の runner がないため）。
#
# 使い方（docker と、リポジトリの管理者権限で認証済みの gh が要る）:
#   bash setup.sh pull
#   bash setup.sh build        （ローカルでビルドしたいときだけ）
#   bash setup.sh install [--dry-run] OWNER/REPO...
#   bash setup.sh status  OWNER/REPO...
#   bash setup.sh uninstall [--dry-run] OWNER/REPO...
#
# 環境変数:
#   RUNNER_LABEL   runner に付けるラベル（既定: linux-sh）
#   RUNNER_HOST    runner 名の接頭辞（既定: hostname -s）
#   RUNNER_IMAGE   イメージ名（既定: ghcr.io/y-marui/actions-runner:latest）
#   RUNNER_CPUS / RUNNER_MEMORY   コンテナごとの上限（任意。例: 2 / 4g）
#   RUNNER_REPLICAS  リポジトリごとのコンテナ数（既定: 1）。1 つ目は ar-<repo>、2 つ目以降は ar-<repo>-2, -3...。
#                  1 つの runner は同時に 1 ジョブしか処理できないので、重いリポジトリの並列度を上げたいときだけ増やす
#   RUNNER_PODMAN  1 にすると、rootless podman（docker ソケットなしのイメージビルド）を使えるように
#                  CAP_SYS_ADMIN を足し seccomp/AppArmor を緩めて起動し、ラベル linux-podman も付ける（既定: 0）
#
# install は、イメージがホストに無ければ docker run が GHCR から自動で pull する。更新するには
# pull してからコンテナを入れ替える（docker stop -t 30 → docker rm → install。docker rm -f は使わない）。
#
# 方針と条件は dev-charter の topics/CI_POLICY-full.md「Runner Billing」を参照する。
# リポジトリ名はこのファイルに持たせない（引数で渡す）。登録トークンはファイルに残さない。
# runner の登録状態は、リポジトリごとの Docker volume（ar-<repo>）に保存する。

set -euo pipefail

RUNNER_LABEL="${RUNNER_LABEL:-linux-sh}"
RUNNER_HOST="${RUNNER_HOST:-$(hostname -s)}"
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/y-marui/actions-runner:latest}"
CACHE_VOLUME="ar-cache"
REPLICAS="${RUNNER_REPLICAS:-1}"
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '  %s\n' "$*"
}

# dry-run では実行せずに表示だけする
run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '  + %s\n' "$*"
    return 0
  fi
  "$@"
}

# gh の出力から CR を取り除く（WSL から Windows の gh.exe を呼ぶ場合に CRLF が付くため）
ghc() {
  gh "$@" | tr -d '\r'
}

# 1 つ目は従来どおり ar-<repo>（runner-ctl.sh と既存のコンテナを壊さない）、2 つ目以降に -N を付ける
container_name() {
  if [[ "${2:-1}" -gt 1 ]]; then
    printf 'ar-%s-%s' "${1#*/}" "$2"
  else
    printf 'ar-%s' "${1#*/}"
  fi
}

# repo の全レプリカ（既存のコンテナ）。名前は正規表現ではなく文字列として比べる（repo 名の "." を任意の 1 文字にしない）。
# -N の接尾辞を含むので、別の repo 名（foo と foo-2）とは区別できない
existing_containers() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | awk -v b="$(container_name "$1")" '
    $0 == b { print; next }
    index($0, b "-") == 1 && substr($0, length(b) + 2) ~ /^[0-9]+$/ { print }' || true
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

require_private() {
  local repo="$1" private
  private="$(ghc api "repos/${repo}" --jq .private)" || die "${repo} を取得できません"
  [[ "${private}" == "true" ]] || die "${repo} は public です。public には runner を登録しません（fork の PR が任意のコードを実行できるため）"
}

cmd_pull() {
  run docker pull "${RUNNER_IMAGE}"
}

cmd_build() {
  run docker build -t "${RUNNER_IMAGE}" "${SCRIPT_DIR}"
}

cmd_install() {
  local repo i
  [[ "${REPLICAS}" =~ ^[1-9][0-9]*$ ]] || die "RUNNER_REPLICAS は 1 以上の整数にしてください: ${REPLICAS}"
  for repo in "$@"; do
    echo "== ${repo}"
    [[ "${repo}" == */* ]] || die "OWNER/REPO の形式で指定してください: ${repo}"
    require_private "${repo}"
    for ((i = 1; i <= REPLICAS; i++)); do
      install_one "${repo}" "${i}"
    done
  done
}

install_one() {
  local repo="$1" idx="$2" name cname reg args labels
  cname="$(container_name "${repo}" "${idx}")"
  name="${RUNNER_HOST}-${repo#*/}"
  [[ "${idx}" -gt 1 ]] && name="${name}-${idx}"

  if container_exists "${cname}"; then
    log "コンテナ ${cname} は既にあります（スキップ。作り直すには uninstall してから）"
    return 0
  fi
  labels="${RUNNER_LABEL}"
  [[ "${RUNNER_PODMAN:-0}" == "1" ]] && labels="${labels},linux-podman"
  args=(docker run -d --name "${cname}" --restart unless-stopped
    -e "REPO_URL=https://github.com/${repo}"
    -e "RUNNER_NAME=${name}"
    -e "RUNNER_LABELS=${labels}"
    -v "${cname}:/runner/actions-runner"
    -v "${CACHE_VOLUME}:/runner/.cache")
  if [[ "${RUNNER_PODMAN:-0}" == "1" ]]; then
    # rootless podman needs user namespaces, mounts and pivot_root, which Docker's default
    # capabilities and seccomp/AppArmor profiles block. Only runners installed with this option get the looser profile.
    args+=(--device /dev/fuse --cap-add SYS_ADMIN --security-opt seccomp=unconfined --security-opt apparmor=unconfined)
  fi
  [[ -n "${RUNNER_CPUS:-}" ]] && args+=(--cpus "${RUNNER_CPUS}")
  [[ -n "${RUNNER_MEMORY:-}" ]] && args+=(--memory "${RUNNER_MEMORY}")

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ gh api -X POST repos/${repo}/actions/runners/registration-token"
    log "+ ${args[*]} -e REG_TOKEN=<token> ${RUNNER_IMAGE}"
    return 0
  fi
  reg="$(ghc api -X POST "repos/${repo}/actions/runners/registration-token" --jq .token)"
  "${args[@]}" -e "REG_TOKEN=${reg}" "${RUNNER_IMAGE}" >/dev/null
  log "登録しました: ${name}（label ${labels}）"
}

cmd_status() {
  local repo
  for repo in "$@"; do
    echo "== ${repo}"
    docker ps -a --format '{{.Names}} {{.Status}}' | awk -v b="$(container_name "${repo}")" '
      $1 == b || (index($1, b "-") == 1 && substr($1, length(b) + 2) ~ /^[0-9]+$/) { print "  container: " $0 }'
    ghc api "repos/${repo}/actions/runners" \
      --jq '.runners[] | "  github: \(.name) \(.status) busy=\(.busy) [\([.labels[].name]|join(","))]"'
  done
}

cmd_uninstall() {
  local repo cname rm found
  for repo in "$@"; do
    echo "== ${repo}"
    found=0
    while IFS= read -r cname; do
      [[ -n "${cname}" ]] || continue
      found=1
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "+ gh api -X POST repos/${repo}/actions/runners/remove-token"
        log "+ docker exec ${cname} ./config.sh remove --token <token>"
        log "+ docker stop -t 30 ${cname}; docker rm ${cname}; docker volume rm ${cname}"
        continue
      fi
      rm="$(ghc api -X POST "repos/${repo}/actions/runners/remove-token" --jq .token)"
      # runner-ctl.sh が止めたコンテナは exec できないので、先に起動する
      if [[ "$(docker inspect -f '{{.State.Running}}' "${cname}")" != "true" ]]; then
        docker start "${cname}" >/dev/null
        sleep 3
      fi
      docker exec "${cname}" ./config.sh remove --token "${rm}" || log "GitHub 側の解除に失敗しました（手動で削除してください）"
      docker stop -t 30 "${cname}" >/dev/null
      docker rm "${cname}" >/dev/null
      docker volume rm "${cname}" >/dev/null
      log "削除しました: ${cname}"
    done < <(existing_containers "${repo}")
    [[ "${found}" -eq 1 ]] || log "コンテナ $(container_name "${repo}") はありません"
  done
}

main() {
  local sub="${1:-}"
  [[ -n "${sub}" ]] || die "usage: $0 pull|build|install|status|uninstall [--dry-run] OWNER/REPO..."
  shift
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
  fi
  case "${sub}" in
    pull) cmd_pull ;;
    build) cmd_build ;;
    install | status | uninstall)
      [[ $# -gt 0 ]] || die "OWNER/REPO を 1 つ以上指定してください"
      "cmd_${sub}" "$@"
      ;;
    *) die "unknown subcommand: ${sub}" ;;
  esac
}

main "$@"
