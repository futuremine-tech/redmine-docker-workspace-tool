#!/usr/bin/env bats
# test/bats/rdw_clean.bats
# 結合テスト: clean サブコマンド
# 根拠要件: RDC-REQ-F0914, RDC-REQ-F0914A

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  rdw_full_state_passenger "$WS"
  # ワークスペースルートに生成物を配置
  echo "FROM ruby:3.1-slim" > "$WS/Dockerfile"
  echo "version: '3'" > "$WS/docker-compose.yml"
  echo "TAG=6.1.2" > "$WS/.env"
  # verification/ に manifest を配置
  echo '{"status":"passed"}' > "$WS/verification/manifest.json"
  # log/ にログを配置
  echo "test log" > "$WS/log/redmine-docker-workspace.log"
  # plugins/ にダミー plugin を配置
  mkdir -p "$WS/plugins/sample_plugin"
}

teardown() {
  rm -rf "$WS"
}

# RDC-REQ-F0914: Docker 関連生成物と state を削除し logs/plugins/DB 永続データを残す
@test "[RDC-REQ-F0914] clean: compose 生成物と .rdc_state を削除し logs と plugins は残す" {
  cd "$WS"
  run rdw clean
  [ "$status" -eq 0 ]
  # .rdc_state は clean_status=done のみ残る（再 init を可能にするため）
  [ -f "$WS/.rdc_state" ]
  grep -q "^clean_status=done$" "$WS/.rdc_state"
  [ "$(wc -l < "$WS/.rdc_state")" -eq 1 ]
  # 削除対象
  [ ! -f "$WS/Dockerfile" ]
  [ ! -f "$WS/docker-compose.yml" ]
  [ ! -f "$WS/verification/manifest.json" ]
  # 残すもの
  [ -f "$WS/log/redmine-docker-workspace.log" ]
  [ -d "$WS/plugins/sample_plugin" ]
}

# RDC-REQ-F0914A: compose 起動中なら down を案内して停止する

# clean 後の status は再 init を案内する
@test "[RDC-REQ-F0914][RDC-REQ-F0923A] clean 後: status は re-init を案内するメッセージを表示する" {
  cd "$WS"
  rdw clean
  run rdw status
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "clean\|init"
}

# clean 後: --target なしで init するとカレントディレクトリが再初期化される
@test "[RDC-REQ-F0914] clean 後: --target なしの init でカレントディレクトリを再初期化できる" {
  cd "$WS"
  rdw clean
  run rdw init --mode new --redmine latest
  [ "$status" -eq 0 ]
  [ -f "$WS/.rdc_state" ]
  grep -q "^mode=new$" "$WS/.rdc_state"
  grep -q "^workspace_initialized=true$" "$WS/.rdc_state"
}
@test "[RDC-REQ-F0914A] clean: compose が起動中の場合は down を案内して失敗する" {
  # compose 起動中をシミュレート
  export RDC_MOCK_COMPOSE_RUNNING=true
  cd "$WS"
  run rdw clean
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "down\|停止"
  unset RDC_MOCK_COMPOSE_RUNNING
}

# RDC-REQ-F0107B/RDC-REQ-F0501: clean 実行時に activate-workspace-tool.sh が削除される
@test "[RDC-REQ-F0107B][RDC-REQ-F0501] clean: activate-workspace-tool.sh が削除される" {
  echo "export PATH=\"/dummy/bin:\$PATH\"" > "$WS/activate-workspace-tool.sh"
  cd "$WS"
  run rdw clean
  [ "$status" -eq 0 ]
  [ ! -f "$WS/activate-workspace-tool.sh" ]
}
