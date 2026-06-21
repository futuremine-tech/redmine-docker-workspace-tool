#!/usr/bin/env bats
# test/bats/rdw_unit.bats
# 単体テスト: ModeResolver, StateStore, ComposeRenderer, ManifestBuilder
# 根拠要件: RDC-REQ-F0907, RDC-REQ-F0908, RDC-REQ-F0908A, RDC-REQ-F0910, RDC-REQ-F0912B, RDC-REQ-F0912C

source test/helpers/rdw_helpers.sh

setup() {
  source lib/rdc/state_store.bash
  source lib/rdc/mode_resolver.bash
  source lib/rdc/compose_renderer.bash
  source lib/rdc/manifest_builder.bash
  source lib/rdc/prepare_db_service.bash
  source lib/rdc/generate_service.bash
  WS=$(rdw_make_workspace)
}

teardown() {
  rm -rf "$WS"
}

# ---- ModeResolver#resolve ----

# RDC-REQ-F0907: --mode 未指定かつ mode 専用入力なしで new を既定採用する
@test "[RDC-REQ-F0907] ModeResolver: --mode 未指定・専用入力なしで new を採用する" {
  run mode_resolver_resolve
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]
}

# RDC-REQ-F0908: --mode 未指定で passenger/workspace 専用入力がある場合は失敗する
@test "[RDC-REQ-F0908] ModeResolver: --mode 未指定・--redmine-root 指定は失敗する" {
  run mode_resolver_resolve --redmine-root /var/lib/redmine
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "mode"
}

# RDC-REQ-F0908A: workspace モードで --source 未指定を拒否する
@test "[RDC-REQ-F0908A] ModeResolver: --mode workspace で --source 未指定は失敗する" {
  run mode_resolver_resolve --mode workspace
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "source"
}

# RDC-REQ-F0908A: workspace モードで target と同一パスの --source を拒否する
@test "[RDC-REQ-F0908A] ModeResolver: --mode workspace で source と target が同一パスは失敗する" {
  cd "$WS"
  run mode_resolver_resolve --mode workspace --source "$WS"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "same"
}

# ---- StateStore#reset_after_reinit ----

# RDC-REQ-F0907B: 同一 mode 再 init で下流状態を pending へ戻す
@test "[RDC-REQ-F0907B] StateStore: 同一 mode 再 init で下流状態が pending に戻る" {
  rdw_full_state_passenger "$WS"
  run state_store_reset_after_reinit "$WS"
  [ "$status" -eq 0 ]
  val=$(rdw_read_state "$WS" "generate_status")
  [ "$val" = "pending" ]
  val=$(rdw_read_state "$WS" "import_status")
  [ "$val" = "pending" ]
}

# RDC-REQ-F0907C: mode 相違時に clean 案内を返す前提データを保つ
@test "[RDC-REQ-F0907C] StateStore: mode 相違時の clean 案内メッセージを保持する" {
  rdw_init_state "$WS" "workspace_initialized=true" "mode=passenger" "init_status=done"
  run state_store_reset_after_reinit "$WS" "workspace"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "clean"
}

# ---- ComposeRenderer#render_compose ----

# RDC-REQ-F0910: workspace-path ラベルを埋め込む
@test "[RDC-REQ-F0910] ComposeRenderer: workspace-path ラベルが compose 定義に含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "workspace-path"
}

# RDC-REQ-F0910A: PostgreSQL を既定では公開しない
@test "[RDC-REQ-F0910A] ComposeRenderer: PostgreSQL を既定ではホスト公開しない" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_PG_PUBLISH_PORT=""
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "5432:"
}

# RDC-REQ-F0910B: 明示ポートをホスト公開ポートとして反映する
@test "[RDC-REQ-F0910B] ComposeRenderer: --db-publish-port を指定するとホスト公開ポートとして反映される" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_PG_PUBLISH_PORT="15432"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "15432"
}

# RDC-REQ-F0910F: 通常 up で bundle install が走らない構成を生成する
@test "[RDC-REQ-F0910F] ComposeRenderer: 通常 up で bundle install が走らない構成を生成する" {
  export RDC_WORKSPACE_PATH="$WS"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "bundle install"
}

# RDC-REQ-F0910F: Dockerfile には generate ごとの build 判定用ラベルを埋め込める
@test "[RDC-REQ-F0910F] ComposeRenderer: Dockerfile に generate-id ラベルを含める" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_GENERATE_ID="2026-06-01T12:00:00Z"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'io.github.futuremine-tech.rdc.generate-id'
  echo "$output" | grep -q '2026-06-01T12:00:00Z'
}

# RDC-REQ-F0303A: build 時に config/database.yml を参照して adapter 依存を解決できる
@test "[RDC-REQ-F0303A] ComposeRenderer: Dockerfile は bundle install 時に config/database.yml を bind mount する" {
  export RDC_WORKSPACE_PATH="$WS"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'source=config/database.yml,target=/usr/src/redmine/config/database.yml,readonly'
}

# RDC-REQ-F0007: RedMica 3.1.x 以前は redmica/redmica:<tag> を使う（公式イメージ提供期間内）
@test "[RDC-REQ-F0007] ComposeRenderer: redmica 3.1.7 の Dockerfile は redmica/redmica:<tag> を FROM に使う" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_PRODUCT="redmica"
  export RDC_TARGET_IMAGE_TAG="3.1.7"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^FROM redmica/redmica:3.1.7$'
}

# RDC-REQ-F0007: image name resolver は RedMica 3.1.x → redmica/redmica を解決する
@test "[RDC-REQ-F0007] ComposeRenderer: redmica 3.1.7 の image 名を redmica/redmica:<tag> に解決する" {
  run compose_renderer_resolve_image_name redmica 3.1.7
  [ "$status" -eq 0 ]
  [ "$output" = "redmica/redmica:3.1.7" ]
}

# RedMica 3.2.0 以降は公式イメージが終了し futuremine/redmica を使う
@test "[DESIGN] ComposeRenderer: redmica 3.2.0 の image 名を futuremine/redmica:<tag> に解決する" {
  run compose_renderer_resolve_image_name redmica 3.2.0
  [ "$status" -eq 0 ]
  [ "$output" = "futuremine/redmica:3.2.0" ]
}

@test "[DESIGN] ComposeRenderer: redmica 4.0.0 の image 名を futuremine/redmica:<tag> に解決する" {
  run compose_renderer_resolve_image_name redmica 4.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "futuremine/redmica:4.0.0" ]
}

@test "[DESIGN] ComposeRenderer: redmica latest の image 名を futuremine/redmica:latest に解決する" {
  run compose_renderer_resolve_image_name redmica latest
  [ "$status" -eq 0 ]
  [ "$output" = "futuremine/redmica:latest" ]
}

@test "[DESIGN] ComposeRenderer: redmica 3.2.0 の Dockerfile は futuremine/redmica:<tag> を FROM に使う" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_PRODUCT="redmica"
  export RDC_TARGET_IMAGE_TAG="3.2.0"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^FROM futuremine/redmica:3.2.0$'
}

# RDC-REQ-F0354: fresh-db は force-recreate 付きで DB コンテナを起動する
@test "[RDC-REQ-F0354] PrepareDbService: fresh-db は force-recreate 付きで DB コンテナを起動する" {
  local fake_dir log_file
  fake_dir=$(mktemp -d)
  log_file="$fake_dir/docker.log"
  cat > "$fake_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$*" in
  *"compose up -d --force-recreate db"*)
    exit 0
    ;;
  *"compose exec -T db pg_isready -U redmine -d redmine"*)
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$fake_dir/docker"
  export FAKE_DOCKER_LOG="$log_file"
  export PATH="$fake_dir:$PATH"
  export RDC_ALLOW_MOCK=0

  mkdir -p "$WS/compose"
  cat > "$WS/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres:14-alpine
EOF

  run prepare_db_service_initialize_fresh_db "$WS"
  [ "$status" -eq 0 ]
  grep -q -- "compose up -d --force-recreate db" "$log_file"
}

# RDC-REQ-F0312: themes path 検出は docker run 経由で安定して取得する
@test "[RDC-REQ-F0312] GenerateService: themes path 検出は docker run --rm で実行する" {
  local fake_dir log_file
  fake_dir=$(mktemp -d)
  log_file="$fake_dir/docker.log"
  cat > "$fake_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  run)
    echo "/usr/src/redmine/themes"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$fake_dir/docker"
  export FAKE_DOCKER_LOG="$log_file"
  export PATH="$fake_dir:$PATH"

  run generate_service_detect_themes_path explicit futuremine/redmica:3.2.0
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/src/redmine/themes" ]
  grep -q -- "run --rm futuremine/redmica:3.2.0" "$log_file"
}

# ---- ManifestBuilder#build_success ----

# RDC-REQ-F0912B: 成功 manifest に必要な情報が含まれる
@test "[RDC-REQ-F0912B] ManifestBuilder: 成功 manifest に image_digest, migrate, check, target 情報が含まれる" {
  rdw_full_state_passenger "$WS"
  run manifest_builder_build_success "$WS" "sha256:abc123" "redmineup_tags@unknown"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "image_digest"
  echo "$output" | grep -q "migrate"
  echo "$output" | grep -q "check"
  echo "$output" | grep -q "passed"
}

# RDC-REQ-F0912C: 失敗時と成功時の status が混同しない
@test "[RDC-REQ-F0912C] ManifestBuilder: 失敗 manifest の status は passed にならない" {
  rdw_full_state_passenger "$WS"
  run manifest_builder_build_failure "$WS" "HTTP timeout"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv '"status": "passed"'
  echo "$output" | grep -q "failed"
}

# ---- StateStore#state_store_find_workspace_root ----

# RDC-REQ-F0101A: ワークスペースルートに .rdc_state がある場合にそのパスを返す
@test "[RDC-REQ-F0101A] StateStore: ワークスペースルートに .rdc_state がある場合にそのパスを返す" {
  touch "$WS/.rdc_state"
  cd "$WS"
  run state_store_find_workspace_root
  [ "$status" -eq 0 ]
  [ "$output" = "$WS" ]
}

# RDC-REQ-F0101A: サブディレクトリからでも .rdc_state のあるルートを返す
@test "[RDC-REQ-F0101A] StateStore: サブディレクトリからでも上位の .rdc_state を返す" {
  touch "$WS/.rdc_state"
  mkdir -p "$WS/plugins/sub"
  cd "$WS/plugins/sub"
  run state_store_find_workspace_root
  [ "$status" -eq 0 ]
  [ "$output" = "$WS" ]
}

# RDC-REQ-F0101A: .rdc_state が存在しない場合は失敗する
@test "[RDC-REQ-F0101A] StateStore: .rdc_state が存在しない場合は非ゼロで終了する" {
  cd "$WS"
  run state_store_find_workspace_root
  [ "$status" -ne 0 ]
}

# ---- ComposeRenderer: RAILS_RELATIVE_URL_ROOT ----

# RDC-REQ-F0314: --relative-url-root 指定時に RAILS_RELATIVE_URL_ROOT が compose に含まれる
@test "[RDC-REQ-F0314] ComposeRenderer: RDC_RELATIVE_URL_ROOT=/redmine のとき compose に RAILS_RELATIVE_URL_ROOT が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_RELATIVE_URL_ROOT="/redmine"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "RAILS_RELATIVE_URL_ROOT"
  echo "$output" | grep -q '"/redmine"'
  echo "$output" | grep -q "rdc-config.ru:/usr/src/redmine/config.ru:ro"
}

# RDC-REQ-F0314: --relative-url-root 省略時は RAILS_RELATIVE_URL_ROOT が compose に含まれない
@test "[RDC-REQ-F0314] ComposeRenderer: RDC_RELATIVE_URL_ROOT 未設定のとき compose に RAILS_RELATIVE_URL_ROOT が含まれない" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_RELATIVE_URL_ROOT=""
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "RAILS_RELATIVE_URL_ROOT"
  echo "$output" | grep -qv "rdc-config.ru:/usr/src/redmine/config.ru:ro"
}

# RDC-REQ-F0314: relative-url-root 用 Rackup は map でアプリをサブパスへマウントする
@test "[RDC-REQ-F0314] ComposeRenderer: rackup は RAILS_RELATIVE_URL_ROOT を map して run Rails.application する" {
  export RDC_RELATIVE_URL_ROOT="/redmine"
  run compose_renderer_render_rackup
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ENV.fetch('RAILS_RELATIVE_URL_ROOT'"
  echo "$output" | grep -q "map relative_url"
  echo "$output" | grep -q "run Rails.application"
}

# ---- PrepareDbService: --from-external-db PGPASSWORD 挙動 ----

# RDC-REQ-F0351B: database.yml に password があれば PGPASSWORD を pg_dump へ渡す
@test "[RDC-REQ-F0351B] PrepareDbService: database.yml の password を PGPASSWORD として pg_dump へ渡す" {
  unset RDC_ALLOW_MOCK PGPASSWORD
  prepare_db_service_reset_db_volume() { return 0; }
  prepare_db_service_restore_dump() { return 0; }

  local fake_root="$WS/fake_redmine"
  mkdir -p "$fake_root/config"
  cat > "$fake_root/config/database.yml" <<'EOF'
production:
  adapter: postgresql
  host: localhost
  database: redmine
  username: redmine
  password: s3cretpw
EOF

  local fake_bin log_file
  fake_bin=$(mktemp -d)
  log_file="$fake_bin/pg_dump.log"
  cat > "$fake_bin/pg_dump" <<PGEOF
#!/usr/bin/env bash
echo "PGPASSWORD=\${PGPASSWORD:-__NOT_SET__}" >> "$log_file"
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "-f" ]]; then touch "\$arg"; break; fi
  prev="\$arg"
done
exit 0
PGEOF
  chmod +x "$fake_bin/pg_dump"
  export PATH="$fake_bin:$PATH"
  export RDC_STATE_redmine_root="$fake_root"
  export RDC_LOG_FILE="$WS/test.log"

  prepare_db_service_prepare_from_external_db "$WS"
  local result=$?
  [ "$result" -eq 0 ]
  grep -q "PGPASSWORD=s3cretpw" "$log_file"
  rm -rf "$fake_bin"
}

# RDC-REQ-F0351B: database.yml に password がなければ PGPASSWORD なしで pg_dump を呼ぶ
@test "[RDC-REQ-F0351B] PrepareDbService: database.yml に password がなければ PGPASSWORD なしで pg_dump を呼ぶ" {
  unset RDC_ALLOW_MOCK PGPASSWORD
  prepare_db_service_reset_db_volume() { return 0; }
  prepare_db_service_restore_dump() { return 0; }

  local fake_root="$WS/fake_redmine"
  mkdir -p "$fake_root/config"
  cat > "$fake_root/config/database.yml" <<'EOF'
production:
  adapter: postgresql
  host: localhost
  database: redmine
  username: redmine
EOF

  local fake_bin log_file
  fake_bin=$(mktemp -d)
  log_file="$fake_bin/pg_dump.log"
  cat > "$fake_bin/pg_dump" <<PGEOF
#!/usr/bin/env bash
echo "PGPASSWORD=\${PGPASSWORD:-__NOT_SET__}" >> "$log_file"
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "-f" ]]; then touch "\$arg"; break; fi
  prev="\$arg"
done
exit 0
PGEOF
  chmod +x "$fake_bin/pg_dump"
  export PATH="$fake_bin:$PATH"
  export RDC_STATE_redmine_root="$fake_root"
  export RDC_LOG_FILE="$WS/test.log"

  prepare_db_service_prepare_from_external_db "$WS"
  local result=$?
  [ "$result" -eq 0 ]
  grep -q "PGPASSWORD=__NOT_SET__" "$log_file"
  rm -rf "$fake_bin"
}
