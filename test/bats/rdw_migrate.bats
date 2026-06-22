#!/usr/bin/env bats
# test/bats/rdw_migrate.bats
# 結合テスト: migrate サブコマンド
# 根拠要件: RDC-REQ-F0910G, RDC-REQ-F0919

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export RDC_ALLOW_MOCK=1
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=pending"
}

teardown() {
  rm -rf "$WS"
}

# RDC-REQ-F0910G: db:migrate と redmine:plugins:migrate を毎回実行する
@test "[RDC-REQ-F0910G] migrate: db:migrate と redmine:plugins:migrate を毎回実行する" {
  cd "$WS"
  run rdw migrate
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "Starting db:migrate"
  echo "$output" | grep -qi "Starting redmine:plugins:migrate"
  grep -q "migrate_status=done" "$WS/.rdc_state"
}

# RDC-REQ-F0919: migrate --help に migrate 後の next step が含まれる
@test "[RDC-REQ-F0919] migrate --help: migrate 後の次ステップが Usage に含まれる" {
  run rdw migrate --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "up\|check\|next\|次"
}

# ---- compose 稼働中ガード ----

# RDC-REQ-F0384A: Redmine 実行中は migrate を拒否し down を案内する
@test "[RDC-REQ-F0384A] migrate: Redmine コンテナが実行中の場合は migrate を拒否し down を案内する" {
  # Implementation added

  export RDC_MOCK_REDMINE_RUNNING=true
  cd "$WS"
  # docker compose up -d で Redmine が起動したまま
  run rdw migrate
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "docker compose down"
}

# ---- 前提不足ガード ----

# RDC-REQ-F0384B: 前提不足（prepare-db 未完了 / build stale）時は migrate を拒否し不足手順を案内する
@test "[RDC-REQ-F0384B] migrate: prepare-db が未完了の場合は migrate を拒否し prepare-db を案内する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=pending" \
    "migrate_status=pending"
  cd "$WS"
  run rdw migrate
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "prepare-db"
}

# ---- migrate 成功時の check pending 戻し ----

# RDC-REQ-F0386: migrate 成功時に check を pending へ戻す
@test "[RDC-REQ-F0386] migrate: 成功時に check_status が pending に戻る" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  cd "$WS"
  run rdw migrate
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "check_status")
  [ "$val" = "pending" ]
}

# ---- 逆行操作と確認プロンプト ----

# RDC-REQ-F0003A: 逆行再 migrate で確認プロンプトを要求する
@test "[RDC-REQ-F0003A] migrate: check 完료済みからの再 migrate で確認プロンプトが表示される" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw migrate < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "confirm\|overwrite\|force"
}

# RDC-REQ-F0003B: --force で確認プロンプトを省略できる
@test "[RDC-REQ-F0003B] migrate: --force で確認プロンプト省略する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw migrate --force
  [ "$status" -eq 0 ]
}

# RDC-REQ-F0003C: 非対話環境では --force なしを拒否する
@test "[RDC-REQ-F0003C] migrate: TTY でない環境では --force なしの逆行操作は失敗する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw migrate < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "force\|--force"
}

# ---- load_default_data (RDC-REQ-F0389) ----

# mode=new + fresh-db のとき load_default_data が実行される
@test "[RDC-REQ-F0389] migrate: mode=new かつ import_mode=fresh-db のとき load_default_data が実行される" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "import_mode=fresh-db" \
    "migrate_status=pending"
  cd "$WS"
  run rdw migrate
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "load_default_data"
}

# --lang en を指定すると REDMINE_LANG=en で実行される
@test "[RDC-REQ-F0389] migrate: --lang en を指定すると REDMINE_LANG=en で load_default_data が実行される" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "import_mode=fresh-db" \
    "migrate_status=pending"
  cd "$WS"
  run rdw migrate --lang en
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "REDMINE_LANG=en"
}

# mode=passenger のとき load_default_data は実行されない
@test "[RDC-REQ-F0389] migrate: mode=passenger のとき load_default_data は実行されない" {
  cd "$WS"
  run rdw migrate
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "load_default_data"
}

# mode=new でも import_mode=import-from のとき load_default_data は実行されない
@test "[RDC-REQ-F0389] migrate: mode=new でも import_mode=import-from のとき load_default_data は実行されない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "import_mode=import-from" \
    "migrate_status=pending"
  cd "$WS"
  run rdw migrate
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "load_default_data"
}

# --help に --lang が含まれる
@test "[RDC-REQ-F0389] migrate --help: --lang オプションが Usage に含まれる" {
  run rdw migrate --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--lang"
}

# ---- 完了後自動 status 表示 ----

# migrate 完了後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] migrate: 完了後にステップ状態一覧と次アクション案内が自動表示される" {
  cd "$WS"
  run rdw migrate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
}
