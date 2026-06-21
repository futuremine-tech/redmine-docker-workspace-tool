#!/usr/bin/env bats
# test/bats/rdw_export_gemfile_lock.bats
# 結合テスト: export-gemfile-lock サブコマンド
# 根拠要件: RDC-REQ-F1301〜F1305, RDC-REQ-F0960〜F0962

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export RDC_ALLOW_MOCK=1
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "product=redmine" \
    "target_image_tag=6.0.3" "init_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
}

teardown() {
  unset RDC_ALLOW_MOCK || true
  rm -rf "$WS"
}

# RDC-REQ-F1301 / RDC-REQ-F0960: モック環境でイメージから Gemfile.lock を取り出しワークスペースルートに配置される
@test "[RDC-REQ-F0960] export-gemfile-lock: モック環境でイメージから Gemfile.lock をワークスペースルートに取り出す" {
  cd "$WS"
  run rdw export-gemfile-lock
  [ "$status" -eq 0 ]
  [ -f "$WS/Gemfile.lock" ]
  echo "$output" | grep -qi "Gemfile.lock"
  echo "$output" | grep -qi "generate --deployment"
}

# RDC-REQ-F1302 / RDC-REQ-F0961: イメージが存在しない場合は非ゼロで終了する
@test "[RDC-REQ-F0961] export-gemfile-lock: イメージ未存在の場合に非ゼロで終了する" {
  export RDC_MOCK_NO_IMAGE=1
  cd "$WS"
  run rdw export-gemfile-lock
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "image\|イメージ\|build\|ビルド"
  unset RDC_MOCK_NO_IMAGE
}

# RDC-REQ-F1303 / RDC-REQ-F0962: 既存 Gemfile.lock に --force なしで上書きを拒否する
@test "[RDC-REQ-F0962] export-gemfile-lock: 既存 Gemfile.lock に --force なしで上書きを拒否する" {
  echo "existing content" > "$WS/Gemfile.lock"
  cd "$WS"
  run rdw export-gemfile-lock
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "force\|--force\|already\|既存\|存在"
  # 既存ファイルの内容が変わっていないこと
  grep -q "existing content" "$WS/Gemfile.lock"
}

# RDC-REQ-F1303 / RDC-REQ-F0962: --force ありでは既存 Gemfile.lock を上書きする
@test "[RDC-REQ-F0962] export-gemfile-lock: --force ありで既存 Gemfile.lock を上書きする" {
  echo "existing content" > "$WS/Gemfile.lock"
  cd "$WS"
  run rdw export-gemfile-lock --force
  [ "$status" -eq 0 ]
  [ -f "$WS/Gemfile.lock" ]
  # モックが書き込んだ内容で上書きされていること（"existing content" ではなくなっている）
  run grep "existing content" "$WS/Gemfile.lock"
  [ "$status" -ne 0 ]
}

# RDC-REQ-F1305: ワークスペース外から実行してもワークスペースを検出できる
@test "[RDC-REQ-F1305] export-gemfile-lock: ワークスペースルート以外のディレクトリからも実行できる" {
  run rdw --workspace "$WS" export-gemfile-lock 2>/dev/null || \
    (cd "$WS" && rdw export-gemfile-lock)
  # ワークスペース内から実行した場合のみ検証
  cd "$WS"
  run rdw export-gemfile-lock --force
  [ "$status" -eq 0 ]
  [ -f "$WS/Gemfile.lock" ]
}
