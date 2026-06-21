#!/usr/bin/env bats
# test/bats/rdw_add_plugin.bats
# 結合テスト: add-plugin サブコマンド
# 根拠要件: RDC-REQ-F1201〜F1209, RDC-REQ-F0937〜F0949, RDC-REQ-F0953

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export RDC_ALLOW_MOCK=1
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" \
    "migrate_status=done" "check_status=done"
}

teardown() {
  rm -rf "$WS"
}

# ---- 引数なし ----

# RDC-REQ-F1201 / RDC-REQ-F0937: git_url 引数なしで Usage 表示して失敗終了
@test "[RDC-REQ-F0937] add-plugin: git_url 引数なしで失敗終了し Usage を表示する" {
  cd "$WS"
  run rdw add-plugin
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage\|git_url\|Usage"
}

# ---- --help ----

# RDC-REQ-F1206 / RDC-REQ-F0938: Usage に役割・引数・--name・--ref オプション・次手順が含まれる
@test "[RDC-REQ-F0938] add-plugin --help: Usage に役割・git_url・--name・--ref オプション・次手順が含まれる" {
  run rdw add-plugin --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "git_url\|<url\|git"
  echo "$output" | grep -qi "\-\-name"
  echo "$output" | grep -qi "\-\-ref"
  echo "$output" | grep -qi "migrate\|build\|next\|次"
}

# ---- 導入済み判定（冪等性・再クローン・URL 不一致） ----

# RDC-REQ-F1203(a) / RDC-REQ-F0939: URL と ref が一致する場合は導入済みメッセージで正常終了し .rdc_state を変更しない
@test "[RDC-REQ-F0939] add-plugin: URL と ref が一致する場合は導入済みメッセージで正常終了し .rdc_state を変更しない" {
  mkdir -p "$WS/plugins/existing_plugin" "$WS/.rdc_plugins"
  # メタデータファイルで既存情報を記録（同 URL・同 ref）
  printf 'git_url=https://example.com/existing_plugin.git\nref=\n' \
    > "$WS/.rdc_plugins/existing_plugin"
  cd "$WS"
  run rdw add-plugin https://example.com/existing_plugin.git --name existing_plugin
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already\|導入済み\|exists"
  # migrate_status は変わっていないこと
  val=$(rdw_read_state "$WS" "migrate_status")
  [ "$val" = "done" ]
}

# RDC-REQ-F1203(b) / RDC-REQ-F0945: URL 一致・ref 不一致で --force なしは失敗終了し remove-plugin 推奨を表示する
@test "[RDC-REQ-F0945] add-plugin: URL 一致・ref 不一致で --force なしは失敗終了し remove-plugin 推奨を表示する" {
  mkdir -p "$WS/plugins/versioned_plugin" "$WS/.rdc_plugins"
  # 既存は v1.0.0 でインストール済み
  printf 'git_url=https://example.com/versioned_plugin.git\nref=v1.0.0\n' \
    > "$WS/.rdc_plugins/versioned_plugin"
  cd "$WS"
  # v2.0.0 を要求（ref 不一致）
  run rdw add-plugin https://example.com/versioned_plugin.git --name versioned_plugin --ref v2.0.0
  [ "$status" -ne 0 ]
  # remove-plugin の先行実行を推奨するメッセージが含まれること
  echo "$output" | grep -qi "remove-plugin\|remove_plugin"
  # --force で強行できることも案内されること
  echo "$output" | grep -qi "\-\-force\|force"
}

# RDC-REQ-F1203(b) / RDC-REQ-F0946: URL 一致・ref 不一致で --force あり → 再クローンし state を更新する
@test "[RDC-REQ-F0946] add-plugin: URL 一致・ref 不一致で --force あり → 再クローンし .rdc_state を更新する" {
  mkdir -p "$WS/plugins/versioned_plugin" "$WS/.rdc_plugins"
  printf 'git_url=https://example.com/versioned_plugin.git\nref=v1.0.0\n' \
    > "$WS/.rdc_plugins/versioned_plugin"
  cd "$WS"
  run rdw add-plugin https://example.com/versioned_plugin.git \
    --name versioned_plugin --ref v2.0.0 --force
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/versioned_plugin" ]
  val_migrate=$(rdw_read_state "$WS" "migrate_status")
  val_check=$(rdw_read_state "$WS" "check_status")
  [ "$val_migrate" = "pending" ]
  [ "$val_check" = "pending" ]
}

# RDC-REQ-F1203(c) / RDC-REQ-F0947: URL 不一致（別 fork）で --force なしは警告・remove-plugin 推奨・失敗終了
@test "[RDC-REQ-F0947] add-plugin: URL 不一致（別 fork）で --force なしは警告・remove-plugin 推奨・失敗終了する" {
  mkdir -p "$WS/plugins/my_plugin" "$WS/.rdc_plugins"
  # 別 URL で既存インストール済み
  printf 'git_url=https://original.example.com/my_plugin.git\nref=\n' \
    > "$WS/.rdc_plugins/my_plugin"
  cd "$WS"
  # 別 fork URL を指定
  run rdw add-plugin https://fork.example.com/my_plugin.git --name my_plugin
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "fork\|別.*リポジトリ\|different.*repo\|url\|URL\|warn\|警告"
  echo "$output" | grep -qi "remove-plugin\|remove_plugin"
}

# RDC-REQ-F1203(c) / RDC-REQ-F0948: URL 不一致で --force あり → 警告のうえ再クローンし state を更新する
@test "[RDC-REQ-F0948] add-plugin: URL 不一致で --force あり → 警告のうえ再クローンし .rdc_state を更新する" {
  mkdir -p "$WS/plugins/my_plugin" "$WS/.rdc_plugins"
  printf 'git_url=https://original.example.com/my_plugin.git\nref=\n' \
    > "$WS/.rdc_plugins/my_plugin"
  cd "$WS"
  run rdw add-plugin https://fork.example.com/my_plugin.git --name my_plugin --force
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/my_plugin" ]
  val_migrate=$(rdw_read_state "$WS" "migrate_status")
  val_check=$(rdw_read_state "$WS" "check_status")
  [ "$val_migrate" = "pending" ]
  [ "$val_check" = "pending" ]
}

# ---- 新規クローン成功 ----

# RDC-REQ-F1201 / RDC-REQ-F1205 / RDC-REQ-F0940:
# git clone 成功後にディレクトリが作成され migrate_status=pending, check_status=pending になる
@test "[RDC-REQ-F0940] add-plugin: git clone 成功後にプラグインディレクトリが作成され状態が更新される" {
  cd "$WS"
  run rdw add-plugin https://example.com/new_plugin.git --name new_plugin
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/new_plugin" ]
  val_migrate=$(rdw_read_state "$WS" "migrate_status")
  val_check=$(rdw_read_state "$WS" "check_status")
  [ "$val_migrate" = "pending" ]
  [ "$val_check" = "pending" ]
}

# ---- --name オプション ----

# RDC-REQ-F1202 / RDC-REQ-F0941: --name 指定時に指定名のディレクトリにクローンされる
@test "[RDC-REQ-F0941] add-plugin: --name 指定時に指定名のディレクトリへクローンする" {
  cd "$WS"
  run rdw add-plugin https://example.com/some_repo.git --name custom_name
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/custom_name" ]
  [ ! -d "$WS/plugins/some_repo" ]
}

# ---- URL からのプラグイン名自動導出 ----

# RDC-REQ-F1202 / RDC-REQ-F0942: --name 省略時に URL basename から .git を除いた名前でクローンされる
@test "[RDC-REQ-F0942] add-plugin: --name 省略時に URL から自動導出した名前でクローンする" {
  cd "$WS"
  run rdw add-plugin https://github.com/example/redmine_cool_plugin.git
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/redmine_cool_plugin" ]
}

# ---- git clone 失敗 ----

# RDC-REQ-F1204 / RDC-REQ-F0943: git clone 失敗時に理由を明示して失敗終了し不完全なディレクトリが残らない
@test "[RDC-REQ-F0943] add-plugin: git clone 失敗時に失敗終了し不完全なディレクトリが残存しない" {
  export RDC_MOCK_GIT_CLONE_FAIL=1
  cd "$WS"
  run rdw add-plugin https://example.com/nonexistent.git --name nonexistent
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "fail\|失敗\|error\|clone"
  [ ! -d "$WS/plugins/nonexistent" ]
}

# ---- 完了後 status 自動表示 ----

# RDC-DESIGN: 新規クローン成功後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] add-plugin: 新規クローン成功後にステップ状態一覧と次アクション案内が自動表示される" {
  cd "$WS"
  run rdw add-plugin https://example.com/new_plugin2.git --name new_plugin2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
}

# ---- --ref オプション ----

# RDC-REQ-F1207 / RDC-REQ-F0944: --ref 指定時に成功しディレクトリが作成され状態が更新される
@test "[RDC-REQ-F0944] add-plugin: --ref 指定時に成功しプラグインディレクトリが作成され状態が更新される" {
  cd "$WS"
  run rdw add-plugin https://example.com/versioned_plugin.git --name versioned_plugin --ref v2.1.0
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/versioned_plugin" ]
  val_migrate=$(rdw_read_state "$WS" "migrate_status")
  val_check=$(rdw_read_state "$WS" "check_status")
  [ "$val_migrate" = "pending" ]
  [ "$val_check" = "pending" ]
}

# RDC-REQ-F1207 / RDC-REQ-F0944: --ref と --name の同時指定が正しく動作する
@test "[RDC-REQ-F0944b] add-plugin: --ref と --name を同時指定した場合に指定名・指定バージョンでクローンする" {
  cd "$WS"
  run rdw add-plugin https://example.com/some_repo.git --name my_plugin_alias --ref v1.0.0
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/my_plugin_alias" ]
  [ ! -d "$WS/plugins/some_repo" ]
}

# RDC-REQ-F1207: --ref 省略時は通常クローン（デフォルトブランチ）が成功する（F0940 で兼ねるが明示）
@test "[RDC-REQ-F1207] add-plugin: --ref 省略時はデフォルトブランチでクローンし成功する" {
  cd "$WS"
  run rdw add-plugin https://example.com/no_ref_plugin.git --name no_ref_plugin
  [ "$status" -eq 0 ]
  [ -d "$WS/plugins/no_ref_plugin" ]
}

# ---- 未追跡プラグインの管理下採用（ケース d） ----

# RDC-REQ-F1203(d) / RDC-REQ-F0949:
# サイドカーなし（手動配置等）→ ディレクトリ保持のままサイドカー書き込みで管理下採用
# migrate_status・check_status は変更せず、plugins_last_changed が記録される
@test "[RDC-REQ-F0949] add-plugin: サイドカーなし（手動配置等）はディレクトリを削除せずサイドカーを書き込んで管理下に採用する" {
  mkdir -p "$WS/plugins/manual_plugin"
  # サイドカーファイルを意図的に置かない（手動 git clone や rsync コピーを模擬）
  touch "$WS/plugins/manual_plugin/init.rb"
  cd "$WS"
  run rdw add-plugin https://example.com/manual_plugin.git --name manual_plugin
  [ "$status" -eq 0 ]
  # ディレクトリが削除されていないこと
  [ -d "$WS/plugins/manual_plugin" ]
  # 既存ファイルが保持されていること
  [ -f "$WS/plugins/manual_plugin/init.rb" ]
  # メタデータファイルが書き込まれていること
  [ -f "$WS/.rdc_plugins/manual_plugin" ]
  grep -q "git_url=https://example.com/manual_plugin.git" "$WS/.rdc_plugins/manual_plugin"
  # migrate_status・check_status は変更されていないこと（内容は変わっていないため）
  val_migrate=$(rdw_read_state "$WS" "migrate_status")
  val_check=$(rdw_read_state "$WS" "check_status")
  [ "$val_migrate" = "done" ]
  [ "$val_check" = "done" ]
  # 採用完了メッセージが含まれること
  echo "$output" | grep -qi "adopt\|採用\|tracked\|管理下\|registered"
}

# ---- plugins_last_changed の記録 ----

# RDC-REQ-F1209 / RDC-REQ-F0953: 新規クローン成功時に plugins_last_changed が .rdc_state に記録される
@test "[RDC-REQ-F0953] add-plugin: 新規クローン成功時に plugins_last_changed が .rdc_state に記録される" {
  cd "$WS"
  run rdw add-plugin https://example.com/new_plugin3.git --name new_plugin3
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "plugins_last_changed")
  [ -n "$val" ]
}
