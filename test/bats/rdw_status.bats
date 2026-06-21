#!/usr/bin/env bats
# test/bats/rdw_status.bats
# 結合テスト: status サブコマンド（StatusService#run, StatusService#resolve_next_action）
# 根拠要件: RDC-REQ-F1001〜F1005, RDC-REQ-F1006, RDC-REQ-F1007, RDC-REQ-F0814, RDC-REQ-F0920〜F0923, RDC-REQ-F0950, RDC-REQ-F0951

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
}

teardown() {
  rm -rf "$WS"
}

# ---- StatusService#run ----

# RDC-REQ-F0920: .rdc_state の全ステップを読み取り完了/未完了の一覧を表示する
@test "[RDC-REQ-F0920] status run: .rdc_state 全ステップの完了/未完了一覧を表示する" {
  rdw_partial_state_until_generate "$WS"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "init"
  echo "$output" | grep -q "done\|完了"
  echo "$output" | grep -q "prepare-db"
  echo "$output" | grep -q "pending\|未完了"
}

# RDC-REQ-F0922: .rdc_state を変更しないことを確認する（読み取り専用）
@test "[RDC-REQ-F0922] status run: 実行後も .rdc_state が変更されない（読み取り専用）" {
  rdw_partial_state_until_generate "$WS"
  before=$(cat "$WS/.rdc_state")
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  after=$(cat "$WS/.rdc_state")
  [ "$before" = "$after" ]
}

# RDC-REQ-F0923: .rdc_state 未存在の場合に未初期化として init を案内する
@test "[RDC-REQ-F0923] status run: .rdc_state が存在しない場合は init を案内する" {
  cd "$WS"
  run rdw status
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "init\|初期化"
}

# ---- StatusService#resolve_next_action ----

# RDC-REQ-F0921: init 未完了 → init を案内する
@test "[RDC-REQ-F0921] status next: init 未完了の場合は init を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "init_status=pending"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "init"
}

# RDC-REQ-F0921: generate 未完了 → generate を案内する
@test "[RDC-REQ-F0921] status next: generate 未完了の場合は generate を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "generate"
}

# RDC-REQ-F1001: status の Steps: 一覧に dbdump が含まれない（パイプライン外のため）
@test "[RDC-REQ-F1001] status: Steps: 一覧に dbdump ステップが表示されない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "Steps:"
  # dbdump はパイプラインステップではないので Steps: ブロックに表示されない
  steps_block=$(echo "$output" | awk '/Steps:/,/^$/' | head -20)
  echo "$steps_block" | grep -qv "dbdump"
}

# RDC-REQ-F0814: generate 完了・イメージ未存在 → docker compose build を案内する
@test "[RDC-REQ-F0814] status next: generate 完了・イメージ未存在の場合は docker compose build を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_MOCK_IMAGE_EXISTS=false
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "docker compose build"
  unset RDC_MOCK_IMAGE_EXISTS
}

# RDC-REQ-F0814: generate 完了・イメージ存在・prepare-db 未完了 → prepare-db を案内する
@test "[RDC-REQ-F0814] status next: generate 完了・イメージ存在・prepare-db 未完了は prepare-db を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-01-01T00:00:00Z
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "prepare-db"
  unset RDC_MOCK_IMAGE_EXISTS
  unset RDC_MOCK_IMAGE_GENERATE_ID
}

# RDC-REQ-F0814: 古い image が残っていても generate より前に作られた build は pending 扱いにする
@test "[RDC-REQ-F0814] status next: generate 後に build されていない image は pending 扱いにする" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "generate_completed_at=2026-06-01T12:00:00Z" \
    "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-05-31T12:00:00Z
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "docker compose build"
  unset RDC_MOCK_IMAGE_EXISTS
  unset RDC_MOCK_IMAGE_GENERATE_ID
}

# RDC-REQ-F0814: prepare-db/migrate 済みでも build が古い場合は build を最優先で案内する
@test "[RDC-REQ-F0814] status next: prepare-db と migrate 済みでも stale image なら build を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "generate_completed_at=2026-06-01T12:00:00Z" \
    "import_status=done" "migrate_status=done" "check_status=pending"
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-05-31T12:00:00Z
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docker compose build"
  echo "$output" | grep -q "redmine-docker-workspace migrate"
  echo "$output" | grep -q "migrate[[:space:]]*pending"
  unset RDC_MOCK_IMAGE_EXISTS
  unset RDC_MOCK_IMAGE_GENERATE_ID
}

# RDC-REQ-F0921: prepare-db 完了・migrate 未完了 → migrate を案内する
@test "[RDC-REQ-F0921] status next: prepare-db 完了・migrate 未完了の場合は migrate を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "migrate"
}

# RDC-REQ-F0921: migrate 完了・check 未完了 → docker compose up -d と check を案内する
@test "[RDC-REQ-F0921] status next: migrate 完了・check 未完了は docker compose up -d と check を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=pending"
  cd "$WS"
  RDC_MOCK_COMPOSE_RUNNING=false run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "docker compose up\|check"
}

# RDC-REQ-F0921: migrate 完了・compose 起動済み・check 未完了 → check だけを案内する
@test "[RDC-REQ-F0921] status next: migrate 完了・compose 起動済み・check 未完了は check だけを案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=pending"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_COMPOSE_RUNNING=true run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "redmine-docker-workspace check"
  echo "$output" | grep -qv "docker compose up"
}

# RDC-REQ-F0921: db だけ起動していても redmine 未起動なら compose up -d は pending 扱い
@test "[RDC-REQ-F0921] status next: db のみ起動している場合は compose up -d を pending 扱いにする" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=pending"
  cd "$WS"
  RDC_MOCK_REDMINE_RUNNING=false run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "compose up -d"
  echo "$output" | grep -q "pending"
}

# RDC-REQ-F0921: 全ステップ完了 → 完了済みを表示する
@test "[RDC-REQ-F0921] status next: 全ステップ完了の場合は完了済みを表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" \
    "check_status=done" "redmine_bind=127.0.0.1:38080" \
    "relative_url_root=/redmine"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_REDMINE_RUNNING=true run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "complete\|完了\|all.*done"
  echo "$output" | grep -q "Redmine is running at: http://127.0.0.1:38080/redmine/"
}

# RDC-REQ-F0920: status は外部手動ステップ（compose build / up -d）を参照表示する
@test "[RDC-REQ-F0920] status run: 外部手動ステップとして compose build/up -d を表示する" {
  rdw_partial_state_until_generate "$WS"
  export RDC_MOCK_IMAGE_EXISTS=false
  export RDC_MOCK_COMPOSE_RUNNING=false
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "External (reference):"
  echo "$output" | grep -q "compose build"
  echo "$output" | grep -q "compose up -d"
  echo "$output" | grep -q "compose runtime"
  unset RDC_MOCK_IMAGE_EXISTS
  unset RDC_MOCK_COMPOSE_RUNNING
}

# RDC-REQ-F0920: status は compose プロジェクト実ランタイム（何かが起動中か）を表示する
@test "[RDC-REQ-F0920] status run: db のみ起動中でも compose runtime は running と表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=pending"
  cd "$WS"
  RDC_MOCK_REDMINE_RUNNING=false RDC_MOCK_COMPOSE_ANY_RUNNING=true run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "compose up -d"
  echo "$output" | grep -q "pending"
  echo "$output" | grep -q "compose runtime"
  echo "$output" | grep -q "running"
  echo "$output" | grep -q "mock-compose-container"
}

# ---- 実状態併用判定（image 鮮度） ----

# RDC-REQ-F0814A: generate 出力との鮮度不整合を検出して build を pending として案内する
@test "[RDC-REQ-F0814A] status next: generate より前に作られた古い image は docker compose build を案内する" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "generate_completed_at=2026-06-04T02:00:00Z" \
    "import_status=done" "migrate_status=done" "check_status=done"
  # image が generate より前に build された古い状態
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-06-03T12:00:00Z
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "docker compose build"
  unset RDC_MOCK_IMAGE_EXISTS
  unset RDC_MOCK_IMAGE_GENERATE_ID
}

# ---- 実行前提の一致検証 ----

# RDC-REQ-F1005A: status が未完了と判定した前提ステップを prepare-db/migrate でも拒否される
@test "[RDC-REQ-F1005A] status と各サブコマンドの受理条件が一致する（generate 未完了）" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending" \
    "migrate_status=pending" "check_status=pending"
  cd "$WS"
  # status が generate 未完了と案内
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "generate"
  # prepare-db を飛ばして実行しても status 同様に拒否される
  run rdw prepare-db --fresh-db
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "generate"
}

# RDC-REQ-F1005A: status が prepare-db 未完了と判定した場合 migrate でも拒否される
@test "[RDC-REQ-F1005A] status と各サブコマンドの受理条件が一致する（prepare-db 未完了）" {
  # Implementation added

  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" \
    "migrate_status=pending" "check_status=pending"
  cd "$WS"
  # status が prepare-db 未完了と案内
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "prepare-db"
  # migrate を実行しても status 同様に拒否される
  run rdw migrate
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "prepare-db"
}

# ---- Docker デーモン未起動時の挙動 ----

# Docker デーモンに接続できない場合 image/compose の状態を "unknown" として表示する
@test "[RDC-DESIGN] status: Docker デーモン未起動時は image/compose 状態を unknown として表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  # reachability gate は compose ファイル存在後にチェックされるためダミーを置く
  echo "services: {}" > "$WS/docker-compose.yml"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "unknown"
}

# Docker デーモンに接続できない場合、次アクション案内に Docker 起動を促すメッセージが出る
@test "[RDC-DESIGN] status: Docker デーモン未起動時は次アクション案内に Docker 起動促進メッセージが出る" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=pending"
  # reachability gate は compose ファイル存在後にチェックされるためダミーを置く
  echo "services: {}" > "$WS/docker-compose.yml"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Docker"
}

# ---- プラグイン一覧表示 ----

# RDC-REQ-F1006 / RDC-REQ-F0950:
# status が plugins/ を走査し、追跡あり・[manual] をそれぞれ正しく表示する
@test "[RDC-REQ-F0950] status: plugins/ のプラグイン一覧を追跡あり・[manual] を区別して表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  # 追跡済みプラグイン（メタデータファイルあり）
  mkdir -p "$WS/plugins/tracked_plugin" "$WS/.rdc_plugins"
  printf 'git_url=https://example.com/tracked_plugin.git\nref=v1.0.0\n' \
    > "$WS/.rdc_plugins/tracked_plugin"
  # 手動配置プラグイン（サイドカーファイルなし）
  mkdir -p "$WS/plugins/manual_plugin"
  touch "$WS/plugins/manual_plugin/init.rb"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  # 追跡済みプラグインの URL が表示されること
  echo "$output" | grep -q "tracked_plugin"
  echo "$output" | grep -q "https://example.com/tracked_plugin.git"
  # 手動配置プラグインが [manual] として表示されること
  echo "$output" | grep -q "manual_plugin"
  echo "$output" | grep -qi "\[manual\]"
}

# ---- プラグイン変更後のリビルド検出 ----

# RDC-REQ-F1007 / RDC-REQ-F0951:
# plugins_last_changed がイメージ作成時刻より新しい場合は rebuild 警告と docker compose build を案内する
@test "[RDC-REQ-F0951] status: plugins_last_changed がイメージ作成時刻より新しい場合に rebuild 警告を表示し docker compose build を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "generate_completed_at=2026-06-04T02:00:00Z" \
    "import_status=done" "migrate_status=done" "check_status=done" \
    "plugins_last_changed=2026-06-05T10:00:00Z"
  # image は存在するが plugins_last_changed がそれより新しい
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-06-04T02:00:00Z
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  # プラグイン変更後のリビルド警告が表示されること
  echo "$output" | grep -qi "plugin\|プラグイン"
  # docker compose build が次手順として案内されること
  echo "$output" | grep -qi "docker compose build"
  unset RDC_MOCK_IMAGE_EXISTS
  unset RDC_MOCK_IMAGE_GENERATE_ID
}


# ---- deployment_build 表示 ----

# RDC-REQ-F0210: deployment_build=true の場合に [deployment build] を表示する
@test "[RDC-REQ-F0963] status: deployment_build=true の場合に [deployment build] を表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.0.3" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done" \
    "deployment_build=true"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "deployment"
}

# RDC-REQ-F0210: deployment_build=false または未設定の場合は [deployment build] を表示しない
@test "[RDC-REQ-F0963] status: deployment_build=false の場合に deployment build を表示しない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.0.3" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done" \
    "deployment_build=false"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  run grep -qi "deployment" <<< "$output"
  [ "$status" -ne 0 ]
}
