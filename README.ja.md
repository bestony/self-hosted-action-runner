# Docker GitHub Actions セルフホストランナー (Self-Hosted Runner)

コンテナ化され、マルチアーキテクチャ（amd64 / arm64）に対応した GitHub Actions セルフホストランナーです。Docker ワークフロー（Docker-outside-of-Docker / DooD）をネイティブサポートし、GitHub Actions Cache Server によるキャッシュアクセラレーションを統合しています。

**言語ナビゲーション / Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [Español](README.es.md)

- **GitHub リポジトリ**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub リポジトリ**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

---

## ワンライナー対話型インストーラー

単一または複数のリポジトリランナーをデプロイし、共有 Actions キャッシュサーバー（オプション）を構成するための最も簡単な方法です：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### 主な特徴
- **事前検証と依存関係の自動構成**：Docker Engine、Docker Compose v2、および Docker デーモンの導通を自動確認します。Linux（`get.docker.com` 経由）および macOS（Homebrew 経由）での自動インストールに対応しています。
- **対話型セットアップウィザード**：リポジトリ/組織 URL、非表示の登録トークン、ランナー名プレフィックス、ラベルの入力をガイドします。1 回のデプロイで複数ランナーのセットアップが可能です。
- **共有キャッシュサーバー**：`ghcr.io/falcondev-oss/github-actions-cache-server:latest` をオプションで自動構成し、DooD ホスト IP を自動検出します。
- **再現性のある Compose とセキュリティ**：`chmod 600` の厳格な権限を持つ `docker-compose.yml` および `.env` を生成します。Compose ファイル内にトークンが直接露出することはありません。
- **ヘルスチェックとログ自動検証**：スタックを起動し、GitHub への登録ログを自動追跡して接続完了を確認します。

### インストーラー CLI オプション
- `--dir <path>`：インストール先ディレクトリ（root の既定値：`/opt/github-runner`、一般ユーザーの既定値：`$HOME/github-runner`）。
- `--non-interactive`：`GHR_*` 環境変数を使用してプロンプトなしで自動デプロイを実行します。
- `--no-start`：設定ファイルとディレクトリ構成のみを生成し、コンテナは起動しません。
- `--skip-docker-install`：Docker および Compose プラグインの自動インストール試行をスキップします。
- `--uninstall`：コンテナを停止して削除し、永続ボリュームを削除するか確認します。
- `--debug`：詳細なデバッグログ出力を有効にします。
- `-h, --help`：ヘルプメッセージとオプションを表示します。

### 対話型デプロイの例（デフォルト）

`GHR_*` 環境変数やフラグを指定せずに実行します。インストーラーは端末（`/dev/tty`）から直接入力を読み取るため、`curl | bash` パイプライン経由でも安全に動作します。Enter キーを押すとデフォルト値が採用され、トークン入力は自動的にマスクされます。

```text
$ curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash

==> [3/6] Collecting configuration
Enter installation directory [default: /home/me/github-runner]:

--- Configuring Runner #1 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org/repo-a
GitHub Runner Registration Token:
Runner name prefix [default: repo-a-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 2
Add another repository/org runner? [y/N]: y

--- Configuring Runner #2 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org
GitHub Runner Registration Token:
Runner name prefix [default: my-org-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 1
Add another repository/org runner? [y/N]:

--- Cache Server Configuration ---
Enable shared GitHub Actions cache server? [Y/n]:
Select cache URL mode: [1] Internal (http://cache-server:3000) or [2] Host IP (reachable by container jobs) [default: 1]:
Runner container image [default: ghcr.io/bestony/self-hosted-action-runner:latest]:

(configuration summary, tokens masked)
Write configuration and continue? [Y/n]:
```

> **注意**：GitHub リポジトリまたは組織の **Settings > Actions > Runners > New self-hosted runner** 画面から登録トークンを取得してください。トークンの有効期限は 1 時間ですが、ランナーの初回登録時のみ必要となります。

同じディレクトリで再度スクリプトを実行すると、既存のランナー一覧が表示され、`[A]dd runners`（ランナー追加）、`[R]econfigure from scratch`（最初から再設定）、`[Q]uit`（終了）を選択できます。

### 非対話型デプロイの例（CI / 自動化）

ターミナルに対話者が存在しない自動化環境では `--non-interactive` を使用します。このモードではプロンプトを表示せず、`GHR_*` 環境変数から値を直接読み込みます：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | \
  GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
  GHR_RUNNER_1_TOKEN="YOUR_REPO_A_TOKEN" \
  GHR_RUNNER_1_INSTANCES=2 \
  GHR_RUNNER_2_URL="https://github.com/my-org/repo-b" \
  GHR_RUNNER_2_TOKEN="YOUR_REPO_B_TOKEN" \
  GHR_CACHE=1 \
  bash -s -- --non-interactive --dir /opt/github-runner
```

---

## Podman + systemd (Quadlet) インストーラー

Docker Engine ではなく Podman を使用する Linux ホスト向けに、`install-podman.sh` を提供しています。[Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) ユニットファイルを生成し、**systemd** がマシンの起動時からサービスのライフサイクルを管理します：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
```

このスクリプトは `install.sh` と共通の対話型入力、`GHR_*` 環境変数、および `.env` 規約を持ちます。デプロイ形式とライフサイクル管理ツールのみが異なります：

| 項目 | `install.sh` (Docker) | `install-podman.sh` (Podman) |
|---|---|---|
| **デプロイ単位** | `docker-compose.yml` + `.env` | Quadlet `.container` ファイル + `.env` |
| **管理主体** | `docker compose` | systemd (`systemctl`, `journalctl`) |
| **起動時自動実行** | コンテナの `restart:` ポリシー | ユニット内の `[Install] WantedBy=multi-user.target default.target` |
| **動作要件** | Docker Engine + Compose v2 | systemd が PID 1 の Linux、rootful Podman >= 4.4 |
| **インスタンス数** | `--instances`, `GHR_RUNNER_<n>_INSTANCES` | 同左 |
| **サブコマンド** | `--uninstall` | `--status`, `--start`, `--stop`, `--restart`, `--upgrade`, `--uninstall` |

```bash
# 非対話型デプロイ（既存の Podman 環境向け）
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | \
  sudo bash -s -- --non-interactive --dir /opt/github-runner --skip-podman-install
```

### Podman 利用時の仕様と注意点
- **バージョン要件**：Quadlet は Podman 4.4 以降に含まれます。Podman が未導入の場合は自動インストールを試行し、バージョンおよび `podman-system-generator` の存在を確認します。
- **`systemctl enable` 不要の自動起動**：Quadlet ユニットは動的生成ファイルであるため、`systemctl enable` は使用できません。ユニット内の `[Install] WantedBy=` によって起動時の自動実行が担保されます。
- **アップグレード**：`--upgrade` を実行すると最新の `RUNNER_IMAGE` / `CACHE_IMAGE` を取得して全ユニットを再起動します。`AUTO_UPDATE=1` の場合は Quadlet に `AutoUpdate=registry` が設定されます。
- **キャッシュサーバーの通信モード**：`internal`（既定：内部ネットワーク経由で `http://cache-server:3000/` にアクセス、ホストポート開放なし）および `host`（ジョブ内で `container:` を使う場合にホストポート `<port>:3000` を開放）に対応しています。`GHR_CACHE_MODE` で切り替えます。
- **コンテナジョブ（DooD）サポート**：ホストの Podman ソケットが `/var/run/docker.sock` と `/run/podman/podman.sock` の両方にマウントされるため、標準的な Docker コマンドがそのまま機能します。
- **ホストファイアウォール**：コンテナが `https://api.github.com` と通信できる必要があります。インストーラーは起動前に疎通テストを行い、必要に応じてルーティング設定（例: `sudo ufw route allow in on podman1`）を案内します。
- **再起動ポリシー**：ユニットには `StartLimitIntervalSec=0` と `RestartSec=10` が付与されており、一時的なネットワーク障害等が発生しても 10 秒ごとに再試行を継続し、systemd の `failed` 状態に陥るのを防ぎます。

詳細については [deployments/podman/README.md](deployments/podman/README.md) を参照してください。

---

## デプロイメントマトリクス

| 構成トポロジー | Docker Compose | CapRover | Kubernetes | Podman + systemd |
|---|---|---|---|---|
| **単一ランナー** | [docker-compose.yml](docker-compose.yml) | [単一アプリガイド](deployments/caprover/README.md) | [Deployment + PVC](deployments/kubernetes/README.md#option-b-single-runner-deployment) | [Podman デプロイ](deployments/podman/README.md) |
| **複数ランナー（独立）** | [docker-compose.multi.yml](deployments/docker-compose/docker-compose.multi.yml) | [マルチアプリ構成](deployments/caprover/README.md#option-b-independent-single-runner-apps) | [StatefulSet クラスタ](deployments/kubernetes/README.md#option-a-scalable-cluster-statefulset) | [ランナーの追加](deployments/podman/README.md#adding-runners-later) |
| **複数ランナー + 共有キャッシュ** | [マルチリポキャッシュ Compose](deployments/docker-compose/multi-repo-cache/README.md) | [ワンクリックテンプレート](deployments/caprover/multi-repo-cache/README.md) | [Kustomize マニフェスト](deployments/kubernetes/multi-repo-cache/README.md) | [キャッシュモード解説](deployments/podman/README.md#cache-server-modes) |

---

## 1. クイックスタート（単一コンテナの手動実行）

単一のランナーコンテナをすばやく試す場合は、`docker run` を直接使用できます。

### ステップ 1: 登録トークンの取得
GitHub リポジトリまたは組織でランナー登録トークンを発行します：
- **リポジトリ**: `Settings` > `Actions` > `Runners` > `New runner`
- **組織**: `Organization Settings` > `Actions` > `Runners` > `New runner`

### ステップ 2: コンテナの起動
ホストマシンで次のコマンドを実行します：

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

ランナーが自動設定されて GitHub に登録され、ジョブの待機を開始します。登録情報は `runner_data` ボリュームに保持されるため、コンテナ再起動時に再登録は不要です。

---

## 2. キャッシュサーバーとの連携

本イメージは、外部の GitHub Actions Cache Server（例: [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)）に対応しています。イメージ内には `ACTIONS_RESULTS_URL` 用のバイナリパッチが含まれており、高速圧縮のための `zstd` が同梱されています。

### キャッシュの有効化方法

`ACTIONS_RESULTS_URL` 環境変数を設定します：

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -e ACTIONS_RESULTS_URL="http://cache-server:3000/" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

`ACTIONS_RESULTS_URL` を指定した場合：
1. ワークフロー内の `actions/cache` ステップが指定したキャッシュサーバーと直接キャッシュを保存・復元します。
2. 内蔵パッチの上書きを防ぐため、公式の自動更新が無効化されます（`--disableupdate`）。
3. ワークフローでコンテナアクション（`container:`）を実行する場合は、ホストから到達可能な URL（例: `http://host.docker.internal:3000/` やホスト IP）を指定してください。

---

## 3. Docker Compose による構成管理

Docker Compose を利用してランナーとキャッシュサーバーを一括管理できます。

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
    build:
      context: .
      dockerfile: Dockerfile
    image: bestony/self-hosted-runner:latest
    restart: unless-stopped
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_1:-${RUNNER_NAME:-}}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_1:-${RUNNER_NAME_PREFIX:-runner-1-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
    volumes:
      - runner_1_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}:${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
    depends_on:
      cache-server:
        condition: service_started
        required: false

  runner-2:
    <<: *runner-base
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_2:-}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_2:-${RUNNER_NAME_PREFIX:-runner-2-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
    volumes:
      - runner_2_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}:${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
    profiles:
      - multi
      - scale
      - all

  cache-server:
    image: ghcr.io/falcondev-oss/github-actions-cache-server:latest
    restart: unless-stopped
#   ports:
#     - "${CACHE_PORT:-3000}:3000"
    environment:
      API_BASE_URL: ${CACHE_API_BASE_URL:-http://cache-server:3000}
      STORAGE_DRIVER: filesystem
      STORAGE_FILESYSTEM_PATH: /data/cache
      DB_DRIVER: sqlite
      DB_SQLITE_PATH: /data/cache-server.db
    volumes:
      - cache_data:/data
    profiles:
      - cache
      - full
      - all

volumes:
  runner_1_data:
  runner_2_data:
  runner_3_data:
  runner_4_data:
  cache_data:
```

### 使用手順

1. `.env` ファイルを作成：
   ```bash
   cp .env.example .env
   ```
2. `.env` 内の `RUNNER_URL` および `RUNNER_TOKEN` を設定。
3. サービスを起動：
   ```bash
   # 単一ランナーインスタンスの起動（デフォルト）
   docker compose up -d

   # 2 つの並列ランナーインスタンスを起動
   docker compose --profile multi up -d

   # 4 つの並列ランナーインスタンスにスケール
   docker compose --profile scale up -d

   # キャッシュサーバー付きで起動
   docker compose --profile cache up -d
   ```
4. ログの確認：
   ```bash
   docker compose logs -f
   ```

---

## 4. 単一ホストでの複数独立スタック運用

同一ホスト上で、異なるチームやプロジェクト向けの複数の独立したランナースタックを衝突なく安全に並行稼働できます：

- **プロジェクト名の分離**：各スタックは一意の Docker Compose プロジェクト名を使用します（`.env` の `COMPOSE_PROJECT_NAME` または `docker-compose.yml` 内の `name:`）。インストーラーは衝突のない決定論的な名称（`ghr-<dir>-<sha256:8>`）を自動生成します。
- **動的コンテナ命名**：静的な `container_name` を排除し、Compose によって `<project>-<service>-<index>` として動的に割り当てられます。
- **ネットワーク分離**：スタックごとに専用の bridge ネットワークが作成され、DNS やルーティングの干渉を防ぎます。
- **ボリュームおよび資格情報の隔離**：名前付きボリューム（`runner_data`、`cache_data` 等）はプロジェクト単位でスコープ化され、登録情報や SQLite データベースが混ざりません。
- **ワークスペースの分離**：ジョブ作業ディレクトリはディレクトリ単位（`${PWD}/work/<runner>` または `<install_dir>/work/runner-<n>`）で管理され、DooD ホストマウントの衝突を回避します。
- **キャッシュポートの競合回避**：既定の内部通信モードではホストポートをバインドせず、ホスト IP モードではスタックごとに異なるポート番号が自動設定されます。

---

## 5. GitHub ホストランナー互換性仕様

GitHub Marketplace の各種 Actions は、公式 GitHub-hosted ランナー環境を前提に設計されています。素のコンテナで運用すると、`EACCES: permission denied, mkdir '/opt/hostedtoolcache'`（`ruby/setup-ruby`, `actions/setup-python`）や `EACCES: permission denied, stat '/root/.gitconfig'`（`actions/checkout`）などの権限エラーが発生しがちです。

本イメージでは、これらの前提条件を環境仕様（Contract）として完全に満たしており、起動時に整合性を自動検証します：

| 仕様項目 | 本イメージの提供内容 |
|---|---|
| **実行ユーザー** | 非特権の `runner` ユーザーとして実行。`HOME=/home/runner` かつパスワード不要の `sudo` 権限を保持。 |
| **ツールキャッシュ** | `RUNNER_TOOL_CACHE` および `AGENT_TOOLSDIRECTORY` は `/opt/hostedtoolcache`（`runner` 所有）。インストールされたツールは `/runner` ボリューム（`/runner/_tool-cache`）に保存され、コンテナ再作成時も再ダウンロードを回避。 |
| **ワークスペース権限修正** | ジョブフック（`/opt/runner-hooks/fix-workspace-ownership.sh`）により、各ジョブの実行前後で root 所有となったファイルを `runner` ユーザー所有へ自動復元。 |
| **標準ツール一式** | Docker CLI、Buildx、Compose プラグイン（ホストのソケット経由）、GitHub CLI (`gh`)、`git`、`git-lfs`、`curl`、`wget`、`jq`、`zip`、`unzip`、`xz`、`zstd`、`rsync`、`openssh-client`、`python3`。 |
| **ネイティブビルド環境** | `build-essential`、`pkg-config`、および各種ヘッダー（`libssl-dev`, `libyaml-dev`, `libffi-dev`, `libreadline-dev`, `libgmp-dev`, `zlib1g-dev`）。Ruby gem、Node.js ネイティブモジュール、Python wheel のコンパイルが可能。 |
| **ロケール** | `LANG=C.UTF-8`。 |

> ジョブ内で `gh` CLI を使用する場合は、`env: GH_TOKEN: ${{ github.token }}` などのトークンを設定してください。特定ワークフロー限定でパッケージが必要な場合は、公式ランナーと同様に `sudo apt-get update && sudo apt-get install -y <package>` が実行可能です。

### 拡張設定オプション

ワークフローに特別な要件がある場合、イメージを再ビルドすることなく環境変数経由で挙動をカスタマイズできます：

| 環境変数 | デフォルト値 | 説明 |
|---|---|---|
| `RUNNER_EXTRA_APT_PACKAGES` | - | コンテナ起動時に自動インストールする apt パッケージ（スペースまたはカンマ区切り、例: `libpq-dev libsqlite3-dev`）。 |
| `RUNNER_WRITABLE_PATHS` | - | コロン区切りの絶対パスリスト。コンテナ起動時にディレクトリを作成し、`runner` ユーザーに所有権を付与します（`/usr` 等のシステム領域は除外）。 |
| `RUNNER_INIT_DIR` | `/opt/runner-init.d` | このディレクトリ内の各 `*.sh` スクリプトが、ランナー起動前に `bash` で実行されます。初期化処理のマウント用です。 |
| `RUNNER_TOOL_CACHE` | `/opt/hostedtoolcache` | ツールキャッシュの配置パス。ビルド済みバイナリにパスが埋め込まれているため、原則変更しないでください。 |
| `RUNNER_TOOL_CACHE_PERSIST` | `true` | `false` に設定するとツールキャッシュをコンテナ一時層に保持します。 |
| `FIX_WORKSPACE_OWNERSHIP` | `true` | `false` に設定するとワークスペース権限の自動修正フックを無効化します。 |
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` | 権限修復スクリプト | ジョブ開始時フックをカスタムスクリプトで差し替えます。 |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` | 権限修復スクリプト | ジョブ完了時フックをカスタムスクリプトで差し替えます。 |

> 拡張処理で軽微な問題が生じた場合でもランナーの起動は中断されず、ログに警告（Warning）が出力されます。

### 動作診断（Diagnostics）

コンテナ起動時、エントリポイントが `runner` ユーザーとして `runner-doctor` を自動実行します。要件が満たされていない項目がある場合はログに `FAIL` と原因が出力されます。稼働中のコンテナを手動診断するには：

```bash
docker exec -u runner <container> runner-doctor
```

### 並行ジョブ実行

マトリックスジョブを並列処理するには、同一ディレクトリで再度インストーラーを実行し、`[A]dd runners` を選択して複数のランナーを登録してください。1 つのランナーは一度に 1 つのジョブを実行します。

---

## 6. 詳細ドキュメント

より詳細な情報については、以下を参照してください：
- [deployments/podman/README.md](deployments/podman/README.md)：Podman + systemd (Quadlet) のデプロイ構成、ユニット設計、キャッシュモード、アンインストールおよびロールバック手順。
- [development.md](development.md)：アーキテクチャ詳細、環境変数リファレンス、DooD 設計、マルチプラットフォームビルド、Kubernetes / CapRover 構成、CI/CD 自動化。
- [GitHub リポジトリ](https://github.com/bestony/self-hosted-action-runner)：ソースコード、リリースノート、Issue トラッカー。
