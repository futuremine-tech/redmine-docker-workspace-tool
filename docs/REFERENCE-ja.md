# サブコマンドリファレンス

## グローバルオプション

```
redmine-docker-workspace [--force] [--verbose] <subcommand> [...]
```

| オプション | 説明 |
|-----------|------|
| `-f`, `--force` | 破壊的操作の確認プロンプトをスキップ |
| `-v`, `--verbose` | デバッグ出力を有効化 |
| `-V`, `--version` | バージョン情報を表示 |
| `-h`, `--help` | ヘルプを表示 |

---

## `init` — ワークスペース初期化

```
redmine-docker-workspace init --target PATH [--mode <passenger|workspace|new>] [options]
```

| オプション | 説明 |
|-----------|------|
| `--target PATH` | ワークスペースディレクトリ（必須） |
| `--mode MODE` | 入力モード（省略時: `new`） |
| `--redmine TAG` | Redmine イメージタグ |
| `--redmica TAG` | RedMica イメージタグ |
| `--base-image REPO:TAG` | 任意のベースイメージ（new モードのみ） |
| `--redmine-root PATH` | Redmine ルートディレクトリ（passenger モード） |
| `--apache-config-dir PATH` | Apache 設定ディレクトリ（passenger モード） |
| `--source PATH` | 移行元ワークスペース（workspace モード） |
| `--list` | 対応イメージ一覧を表示して終了（`x.y.z` 形式のみ、`--target` 不要） |
| `--list-all` | 対応イメージ一覧を表示して終了（派生タグ含む全件、`--target` 不要） |

---

## `generate` — Docker 設定生成

```
redmine-docker-workspace generate [options]
```

Dockerfile、docker-compose.yml、.env などを生成します。

| オプション | 説明 |
|-----------|------|
| `--bind-host HOST` | Redmine バインドホスト（既定: 127.0.0.1） |
| `--bind-port PORT` | Redmine ホスト公開ポート（既定: 自動検出） |
| `--db-publish-port PORT` | PostgreSQL をホストへ公開するポート（既定: ホスト非公開・Docker ネットワーク内のコンテナ間のみ接続可） |
| `--relative-url-root PATH` | サブディレクトリ運用パス（例: `/redmine`） |
| `--deployment` | ワークスペースルートの `Gemfile.lock` を使って `bundle install --deployment` を実行する（再現性のあるビルド） |

`--deployment` を指定すると、生成される Dockerfile には `COPY Gemfile.lock` と `bundle install --deployment` が含まれます。ワークスペースルートに `Gemfile.lock` がない場合はエラーになります。先に [`export-gemfile-lock`](#export-gemfile-lock--gemfilelock-の取り出し) でイメージからファイルを取り出してください。

`--deployment` なしで再実行すると、通常の `bundle install` に戻ります（`.rdc_state` の `deployment_build` が `false` に更新され、`docker compose build` で反映されます）。

---

## `prepare-db` — DB 準備

```
redmine-docker-workspace prepare-db (--import-from PATH | --fresh-db | --from-external-db | --skip --reason TEXT)
```

いずれか 1 つのオプションが必須です。

| オプション | 説明 |
|-----------|------|
| `--import-from PATH` | SQL ダンプをインポート |
| `--fresh-db` | 空の DB を作成 |
| `--from-external-db` | 外部 PostgreSQL から取得してインポート |
| `--skip --reason TEXT` | スキップ（理由を記録） |

---

## `migrate` — マイグレーション実行

```
redmine-docker-workspace migrate
```

`db:migrate` と `redmine:plugins:migrate` をコンテナ内で実行します。

---

## `check` — 動作確認

```
redmine-docker-workspace check
```

起動中の Redmine への HTTP アクセスを確認します。

---

## `dbdump` — DB ダンプ

```
redmine-docker-workspace dbdump [--dump-filename FILENAME]
```

ワークスペースの `db` コンテナから `pg_dump` を実行し `./dbdump/` に保存します。パイプラインの必須ステップではなく、任意のタイミングで使用できます。

---

## `status` — 状態確認

```
redmine-docker-workspace status
```

現在のパイプライン進捗、インストール済みプラグイン一覧、次のアクションを表示します。

**表示例:**

```
[init]       done
[generate]   done [deployment build]
[prepare-db] done
[migrate]    done
[check]      done

Plugins:
  redmine_agile              https://github.com/example/redmine_agile.git (ref: v1.6.0)
  my_custom_plugin           https://github.com/example/my_custom_plugin.git
  legacy_plugin              [manual]

Next action: All steps complete. Run 'docker compose up -d' to start Redmine.
```

`generate --deployment` で構築した場合、generate 行に `[deployment build]` が付きます。プラグインを追加・削除した後にイメージの再ビルドが必要な場合は、`docker compose build` の実行を案内します。

---

## `add-plugin` — プラグイン追加

```
redmine-docker-workspace add-plugin URL [--ref REF] [--name NAME] [--force]
```

| オプション | 説明 |
|-----------|------|
| `URL` | プラグインの git リポジトリ URL（必須） |
| `--ref REF` | タグまたはブランチ（省略時: デフォルトブランチ） |
| `--name NAME` | インストール先ディレクトリ名（省略時: URL のベース名） |
| `--force` | 既存ディレクトリを強制再クローン |

---

## `remove-plugin` — プラグイン削除

```
redmine-docker-workspace remove-plugin <plugin_name> --force
```

逆マイグレーション（`redmine:plugin:migrate VERSION=0`）を実行してから、プラグインディレクトリを削除します。`--force` は必須です。

---

## `export-gemfile-lock` — Gemfile.lock の取り出し

```
redmine-docker-workspace export-gemfile-lock [--force]
```

`docker compose build` 済みのイメージからコンテナ内の `/usr/src/redmine/Gemfile.lock` をワークスペースルートにコピーします。パイプラインの必須ステップではなく、任意のタイミングで実行できます。

| オプション | 説明 |
|-----------|------|
| `--force` | 既存の `Gemfile.lock` を確認なく上書き |

**利用フロー:**

```
# 1. 通常ビルドで Gemfile.lock を確定させる
docker compose build

# 2. イメージから取り出す
redmine-docker-workspace export-gemfile-lock

# 3. 以降は再現性のあるビルドを使う
redmine-docker-workspace generate --deployment
docker compose build
```

イメージが存在しない場合（`docker compose build` 未実施）はエラーになります。

---

## `clean` — リセット

```
redmine-docker-workspace clean
```

生成ファイルを削除し、ワークスペースの状態をリセットします。再構築は `generate` から始めてください。
