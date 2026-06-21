#!/usr/bin/env bats
# test/bats/rdw_dbdump.bats
# 結合テスト: dbdump サブコマンド（スタンドアロンユーティリティ）
# 根拠要件: RDC-REQ-F0201, RDC-REQ-F0201A, RDC-REQ-F0202, RDC-REQ-F0203, RDC-REQ-F0204, RDC-REQ-F0909

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export RDC_ALLOW_MOCK=1
}

teardown() {
  rm -rf "$WS"
}

# ---- 全モード統一動作: compose db コンテナから pg_dump ----

# RDC-REQ-F0909: passenger モードでも自ワークスペースの compose db コンテナから dump を作成する
@test "[RDC-REQ-F0909] dbdump passenger: compose db コンテナから pg_dump でダンプを作成する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw dbdump
  [ "$status" -eq 0 ]
  ls "$WS/dbdump/"*.dump 2>/dev/null | grep -q "."
}

# RDC-REQ-F0909: workspace モードでも compose db コンテナから dump を作成する（source コピーではない）
@test "[RDC-REQ-F0909] dbdump workspace: compose db コンテナから pg_dump でダンプを作成する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=workspace" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw dbdump
  [ "$status" -eq 0 ]
  ls "$WS/dbdump/"*.dump 2>/dev/null | grep -q "."
}

# RDC-REQ-F0909: new モードでも compose db コンテナから dump を作成できる（以前はブロックされていた）
@test "[RDC-REQ-F0909] dbdump new: compose db コンテナから pg_dump でダンプを作成できる" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw dbdump
  [ "$status" -eq 0 ]
  ls "$WS/dbdump/"*.dump 2>/dev/null | grep -q "."
}

# ---- 異常系: compose 定義なし / db コンテナ未起動 ----

# RDC-REQ-F0201A: compose 定義が存在しない場合は理由を明示して失敗終了する
@test "[RDC-REQ-F0201A] dbdump: compose 定義が存在しない場合は理由を明示して失敗する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  # docker-compose.yml を生成しない状態で実行
  cd "$WS"
  RDC_MOCK_COMPOSE_DEFINED=false run rdw dbdump
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eqi "compose|定義|not found|not initialized"
}

# RDC-REQ-F0201A: db コンテナが未起動の場合は理由を明示して失敗終了する
@test "[RDC-REQ-F0201A] dbdump: db コンテナが未起動の場合は理由を明示して失敗する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  RDC_MOCK_DB_RUNNING=false run rdw dbdump
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eqi "db|running|起動|container"
}

# ---- パイプライン状態を変更しない ----

# RDC-REQ-F0204: dbdump はパイプライン外のユーティリティであり dbdump_status を状態ファイルに書き込まない
@test "[RDC-REQ-F0204] dbdump: 成功しても dbdump_status を .rdc_state に書き込まない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw dbdump
  [ "$status" -eq 0 ]
  # dbdump_status が書き込まれていないことを確認
  run grep "dbdump_status" "$WS/.rdc_state"
  [ "$status" -ne 0 ]
}

# ---- dbdump は自動ステータス表示をしない ----

# RDC-REQ-F0204: dbdump はパイプライン外のため完了後に Steps:/Next Action の自動表示をしない
@test "[RDC-REQ-F0204] dbdump: 完了後にパイプラインのステップ一覧を自動表示しない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw dbdump
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "Steps:"
}
