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

イメージは Ubuntu 24.04 に runner、`git`、`gh`、`curl`、`jq`、`zip`、python(`pip`、`uv`)、node、`shellcheck`、`gitleaks`、`swiftlint`、Qt テストが読み込む共有ライブラリを加えたもの。秘密情報は含まず、登録トークンは実行時に渡す。Docker ソケットはマウントせず、runner ユーザーは sudo を使えない。ジョブ内でイメージをビルドするための rootless `podman` を含む。

## Runners per OS

| OS | 方式 | 登録 |
|---|---|---|
| macOS | ネイティブ(LaunchDaemon) | dotfiles の `macos/setup_actions_runner.sh` |
| Windows | ネイティブ(Windows サービス) | dotfiles の `windows/setup_actions_runner.ps1` |
| Linux | Docker(リポジトリごとに 1 コンテナ) | このリポジトリの `setup.sh` |

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

runner はリポジトリ単位で登録する(個人アカウントにはアカウント単位の runner がないため)。コンテナ名は `ar-<repo>`、登録状態は Docker volume `ar-<repo>` に保存する。ワークフローは `runs-on: [self-hosted, linux-sh]` で選ぶ。

`setup.sh` の環境変数:

| 変数 | 既定値 | 意味 |
|---|---|---|
| `RUNNER_LABEL` | `linux-sh` | runner に付けるラベル |
| `RUNNER_HOST` | `hostname -s` | runner 名の接頭辞 |
| `RUNNER_IMAGE` | `ghcr.io/y-marui/actions-runner:latest` | 使用するイメージ |
| `RUNNER_CPUS` / `RUNNER_MEMORY` | 未設定 | コンテナごとの上限(例: `2` / `4g`) |
| `RUNNER_PODMAN` | `0` | `1` にすると、ジョブ内でイメージをビルドできる(下記)。ラベル `linux-podman` も付く |

## Building images in jobs (rootless podman)

イメージには rootless の `podman` が入っており、ジョブは Docker ソケットなしで `Dockerfile` を `podman build` し、結果を `podman run` できる。これにはユーザー名前空間とマウントが要り、Docker 既定の seccomp と AppArmor のプロファイルが妨げるため、runner ごとに明示的に有効にする。

~~~sh
RUNNER_PODMAN=1 bash setup.sh install OWNER/REPO
~~~

このコンテナは `--device /dev/fuse` と `seccomp=unconfined` / `apparmor=unconfined` で起動し(特権なし、ソケットなしは変わらない)、ラベル `linux-podman` が加わる。オプションなしで入れた runner は変わらない。ワークフローは `runs-on: [self-hosted, linux-sh, linux-podman]` で選ぶ。イメージの保存先はその runner 専用の volume で、レイヤーはジョブ間でキャッシュされる。

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
作り直した直後の数分間は、GitHub 側で古いセッションが失効するまで "A session for this runner already exists" と出続けることがあるが、自動で再接続する。

## Removing a runner

~~~sh
bash setup.sh uninstall OWNER/REPO
~~~

GitHub 側の登録を解除し、コンテナを停止・削除して、volume も削除する。

## Publishing

`.github/workflows/publish.yml` が、`main` の `Dockerfile` / `entrypoint.sh` の変更時と毎週、イメージをビルドして GHCR に push する(`latest` と runner のバージョン)。pull request では `ci.yml` がビルドできることだけを確認する。

最初の push ではパッケージが private で作られる。ホストが認証なしで pull できるよう、*Packages > actions-runner > Package settings* で一度 public にする。

## Versions

- `Dockerfile` の `RUNNER_VERSION` が runner のバージョンを固定する。runner は実行時に自己更新するので、古いままでも支障はない。ときどき上げる。
- Dependabot(`.github/dependabot.yml`)は、Docker のベースイメージと GitHub Actions を更新する。`SWIFTLINT_VERSION`、`GITLEAKS_VERSION`、`RUNNER_VERSION` は単なるビルド引数なので、手動で上げる。

## License

[MIT](LICENSE)

---
*この文書には英語版 [README.md](README.md) があります。編集時は同一コミットで更新してください。*
