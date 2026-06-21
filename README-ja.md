# redmine-docker-workspace-tools

Redmine/RedMica の Docker ワークスペースを構築・管理する CLI ツールです。

## 概要

`redmine-docker-workspace` は、システム管理者が Redmine または RedMica の Docker 実行環境（ワークスペース）を構築・維持するための Bash ベース CLI です。

**解決する課題:**
- Apache + Passenger で動作している既存 Redmine 環境を Docker へ移行する
- 既存の Docker ワークスペースを別サーバへ移行・再構築する
- 新規に Redmine/RedMica の Docker 環境をゼロから立ち上げる

構築した環境は、標準的な `docker compose` コマンドで起動・停止します。本ツールは初期構築と、プラグイン管理・マイグレーション等の継続的な保守作業を担います。

## 対象ユーザー

- Redmine または RedMica を管理するシステム管理者
- Passenger 運用から Docker へ移行したい管理者
- ステージング環境や開発環境を素早く立ち上げたい開発者

## 動作環境・前提条件

| 要件 | 詳細 |
|------|------|
| OS | Linux (bash 4.0 以上) |
| Docker | Docker Engine + `docker compose` プラグイン |
| passenger モード使用時の追加条件 | Apache + Passenger（mod_passenger）で動作中の Redmine 環境。スタンドアロン Passenger（`passenger start`）は非対応 |

## インストール

リポジトリを任意のディレクトリへクローンします。

```bash
git clone <repository-url> ~/redmine-docker-workspace-tools
```

`activate-workspace-tool.sh` を source することで、現在のシェルセッションにパスが追加されます。

```bash
source ~/redmine-docker-workspace-tools/activate-workspace-tool.sh
```

毎回 source を避けたい場合は、シェルプロファイルに追記します。

```bash
echo 'source "$HOME/redmine-docker-workspace-tools/activate-workspace-tool.sh"' >> ~/.bashrc
source ~/.bashrc
```

インストール確認:

```bash
redmine-docker-workspace --help
```

---

## 使い方

### 入力モード

`init` コマンドの `--mode` で、ワークスペースの作成元を指定します。

| モード | 用途 |
|--------|------|
| `passenger` | Apache + Passenger で動作中の Redmine から移行 |
| `workspace` | 既存 Docker ワークスペースを移行・再構築 |
| `new` | ゼロから新規構築 |

### 標準ワークフロー

以下の順序でコマンドを実行します。`status` で現在地を確認しながら進めてください。

```
init → generate → docker compose build → prepare-db → migrate → docker compose up -d → check
```

### ステップ詳細

#### 1. ワークスペース初期化

```bash
# passenger モード（Apache + Passenger の Redmine から移行）
redmine-docker-workspace init \
  --target /srv/redmine-workspace \
  --mode passenger \
  --redmine-root /var/lib/redmine \
  --apache-config-dir /etc/apache2/sites-enabled \
  --redmine 6.0.3

# workspace モード（既存 Docker ワークスペースを移行）
redmine-docker-workspace init \
  --target /srv/redmine-workspace-new \
  --mode workspace \
  --source /srv/redmine-workspace-old

# new モード（新規構築）
redmine-docker-workspace init \
  --target /srv/redmine-workspace \
  --mode new \
  --redmine 6.0.3
```

`init` 完了後、ワークスペースのルートで `source activate-workspace-tool.sh` を実行すると、以降のコマンドをワークスペース内から実行できるようになります。

#### 2. Docker 設定生成

```bash
cd /srv/redmine-workspace
redmine-docker-workspace generate \
  --bind-port 38080 \
  --relative-url-root /redmine   # サブディレクトリ運用する場合
```

#### 3. プラグイン追加・削除（任意）

`add-plugin` / `remove-plugin` でプラグインを管理できます。ビルド前に追加しておくことで、次のステップのビルド 1 回に含められます。詳細は[プラグイン管理](#プラグイン管理)を参照してください。

#### 4. Docker イメージビルド

```bash
docker compose build
```

#### 5. DB 準備

```bash
# Passenger の DB（PostgreSQL）からデータをインポートする場合
redmine-docker-workspace prepare-db --import-from /path/to/dump.sql

# 外部 DB から取得する場合
redmine-docker-workspace prepare-db --from-external-db

# 新規（空の DB）にする場合
redmine-docker-workspace prepare-db --fresh-db
```

#### 6. マイグレーション

```bash
redmine-docker-workspace migrate
```

#### 7. 起動・確認

```bash
docker compose up -d
redmine-docker-workspace check
```

#### 8. リバースプロキシ設定（任意）

Redmine はデフォルトでローカルホストにのみバインドされます（`--bind-host 127.0.0.1`）。外部からアクセスするには、Nginx や Apache 等のリバースプロキシを設定してください。

---

## プラグイン管理

### プラグインの追加

```bash
# 基本（URL のみ。プラグイン名は URL のベース名から自動解決）
redmine-docker-workspace add-plugin https://github.com/example/redmine_agile.git

# バージョン指定（タグまたはブランチ）
redmine-docker-workspace add-plugin https://github.com/example/redmine_agile.git \
  --ref v1.6.0
```

追加後は `docker compose build` → `migrate` → `docker compose up -d` → `check` を手動で実行してください（`status` で次のステップを確認できます）。

**手動配置プラグインの採用:**
`plugins/` に手動コピーまたは rsync で配置済みのプラグインは、`add-plugin` を実行することで管理下に採用できます。ディレクトリはそのまま保持され、メタデータ（サイドカーファイル）のみが書き込まれます。

### プラグインの削除

```bash
redmine-docker-workspace remove-plugin <plugin_name> --force
```

逆マイグレーションはツールが自動で実行します。削除後は `docker compose build`（イメージ再ビルドが必要な場合）→ `docker compose up -d` → `check` を手動で実行してください（`status` で次のステップを確認できます）。

---

## ワークスペース構造

```
/srv/redmine-workspace/
├── .rdc_state                    # ツールの状態ファイル（内部管理用）
├── .rdc_plugins/                 # プラグインのメタデータ（git URL・ref）
│   └── my_plugin
├── redmine-docker-workspace.log  # 操作ログ
├── activate-workspace-tool.sh    # PATH 設定スクリプト
├── docker-compose.yml            # 生成ファイル
├── Dockerfile                    # 生成ファイル
├── .env                          # 生成ファイル（DB パスワード等）
├── plugins/                      # Redmine プラグイン
│   └── my_plugin/
├── themes/                       # Redmine テーマ
├── files/                        # Redmine 添付ファイル
├── config/                       # configuration.yml 等
├── dbdump/                       # DB ダンプ保存先
└── logs/                         # Redmine ログ
```

---

## ログ

各サブコマンドの実行はワークスペースの `redmine-docker-workspace.log` へ記録されます。コマンド実行のたびにタイムスタンプ付きの `[CMD]` 行が記録されます。

---

## ドキュメント

- [サブコマンドリファレンス](docs/REFERENCE-ja.md) — 全オプション一覧
- [レシピスクリプト](docs/RECIPES-ja.md) — 環境構築手順のサンプルスクリプト

English documentation: [README](README.md) / [Reference](docs/REFERENCE.md) / [Recipes](docs/RECIPES.md)

---

## サポート・お問い合わせ

ご質問・不具合報告は [futuremine.jp のお問い合わせフォーム](https://futuremine.jp/) からご連絡ください。個人での開発・運営のため、すべてのご要望にお応えできるとは限りませんが、可能な範囲で対応いたします。

---

## ライセンス

Copyright (C) 2026 Futuremine Technologies

GNU General Public License v2 or later (GPL-2.0-or-later) の下で配布されます。詳細は [LICENSE](LICENSE) を参照してください。
