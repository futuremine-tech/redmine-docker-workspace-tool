# 機械可読（`--json`）リファレンス

`info`・`status`・`init --list`/`--list-all`の`--json`出力についてまとめたドキュメントです。対話的な人間の利用ではなく、複数ワークスペースを管理する外部ツール（レジストリ、オーケストレーションエージェント等）からのプログラム的な呼び出しを想定しています。それ以外の内容は[サブコマンドリファレンス](REFERENCE-ja.md)を参照してください。

JSONは1回の実行につき1ドキュメントを標準出力へ、ログ行等を混在させず出力します。エラー時も標準エラー出力ではなく標準出力へJSONを出力したうえで非ゼロ終了するため、成功・失敗いずれも同じ方法でパースできます。

---

## `info --json` — ワークスペースのスナップショット

```
redmine-docker-workspace info --json
```

複数ワークスペースを管理する外部ツール向けの読み取り専用スナップショットです（人間へパイプライン進捗を案内する`status`とは異なります）。他の大半のサブコマンドと異なり、`info`はDockerデーモンを前提としません。コンテナ稼働状態の取得のみベストエフォートで試み、疎通できない場合は「不明」として扱ったうえで、他の情報は通常通り出力し正常終了します。

**出力例:**

```json
{
  "workspace_path": "/home/user/ws/myredmine",
  "mode": "passenger",
  "product": "redmine",
  "target_image_tag": "6.0.3",
  "redmine_version": "6.0.3",
  "image": "futuremine/redmine:6.0.3",
  "redmine_bind": "127.0.0.1:38080",
  "relative_url_root": "",
  "steps": {
    "init": "done",
    "generate": "done",
    "prepare-db": "done",
    "migrate": "done",
    "check": "done"
  },
  "verification": {
    "status": "passed",
    "verified_at": "2026-08-17T02:00:00Z",
    "base_image_digest": "sha256:abcd1234..."
  },
  "runtime": {
    "state": "running",
    "started_at": "2026-08-17T02:05:11Z"
  }
}
```

`redmine_version`は実際に検出されたRedmine/RedMicaバージョンです（[バージョン・ベースイメージの検出](REFERENCE-ja.md#generate--docker-設定生成)参照）。未検出（本機能実装前に`generate`済みのワークスペース等）の場合は`target_image_tag`へフォールバックします。`verification`は`check`未実行時`{"status": "not_completed"}`のみになります。`runtime.state`は`running`・`stopped`・`unknown`（Docker疎通不可）のいずれかで、`started_at`は`state`が`running`のときのみ含まれます。

**エラー時**（未初期化またはクリーン済み）:

```json
{"error": "workspace_not_initialized", "message": "Workspace not initialized. Run 'init' to start."}
```

---

## `status --json` — パイプライン進捗

```
redmine-docker-workspace status --json
```

人間可読の`status`出力（各ステップの完了状態・次の推奨アクション）と同内容をJSONで出力します。`info`とは異なり、`status --json`は人間可読版と同様Dockerデーモンを前提とし、疎通不可時はエラー終了します。

**出力例:**

```json
{
  "steps": {
    "init": "done",
    "generate": "done",
    "prepare-db": "pending",
    "migrate": "pending",
    "check": "pending"
  },
  "external": {
    "compose_build": "pending",
    "compose_up": "pending",
    "compose_runtime": "stopped"
  },
  "url": "http://127.0.0.1:38081/redmine-auto/",
  "next_action": {
    "lines": [
      "Run one of:",
      "  redmine-docker-workspace prepare-db --import-from PATH",
      "  redmine-docker-workspace prepare-db --fresh-db",
      "Then: docker compose build (in /home/user/ws/myredmine)"
    ]
  }
}
```

`steps`は`info`と同じステップ名です。`external`は、このツールが自動実行しない3つの手動Docker Composeステップ（`compose_build`・`compose_up`・`compose_runtime`）を、人間可読出力の「External (reference)」節と同じ内容で報告します（`unknown (Docker daemon unreachable)`等の値も含みうる）。`next_action.lines`は`status`が表示する案内文をそのまま行配列にしたもので、文言の安定性は保証されない表示用の情報です。プログラムから進捗を追う場合は`steps`/`external`をポーリングしてください。

`url`は`redmine_bind`/`relative_url_root`から組み立てたRedmineアクセスURLで、`generate`完了後に設定されます（未完了時は`null`）。このフィールドは「Redmineが提供されるべきURL」を表すもので、現在実際にアクセス可能かどうか（`external.compose_runtime`で確認）とは独立しています。全ステップが`"done"`（`check`含む）であっても、それだけでは**現在Redmineが起動中であることを意味しません**— `check`は過去のある時点で検証に成功したという記録であり、その後`docker compose down`しても`check`の完了状態はリセットされません。`next_action`はこれを踏まえており、全ステップ完了済みでも`compose_runtime`が`running`でなければ、完了とは案内せず`docker compose up -d`を案内します。

**エラー時**（未初期化・クリーン済み・Docker疎通不可のいずれか）:

```json
{"error": "workspace_not_initialized", "message": "Workspace not initialized. Run 'init' to start."}
```

```json
{"error": "docker_daemon_unreachable", "message": "Docker デーモンに接続できません。Docker を起動してから再実行してください。"}
```

---

## `init --list --json` / `init --list-all --json` — 対応イメージ一覧

```
redmine-docker-workspace init --list --json
redmine-docker-workspace init --list-all --json
```

人間可読の`--list`/`--list-all`と同じタグ一覧をJSONで出力します。`auto`や`init`実行前にバージョン選択肢を提示する（GUI等の）用途を想定しています。`--list --json`は人間可読版と同じセマンティックバージョン絞り込み・`futuremine/redmine`の7.0.0閾値を適用し（[`init`](REFERENCE-ja.md#init--ワークスペース初期化)参照）、`--list-all --json`は絞り込みなしの全タグを含みます。

**出力例:**

```json
{
  "repositories": [
    {
      "cli_option": "--redmine",
      "repo": "library/redmine",
      "label": "Redmine < 7.0.0 (official)",
      "images": ["library/redmine:6.0.3", "library/redmine:6.0.2"]
    },
    {
      "cli_option": "--redmine",
      "repo": "futuremine/redmine",
      "label": "Redmine >= 7.0.0 (futuremine)",
      "images": ["futuremine/redmine:7.0.0", "futuremine/redmine:6.1.3"]
    },
    {
      "cli_option": "--redmica",
      "repo": "redmica/redmica",
      "label": "RedMica < 3.2.0",
      "images": ["redmica/redmica:2.7.0"]
    },
    {
      "cli_option": "--redmica",
      "repo": "futuremine/redmica",
      "label": "RedMica >= 3.2.0",
      "images": ["futuremine/redmica:3.2.0"]
    }
  ]
}
```

`images`は`docker pull`や`--redmine`/`--redmica`/`--base-image`へそのまま渡せる完全なイメージ参照（`<repo>:<tag>`）です。人間可読出力と異なり、`library/`プレフィックスは省略されません。

**一部失敗時**（例: 特定リポジトリでDocker Hubがレート制限された場合）、失敗したリポジトリは`images`の代わりに`"error": "fetch_failed"`として表現され、他のリポジトリは通常通り出力されます。

```json
{"repositories": [
  {"cli_option": "--redmine", "repo": "library/redmine", "label": "Redmine < 7.0.0 (official)", "error": "fetch_failed"},
  {"cli_option": "--redmine", "repo": "futuremine/redmine", "label": "Redmine >= 7.0.0 (futuremine)", "images": ["futuremine/redmine:7.0.0"]}
]}
```

**全滅時**（4リポジトリすべて取得失敗）:

```json
{"error": "fetch_failed", "message": "Failed to fetch tags for all repositories."}
```
