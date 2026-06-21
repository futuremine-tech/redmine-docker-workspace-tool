#!/usr/bin/env bats
# test/bats/rdw_init.bats
# 結合テスト: init サブコマンド（passenger / workspace モード）
# 根拠要件: RDC-REQ-F0904, RDC-REQ-F0905, RDC-REQ-F0906, RDC-REQ-F0810, RDC-REQ-F0954, RDC-REQ-F0955, RDC-REQ-F0956

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
}

teardown() {
  rm -rf "$WS"
}

# RDC-REQ-F0904: Apache 設定から REDMINE_ROOT と product/tag 候補を抽出できる
@test "[RDC-REQ-F0904] init passenger: Apache 設定から REDMINE_ROOT と product/tag を抽出する" {
  apache_dir=$(mktemp -d)
  cp test/fixtures/apache/passenger_vhost.conf "$apache_dir/"
  run rdw init --mode passenger --apache-config-dir "$apache_dir" --target "$WS"
  [ "$status" -eq 0 ]
  [ -f "$WS/.rdc_state" ]
  grep -q "mode=passenger" "$WS/.rdc_state"
  rm -rf "$apache_dir"
}

# RDC-REQ-F0904: <Directory ".../public"> パターンの Apache 設定から REDMINE_ROOT を検知できる
@test "[RDC-REQ-F0904] init passenger: <Directory> パターンの Apache 設定から REDMINE_ROOT を検知できる" {
  apache_dir=$(mktemp -d)
  cp test/fixtures/apache/passenger_directory.conf "$apache_dir/"
  run rdw init --mode passenger --apache-config-dir "$apache_dir" --target "$WS"
  [ "$status" -eq 0 ]
  grep -q "redmine_root=/var/lib/redmine" "$WS/.rdc_state"
  rm -rf "$apache_dir"
}

# RDC-REQ-F0904: RedMica の場合は lib/redmica/version.rb からバージョンを取得する（Redmine 本体バージョンを使わない）
@test "[RDC-REQ-F0904] init passenger: RedMica の場合は lib/redmica/version.rb のバージョンを取得する" {
  fake_root=$(mktemp -d)
  mkdir -p "$fake_root/lib/redmica" "$fake_root/lib/redmine"
  cat > "$fake_root/redmica.gemspec" <<'EOF'
Gem::Specification.new { |s| s.name = "redmica" }
EOF
  cat > "$fake_root/lib/redmica/version.rb" <<'EOF'
module RedMica
  module VERSION
    MAJOR = 3
    MINOR = 1
    TINY  = 0
  end
end
EOF
  cat > "$fake_root/lib/redmine/version.rb" <<'EOF'
module Redmine
  module VERSION
    MAJOR = 6
    MINOR = 1
    TINY  = 2
  end
end
EOF
  run rdw init --mode passenger --redmine-root "$fake_root" --target "$WS"
  [ "$status" -eq 0 ]
  grep -q "product=redmica" "$WS/.rdc_state"
  grep -q "target_image_tag=3.1.0" "$WS/.rdc_state"
  # Redmine 本体バージョン (6.1.2) が誤って使われていないこと
  ! grep -q "target_image_tag=6.1.2" "$WS/.rdc_state"
  rm -rf "$fake_root"
}

# RDC-REQ-F0906: passenger モードで --redmine/--redmica の明示指定が検出結果より優先される
@test "[RDC-REQ-F0906] init passenger: --redmine TAG が検出結果より優先される" {
  apache_dir=$(mktemp -d)
  cp test/fixtures/apache/passenger_vhost.conf "$apache_dir/"
  run rdw init --mode passenger --apache-config-dir "$apache_dir" --redmine 6.2.0 --target "$WS"
  [ "$status" -eq 0 ]
  grep -q "target_image_tag=6.2.0" "$WS/.rdc_state"
  rm -rf "$apache_dir"
}

# RDC-REQ-F0810: Passenger を特定できない場合に理由付きで停止する
@test "[RDC-REQ-F0810] init passenger: Apache 設定が見つからない場合は理由付きで失敗する" {
  empty_dir=$(mktemp -d)
  run rdw init --mode passenger --apache-config-dir "$empty_dir" --target "$WS"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "passenger\|apache\|not found\|検出"
  rm -rf "$empty_dir"
}

# RDC-REQ-F0905: source workspace から dump/plugins/state を再利用対象として扱える
@test "[RDC-REQ-F0905] init workspace: source workspace の状態と資材を検証して初期化できる" {
  src_ws=$(rdw_make_workspace)
  cp test/fixtures/workspace/source_state_ok.env "$src_ws/.rdc_state"
  cp test/fixtures/sample.dump "$src_ws/dbdump/"
  run rdw init --mode workspace --source "$src_ws" --target "$WS"
  [ "$status" -eq 0 ]
  grep -q "mode=workspace" "$WS/.rdc_state"
  rm -rf "$src_ws"
}

# RDC-REQ-F0905A: plugins/dbdump ディレクトリが空でも init は通る
@test "[RDC-REQ-F0905A] init workspace: source workspace の plugins/dbdump が空でも init は通る" {
  src_ws=$(rdw_make_workspace)
  cp test/fixtures/workspace/source_state_ok.env "$src_ws/.rdc_state"
  run rdw init --mode workspace --source "$src_ws" --target "$WS"
  [ "$status" -eq 0 ]
  rm -rf "$src_ws"
}

# RDC-REQ-F0905F: --mode workspace で --source 省略時、カレントがワークスペースなら自動適用
@test "[RDC-REQ-F0905F] init workspace: カレントディレクトリがワークスペースなら --source 省略で自動適用される" {
  src_ws=$(rdw_make_workspace)
  cp test/fixtures/workspace/source_state_ok.env "$src_ws/.rdc_state"
  cd "$src_ws"
  run rdw init --mode workspace --target "$WS"
  [ "$status" -eq 0 ]
  saved=$(grep "^source_workspace=" "$WS/.rdc_state" | cut -d= -f2-)
  [[ "$saved" == "$src_ws" ]]
  rm -rf "$src_ws"
}

# RDC-REQ-F0905F: --mode workspace で --source 省略かつカレントが非ワークスペースならエラー
@test "[RDC-REQ-F0905F] init workspace: カレントが非ワークスペースで --source 省略ならエラー" {
  empty_dir=$(mktemp -d)
  cd "$empty_dir"
  run rdw init --mode workspace --target "$WS"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "source"
  rm -rf "$empty_dir"
}

# RDC-REQ-F0905: --source に相対パスを渡した場合、絶対パスに正規化して保存する
@test "[RDC-REQ-F0905] init workspace: --source の相対パスが .rdc_state に絶対パスとして保存される" {
  src_ws=$(rdw_make_workspace)
  cp test/fixtures/workspace/source_state_ok.env "$src_ws/.rdc_state"
  cd "$src_ws"
  run rdw init --mode workspace --source . --target "$WS"
  [ "$status" -eq 0 ]
  saved=$(grep "^source_workspace=" "$WS/.rdc_state" | cut -d= -f2-)
  [[ "$saved" == /* ]]
  [[ "$saved" == "$src_ws" ]]
  rm -rf "$src_ws"
}

# RDC-REQ-F0905B: check 未完了でも再利用に必要な状態が揃っていれば受け付ける
@test "[RDC-REQ-F0905B] init workspace: source の check が未完了でも必須状態が揃っていれば受け付ける" {
  src_ws=$(rdw_make_workspace)
  # check_status が pending の状態で init 受け付ける
  rdw_init_state "$src_ws" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "generate_status=done" \
    "import_status=done" "migrate_status=done" "check_status=pending"
  run rdw init --mode workspace --source "$src_ws" --target "$WS"
  [ "$status" -eq 0 ]
  rm -rf "$src_ws"
}

# RDC-REQ-F0905C: 必須 state 欠損時に不足条件を案内して停止する
@test "[RDC-REQ-F0905C] init workspace: source の必須 state が欠損している場合は案内して停止する" {
  src_ws=$(rdw_make_workspace)
  cp test/fixtures/workspace/source_state_broken.env "$src_ws/.rdc_state"
  run rdw init --mode workspace --source "$src_ws" --target "$WS"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "missing\|不足\|invalid"
  rm -rf "$src_ws"
}

# ---- --target オプション ----

# RDC-REQ-F0101/F0103: --target で新規ディレクトリを指定した場合にそこへ初期化される
@test "[RDC-REQ-F0101][RDC-REQ-F0103] init: --target で新規ディレクトリを指定するとそこへ .rdc_state が作成される" {
  target_dir="$WS/newdir"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -eq 0 ]
  [ -f "$target_dir/.rdc_state" ]
  grep -q "workspace_initialized=true" "$target_dir/.rdc_state"
}

# RDC-REQ-F0101: --target 省略・カレントが clean 済みワークスペースなら再初期化できる
@test "[RDC-REQ-F0101] init: --target 省略でカレントが clean 済みワークスペースなら再初期化できる" {
  rdw init --mode new --target "$WS" >/dev/null
  cd "$WS" && rdw clean >/dev/null 2>&1
  run rdw init --mode new
  [ "$status" -eq 0 ]
  grep -q "workspace_initialized=true" "$WS/.rdc_state"
}

# RDC-REQ-F0101: --target 省略・カレントが clean されていない（未初期化や初期化済み）場合はエラー
@test "[RDC-REQ-F0101] init: --target 省略でカレントが clean されていない場合はエラー終了する" {
  cd "$WS"
  run rdw init --mode new
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "target"
}

# RDC-REQ-F0103: ツール自身のディレクトリを --target に指定した場合は拒否する
@test "[RDC-REQ-F0103] init: ツール自身のディレクトリを --target に指定すると拒否する" {
  tool_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  run rdw init --mode new --target "$tool_dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "tool’s own\|tool.*own\|ツール"
}

# RDC-REQ-F0107/F0107A: --target 指定時、完了メッセージに PATH スニペットとワークスペース絶対パスが含まれる
@test "[RDC-REQ-F0107][RDC-REQ-F0107A] init: --target 指定時に PATH スニペットと絶対パスが完了メッセージに含まれる" {
  target_dir="$WS/myws"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "export PATH="
  echo "$output" | grep -q "$target_dir"
}

# RDC-REQ-F0805: new モード init 後の Next step は generate を案内する
@test "[RDC-REQ-F0805] init new: Next step は generate を表示する" {
  target_dir="$WS/newmode"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "redmine-docker-workspace generate"
}

# RDC-REQ-F0103: --target に書き込み権限がない場合は理由付きで失敗する
@test "[RDC-REQ-F0103] init: --target に書き込み権限がない親ディレクトリの場合は失敗する" {
  readonly_dir=$(mktemp -d)
  chmod 555 "$readonly_dir"
  target_dir="$readonly_dir/newws"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "permission\|write\|権限"
  chmod 755 "$readonly_dir"
  rm -rf "$readonly_dir"
}

# RDC-REQ-F0121: --source と --target が同一パスの場合は失敗する
@test "[RDC-REQ-F0121] init workspace: --source と --target が同一パスの場合は失敗する" {
  src_ws=$(rdw_make_workspace)
  cp test/fixtures/workspace/source_state_ok.env "$src_ws/.rdc_state"
  cp test/fixtures/sample.dump "$src_ws/dbdump/"
  run rdw init --mode workspace --source "$src_ws" --target "$src_ws"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "same\|同一"
  rm -rf "$src_ws"
}

# RDC-REQ-F0101A: --target で init 後、サブディレクトリから他サブコマンドが上位探索で動作する
@test "[RDC-REQ-F0101A] init: --target で init 後、サブディレクトリから rdw status が動作する" {
  target_dir="$WS/wsroot"
  rdw init --mode new --target "$target_dir" >/dev/null
  mkdir -p "$target_dir/plugins/sub"
  cd "$target_dir/plugins/sub"
  run rdw status
  [ "$status" -eq 0 ]
}

# RDC-REQ-F0925: --base-image 指定時に mode=new が自動検出される
@test "[RDC-REQ-F0925] init --base-image: mode 明示なしで mode=new が自動検出される" {
  run rdw init --base-image futuremine/redmica:4.1.1 --target "$WS"
  [ "$status" -eq 0 ]
  [ -f "$WS/.rdc_state" ]
  grep -q "image_ref=futuremine/redmica:4.1.1" "$WS/.rdc_state"
  grep -q "image_source=explicit" "$WS/.rdc_state"
  grep -q "product=" "$WS/.rdc_state"
}

# RDC-REQ-F0926: --redmine と --base-image は同時指定不可
@test "[RDC-REQ-F0926] init: --redmine と --base-image 同時指定で失敗する" {
  run rdw init --target "$WS" --redmine latest --base-image futuremine/redmica:4.1.1
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "同時指定\|exclusive\|cannot"
}

# RDC-REQ-F0926: --redmica と --base-image は同時指定不可
@test "[RDC-REQ-F0926] init: --redmica と --base-image 同時指定で失敗する" {
  run rdw init --target "$WS" --redmica 4.0.0 --base-image futuremine/redmica:4.1.1
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "同時指定\|exclusive\|cannot"
}

# RDC-REQ-F0927: --base-image と --mode passenger は同時指定不可
@test "[RDC-REQ-F0927] init: --base-image と --mode passenger 同時指定で失敗する" {
  run rdw init --target "$WS" --base-image futuremine/redmica:4.1.1 --mode passenger
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "新規生成\|new モード\|mode new"
}

# RDC-REQ-F0927: --base-image と --mode workspace は同時指定不可
@test "[RDC-REQ-F0927] init: --base-image と --mode workspace 同時指定で失敗する" {
  run rdw init --target "$WS" --base-image futuremine/redmica:4.1.1 --mode workspace
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "新規生成\|new モード\|mode new"
}

# RDC-REQ-F0927: --base-image と --redmine-root は同時指定不可
@test "[RDC-REQ-F0927] init: --base-image と --redmine-root 同時指定で失敗する" {
  run rdw init --target "$WS" --base-image futuremine/redmica:4.1.1 --redmine-root /var/www/redmine
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "Passenger\|新規生成\|専用"
}

# RDC-REQ-F0927: --base-image と --source は同時指定不可
@test "[RDC-REQ-F0927] init: --base-image と --source 同時指定で失敗する" {
  src_ws=$(rdw_make_workspace)
  run rdw init --target "$WS" --base-image futuremine/redmica:4.1.1 --source "$src_ws"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "source\|exclusive\|cannot"
  rm -rf "$src_ws"
}

# ---- 完了後自動 status 表示 ----

# init 完了後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] init: 完了後にステップ状態一覧と次アクション案内が自動表示される" {
  target_dir="$WS/newmode"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
}

# ---- activate-workspace-tool.sh 生成 ----

# RDC-REQ-F0107B: init 完了時に activate-workspace-tool.sh がワークスペースルートに生成される
@test "[RDC-REQ-F0107B] init: 完了時に activate-workspace-tool.sh がワークスペースルートに生成される" {
  target_dir="$WS/activatews"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -eq 0 ]
  [ -f "$target_dir/activate-workspace-tool.sh" ]
}

# RDC-REQ-F0107B: activate-workspace-tool.sh を source するとツールの bin が PATH に追加される
@test "[RDC-REQ-F0107B] init: activate-workspace-tool.sh を source するとツールの bin が PATH に追加される" {
  target_dir="$WS/activatepath"
  rdw init --mode new --target "$target_dir" >/dev/null
  [ -f "$target_dir/activate-workspace-tool.sh" ]
  bin_dir="$(dirname "$RDW_BIN")"
  new_path=$(bash -c "source '${target_dir}/activate-workspace-tool.sh'; echo \"\$PATH\"" 2>/dev/null)
  echo "$new_path" | tr ':' '\n' | grep -qF "$bin_dir"
}

# RDC-REQ-F0107B: activate-workspace-tool.sh を複数回 source しても PATH が重複追加されない
@test "[RDC-REQ-F0107B] init: activate-workspace-tool.sh を複数回 source しても PATH が重複追加されない" {
  target_dir="$WS/activatedup"
  rdw init --mode new --target "$target_dir" >/dev/null
  [ -f "$target_dir/activate-workspace-tool.sh" ]
  path_once=$(bash -c "source '${target_dir}/activate-workspace-tool.sh'; echo \"\$PATH\"" 2>/dev/null)
  path_twice=$(bash -c "
    source '${target_dir}/activate-workspace-tool.sh'
    source '${target_dir}/activate-workspace-tool.sh'
    echo \"\$PATH\"
  " 2>/dev/null)
  [ "$path_once" = "$path_twice" ]
}

# RDC-REQ-F0107B: init 完了メッセージに activate-workspace-tool.sh の利用案内が含まれる
@test "[RDC-REQ-F0107B] init: 完了メッセージに activate-workspace-tool.sh の利用案内が含まれる" {
  target_dir="$WS/activatemsg"
  run rdw init --mode new --target "$target_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "activate-workspace-tool.sh"
}

# RDC-REQ-F0904: version.rb に [MAJOR, MINOR, TINY, REVISION].compact がある場合も MAJOR.MINOR.TINY のみ抽出する
@test "[RDC-REQ-F0904] init passenger: version.rb の REVISION]/compact 行に影響されず MAJOR.MINOR.TINY だけ抽出する" {
  fake_root=$(mktemp -d)
  mkdir -p "$fake_root/lib/redmine"
  cat > "$fake_root/lib/redmine/version.rb" <<'EOF'
module Redmine
  module VERSION
    MAJOR = 5
    MINOR = 1
    TINY  = 2
    BRANCH = 'stable'
    REVISION = nil
    def self.to_a
      [MAJOR, MINOR, TINY, REVISION].compact
    end
    def self.to_s; to_a.join('.'); end
  end
end
EOF
  run rdw init --mode passenger --redmine-root "$fake_root" --target "$WS"
  [ "$status" -eq 0 ]
  grep -qE "^target_image_tag=5\.1\.2$" "$WS/.rdc_state"
  rm -rf "$fake_root"
}

# RDC-REQ-F0107B: 既存 activate-workspace-tool.sh がある場合も再 init で上書き再生成される
@test "[RDC-REQ-F0107B] init: 既存 activate-workspace-tool.sh は再 init で上書き再生成される" {
  target_dir="$WS/activatereinit"
  mkdir -p "$target_dir"
  echo "# stale-content" > "$target_dir/activate-workspace-tool.sh"
  rdw init --mode new --target "$target_dir" >/dev/null
  [ -f "$target_dir/activate-workspace-tool.sh" ]
  run grep -c "stale-content" "$target_dir/activate-workspace-tool.sh"
  [ "$output" -eq 0 ]
}

# RDC-REQ-F0954, RDC-REQ-F0956: --list は x.y.z 形式のみ表示し --target 不要で動作する
@test "[RDC-REQ-F0954][RDC-REQ-F0956] init --list: x.y.z 形式のフルイメージ名のみ表示し --target なしで正常終了する" {
  export RDC_ALLOW_MOCK=1
  run rdw init --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "redmine:6\.0\."
  echo "$output" | grep -q "redmica/redmica:2\."
  echo "$output" | grep -q "futuremine/redmica:3\."
  echo "$output" | grep -qv "alpine"
  echo "$output" | grep -qv "latest"
}

# RDC-REQ-F0955, RDC-REQ-F0956: --list-all は派生タグを含む全イメージを表示し --target 不要で動作する
@test "[RDC-REQ-F0955][RDC-REQ-F0956] init --list-all: 派生タグを含む全フルイメージ名を表示し --target なしで正常終了する" {
  export RDC_ALLOW_MOCK=1
  run rdw init --list-all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "redmine:6\.0\."
  echo "$output" | grep -q "redmine:.*alpine"
  echo "$output" | grep -q "redmica/redmica:2\."
  echo "$output" | grep -q "futuremine/redmica:3\."
}
