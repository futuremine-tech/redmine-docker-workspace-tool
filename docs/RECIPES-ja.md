# レシピスクリプト

一連のコマンドをシェルスクリプトにまとめることで、環境構築手順をレシピ化・再現可能にできます。`set -euo pipefail` を指定することで、いずれかのステップが失敗した時点でスクリプトが停止します。

## passenger モードからの移行

```bash
#!/usr/bin/env bash
set -euo pipefail

source ~/redmine-docker-workspace-tools/activate-workspace-tool.sh

WORKSPACE=/srv/redmine-workspace

redmine-docker-workspace init \
  --target "$WORKSPACE" \
  --mode passenger \
  --redmine-root /var/lib/redmine \
  --apache-config-dir /etc/apache2/sites-enabled \
  --redmine 6.0.3

cd "$WORKSPACE"

redmine-docker-workspace generate --bind-port 38080

docker compose build

redmine-docker-workspace prepare-db --import-from /path/to/dump.sql

redmine-docker-workspace migrate

docker compose up -d

redmine-docker-workspace check
```

## new モードでの新規構築

```bash
#!/usr/bin/env bash
set -euo pipefail

source ~/redmine-docker-workspace-tools/activate-workspace-tool.sh

WORKSPACE=/srv/redmine-workspace

redmine-docker-workspace init \
  --target "$WORKSPACE" \
  --mode new \
  --redmine 6.0.3

cd "$WORKSPACE"

redmine-docker-workspace generate --bind-port 38080

docker compose build

redmine-docker-workspace prepare-db --fresh-db

redmine-docker-workspace migrate

docker compose up -d

redmine-docker-workspace check
```

## 再現性のあるビルド（Gemfile.lock 固定）

`--deployment` オプションを使うと、gem バージョンを固定し、環境・再ビルドをまたいで同一の依存関係でビルドできます。

**ステップ 1 — 一度ビルドして Gemfile.lock を取り出す:**

```bash
cd "$WORKSPACE"

# 通常ビルド: gem バージョンがイメージ内で解決・確定される
redmine-docker-workspace generate --bind-port 38080
docker compose build

# ビルド済みイメージから Gemfile.lock を取り出す
redmine-docker-workspace export-gemfile-lock
```

**ステップ 2 — 固定バージョンで再ビルド:**

```bash
# 取り出した Gemfile.lock を使って再生成
redmine-docker-workspace generate --deployment --bind-port 38080

# イメージ再ビルド — bundle install --deployment が使われる
docker compose build
```

以降は `generate --deployment` + `docker compose build` で常に同一の gem バージョンが使われます。

通常の `bundle install`（再ビルドのたびに依存を再解決）に戻すには、`--deployment` なしで `generate` を実行して `docker compose build` してください。
