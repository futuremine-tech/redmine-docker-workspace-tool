#!/usr/bin/env bats
# test/bats/rdw_status.bats
# 結合テスト: status サブコマンド（StatusService#run, StatusService#resolve_next_action）
# 根拠要件: RDC-REQ-F1001〜F1005, RDC-REQ-F1006, RDC-REQ-F1007, RDC-REQ-F0814, RDC-REQ-F0920〜F0923, RDC-REQ-F0950, RDC-REQ-F0951
# RDC-REQ-F1412〜F1414（status --json）、RDC-REQ-F0980〜F0981（テスト要件）
# 設計: develop/docs/1A-DESIGN-F1415-auto-and-json-outputs.md 2節

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

# ---- Docker デーモン未起動時の挙動 (RDC-REQ-F0001) ----
# 旧仕様（unknown表示 + exit 0）はRDC-REQ-F0001により置き換えられた。
# 「疎通不可時はrootful警告を表示しない」旧テスト（F1010）も、statusが状態表示に到達する前に
# 即エラー終了するようになったため本テストに統合された。

# RDC-REQ-F0001: Docker デーモンに疎通できない場合は状態表示を行わず即エラー終了する
@test "[RDC-REQ-F0001] status: Docker デーモンに疎通できない場合は即エラー終了する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=false run rdw status
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "接続できません"
  ! echo "$output" | grep -q "=== Workspace Status ==="
}

# ---- rootful Docker検出時のセキュリティ警告 (RDC-REQ-F1010) ----

# RDC-REQ-F1010: rootful Docker検出時は status にセキュリティ上のリスクがある旨の警告が出る
@test "[RDC-REQ-F1010] status: rootful Docker検出時はセキュリティ警告が表示される" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=true RDC_MOCK_DOCKER_ROOTLESS=false run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "rootful"
}

# RDC-REQ-F1010: rootless Docker検出時はセキュリティ警告が表示されない
@test "[RDC-REQ-F1010] status: rootless Docker検出時はセキュリティ警告が表示されない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  RDC_MOCK_DOCKER_DAEMON_REACHABLE=true RDC_MOCK_DOCKER_ROOTLESS=true run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qvi "rootful"
}

# 旧テスト「Dockerデーモン未起動時はrootful警告を表示しない（判定不能のため）」はRDC-REQ-F0001により
# 陳腐化した（statusはこのロジックへ到達する前に即エラー終了するため）。上記の
# [RDC-REQ-F0001] status: Docker デーモンに疎通できない場合は即エラー終了する に統合済み。

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

# ---- Themes: 一覧・変更検出 (RDC-REQ-F1008 / F1009) ----

# RDC-REQ-F1009: テーマ変更検出・rebuild警告（テーマパスが /usr/src/redmine/themes のとき）
@test "[RDC-REQ-F0970] status: RDC_MOCK_THEMES_CHANGED=true のとき themes 変更警告と docker compose build を案内する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "generate_completed_at=2026-06-04T02:00:00Z" \
    "import_status=done" "migrate_status=done" "check_status=done" \
    "themes_container_path=/usr/src/redmine/themes"
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-06-04T02:00:00Z
  export RDC_MOCK_THEMES_CHANGED=true
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "theme\|テーマ"
  echo "$output" | grep -qi "docker compose build"
  unset RDC_MOCK_IMAGE_EXISTS RDC_MOCK_IMAGE_GENERATE_ID RDC_MOCK_THEMES_CHANGED
}

# RDC-REQ-F1009: テーマ未変更のとき themes 警告を表示しない
@test "[RDC-REQ-F0971] status: RDC_MOCK_THEMES_CHANGED=false のとき themes 変更警告を表示しない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "generate_completed_at=2026-06-04T02:00:00Z" \
    "import_status=done" "migrate_status=done" "check_status=done" \
    "themes_container_path=/usr/src/redmine/themes"
  export RDC_MOCK_IMAGE_EXISTS=true
  export RDC_MOCK_IMAGE_GENERATE_ID=2026-06-04T02:00:00Z
  export RDC_MOCK_THEMES_CHANGED=false
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "themes have been"
  unset RDC_MOCK_IMAGE_EXISTS RDC_MOCK_IMAGE_GENERATE_ID RDC_MOCK_THEMES_CHANGED
}

# RDC-REQ-F1008: themes ディレクトリにサブディレクトリがあるとき一覧を表示する
@test "[RDC-REQ-F1008] status: themes/ にテーマがあるとき一覧を表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  mkdir -p "$WS/themes/farend_fancy"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "farend_fancy"
}

# RDC-REQ-F1008: themes ディレクトリが空のとき (no themes installed) を表示する
@test "[RDC-REQ-F1008] status: themes/ が空のとき (no themes installed) を表示する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no themes installed"
}

# ---- StatusService#run: JSON出力 (RDC-REQ-F1412〜F1414) ----

# RDC-REQ-F0980: status --json の出力が有効なJSON形式である
@test "[RDC-REQ-F0980] status --json: 出力が有効なJSON形式である" {
  rdw_partial_state_until_generate "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=false run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

# RDC-REQ-F1412, F0980: status --json は人間可読出力と同内容（各ステップの完了状態・次アクション）を含む
@test "[RDC-REQ-F1412][RDC-REQ-F0980] status --json: 各ステップの完了状態一覧と次アクションを含む" {
  rdw_partial_state_until_generate "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=false run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['steps']['init'] == 'done'
assert d['steps']['generate'] == 'done'
assert d['steps']['prepare-db'] == 'pending'
assert d['steps']['migrate'] == 'pending'
assert d['steps']['check'] == 'pending'
assert 'external' in d
assert isinstance(d['next_action']['lines'], list)
assert len(d['next_action']['lines']) > 0
"
}

# RDC-REQ-F1412: status --json の external セクションは compose build/up/runtime の状態を含む
@test "[RDC-REQ-F1412] status --json: external セクションに compose build/up/runtime の状態を含む" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_IMAGE_GENERATE_ID=2026-01-01T00:00:00Z RDC_MOCK_COMPOSE_RUNNING=true \
    run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['external']['compose_build'] == 'done'
assert d['external']['compose_up'] == 'done'
assert d['external']['compose_runtime'] == 'running'
"
}

# RDC-REQ-F1413: .rdc_state が存在しない場合、エラー内容を含むJSONを出力したうえで失敗終了する
@test "[RDC-REQ-F1413] status --json: .rdc_state が存在しない場合はエラーJSONを出力し失敗終了する" {
  cd "$WS"
  run rdw status --json
  [ "$status" -ne 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'error' in d"
}

# RDC-REQ-F1413: クリーン済みワークスペースでもエラーJSONを出力したうえで失敗終了する
@test "[RDC-REQ-F1413] status --json: クリーン済みワークスペースはエラーJSONを出力し失敗終了する" {
  rdw_init_state "$WS" "clean_status=done"
  cd "$WS"
  run rdw status --json
  [ "$status" -ne 0 ]
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'error' in d"
}

# RDC-REQ-F1414: status --json の出力にDB接続パスワードやsecret key等の機密情報が含まれない
@test "[RDC-REQ-F1414] status --json: 出力にDB接続パスワードやsecret key等の機密情報が含まれない" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "generate_status=pending" \
    "import_status=pending" "migrate_status=pending" "check_status=pending" \
    "db_password=super-secret-password" "secret_key_base=super-secret-key-base"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=false run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
  ! echo "$output" | grep -qi "super-secret-password"
  ! echo "$output" | grep -qi "super-secret-key-base"
}

# ---- StatusService: Stage 9是正・urlフィールド (RDC-REQ-F1441〜F1443、F0998〜F1000) ----
# 設計: develop/docs/1B-DESIGN-F1441-status-accuracy-and-port-collision.md

# RDC-REQ-F1442, F0999: 全ステップ完了済みでもcompose未起動なら「完了」ではなくdocker compose up -dを案内する（人間可読）
@test "[RDC-REQ-F1442][RDC-REQ-F0999] status: 全ステップ完了済みでもcompose未起動なら完了と案内しない" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_IMAGE_GENERATE_ID=2026-01-01T00:00:00Z RDC_MOCK_COMPOSE_RUNNING=false \
    run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "docker compose up -d"
  ! echo "$output" | grep -q "完了 (complete)"
}

# RDC-REQ-F1442, F0999: 同上をstatus --jsonでも確認する
@test "[RDC-REQ-F1442][RDC-REQ-F0999] status --json: 全ステップ完了済みでもcompose未起動ならnext_actionが完了を示さない" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_IMAGE_GENERATE_ID=2026-01-01T00:00:00Z RDC_MOCK_COMPOSE_RUNNING=false \
    run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = ' '.join(d['next_action']['lines'])
assert 'docker compose up -d' in lines
assert '完了' not in lines
"
}

# RDC-REQ-F1442: 全ステップ完了済みでcompose起動中なら従来通り完了と案内する（回帰確認）
@test "[RDC-REQ-F1442] status: 全ステップ完了済みでcompose起動中なら完了と案内する（回帰確認）" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_IMAGE_GENERATE_ID=2026-01-01T00:00:00Z RDC_MOCK_COMPOSE_RUNNING=true \
    run rdw status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "完了 (complete)"
  echo "$output" | grep -q "Redmine is running at"
}

# RDC-REQ-F1443, F1000: status --json はgenerate完了後にurlフィールドを含む
@test "[RDC-REQ-F1443][RDC-REQ-F1000] status --json: generate完了後はurlフィールドを含む" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "redmine_bind=127.0.0.1:38081" "relative_url_root=/redmine-auto" \
    "init_status=done" "generate_status=done" "import_status=pending" \
    "migrate_status=pending" "check_status=pending"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=false run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['url'] == 'http://127.0.0.1:38081/redmine-auto/'
"
}

# RDC-REQ-F1443, F1000: status --json はgenerate未完了時はurlフィールドを含まない（null）
@test "[RDC-REQ-F1443][RDC-REQ-F1000] status --json: generate未完了時はurlがnull" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "generate_status=pending" \
    "import_status=pending" "migrate_status=pending" "check_status=pending"
  cd "$WS"
  run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['url'] is None
"
}

# RDC-REQ-F1443, F1000: urlフィールドはcompose_runtimeがstoppedであっても出力される（起動状態とは独立）
@test "[RDC-REQ-F1443][RDC-REQ-F1000] status --json: compose未起動でもurlフィールドは出力される" {
  rdw_full_state_passenger "$WS"
  cd "$WS"
  RDC_MOCK_IMAGE_EXISTS=true RDC_MOCK_IMAGE_GENERATE_ID=2026-01-01T00:00:00Z RDC_MOCK_COMPOSE_RUNNING=false \
    run rdw status --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['url'] is not None
assert d['external']['compose_runtime'] == 'stopped'
"
}
