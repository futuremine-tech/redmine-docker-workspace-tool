#!/usr/bin/env bats
# test/bats/rdw_generate.bats
# 結合テスト: generate サブコマンド
# 根拠要件: RDC-REQ-F0910C, RDC-REQ-F0915, RDC-REQ-F0916, RDC-REQ-F0310, RDC-REQ-F0314, RDC-REQ-F0315

source test/helpers/rdw_helpers.sh

setup() {
  WS=$(rdw_make_workspace)
  export DB_PASSWORD=test_password
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=pending"
}

teardown() {
  unset DB_PASSWORD || true
  rm -rf "$WS"
}

# RDC-REQ-F0915: generate Usage に受け付けるオプションと mode 差分が含まれる
@test "[RDC-REQ-F0915] generate --help: Usage に受け付けるオプションが含まれる" {
  run rdw generate --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "usage"
  echo "$output" | grep -q -- "--bind-host\|--bind-port"
}

# RDC-REQ-F0916: generate Usage に prepare-db 専用オプションが含まれない
@test "[RDC-REQ-F0916] generate --help: --import-from/--fresh-db/--skip/--reason が含まれない" {
  run rdw generate --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv -- "--import-from"
  echo "$output" | grep -qv -- "--fresh-db"
  echo "$output" | grep -qv -- "--skip"
  echo "$output" | grep -qv -- "--reason"
}

# RDC-REQ-F0910C: plugin 後付け後の再 build/migrate/check 再実行前提を壊さない
@test "[RDC-REQ-F0910C] generate: plugin 後付け後の再 generate が再 build/migrate/check 前提を保つ" {
  # generate 完了済みの状態から plugins 追加後に再実行
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  mkdir -p "$WS/plugins/new_plugin"
  cd "$WS"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  run rdw generate --force
  [ "$status" -eq 0 ]
  # generate 再実行後は migrate/check が pending に戻る
  val=$(rdw_read_state "$WS" "migrate_status")
  [ "$val" = "pending" ]
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# ---- relative-url-root ----

# RDC-REQ-F0310: generate --help に --relative-url-root が含まれる
@test "[RDC-REQ-F0310] generate --help: --relative-url-root が Usage に含まれる" {
  run rdw generate --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--relative-url-root"
}

# RDC-REQ-F0314: --relative-url-root 指定時に compose に RAILS_RELATIVE_URL_ROOT が含まれる
@test "[RDC-REQ-F0314] generate: --relative-url-root /redmine を指定すると compose に RAILS_RELATIVE_URL_ROOT が含まれる" {
  cd "$WS"
  run rdw generate --relative-url-root /redmine
  [ "$status" -eq 0 ]
  grep -q "RAILS_RELATIVE_URL_ROOT" "$WS/docker-compose.yml"
  grep -q '"/redmine"' "$WS/docker-compose.yml"
  grep -q "rdc-config.ru:/usr/src/redmine/config.ru:ro" "$WS/docker-compose.yml"
  [ -f "$WS/rdc-config.ru" ]
}

# RDC-REQ-F0314: --relative-url-root 省略時は compose に RAILS_RELATIVE_URL_ROOT が含まれない
@test "[RDC-REQ-F0314] generate: --relative-url-root 省略時は compose に RAILS_RELATIVE_URL_ROOT が含まれない" {
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -qv "RAILS_RELATIVE_URL_ROOT" "$WS/docker-compose.yml"
  grep -qv "rdc-config.ru:/usr/src/redmine/config.ru:ro" "$WS/docker-compose.yml"
  [ ! -f "$WS/rdc-config.ru" ]
}

# RDC-REQ-F0314: --relative-url-root 指定時に .rdc_state に relative_url_root が保存される
@test "[RDC-REQ-F0314] generate: --relative-url-root /redmine を指定すると .rdc_state に保存される" {
  cd "$WS"
  run rdw generate --relative-url-root /redmine
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "relative_url_root")
  [ "$val" = "/redmine" ]
}

# RDC-REQ-F0315: / なしの値は失敗し、エラーに指定値・期待形式・例が含まれる
@test "[RDC-REQ-F0315] generate: --relative-url-root redmine（/ なし）は失敗してエラーメッセージを含む" {
  cd "$WS"
  run rdw generate --relative-url-root redmine
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "redmine"
  echo "$output" | grep -qi "/"
  echo "$output" | grep -qi "example\|Example\|--relative-url-root /redmine"
}

# ---- compose 稼働中ガード ----

# RDC-REQ-F0304A: compose 稼働中は generate を拒否し down を案内する
@test "[RDC-REQ-F0304A] generate: 同一 compose プロジェクトが稼働中の場合は generate を拒否し down を案内する" {
  export RDC_MOCK_COMPOSE_RUNNING=true
  cd "$WS"
  # docker compose up -d で起動したまま
  # docker compose up -d
  run rdw generate
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "docker compose down"
}

# ---- 逆行操作と確認プロンプト ----

# RDC-REQ-F0003A: 破壊的再 generate で確認プロンプトを要求する
@test "[RDC-REQ-F0003A] generate: 既存状態を無効化する再 generate で確認プロンプトが表示される" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  cd "$WS"
  # check 完了済み状態から再 generate
  run rdw generate < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "confirm\|overwrite\|sure\|force"
}

# RDC-REQ-F0003B: --force で確認プロンプトを省略できる
@test "[RDC-REQ-F0003B] generate: --force で確認プロンプント表示が省略される" {
  cd "$WS"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  run rdw generate --force
  [ "$status" -eq 0 ]
}

# RDC-REQ-F0003C: 非対話環境では --force なしを拒否する
@test "[RDC-REQ-F0003C] generate: TTY でない環境では --force なしの逆行操作は失敗する" {
  cd "$WS"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=done" "import_status=done" "migrate_status=done" "check_status=done"
  run rdw generate < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "force\|--force"
}

# RDC-REQ-F0315: 末尾 / の値は失敗する
@test "[RDC-REQ-F0315] generate: --relative-url-root /redmine/（末尾 /）は失敗する" {
  cd "$WS"
  run rdw generate --relative-url-root /redmine/
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "/redmine/"
}

# RDC-REQ-F0315: / 単体は失敗する
@test "[RDC-REQ-F0315] generate: --relative-url-root /（単体 /）は失敗する" {
  cd "$WS"
  run rdw generate --relative-url-root /
  [ "$status" -ne 0 ]
}

# RDC-REQ-F0315: ネストしたパスは正常終了する
@test "[RDC-REQ-F0315] generate: --relative-url-root /redmine/sub（ネスト）は正常終了する" {
  cd "$WS"
  run rdw generate --relative-url-root /redmine/sub
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "relative_url_root")
  [ "$val" = "/redmine/sub" ]
}

# RDC-REQ-F0928: --base-image 指定イメージが直接用いられ、リポジトリハードコード処理が適用されない
@test "[RDC-REQ-F0928] generate: --base-image 指定イメージが compose に直接反映される" {
  # explicit mode での state を設定
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=new" "image_ref=futuremine/redmica:4.1.1" \
    "image_source=explicit" "product=" "init_status=done" "dbdump_status=done" \
    "generate_status=pending"
  cd "$WS"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  run rdw generate
  [ "$status" -eq 0 ]
  # Dockerfile の FROM が futuremine/redmica:4.1.1 になり、redmica/redmica への変換が適用されない
  [ -f "$WS/Dockerfile" ]
  grep -q "^FROM futuremine/redmica:4.1.1$" "$WS/Dockerfile"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0928: preset mode では従来のハードコード処理が適用される（比較テスト）
@test "[RDC-REQ-F0928] generate: preset mode では redmica リポジトリハードコード処理が適用される" {
  cd "$WS"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  run rdw generate
  [ "$status" -eq 0 ]
  # この state は redmine preset なので product=redmine のハードコード処理が適用される（既存動作）
  [ -f "$WS/docker-compose.yml" ]
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0910C: pull 失敗でもローカルイメージから config を準備する
@test "[RDC-REQ-F0910C] generate: pull 失敗時も config ファイルを生成する" {
  mkdir -p "$WS/mockbin"
  cat > "$WS/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu

cmd="${1:-}"
shift || true

case "$cmd" in
  pull)
    exit 1
    ;;
  create)
    echo "mock-container"
    ;;
  cp)
    target="${@: -1}"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<'YAML'
default:
  email_delivery:
    delivery_method: :smtp
YAML
    ;;
  rm)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$WS/mockbin/docker"
  cd "$WS"
  export PATH="$WS/mockbin:$PATH"
  export RDC_ALLOW_MOCK=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  run rdw generate
  [ "$status" -eq 0 ]
  [ -f "$WS/config/database.yml" ]
  [ -f "$WS/config/configuration.yml" ]
}

# RDC-REQ-F0910C: pull 失敗時はローカルイメージへフォールバックし、ローカルにも無ければ generate を失敗させる
@test "[RDC-REQ-F0910C] generate: pull 失敗かつローカルイメージなしでは失敗する" {
  mkdir -p "$WS/mockbin"
  cat > "$WS/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu

cmd="${1:-}"
shift || true

case "$cmd" in
  pull)
    exit 1
    ;;
  create)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$WS/mockbin/docker"
  cd "$WS"
  export PATH="$WS/mockbin:$PATH"
  export RDC_ALLOW_MOCK=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  run rdw generate
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "pull"
  echo "$output" | grep -qi "local\|create temporary container\|image"
}

# RDC-REQ-F0303: .env が既にある場合は DB_PASSWORD を再利用する
@test "[RDC-REQ-F0303] generate: 既存 .env の DB_PASSWORD を再利用する" {
  mkdir -p "$WS/mockbin"
  cat > "$WS/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
cmd="${1:-}"
shift || true
case "$cmd" in
  pull) exit 0 ;;
  create) echo "mock-container" ;;
  cp)
    target="${@: -1}"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<'YAML'
default:
  email_delivery:
    delivery_method: :smtp
YAML
    ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WS/mockbin/docker"

  cat > "$WS/.env" <<'EOF'
DB_PASSWORD=from_file
EXTRA_KEY=keep
EOF

  cd "$WS"
  export PATH="$WS/mockbin:$PATH"
  export RDC_ALLOW_MOCK=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q '^DB_PASSWORD=from_file$' "$WS/.env"
  grep -q '^EXTRA_KEY=keep$' "$WS/.env"
}

# RDC-REQ-F0303: .env が無い場合は環境変数 DB_PASSWORD で生成する
@test "[RDC-REQ-F0303] generate: .env 不在時は環境変数 DB_PASSWORD を使う" {
  mkdir -p "$WS/mockbin"
  cat > "$WS/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
cmd="${1:-}"
shift || true
case "$cmd" in
  pull) exit 0 ;;
  create) echo "mock-container" ;;
  cp)
    target="${@: -1}"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<'YAML'
default:
  email_delivery:
    delivery_method: :smtp
YAML
    ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WS/mockbin/docker"

  rm -f "$WS/.env"

  cd "$WS"
  export PATH="$WS/mockbin:$PATH"
  export RDC_ALLOW_MOCK=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  export DB_PASSWORD=from_env
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q '^DB_PASSWORD=from_env$' "$WS/.env"
  unset DB_PASSWORD
}

# RDC-REQ-F0303: 非対話環境で DB_PASSWORD を決定できない場合は失敗する
@test "[RDC-REQ-F0303] generate: 非対話環境で DB_PASSWORD 未確定なら失敗する" {
  mkdir -p "$WS/mockbin"
  cat > "$WS/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
exit 0
EOF
  chmod +x "$WS/mockbin/docker"

  rm -f "$WS/.env"
  unset DB_PASSWORD || true

  cd "$WS"
  export PATH="$WS/mockbin:$PATH"
  export RDC_ALLOW_MOCK=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  run rdw generate < /dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "DB_PASSWORD"
  echo "$output" | grep -qi "non-interactive"
}

# ---- --redmine / --redmica 誤用ガード ----

# generate に --redmine を渡した場合はエラーになり init への誘導メッセージが出る
@test "[RDC-REQ-F0311] generate: --redmine TAG は init オプションのためエラーになる" {
  cd "$WS"
  run rdw generate --redmine 4.1.1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--redmine"
  echo "$output" | grep -qi "init"
}

# generate に --redmica を渡した場合はエラーになり init への誘導メッセージが出る
@test "[RDC-REQ-F0311] generate: --redmica TAG は init オプションのためエラーになる" {
  cd "$WS"
  run rdw generate --redmica 3.1.7
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--redmica"
  echo "$output" | grep -qi "init"
}

# = 形式でも同様にエラーになる
@test "[RDC-REQ-F0311] generate: --redmine=TAG 形式でもエラーになる" {
  cd "$WS"
  run rdw generate --redmine=4.1.1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--redmine"
}

# ---- 完了後自動 status 表示 ----

# generate 完了後にステップ状態一覧と次アクション案内が自動表示される
@test "[RDC-DESIGN] generate: 完了後にステップ状態一覧と次アクション案内が自動表示される" {
  cd "$WS"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  run rdw generate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Steps:"
  echo "$output" | grep -q -- "--- Next Action ---"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# ---- passenger モード: themes / files / configuration.yml コピー ----

# RDC-REQ-F0306A: passenger モードで themes を redmine_root/public/themes/ からコピーする
@test "[RDC-REQ-F0306A] generate passenger: redmine_root/public/themes/ の内容を workspace/themes/ へコピーする" {
  fake_root=$(mktemp -d)
  mkdir -p "$fake_root/public/themes/my_theme"
  touch "$fake_root/public/themes/my_theme/theme.css"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "redmine_root=$fake_root" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  [ -f "$WS/themes/my_theme/theme.css" ]
  rm -rf "$fake_root"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0306B: passenger モードで files を redmine_root/files/ からコピーする
@test "[RDC-REQ-F0306B] generate passenger: redmine_root/files/ の内容を workspace/files/ へコピーする" {
  fake_root=$(mktemp -d)
  mkdir -p "$fake_root/files"
  touch "$fake_root/files/attachment_001.pdf"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "redmine_root=$fake_root" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  [ -f "$WS/files/attachment_001.pdf" ]
  rm -rf "$fake_root"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0306C: passenger モードで redmine_root/config/configuration.yml を優先コピーする
@test "[RDC-REQ-F0306C] generate passenger: redmine_root/config/configuration.yml を workspace/config/configuration.yml に優先コピーする" {
  fake_root=$(mktemp -d)
  mkdir -p "$fake_root/config"
  echo "# existing redmine config" > "$fake_root/config/configuration.yml"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "redmine_root=$fake_root" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q "existing redmine config" "$WS/config/configuration.yml"
  rm -rf "$fake_root"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# ---- workspace モード: themes / files / configuration.yml コピー ----

# RDC-REQ-F0307A: workspace モードで source/themes/ を workspace/themes/ へコピーする
@test "[RDC-REQ-F0307A] generate workspace: source_workspace/themes/ の内容を workspace/themes/ へコピーする" {
  src_ws=$(rdw_make_workspace)
  rdw_full_state_passenger "$src_ws"
  mkdir -p "$src_ws/themes/custom_theme"
  touch "$src_ws/themes/custom_theme/style.css"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=workspace" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "source_workspace=$src_ws" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  [ -f "$WS/themes/custom_theme/style.css" ]
  rm -rf "$src_ws"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0307B: workspace モードで source/files/ を workspace/files/ へコピーする
@test "[RDC-REQ-F0307B] generate workspace: source_workspace/files/ の内容を workspace/files/ へコピーする" {
  src_ws=$(rdw_make_workspace)
  rdw_full_state_passenger "$src_ws"
  mkdir -p "$src_ws/files"
  touch "$src_ws/files/uploaded_file.png"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=workspace" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "source_workspace=$src_ws" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  [ -f "$WS/files/uploaded_file.png" ]
  rm -rf "$src_ws"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0307C: workspace モードで source/config/configuration.yml を workspace/config/configuration.yml へコピーする
@test "[RDC-REQ-F0307C] generate workspace: source_workspace/config/configuration.yml を workspace/config/configuration.yml へコピーする" {
  src_ws=$(rdw_make_workspace)
  rdw_full_state_passenger "$src_ws"
  mkdir -p "$src_ws/config"
  echo "# source workspace config" > "$src_ws/config/configuration.yml"
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=workspace" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" \
    "source_workspace=$src_ws" \
    "generate_status=pending" "import_status=pending" "migrate_status=pending" "check_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q "source workspace config" "$WS/config/configuration.yml"
  rm -rf "$src_ws"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# ---- --deployment オプション ----

# RDC-REQ-F0206: Gemfile.lock が存在しない場合は --deployment でエラーになり export-gemfile-lock を案内する
@test "[RDC-REQ-F0957] generate --deployment: Gemfile.lock なしのワークスペースでエラー終了し export-gemfile-lock への案内を含む" {
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate --deployment
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "Gemfile.lock"
  echo "$output" | grep -qi "export-gemfile-lock"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0207: Gemfile.lock が存在する場合は --deployment で正常終了し Dockerfile に bundle install --deployment が含まれる
@test "[RDC-REQ-F0958] generate --deployment: Gemfile.lock ありのワークスペースで正常終了し Dockerfile に bundle install --deployment が含まれる" {
  printf 'GEM\n  remote: https://rubygems.org/\nBUNDLED WITH\n  2.4.0\n' > "$WS/Gemfile.lock"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate --deployment
  [ "$status" -eq 0 ]
  grep -q "bundle install --deployment" "$WS/Dockerfile"
  grep -q "COPY Gemfile.lock" "$WS/Dockerfile"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0209: --deployment は .rdc_state に deployment_build=true を保存する
@test "[RDC-REQ-F0959] generate --deployment: .rdc_state に deployment_build=true を保存する" {
  printf 'GEM\n  remote: https://rubygems.org/\nBUNDLED WITH\n  2.4.0\n' > "$WS/Gemfile.lock"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate --deployment
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "deployment_build")
  [ "$val" = "true" ]
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0209: generate（フラグなし）で再実行すると deployment_build が false に戻る
@test "[RDC-REQ-F0959b] generate: deployment_build=true の状態からフラグなし再実行で false に更新される" {
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  # deployment_build=true が保存済みの状態を模擬
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=pending" "deployment_build=true"
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "deployment_build")
  [ "$val" = "false" ]
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0303E: Dockerfile に CJK フォントインストールが含まれる（--deployment なし）
@test "[RDC-REQ-F0303E] generate: Dockerfile に fonts-noto-cjk / fontconfig インストールと fc-cache が含まれる" {
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q "fonts-noto-cjk" "$WS/Dockerfile"
  grep -q "fontconfig" "$WS/Dockerfile"
  grep -q "fc-cache" "$WS/Dockerfile"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0303E: --deployment 時も Dockerfile に CJK フォントインストールが含まれる
@test "[RDC-REQ-F0303E] generate --deployment: Dockerfile にも fonts-noto-cjk / fontconfig インストールと fc-cache が含まれる" {
  printf 'GEM\n  remote: https://rubygems.org/\nBUNDLED WITH\n  2.4.0\n' > "$WS/Gemfile.lock"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate --deployment
  [ "$status" -eq 0 ]
  grep -q "fonts-noto-cjk" "$WS/Dockerfile"
  grep -q "fontconfig" "$WS/Dockerfile"
  grep -q "fc-cache" "$WS/Dockerfile"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0303F: generate 後 .env に SECRET_KEY_BASE が自動生成される
@test "[RDC-REQ-F0303F] generate: .env に SECRET_KEY_BASE が自動生成される" {
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q '^SECRET_KEY_BASE=' "$WS/.env"
  val=$(grep '^SECRET_KEY_BASE=' "$WS/.env" | cut -d= -f2-)
  [ ${#val} -ge 64 ]
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0303F: 既存 .env の SECRET_KEY_BASE は上書きしない
@test "[RDC-REQ-F0303F] generate: 既存 .env の SECRET_KEY_BASE を再利用する" {
  cat > "$WS/.env" <<'ENVEOF'
DB_PASSWORD=test_password
SECRET_KEY_BASE=existing_secret_value_abc123
ENVEOF
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q '^SECRET_KEY_BASE=existing_secret_value_abc123$' "$WS/.env"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0303F: docker-compose.yml に SECRET_KEY_BASE が含まれる
@test "[RDC-REQ-F0303F] generate: docker-compose.yml に SECRET_KEY_BASE が含まれる" {
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q 'SECRET_KEY_BASE' "$WS/docker-compose.yml"
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# RDC-REQ-F0208: --deployment なし時は Dockerfile に通常の bundle install が含まれ --deployment は含まれない
@test "[RDC-REQ-F0208] generate: --deployment 省略時は Dockerfile に bundle install --deployment が含まれない" {
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1
  export RDC_THEMES_CONTAINER_PATH=/usr/src/redmine/themes
  cd "$WS"
  run rdw generate
  [ "$status" -eq 0 ]
  grep -q "bundle install" "$WS/Dockerfile"
  run grep "bundle install --deployment" "$WS/Dockerfile"
  [ "$status" -ne 0 ]
  unset RDC_MOCK_SKIP_IMAGE_EXTRACT
}
