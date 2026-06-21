#!/usr/bin/env bats
# test/bats/rdw_prepare_db.bats
# 結合テスト: prepare-db サブコマンド
# 根拠要件: RDC-REQ-F0911, RDC-REQ-F0911A, RDC-REQ-F0911B, RDC-REQ-F0911C, RDC-REQ-F0911D, RDC-REQ-F0918

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export RDC_ALLOW_MOCK=1
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" \
    "migrate_status=done" "check_status=pending"
}

teardown() {
  rm -rf "$WS"
}

# RDC-REQ-F0911: --fresh-db と --input-dump-file の同時指定を拒否する
@test "[RDC-REQ-F0911] prepare-db: --fresh-db と --import-from の同時指定は失敗する" {
  cd "$WS"
  run rdw prepare-db --fresh-db --import-from test/fixtures/sample.dump
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "conflict\|同時\|exclusive"
}

# RDC-REQ-F0911A: external dump 指定時に workspace dump を探索しない
@test "[RDC-REQ-F0911A] prepare-db: --import-from 指定時は workspace 内 dump を探索しない" {
  # workspace に別の dump を置いておいても --import-from が優先される
  cp test/fixtures/sample.dump "$WS/dbdump/other.dump"
  cd "$WS"
  run rdw prepare-db --import-from test/fixtures/sample.dump
  [ "$status" -eq 0 ]
  grep -q "import_status=done" "$WS/.rdc_state"
}

# RDC-REQ-F0911B: 入力方針未指定は失敗
@test "[RDC-REQ-F0911B] prepare-db: 入力方針未指定は失敗し明示指定を要求する" {
  cp test/fixtures/sample.dump "$WS/dbdump/"
  cd "$WS"
  run rdw prepare-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "No input route\|Specify exactly one\|--import-from\|--fresh-db\|--skip"
}

# RDC-REQ-F0911C: dump 自動探索・自動採用をしない
@test "[RDC-REQ-F0911C] prepare-db: dump 候補が複数でも自動探索せず失敗する" {
  cp test/fixtures/sample.dump "$WS/dbdump/dump1.dump"
  cp test/fixtures/sample.dump "$WS/dbdump/dump2.dump"
  cd "$WS"
  run rdw prepare-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eqi -e "--import-from|No input route|Specify exactly one"
}

# RDC-REQ-F0911D: --skip には --reason が必須
@test "[RDC-REQ-F0911D] prepare-db: --skip 指定時に --reason 未指定なら失敗する" {
  cd "$WS"
  run rdw prepare-db --skip
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eqi -e "--reason"
}

# RDC-REQ-F0918: 不正パスを理由付きで拒否する
@test "[RDC-REQ-F0918] prepare-db: 存在しない --import-from パスは理由付きで失敗する" {
  cd "$WS"
  run rdw prepare-db --import-from /nonexistent/path.dump
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not found\|exist\|read\|存在"
}

# ---- compose 稼働中ガード ----

# RDC-REQ-F0354A: Redmine 実行中は prepare-db を拒否し down を案内する
@test "[RDC-REQ-F0354A] prepare-db: Redmine コンテナが実行中の場合は prepare-db を拒否し down を案内する" {
  # Implementation added

  export RDC_MOCK_REDMINE_RUNNING=true
  cd "$WS"
  # docker compose up -d で Redmine が起動したまま
  run rdw prepare-db --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "docker compose down"
}

# ---- 前提不足ガード ----

# RDC-REQ-F0354B: 前提不足（先飛ばし）時は prepare-db を拒否し不足手順を案内する
@test "[RDC-REQ-F0354B] prepare-db: generate が未完了の場合は prepare-db を拒否し generate を案内する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending"
  cd "$WS"
  run rdw prepare-db --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "generate"
}

# ---- import 成功時の pending 戻し ----

# RDC-REQ-F0355A: prepare-db 成功時に migrate/check を pending へ戻す
@test "[RDC-REQ-F0355A] prepare-db: 成功時に migrate_status と check_status が pending に戻る" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" \
    "migrate_status=done" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  cp test/fixtures/sample.dump "$WS/dbdump/"
  cd "$WS"
  run rdw prepare-db --import-from test/fixtures/sample.dump
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "migrate_status")
  [ "$val" = "pending" ]
  val=$(rdw_read_state "$WS" "check_status")
  [ "$val" = "pending" ]
}

# RDC-REQ-F0354: fresh-db 経路では既存 db コンテナを流用せず、compose プロジェクト内の DB を新規作成して空状態を保証する
# ---- 逆行操作と確認プロンプト ----

# RDC-REQ-F0003A: 逆行再 prepare-db で確認プロンプトを要求する
@test "[RDC-REQ-F0003A] prepare-db: check 完了済みからの再 prepare-db で確認プロンプトが表示される" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  cp test/fixtures/sample.dump "$WS/dbdump/"
  cd "$WS"
  run rdw prepare-db --import-from test/fixtures/sample.dump < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "confirm\|overwrite\|force"
}

# RDC-REQ-F0003B: --force で確認プロンプトを省略できる
@test "[RDC-REQ-F0003B] prepare-db: --force で確認プロンプト省略する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  cp test/fixtures/sample.dump "$WS/dbdump/"
  cd "$WS"
  run rdw prepare-db --import-from test/fixtures/sample.dump --force
  [ "$status" -eq 0 ]
}

# RDC-REQ-F0003C: 非対話環境では --force なしを拒否する
@test "[RDC-REQ-F0003C] prepare-db: TTY でない環境では --force なしの逆行操作は失敗する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  cp test/fixtures/sample.dump "$WS/dbdump/"
  cd "$WS"
  run rdw prepare-db --import-from test/fixtures/sample.dump < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "force\|--force"
}

# ---- --from-external-db ----

# RDC-REQ-F0351B: passenger モード（redmine_root あり）で --from-external-db が成功する
@test "[RDC-REQ-F0351B] prepare-db --from-external-db: passenger モードで外部 DB から pg_dump → リストアする" {
  # redmine_root と database.yml を疑似設定
  local fake_redmine_root="$WS/fake_redmine"
  mkdir -p "$fake_redmine_root/config"
  cat > "$fake_redmine_root/config/database.yml" <<'DBEOF'
production:
  adapter: postgresql
  host: localhost
  database: redmine
  username: redmine
  password: secret
DBEOF
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "redmine_root=$fake_redmine_root" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  cd "$WS"
  run rdw prepare-db --from-external-db
  [ "$status" -eq 0 ]
  grep -q "import_status=done" "$WS/.rdc_state"
}

# RDC-REQ-F0351B: workspace モードで --from-external-db を実行すると外部 DB 情報なしとして失敗する
@test "[RDC-REQ-F0351B] prepare-db --from-external-db: workspace モードでは外部 DB 情報なしとして失敗する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=workspace" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  run rdw prepare-db --from-external-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eqi "external|passenger|redmine_root|外部"
}

# RDC-REQ-F0351B: new モードで --from-external-db を実行すると外部 DB 情報なしとして失敗する
@test "[RDC-REQ-F0351B] prepare-db --from-external-db: new モードでは外部 DB 情報なしとして失敗する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  run rdw prepare-db --from-external-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eqi "external|passenger|redmine_root|外部"
}

# RDC-REQ-F0352: --from-external-db と --import-from の同時指定を拒否する
@test "[RDC-REQ-F0352] prepare-db: --from-external-db と --import-from の同時指定は失敗する" {
  cd "$WS"
  run rdw prepare-db --from-external-db --import-from test/fixtures/sample.dump
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "conflict\|同時\|exclusive"
}

# RDC-REQ-F0352: --from-external-db と --fresh-db の同時指定を拒否する
@test "[RDC-REQ-F0352] prepare-db: --from-external-db と --fresh-db の同時指定は失敗する" {
  cd "$WS"
  run rdw prepare-db --from-external-db --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "conflict\|同時\|exclusive"
}

# RDC-REQ-F0361: --help に --from-external-db の選択肢が含まれる
@test "[RDC-REQ-F0361] prepare-db --help: --from-external-db オプションが Usage に含まれる" {
  cd "$WS"
  run rdw prepare-db --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\-\-from-external-db"
}

# ---- 完了後自動 status 表示 ----

# prepare-db 完了後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] prepare-db: 完了後にステップ状態一覧と次アクション案内が自動表示される" {
  cd "$WS"
  run rdw prepare-db --fresh-db
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
}
