# docker-github-actions-runner

> **このファイルは正本(日本語版)です。**
> 英語版(参照)は [README.md](README.md) を参照してください。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/ci.yml)
[![Charter Check](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/dev-charter-check.yml/badge.svg)](https://github.com/y-marui/docker-github-actions-runner/actions/workflows/dev-charter-check.yml)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/y-marui?style=social)](https://github.com/sponsors/y-marui)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-donate-yellow.svg)](https://www.buymeacoffee.com/y.marui)

Linux の self-hosted GitHub Actions runner を Docker イメージとして提供し、runner をコンテナとして登録するスクリプトも含む。イメージは GHCR に linux/amd64 と linux/arm64(Raspberry Pi)で公開しており、新しいホストには Docker と `gh` があればよい(ローカルでビルドしない)。

~~~text
ghcr.io/y-marui/actions-runner:latest
~~~

イメージは Ubuntu 26.04 に runner、`git`、`gh`、`curl`、`jq`、`zip`、python(`pip`、`uv`)、node、`shellcheck`、`gitleaks`、`swiftlint`、Qt と headless Chromium のテストが読み込む共有ライブラリを加えたもの。秘密情報は含まず、登録トークンは実行時に渡す。Docker ソケットはマウントせず、runner ユーザーは sudo を使えない。ジョブ内でイメージをビルドするための rootless `podman` を含む。
SwiftLintはUbuntu 26.04と異なるlibxml2 ABIを使うため、公式イメージのlibxml2とICUを同梱します。
CIでは書き出したイメージをrunnerユーザーで検証します。公開時は候補イメージを先にpushし、
amd64・arm64のネイティブ環境でSwiftLintと共有ライブラリを検証してから、
検証済みmanifestを`latest`とrunnerバージョンのタグへ昇格させます。


## Headless Chromium tests

Chromiumの共有ライブラリとLiberationフォントをイメージに事前導入し、ブラウザのジョブではsudoを使わない。ブラウザ本体とPlaywrightは含めない。プロジェクトのNode.jsとロック済み依存を準備してから、`npx playwright install chromium`でそのPlaywrightに対応するブラウザを取得し、テストする。小容量ホストに大きなブラウザを取得させない場合は、runnerのアーキテクチャラベルで対象を絞る。

コンテナを再作成するときは、これらのライブラリを含むイメージを使い、非rootのrunnerユーザーで実際のブラウザテストを確認する。古いコンテナ内に直接導入したパッケージは、再作成すると消える。

## Runners per OS

| OS | 方式 | 登録 |
|---|---|---|
| macOS | ネイティブ(LaunchDaemon) | dotfiles の `macos/setup_actions_runner.sh` |
| Windows | ネイティブ(Windows サービス) | dotfiles の `windows/setup_actions_runner.ps1` |
| Linux | Docker(リポジトリごとに 1 つ以上のコンテナ) | このリポジトリの `setup.sh` |

## Security: never register a runner on a public repository

self-hosted runner は、リポジトリのワークフローに書かれたコードをそのまま実行する。public リポジトリでは、fork からの PR が手元のマシンで任意のコードを実行できてしまう。`setup.sh install` は public リポジトリを拒否する。runner は、自分だけがワークフローを編集できる private リポジトリにだけ登録する。

## Adding a host

必要なもの: Docker と、対象リポジトリの管理者権限で認証済みの `gh`。

~~~sh
git clone https://github.com/y-marui/docker-github-actions-runner
cd docker-github-actions-runner
bash setup.sh pull
bash setup.sh install OWNER/REPO...      # --dry-run で内容だけ確認できる
bash setup.sh status OWNER/REPO...
~~~

runner はリポジトリ単位で登録する(個人アカウントにはアカウント単位の runner がないため)。コンテナ名は `ar-<repo>`、登録状態は Docker volume `ar-<repo>` に保存する。volume に入るのは登録情報とジョブの作業領域だけで、runner 本体はイメージのものを共有する(1 ホストに 24 個立てても、本体 約450MB が 24 個にはならない)。ワークフローは `runs-on: [self-hosted, linux-sh]` で選ぶ。

`setup.sh` の環境変数:

| 変数 | 既定値 | 意味 |
|---|---|---|
| `RUNNER_LABEL` | `linux-sh` | runner に付けるラベル |
| `RUNNER_HOST` | `hostname -s` | runner 名の接頭辞 |
| `RUNNER_IMAGE` | `ghcr.io/y-marui/actions-runner:latest` | 使用するイメージ |
| `RUNNER_CPUS` / `RUNNER_MEMORY` | 未設定 | コンテナごとの上限(例: `2` / `4g`) |
| `RUNNER_REPLICAS` | `1` | リポジトリごとのコンテナ数（下記） |
| `RUNNER_PODMAN` | `0` | `1` にすると、ジョブ内でイメージをビルドできる(下記)。ラベル `linux-podman` も付く |

### More than one runner per repository

runner は同時に 1 ジョブしか処理しないので、リポジトリの並列度は、全ホストに登録した runner の数で決まる。CI が少数の runner の後ろで待たされるリポジトリは、主ホストで `RUNNER_REPLICAS` を増やす。

~~~sh
RUNNER_REPLICAS=3 bash setup.sh install OWNER/REPO
~~~

1 つ目のコンテナは従来どおり `ar-<repo>`、2 つ目以降は `ar-<repo>-2`、`ar-<repo>-3`（runner 名も同じ接尾辞）で、volume は別々になる。`install` は既にあるコンテナをスキップするので、導入済みのリポジトリで数を増やすと、足りない分だけ追加される。`status` と `uninstall` は全レプリカが対象。`runner-ctl.sh`(下記 "Idle stop and on-demand start")は、アイドルのコンテナを止め、ジョブが溜まったときに起動する。主ホストでは `ar-<repo>` を常時起動のままにして、追加レプリカだけを管理させることもできる。末尾が `-<数字>` のリポジトリ名（`foo` をレプリカ付きにすると `foo-2` と名前が衝突する）は避ける。

## Building images in jobs (rootless podman)

イメージには rootless の `podman` が入っており、ジョブは Docker ソケットなしで `Dockerfile` を `podman build` し、結果を `podman run` できる。これにはユーザー名前空間とマウントが要り、Docker 既定の capability と seccomp・AppArmor のプロファイルが妨げるため、runner ごとに明示的に有効にする。

~~~sh
RUNNER_PODMAN=1 bash setup.sh install OWNER/REPO
~~~

このコンテナは `--device /dev/fuse`、`--cap-add SYS_ADMIN`、`seccomp=unconfined` / `apparmor=unconfined` で起動し(`--privileged` ではなく、ソケットなしは変わらない)、ラベル `linux-podman` が加わる。オプションなしで入れた runner は変わらない。ワークフローは `runs-on: [self-hosted, linux-sh, linux-podman]` で選ぶ。イメージの保存先はその runner 専用の volume で、レイヤーはジョブ間でキャッシュされる。

~~~sh
podman build -t app:ci .
podman run -d --name app app:ci
podman healthcheck run app   # Dockerfile の HEALTHCHECK と `podman build --format docker` が必要
~~~

## Updating the image on a host

~~~sh
bash setup.sh pull
docker stop -t 30 ar-<repo>
docker rm ar-<repo>
bash setup.sh install OWNER/REPO
~~~

`docker rm -f` は使わない。先に停止して、実行中のジョブを終わらせる。登録状態は volume にあるので、コンテナを作り直しても新しいトークンは要らない。
runner 本体の共有前に作った volume には本体の完全なコピーが残っている。新しいイメージで最初に起動したとき、そのコピーは削除され、登録情報は残る。
通常の停止（`docker stop`）では runner が自分でセッションを閉じるので、新しいコンテナは数秒でオンラインになる。クラッシュや強制終了の後は、GitHub 側で古いセッションが失効するまでの数分間、"A session for this runner already exists" と出続けることがあるが、自動で再接続する。

## Idle stop and on-demand start

任意。常時稼働の主ホストと、小さな副ホスト（Raspberry Pi など）が同じリポジトリを登録していると、GitHub は同じラベルの空いている runner のどれかにジョブを渡す。そのため副ホストにもジョブがランダムに流れ、どのコンテナもリスナーを常時動かしてしまう。`runner-ctl.sh` は副ホストを静かに保つ。主ホストでは `RUNNER_CTL_KEEP_PRIMARY=1` にする。各リポジトリの 1 つ目（`ar-<repo>`）は常時起動のままで、追加レプリカ（`RUNNER_REPLICAS` による `ar-<repo>-2` 以降）だけを、アイドルで止め、ジョブが溜まったときに起動する。

- **停止**: `RUNNER_CTL_IDLE_MINUTES` の間ジョブのない `ar-*` コンテナを `docker stop -t 30` で止める。コンテナは削除しない（登録は volume に残る）。
- **起動**: 停止中のコンテナは、そのリポジトリでこのホストが実行できるジョブ（ラベルが `self-hosted`・`linux`・アーキテクチャ・`RUNNER_LABEL` に収まるもの）が `RUNNER_CTL_START_DELAY` 秒以上キューに残ったときに起動する。動かすコンテナは `RUNNER_CTL_MAX_RUNNING` 個まで。待っているジョブ 1 件につき停止中のコンテナを 1 つ起動するので、1 件のジョブで全レプリカが起きることはない。
- **保活**: GitHub は、14 日間接続のない非 ephemeral の runner の登録を自動で削除する。`RUNNER_CTL_KEEPALIVE_DAYS`（既定 7）日停止したままのコンテナは、ジョブがなくても、古いものから `RUNNER_CTL_MAX_RUNNING` の範囲で起動する。そのあとはアイドル停止でまた止まる。最後の接続は、コンテナの最終停止時刻（一度も動いていなければ作成時刻）で代用するので、状態ファイルは要らない。
- **優先順位**: ホストごとに `RUNNER_CTL_START_DELAY` を変える（例: 60 秒と 120 秒。主ホストの追加レプリカは数秒）。起動の判断は tick のときだけなので、タイマーの間隔より短い遅延は意味がない。ジョブは主ホストがすぐ取り、次に遅延の短い副ホスト、誰も取らなかったときだけ他の副ホストが起動する。

対象は、指定したリポジトリの `ar-*` コンテナだけ。キューの確認は条件付きリクエストで行う（`304` はレート制限に数えられない）。

~~~sh
sudo apt-get install -y jq curl                  # docker は入っている前提
mkdir -p ~/.config/runner-ctl
cp systemd/runner-ctl.env.example ~/.config/runner-ctl/env     # パスと数値を編集する
printf '%s\n' OWNER/REPO ... > ~/.config/runner-ctl/repos     # このホストのリポジトリ
install -m 600 /dev/null ~/.config/runner-ctl/token            # 作ったファイルにトークンを貼る
bash runner-ctl.sh status
bash runner-ctl.sh tick --dry-run                              # 何をするかだけ表示する
~~~

トークンは、対象のリポジトリに *Actions* の読み取り権限だけを付けた fine-grained personal access token。トークン、リポジトリ一覧、env ファイルはリポジトリの外に置く。1 分ごとに動かすには、`systemd/runner-ctl.service` と `systemd/runner-ctl.timer` を `~/.config/systemd/user/` にコピーし、service のパスを直してから次を実行する。

~~~sh
systemctl --user daemon-reload && systemctl --user enable --now runner-ctl.timer
loginctl enable-linger "$USER"                    # ログインしなくてもタイマーを動かし続ける
~~~

| 変数 | 既定値 | 意味 |
|---|---|---|
| `RUNNER_CTL_REPOS_FILE` / `RUNNER_CTL_REPOS` | 必須 | リポジトリ（`OWNER/REPO`）。ファイルは 1 行に 1 つ、変数は空白区切り |
| `RUNNER_CTL_TOKEN_FILE` | 必須 | トークンのファイル（権限 600） |
| `RUNNER_CTL_IDLE_MINUTES` | `15` | アイドルがこの分数続いたら止める |
| `RUNNER_CTL_START_DELAY` | `60` | この秒数以上キューに残ったジョブのときに起動する |
| `RUNNER_CTL_MAX_RUNNING` | `4` | このスクリプトが管理するコンテナの同時起動数の上限 |
| `RUNNER_CTL_KEEPALIVE_DAYS` | `7` | この日数停止したままのコンテナを、ジョブがなくても起動する（`0` で無効） |
| `RUNNER_CTL_KEEP_PRIMARY` | `0` | `1` で `ar-<repo>`（1 つ目）に触れない。主ホスト用 |
| `RUNNER_CTL_STATE_DIR` | `~/.local/state/runner-ctl` | 状態と API のキャッシュ |
| `RUNNER_LABEL` | `linux-sh` | このホストの runner のラベル（`setup.sh` と同じ） |

停止中の runner はオフラインなので、ジョブはその起動を待つ。通常の停止の後なら、起動から数秒でオンラインに戻る（クラッシュや強制終了の場合は、上の "A session for this runner already exists" を参照）。

### Tuning the delays

GitHub は、キューに入ったジョブを、同じラベルの空いている runner のどれかに渡し、どれになるかは指定できない。特定のホストを優先する唯一の方法は、ほかのホストの起動を遅らせること。実測例（1 回 11 ジョブのリポジトリ 1 つ、amd64 の主ホストにレプリカ 4、溢れ用に Raspberry Pi 2 台）:

- Pi の起動遅延が 60 秒だと、主ホストなら約 35 秒で終わるジョブを Pi が取り、206 秒かかった。Pi はアイドル停止までオンラインのままで、次のジョブも取った。全体は約 100 秒のところ 496 秒になった。
- Pi の遅延を 240 秒、アイドル停止を 5 分にすると、全ジョブが主ホストで処理され、全体は 89〜101 秒になった。

そのため、遅いホストの遅延は、速いホストの追加レプリカのコールドスタート（タイマー 20 秒で約 20〜60 秒）より十分長く、アイドル停止は短くする。主ホストの追加レプリカは、遅延を短く（数秒）、アイドル停止を長め（約 10 分。アイドルの runner は約 90MiB）にして、連続する push に対して温めておく。コールドスタートは最初のジョブに約 15〜60 秒を足す。タイマーは、副ホストより主ホストで短い間隔（例: 20 秒）にする。

## Removing a runner

~~~sh
bash setup.sh uninstall OWNER/REPO
~~~

全レプリカについて、GitHub 側の登録を解除し（停止中のコンテナは先に起動する）、コンテナを停止・削除して、volume も削除する。リポジトリの追加レプリカだけを外すときは、`ar-<repo>` を残して 1 つずつ手で解除する。

~~~sh
token=$(gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token)
docker start ar-<repo>-2 && sleep 3
docker exec ar-<repo>-2 ./config.sh remove --token "$token"
docker stop -t 30 ar-<repo>-2 && docker rm ar-<repo>-2 && docker volume rm ar-<repo>-2
~~~

`runner-ctl` を止めるだけでも害はない。停止したままの追加レプリカは、14 日後に GitHub 側で登録が自動削除される。

## Publishing

`.github/workflows/publish.yml` が、`main` の `Dockerfile` / `entrypoint.sh` の変更時と毎週、イメージをビルドして GHCR に push する(`latest` と runner のバージョン)。pull request では `ci.yml` がビルドできることだけを確認する。

最初の push ではパッケージが private で作られる。ホストが認証なしで pull できるよう、*Packages > actions-runner > Package settings* で一度 public にする。

## Versions

- `Dockerfile` の `RUNNER_VERSION` が runner のバージョンを固定する。runner は実行時に自己更新するので、古いままでも支障はない。ときどき上げる。自己更新の結果はコンテナの書き込み層に残る(1 コンテナあたり 約450MB)。新しいイメージでコンテナを作り直すと破棄される。
- Dependabot(`.github/dependabot.yml`)は、Docker のベースイメージと GitHub Actions を更新する。`SWIFTLINT_VERSION`、`GITLEAKS_VERSION`、`RUNNER_VERSION` は単なるビルド引数なので、手動で上げる。

## License

[MIT](LICENSE)

---
*この文書には英語版 [README.md](README.md) があります。編集時は同一コミットで更新してください。*
