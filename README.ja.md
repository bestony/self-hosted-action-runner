# Docker GitHub Actions セルフホストランナー (Self-Hosted Runner)

コンテナ化され、マルチアーキテクチャ（amd64 / arm64）に対応した GitHub Actions セルフホストランナーです。Docker ワークフロー（Docker-outside-of-Docker / DooD）をネイティブサポートし、GitHub Actions Cache Server によるキャッシュアクセラレーションを統合しています。

**言語ナビゲーション / Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [Español](README.es.md)

- **GitHub リポジトリ**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub リポジトリ**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

<img src="https://mobile.thematrixcrop.com/p/cKRqSiJRg" width="1" height="1" alt="" />

---

## なぜこのプロジェクトを選ぶのか？（比較）

| 比較項目 | GitHub公式ホストランナー | ネイティブ自前ランナー（手動構築） | 本プロジェクト（コンテナ型ランナー） |
|---|---|---|---|
| **コストと実行時間** | プライベートリポジトリは分単位で課金（$0.008〜/分）。 | 自前マシンのため実行時間無制限・追加料金なし。 | **追加の実行時間コストなし**。既存のサーバーやクラウドのリソースを最大活用。 |
| **ハードウェアとCPU構成** | 固定スペック（標準2コア）。大容量・ARMランナーは高額。 | ホスト環境次第だが、アーキテクチャ依存の手動設定が必要。 | **リソース割当は完全自由**。マルチアーキテクチャ（`amd64`、`arm64` / Apple Silicon / Raspberry Pi）にネイティブ対応。 |
| **デプロイ・運用の手軽さ** | 運用不要（GitHubによるフルマネージド）。 | 手動手順が煩雑：バイナリのダウンロード、ユーザー作成、systemd登録、手動更新が必要。 | **ワンライナー自動インストール**（`curl \| bash`）。Docker Compose や Podman Quadlet (systemd) でスマートに管理。 |
| **Actionsキャッシュ（`actions/cache`）** | リポジトリあたり10GB上限。インターネット越しの送受信で低速になりがち。 | 標準ではローカルキャッシュ非対応（複雑なS3/MinIO設定が必要、またはキャッシュ不可）。 | **共有Actionsキャッシュサーバーを内蔵**。バイナリパッチと `zstd` 高速圧縮に対応し、ローカルディスク・内部ネットワークで超高速。容量制限なし。 |
| **ホスト環境の分離と安全性** | ジョブごとにクリーンな使い捨てVMを提供。 | ホストOS上で直接実行されるため、パッケージの汚染やゴミファイルの残留が発生。 | **コンテナによる安全な分離**。DooD（Docker-outside-of-Docker）によりホスト環境を汚さずにDockerワークフローを実行。 |
| **ファイルパーミッション問題** | GitHub公式が透過的に管理。 | Dockerジョブがホスト上にroot権限のファイルを作成し、`EACCES: permission denied` が頻発。 | **パーミッション自動修復機能内蔵**。ジョブ前後にフックが走り、root所有ファイルを自動で `runner` 所有へ復帰。 |
| **複数リポジトリ・並列数の拡張** | プランの範囲内で自動並列実行。 | 複数ランナーの構築にはディレクトリやサービスの手動多重管理が必要で困難。 | **単一コマンドで複数リポジトリ・複数インスタンスを設定可能**。Compose profile（`multi`/`scale`）やPodmanで即座にスケール。 |
| **Marketplace Actionsとの互換性** | 100%完全互換。 | `/opt/hostedtoolcache` やビルドツールの不足によりActionsが失敗しやすい。 | **公式互換コントラクトに準拠**。事前設定済みツールキャッシュ、主要ビルドツール群、パスワード不要sudo、`runner-doctor` 自己診断を完備。 |

---

## 1. ワンライナー対話型インストーラー

単一または複数のリポジトリランナーをデプロイし、共有 Actions キャッシュサーバー（オプション）を構成するための最も簡単な方法です：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### 主な特徴
- **環境の事前検証と自動セットアップ**：Docker Engine と Compose v2 の存在を確認。Linux（`get.docker.com`）および macOS（Homebrew）での自動インストールに対応。
- **対話型ウィザード**：リポジトリ/組織 URL、非表示の登録トークン、ランナー名、ラベルを順に入力可能。1 回で複数ランナーを連続設定できます。
- **共有キャッシュサーバー連携**：`falcondev-oss/github-actions-cache-server` をワンクリックで構成し、DooD ホスト IP を自動解決。
- **高信頼性とセキュリティ**：`chmod 600` の厳格な権限で `docker-compose.yml` および `.env` を出力。登録トークンは Compose ファイル内に露出しません。

### 主なオプションフラグ
- `--dir <path>`：インストール先ディレクトリ（root：`/opt/github-runner`、一般ユーザー：`$HOME/github-runner`）。
- `--non-interactive`：`GHR_*` 環境変数を使用して完全自動でセットアップ。
- `--no-start`：設定ファイルのみ生成し、コンテナは起動しない。
- `--uninstall`：コンテナを停止・削除し、データボリュームの削除を確認。

> Docker の代わりに Podman を使用する Linux ホスト向けに、Podman Quadlet インストーラーも用意しています：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
> ```
> 詳細は [deployments/podman/README.md](deployments/podman/README.md) を参照してください。

---

## 2. Docker クイックスタート（手動・単一コンテナ）

インストーラーを使わずに、単一のランナーコンテナをすばやく試す場合：

### ステップ 1: 登録トークンの取得
GitHub リポジトリまたは組織でランナー登録トークンを発行します：
- **リポジトリ**: `Settings` > `Actions` > `Runners` > `New runner`
- **組織**: `Organization Settings` > `Actions` > `Runners` > `New runner`

### ステップ 2: コンテナの起動
ホスト上で次のコマンドを実行します：

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

ランナーは自動設定されて GitHub に登録され、ジョブの待機を開始します。登録情報は `runner_data` ボリュームに永続化されるため、コンテナ再起動時に再登録は不要です。

---

## 3. Docker Compose による構成管理

Docker Compose を利用して、複数ランナーや共有キャッシュサーバーを一元管理できます：

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
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
  cache_data:
```

### 使用手順

1. **設定ファイルの準備**：
   ```bash
   cp .env.example .env
   # .env 内の RUNNER_URL および RUNNER_TOKEN を設定
   ```

2. **サービスの起動**：
   ```bash
   # 単一ランナーの起動（デフォルト）
   docker compose up -d

   # 2 つの並列ランナーインスタンスを起動
   docker compose --profile multi up -d

   # キャッシュサーバー付きで起動
   docker compose --profile cache up -d
   ```

3. **ログの確認**：
   ```bash
   docker compose logs -f
   ```

---

## 4. ドキュメント＆高度なガイド

特定のデプロイ形態、アーキテクチャ詳細、運用ガイドについては以下を参照してください：

| テーマ | 参照ドキュメント | 内容説明 |
|---|---|---|
| **Podman + systemd** | [deployments/podman/README.md](deployments/podman/README.md) | Quadlet ユニット生成、systemd 起動ライフサイクル、ファイアウォール設定、キャッシュモード。 |
| **共有キャッシュサーバー** | [deployments/docker-compose/multi-repo-cache/README.md](deployments/docker-compose/multi-repo-cache/README.md) | キャッシュサーバー連携、DooD ルーティング、`actions/cache` の高速化。 |
| **単一ホストでの複数スタック分離** | [deployments/docker-compose/README.md](deployments/docker-compose/README.md) | 同一マシン上で複数スタックを衝突なく安全に並行稼働させる手法。 |
| **Kubernetes デプロイ** | [deployments/kubernetes/README.md](deployments/kubernetes/README.md) | StatefulSet クラスタ、Deployment + PVC マニフェスト、Kustomize 設定。 |
| **CapRover PaaS** | [deployments/caprover/README.md](deployments/caprover/README.md) | ワンクリックテンプレートによる CapRover への簡単デプロイ。 |
| **公式互換コントラクト＆拡張点** | [development.md#8-hosted-runner-compatibility-contract](development.md#8-hosted-runner-compatibility-contract) | ツールキャッシュ仕様（`/opt/hostedtoolcache`）、`runner-doctor` 診断、権限自動修復 hook。 |
| **アーキテクチャ＆環境変数一覧** | [development.md](development.md) | 完全な環境変数リファレンス、DooD 設計思想、マルチアーキテクチャビルド手法。 |
