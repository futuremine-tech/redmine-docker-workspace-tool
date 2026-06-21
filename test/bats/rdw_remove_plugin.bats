#!/usr/bin/env bats
# test/bats/rdw_remove_plugin.bats
# 結合テスト: remove-plugin サブコマンド
# 根拠要件: RDC-REQ-F1101〜F1109, RDC-REQ-F0930〜F0936, RDC-REQ-F0952

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export RDC_ALLOW_MOCK=1
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
  mkdir -p "$WS/plugins/my_plugin"
  touch "$WS/plugins/my_plugin/init.rb"
}

teardown() {
  rm -rf "$WS"
}

# ---- 引数なし ----

# RDC-REQ-F1101 / RDC-REQ-F0930: plugin_name 引数なしで Usage 表示して失敗終了
@test "[RDC-REQ-F0930] remove-plugin: plugin_name 引数なしで失敗終了し Usage を表示する" {
  cd "$WS"
  run rdw remove-plugin
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage\|plugin_name\|Usage"
}

# ---- --help ----

# RDC-REQ-F1107 / RDC-REQ-F0936: Usage に役割・引数・次手順が含まれる
@test "[RDC-REQ-F0936] remove-plugin --help: Usage に役割・plugin_name・完了後の次手順が含まれる" {
  run rdw remove-plugin --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "plugin_name\|<plugin"
  echo "$output" | grep -qi "migrate\|build\|next\|次"
}

# ---- プラグインディレクトリ未存在 ----

# RDC-REQ-F1102 / RDC-REQ-F0931: プラグインディレクトリ未存在時に理由を明示して失敗終了
@test "[RDC-REQ-F0931] remove-plugin: プラグインディレクトリ未存在時に理由を明示して失敗終了する" {
  cd "$WS"
  run rdw remove-plugin no_such_plugin
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "no_such_plugin\|not found\|存在\|見つかり"
}

# ---- Redmine 実行中ガード ----

# RDC-REQ-F1103 / RDC-REQ-F0932: Redmine コンテナ実行中は docker compose down を案内して失敗終了
@test "[RDC-REQ-F0932] remove-plugin: Redmine コンテナ実行中は docker compose down を案内して失敗終了する" {
  export RDC_MOCK_REDMINE_RUNNING=true
  cd "$WS"
  run rdw remove-plugin my_plugin --force
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "docker compose down"
}

# ---- 非対話環境での --force なし拒否 ----

# RDC-REQ-F1108 / RDC-REQ-F0935: 非対話環境で --force なしは失敗終了し --force を案内する
@test "[RDC-REQ-F0935] remove-plugin: 非対話環境で --force なしの場合は失敗終了し --force を案内する" {
  cd "$WS"
  run rdw remove-plugin my_plugin < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "force\|--force"
}

# ---- 逆マイグレーション成功 → ディレクトリ削除・状態更新 ----

# RDC-REQ-F1104 / RDC-REQ-F1105 / RDC-REQ-F1106 / RDC-REQ-F0933:
# --force で確認省略 → 逆マイグレーション成功 → ディレクトリ削除 → 状態更新
@test "[RDC-REQ-F0933] remove-plugin: 逆マイグレーション成功後にプラグインディレクトリを削除し状態を更新する" {
  cd "$WS"
  run rdw remove-plugin my_plugin --force
  [ "$status" -eq 0 ]
  # プラグインディレクトリが削除されていること
  [ ! -d "$WS/plugins/my_plugin" ]
  # migrate_status と check_status が pending に更新されていること
  val_migrate=$(rdw_read_state "$WS" "migrate_status")
  val_check=$(rdw_read_state "$WS" "check_status")
  [ "$val_migrate" = "pending" ]
  [ "$val_check" = "pending" ]
}

# RDC-REQ-F1104: --force で確認プロンプトを省略できる（上のテストで兼ねる）

# ---- 逆マイグレーション失敗 → ディレクトリ保持 ----

# RDC-REQ-F1105 / RDC-REQ-F0934: 逆マイグレーション失敗時はディレクトリを削除しない
@test "[RDC-REQ-F0934] remove-plugin: 逆マイグレーション失敗時はプラグインディレクトリを削除しない" {
  export RDC_MOCK_REVERSE_MIGRATE_FAIL=1
  cd "$WS"
  run rdw remove-plugin my_plugin --force
  [ "$status" -ne 0 ]
  # プラグインディレクトリが残っていること
  [ -d "$WS/plugins/my_plugin" ]
}

# ---- 完了後 status 自動表示 ----

# RDC-DESIGN: 完了後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] remove-plugin: 完了後にステップ状態一覧と次アクション案内が自動表示される" {
  cd "$WS"
  run rdw remove-plugin my_plugin --force
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
}

# ---- plugins_last_changed の記録 ----

# RDC-REQ-F1109 / RDC-REQ-F0952: remove-plugin 成功時に plugins_last_changed が .rdc_state に記録される
@test "[RDC-REQ-F0952] remove-plugin: 成功時に plugins_last_changed が .rdc_state に記録される" {
  cd "$WS"
  run rdw remove-plugin my_plugin --force
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "plugins_last_changed")
  [ -n "$val" ]
}
