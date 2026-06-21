#!/usr/bin/env bats
# test/bats/rdw_check.bats
# 結合テスト: check サブコマンド
# 根拠要件: RDC-REQ-F0912, RDC-REQ-F0912A, RDC-REQ-F0912B, RDC-REQ-F0912C, RDC-REQ-F0409, RDC-REQ-F0410, RDC-REQ-F0924

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending"
}

teardown() {
  rm -rf "$WS"
}

# RDC-REQ-F0912: Powered by Redmine をタグ除去後本文で判定する
@test "[RDC-REQ-F0912] check: Powered by Redmine を本文テキストで正常判定する" {
  # HTTP レスポンスを fixture で差し替え（モック環境前提）
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  grep -q "check_status=done" "$WS/.rdc_state"
  [ -f "$WS/verification/manifest.json" ]
}

# RDC-REQ-F0912A: fresh-db 正常応答を別判定で扱える
@test "[RDC-REQ-F0912A] check: fresh-db モードでの初期画面応答を正常と判定する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "generate_status=done" \
    "import_status=done" "migrate_status=done" "check_status=pending" \
    "fresh_db_selected=true"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/fresh_db_redmine.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
}

# RDC-REQ-F0912B: 成功時 manifest を生成する
@test "[RDC-REQ-F0912B] check: 正常完了時に verification/manifest.json を出力する" {
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  [ -f "$WS/verification/manifest.json" ]
  grep -q '"status"' "$WS/verification/manifest.json"
  grep -q '"passed"' "$WS/verification/manifest.json"
}

# RDC-REQ-F0912B: explicit mode（target_image_tag 空）でも manifest 出力で失敗しない
@test "[RDC-REQ-F0912B] check: explicit mode で target_image_tag が空でも manifest 出力に成功する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=" \
    "image_source=explicit" "image_ref=futuremine/redmica:4.1.1" \
    "target_image_tag=" "init_status=done" "dbdump_status=pending" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  [ -f "$WS/verification/manifest.json" ]
  grep -q '"status": "passed"' "$WS/verification/manifest.json"
  grep -q '"image_digest": "futuremine/redmica:4.1.1"' "$WS/verification/manifest.json"
}

# RDC-REQ-F0912C: 失敗時 manifest が成功結果と混同しない
@test "[RDC-REQ-F0912C] check: HTTP タイムアウト時の manifest に passed が含まれない" {
  export RDC_MOCK_HTTP_RESPONSE=""
  export RDC_MOCK_HTTP_STATUS="timeout"
  cd "$WS"
  run rdw check
  [ "$status" -ne 0 ]
  [ -f "$WS/verification/manifest.json" ]
  grep -qv '"status": "passed"' "$WS/verification/manifest.json"
}

# ---- relative_url_root ----

# RDC-REQ-F0409: relative_url_root が設定されている場合、出力アクセス URL にサブパスが含まれる
@test "[RDC-REQ-F0409] check: relative_url_root=/redmine 設定時、出力に /redmine が含まれる" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending" "redmine_bind=127.0.0.1:38080" \
    "relative_url_root=/redmine"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "/redmine"
}

# RDC-REQ-F0409: relative_url_root が未設定の場合、出力にサブパスが含まれない
@test "[RDC-REQ-F0409] check: relative_url_root 未設定時、出力に /redmine が含まれない" {
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "http://[^/]*/redmine"
}

# RDC-REQ-F0409: relative_url_root 設定時、Apache 設定例にサブパスが含まれる
@test "[RDC-REQ-F0409] check: relative_url_root=/redmine 設定時、Apache 設定例に /redmine が含まれる" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending" "redmine_bind=127.0.0.1:38080" \
    "relative_url_root=/redmine"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ProxyPass"
  echo "$output" | grep -q "/redmine"
}

# RDC-REQ-F0410 / F0924: reverse proxy 確認成功時は設定済み表示し、ガイドも表示する
@test "[RDC-REQ-F0410][RDC-REQ-F0924] check: reverse proxy 到達確認成功時は結果表示とガイドを表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending" "redmine_bind=127.0.0.1:38080" \
    "relative_url_root=/redmine"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  export RDC_MOCK_PROXY_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Reverse proxy route is already reachable: http://localhost/redmine/"
  echo "$output" | grep -q "Apache example"
  unset RDC_MOCK_PROXY_HTTP_RESPONSE
}

# RDC-REQ-F0410 / F0924: reverse proxy 確認失敗時は設定ガイドを表示する
@test "[RDC-REQ-F0410][RDC-REQ-F0924] check: reverse proxy 到達確認失敗時はガイドを表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending" "redmine_bind=127.0.0.1:38080" \
    "relative_url_root=/redmine"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  export RDC_MOCK_PROXY_HTTP_STATUS="timeout"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Apache example"
  echo "$output" | grep -q "ProxyPass"
  unset RDC_MOCK_PROXY_HTTP_STATUS
}

# RDC-REQ-F0409: -v 時は HTTP probe の詳細が DEBUG で表示される
@test "[RDC-REQ-F0409] check: -v 指定時に probe URL の DEBUG 情報が表示される" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=pending" "redmine_bind=127.0.0.1:38080" \
    "relative_url_root=/redmine"
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check -v
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[DEBUG\] HTTP probe URL: http://127.0.0.1:38080/redmine/"
  echo "$output" | grep -q "\[DEBUG\] HTTP probe attempt 1/15"
}

# ---- 完了後自動 status 表示 ----

# check 完了後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] check: 完了後にステップ状態一覧と次アクション案内が自動表示される" {
  export RDC_MOCK_HTTP_RESPONSE="$(cat test/fixtures/html/redmine_powered.html)"
  cd "$WS"
  run rdw check
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
}
