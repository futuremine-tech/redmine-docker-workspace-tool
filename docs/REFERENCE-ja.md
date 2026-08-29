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

大半のサブコマンド（`dbdump`・`prepare-db`・`migrate`・`export-gemfile-lock`・`status`・`auto`）はDockerデーモンが起動していることを前提とし、疎通できない場合は即座にエラー終了します（`init`・`check`・`add-plugin`はDockerを使わないため対象外）。`clean`・`remove-plugin`は削除処理自体はDocker非依存ですが、Redmineが起動中でないかを確認できないため、詳細は各コマンドの節を参照してください。`info`もDockerを前提とせず、コンテナ稼働状態の取得のみベストエフォートで試み、疎通不可時は「不明」として扱います（詳細は該当節を参照）。

`auto`が対象ワークスペースへ実行中の間は、`init`・`generate`・`prepare-db`・`migrate`・`check`はいずれもその同一ワークスペースへの実行を拒否します（別のワークスペースには影響しません）。詳細は[`auto`](#auto--ワンコマンドで新規ワークスペースを構築)を参照してください。

`info`・`status`・`init --list`/`--list-all`の`--json`出力については、[機械可読リファレンス](REFERENCE-JSON-ja.md)を参照してください。

---

## `auto` — ワンコマンドで新規ワークスペースを構築

```
redmine-docker-workspace auto (--redmine TAG | --redmica TAG | --base-image IMAGE_REF) (--fresh-db | --import-from PATH) [options]
```

`init`・`generate`・`prepare-db`・`docker compose build`・`migrate`・`docker compose up -d`・`check`を順に、1つのコマンドで一気通貫実行します。

**対象範囲**: 新規生成モード相当の入力のみ。Passenger入力モード・既存ワークスペース入力モードは`auto`では対応していません。これらは個別のサブコマンド（`init --mode passenger`または`init --mode workspace`から開始）を使用してください。

| オプション | 説明 |
|-----------|------|
| `--redmine TAG` | 目標Redmineイメージタグ（`--redmine`/`--redmica`/`--base-image`のいずれか1つが必須） |
| `--redmica TAG` | 目標RedMicaイメージタグ |
| `--base-image IMAGE_REF` | 目標ベースイメージ |
| `--target PATH` | ワークスペースディレクトリ（省略時: [`init`](#init--ワークスペース初期化)と同じ既定動作） |
| `--fresh-db` | 空のDBを作成（`--fresh-db`/`--import-from`のいずれか1つが必須） |
| `--import-from PATH` | 指定したダンプファイルから復元 |
| `--relative-url-root PATH` | サブディレクトリ運用パス（例: `/redmine`）、`generate`へそのまま引き継ぎ |
| `--bind-port PORT` | Redmineホスト公開ポート（既定: 自動検出）、`generate`へそのまま引き継ぎ |
| `--lang LANG` | 初期データ読み込み時の言語（既定: `ja`）、`migrate`へそのまま引き継ぎ |
| `--add-plugin URL[#ref]` | ビルド前にプラグインを追加（複数回指定可 — 複数プラグインには複数回指定） |

`--add-plugin`はgit URLをそのまま指定するか、`URL#ref`形式でタグ・ブランチを固定できます（例: `--add-plugin https://github.com/example/redmine_agile.git#v1.6.0`）。`#ref`を省略した場合はリポジトリの既定ブランチを取得するため、後日`auto`を再実行すると、プラグインリポジトリが更新されていれば異なるコミットが入る可能性があります。これは[`add-plugin`](#add-plugin--プラグイン追加)の`URL --ref REF`の簡略形であり、`--name`/`--force`オプションは`auto`からは指定できません。

いずれかのステップが失敗した場合、`auto`は直ちに停止し、どのステップがなぜ失敗したかを報告し、それ以上進みません。完了済みのステップは`.rdc_state`に記録されたままなので、`status`で状況を確認し、個別のサブコマンドで再実行するかを判断できます。自動的な再開機能はありません。最初からやり直すには、`clean`を実行してから`auto`を再実行してください。

`auto`は同一ワークスペースへの多重実行を拒否します。実行中はPIDロックファイル（`.rdc_auto.lock`）を保持し、完了時（成功・失敗いずれも）に自動的に解放します。`auto`が途中で強制終了された場合（Ctrl-C、`kill`等）、ロックファイルが残ることがあります — 再実行前に`clean`を実行して削除してください。

`auto`は常に自身でランダムな`DB_PASSWORD`を生成し、対話的な入力を求めることはありません（端末から直接`generate`を実行した場合とは異なり、`DB_PASSWORD`が他の方法で決定できない場合に対話入力を求めることがあります）。

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
| `--json` | `--list`/`--list-all`と併用時、一覧をJSON形式で出力 — [機械可読リファレンス](REFERENCE-JSON-ja.md)参照 |

`--redmine TAG` はタグのバージョンに応じて使用するイメージリポジトリを自動選択する。`7.0.0`
以降（および`latest`等の非セマンティックバージョンタグ）は、OSパッケージの脆弱性対策と
Pandoc同梱（Redmine 7.0以降の添付ファイルプレビュー機能に必要）を施した`futuremine/redmine:TAG`
を使用し、`7.0.0`未満は公式の`redmine:TAG`を使用する。バージョンに関わらず公式イメージを
使いたい場合は、代わりに`--base-image redmine:TAG`を指定すればこの自動選択を回避できる。
解決された`futuremine/redmine:TAG`が取得できない場合（このタグ群はオンデマンドでビルドされて
おり、まだ全リリースを網羅しているとは限らない）、`generate`は`--base-image`での再実行を
案内して失敗する。`--redmica TAG`も同様に、`3.2.0`未満は`redmica/redmica:TAG`、`3.2.0`以降
（公式イメージがそのバージョンでタグ提供を終了したため）は`futuremine/redmica:TAG`を選択する。

---

## `generate` — Docker 設定生成

```
redmine-docker-workspace generate [options]
```

Dockerfile、docker-compose.yml、.env などを生成します。

| オプション | 説明 |
|-----------|------|
| `--bind-host HOST` | Redmine バインドホスト（既定: 127.0.0.1） |
| `--bind-port PORT` | Redmine ホスト公開ポート（既定: 自動検出 — 下記参照） |
| `--db-publish-port PORT` | PostgreSQL をホストへ公開するポート（既定: ホスト非公開・Docker ネットワーク内のコンテナ間のみ接続可） |
| `--relative-url-root PATH` | サブディレクトリ運用パス（例: `/redmine`） |
| `--extra-config-mount FILENAME` | `config/FILENAME` をコンテナ内 `/usr/src/redmine/config/FILENAME` へ bind mount する（複数回指定可）。`FILENAME` は `config/` 配下の相対パス（`..` 不可、先頭 `/` 不可）で、ワークスペースに事前にファイルが存在している必要がある |
| `--deployment` | ワークスペースルートの `Gemfile.lock` を使って `bundle install --deployment` を実行する（再現性のあるビルド） |
| `--log-stdout` | Redmine のログを STDOUT へ出力する（`docker compose logs redmine` で参照）。未指定時は `log/production.log` へファイル出力 |

`--deployment` を指定すると、生成される Dockerfile には `COPY Gemfile.lock` と `bundle install --deployment` が含まれます。ワークスペースルートに `Gemfile.lock` がない場合はエラーになります。先に [`export-gemfile-lock`](#export-gemfile-lock--gemfilelock-の取り出し) でイメージからファイルを取り出してください。

`--deployment` なしで再実行すると、通常の `bundle install` に戻ります（`.rdc_state` の `deployment_build` が `false` に更新され、`docker compose build` で反映されます）。

`--extra-config-mount` は bind mount の配線のみを行い、ファイル内容の生成・雛形提供は行いません。Redmine core が `.example` を同梱しない、プラグイン固有の追加configファイル（例: `redmine_solid_queue` プラグインの `config/queue.yml`）向けの仕組みです。`generate` 実行前に `config/` 配下へファイルを作成しておいてください。

`generate` は `config/additional_environment.rb` も、`configuration.yml`・`database.yml` と同様にオプション指定不要で常時bind mountします。このファイルはRedmine公式が用意するRails initializerカスタマイズ用の拡張ポイントです（生成される `config/additional_environment.rb.example` 内のコメント参照。例: `config.active_job.queue_adapter = :inline`）。`config/additional_environment.rb` が未存在の場合、`generate` はイメージ内の `additional_environment.rb.example`（全行コメントのみで安全な既定値）からscaffoldします。既存ファイルは上書きしません。

`--log-stdout` なし（デフォルト）では、生成される docker-compose.yml に `RAILS_LOG_TO_STDOUT: ""` が設定され、公式イメージのデフォルト（STDOUT 出力）を上書きしてファイルログを有効にします。Redmine のログはワークスペース配下の `log/production.log` に出力されます。`--log-stdout` を指定すると `RAILS_LOG_TO_STDOUT: "true"` に切り替わります。

**ポート自動検出と兄弟ワークスペース**: `--bind-port` を省略すると、`generate` は38080番から順に空きポートを探します。「空き」の判定は2種類あります: (1) ホスト上で現在誰もLISTENしていないこと、(2) 兄弟ワークスペースディレクトリ（このワークスペースと同じ親ディレクトリの下にある、別のディレクトリ）がそのポートを既に予約していないこと（その兄弟ワークスペースの`.rdc_state`の`redmine_bind`を参照。そのワークスペースのコンテナが現在起動していなくても対象になります）。これにより、片方がまだ起動していない（または一旦停止した）状態でも、共通の親ディレクトリを持つ2つのワークスペースが同じポートを取得してしまうことを避けられます。1階層より深くネストした配置や、無関係な場所に散らばったワークスペースは確認対象外です。`--bind-port` を明示指定すると自動検出自体が発生しないため、このチェックは行われません — 明示指定したポートが既に使用中の場合は、自動変更せずそのまま失敗します。

**テーマのアセットプリコンパイル（Redmine 6.x 以降）**: Redmine 6.x 以降ではテーマ CSS がアセットパイプライン経由で配信されるため、`assets:precompile` が必要です。`generate` が生成する Dockerfile は、テーマパスが `/usr/src/redmine/public/themes` 配下でない場合（= 6.x 系）に `docker compose build` 時に自動で `assets:precompile` を実行します。`SECRET_KEY_BASE` は `.env` の値を Docker build secret 経由で参照し、イメージレイヤーには残りません。`workspace/themes/` にテーマを配置後、`docker compose build && docker compose up -d` を実行してください。Redmine 5.x 系（テーマが `public/themes/` 配下）では `assets:precompile` は実行されません。

**バージョン・ベースイメージの検出**: `generate` は、pullしたベースイメージ内部から実際のRedmine/RedMicaバージョンを検出し、ベースイメージのdigestとともに`.rdc_state`へ記録します。これは目標イメージタグが`latest`のような可変タグの場合に重要で、[`info`](#info--ワークスペース情報表示)は指定したタグ文字列そのものではなく、実際にpullされたバージョンを報告します。ベースイメージのdigestは`generate`実行時点のスナップショットであり、その後`docker compose build`（プラグイン・gem等を組み込む）を実行しても更新されません。したがってこの値は「ワークスペースがどのベースイメージから作られたか」を識別するものであり、ビルド後の実体そのものを指すものではありません（ローカルbuildで生成されるイメージのdigestは、プラグイン構成が同一でもbuildのたびに変わり再現性がないため追跡対象にしていません）。

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
redmine-docker-workspace status [--json]
```

| オプション | 説明 |
|-----------|------|
| `--json` | 同じステップ・進捗情報をJSON形式で標準出力へ出力 — [機械可読リファレンス](REFERENCE-JSON-ja.md)参照 |

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

Themes:
  farend_fancy               (manual)

Next action: All steps complete. Redmine is running at http://127.0.0.1:38080/.
```

`generate --deployment` で構築した場合、generate 行に `[deployment build]` が付きます。プラグインを追加・削除した後にイメージの再ビルドが必要な場合、または Redmine 6.x 系でテーマを追加・更新した後にイメージの再ビルドが必要な場合は、`docker compose build` の実行を案内します。

全ステップが`done`（`check`含む）であっても、それだけでは現在Redmineが起動中であることを意味しません — `check`は過去のある時点で検証に成功したという記録であり、その後`docker compose down`しても`check`の完了状態はリセットされません。`status`はこれを踏まえ、全ステップ完了済みでもRedmineコンテナが現在起動していなければ、完了とは案内せず`docker compose up -d`を案内します。

使用中の Docker が rootful（`docker` グループ所属等による、実質 root 権限での実行）で動作している場合、`status` はセキュリティ上のリスクがある旨の警告を表示します（[rootless Docker](https://docs.docker.com/engine/security/rootless/) への切り替えを検討してください）。

---

## `info` — ワークスペース情報表示

```
redmine-docker-workspace info [--json]
```

| オプション | 説明 |
|-----------|------|
| `--json` | 同じ内容をJSON形式で標準出力へ出力 — [機械可読リファレンス](REFERENCE-JSON-ja.md)参照 |

外部ツール（複数ワークスペースを管理するレジストリ等）向けの読み取り専用スナップショットです。人間へパイプライン進捗を案内する`status`とは異なり、対象製品種別・目標イメージタグ・実際に検出されたRedmine/RedMicaバージョン（`redmine_version`。[バージョン・ベースイメージの検出](#generate--docker-設定生成)参照。未検出（本機能実装前に`generate`済みのワークスペース等）の場合は目標イメージタグへフォールバック）・使用イメージ名・bindアドレス・`relative_url_root`・ワークスペースパス・各ステップ完了状況・検証要約（`check`が生成したmanifestより。`base_image_digest`を含む）・コンテナ稼働状態を出力します。他の大半のサブコマンドと異なり、`info`はDockerデーモンを前提としません。稼働状態の取得のみベストエフォートで試み、疎通できない場合は「不明」として扱ったうえで、他の情報は通常通り出力し正常終了します。

ワークスペースが未初期化（またはクリーン済み）の場合は失敗します。`--json`指定時は、エラーもプレーンテキストではなく標準出力へのJSONとして返すため、成功時・失敗時とも同じ方法でパースできます。

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

Dockerデーモンに疎通できない場合、`remove-plugin` はRedmineが起動中かどうかを確認できません。その旨を警告したうえで続行の確認を求めます（`--force` でプロンプトを省略）。

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

Dockerデーモンに疎通できない場合、`clean` はComposeが起動中かどうかを確認できません。その旨を警告したうえで続行の確認を求めます（`--force` でプロンプトを省略）。
