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
  source lib/rdc/version_detector.bash
  source lib/rdc/generate_service.bash
  source lib/rdc/status_service.bash
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

# RDC-REQ-F0910: user: "999:<GID>" が compose 定義に含まれる
@test "[RDC-REQ-F0910] ComposeRenderer: user に UID 999 と generate 実行ユーザーの GID が設定される" {
  export RDC_WORKSPACE_PATH="$WS"
  local expected_gid
  expected_gid=$(id -g)
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "user: \"999:${expected_gid}\""
}

# RDC-REQ-F0910: RDC_CONTAINER_GID で GID を上書きできる
@test "[RDC-REQ-F0910] ComposeRenderer: RDC_CONTAINER_GID を指定すると user の GID がその値になる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_CONTAINER_GID="1234"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'user: "999:1234"'
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

# RDC-REQ-F1309: Redmine 7.0.0 以降は futuremine/redmine を優先する
@test "[RDC-REQ-F1309] ComposeRenderer: redmine 7.0.0 の image 名を futuremine/redmine:<tag> に解決する" {
  run compose_renderer_resolve_image_name redmine 7.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "futuremine/redmine:7.0.0" ]
}

@test "[RDC-REQ-F1309] ComposeRenderer: redmine 6.1.3 の image 名を redmine:<tag>（公式）に解決する" {
  run compose_renderer_resolve_image_name redmine 6.1.3
  [ "$status" -eq 0 ]
  [ "$output" = "redmine:6.1.3" ]
}

@test "[RDC-REQ-F1309] ComposeRenderer: redmine latest の image 名を futuremine/redmine:latest に解決する" {
  run compose_renderer_resolve_image_name redmine latest
  [ "$status" -eq 0 ]
  [ "$output" = "futuremine/redmine:latest" ]
}

@test "[RDC-REQ-F1309] ComposeRenderer: --base-image futuremine/redmine:6.1.3 は自動選択を適用せずそのまま使う" {
  run compose_renderer_resolve_image_name explicit futuremine/redmine:6.1.3
  [ "$status" -eq 0 ]
  [ "$output" = "futuremine/redmine:6.1.3" ]
}

@test "[RDC-REQ-F1309] ComposeRenderer: --base-image redmine:7.0.0 は閾値判定を適用せず公式イメージのまま使う" {
  run compose_renderer_resolve_image_name explicit redmine:7.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "redmine:7.0.0" ]
}

@test "[RDC-REQ-F1309] ComposeRenderer: redmine 7.0.0 の Dockerfile は futuremine/redmine:<tag> を FROM に使う" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_PRODUCT="redmine"
  export RDC_TARGET_IMAGE_TAG="7.0.0"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^FROM futuremine/redmine:7.0.0$'
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

# ---- VersionDetector#detect_from_root ----

# RDC-REQ-F1413: VERSION ファイルが存在する場合はその内容を優先する（redmine）
@test "[RDC-REQ-F1413] VersionDetector: VERSION ファイルが存在する場合はその内容を返す（redmine）" {
  local root
  root=$(mktemp -d)
  echo "7.0.1" > "$root/VERSION"

  run version_detector_detect_from_root redmine "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "7.0.1" ]
  rm -rf "$root"
}

# RDC-REQ-F1413: VERSION ファイルが無い場合は lib/redmine/version.rb から MAJOR.MINOR.TINY を組み立てる
@test "[RDC-REQ-F1413] VersionDetector: VERSION 無し・lib/redmine/version.rb からバージョンを組み立てる（redmine）" {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/lib/redmine"
  cat > "$root/lib/redmine/version.rb" <<'EOF'
module Redmine
  module VERSION
    MAJOR = 6
    MINOR = 1
    TINY  = 2
  end
end
EOF

  run version_detector_detect_from_root redmine "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "6.1.2" ]
  rm -rf "$root"
}

# RDC-REQ-F1413: RedMica は VERSION が無い場合 lib/redmica/version.rb を優先する（lib/redmine/version.rb は無視）
@test "[RDC-REQ-F1413] VersionDetector: VERSION 無し・RedMica は lib/redmica/version.rb を使う" {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/lib/redmica" "$root/lib/redmine"
  cat > "$root/lib/redmica/version.rb" <<'EOF'
module RedMica
  module VERSION
    MAJOR = 3
    MINOR = 2
    TINY  = 4
  end
end
EOF
  cat > "$root/lib/redmine/version.rb" <<'EOF'
module Redmine
  module VERSION
    MAJOR = 6
    MINOR = 0
    TINY  = 6
  end
end
EOF

  run version_detector_detect_from_root redmica "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "3.2.4" ]
  rm -rf "$root"
}

# RDC-REQ-F1413: 何も見つからない場合は unknown を返す
@test "[RDC-REQ-F1413] VersionDetector: VERSION も version.rb も無い場合は unknown を返す" {
  local root
  root=$(mktemp -d)

  run version_detector_detect_from_root redmine "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  rm -rf "$root"
}

# ---- GenerateService: base_image_digest / redmine_version の .rdc_state 保存 ----

# RDC-REQ-F0407(是正): docker inspect の RepoDigests から base_image_digest を .rdc_state へ保存する
@test "[RDC-REQ-F0407] GenerateService: pull直後に RepoDigests から base_image_digest を .rdc_state へ保存する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=pending"
  local fake_dir log_file
  fake_dir=$(mktemp -d)
  log_file="$fake_dir/docker.log"
  cat > "$fake_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  pull) exit 0 ;;
  inspect) echo "futuremine/redmine@sha256:realdigest000111222" ;;
  create) echo "mock-container" ;;
  cp)
    dest="${*: -1}"
    mkdir -p "$(dirname "$dest")"
    echo "dummy" > "$dest"
    ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_dir/docker"
  export FAKE_DOCKER_LOG="$log_file"
  export PATH="$fake_dir:$PATH"
  # RDC_ALLOW_MOCK=1 が設定されていると docker inspect 自体を呼ばず unknown になる
  # （scripts/run-bats.sh 経由の実行では既定で export されているため、このテストでは明示的に外す）
  unset RDC_ALLOW_MOCK

  run generate_service_extract_configuration_example "$WS" redmine 6.1.2
  [ "$status" -eq 0 ]
  [ "$(rdw_read_state "$WS" base_image_digest)" = "futuremine/redmine@sha256:realdigest000111222" ]
}

# RDC-REQ-F0407(是正): docker inspect の --format には RepoDigests 優先・.Id フォールバックの
# 両方が1回の呼び出しに埋め込まれる（フォールバック判定は docker 側の Go template が行うため、
# bash 側は format 引数の内容と、出力をそのまま保存することだけを検証する）
@test "[RDC-REQ-F0407] GenerateService: docker inspect の --format に RepoDigests 優先・.Id フォールバックの両方を渡す" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=pending"
  local fake_dir log_file
  fake_dir=$(mktemp -d)
  log_file="$fake_dir/docker.log"
  cat > "$fake_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  pull) exit 0 ;;
  # RepoDigests が無いケースを模した戻り値（実際の分岐は docker の Go template が行う）
  inspect) echo "sha256:localimageid333444" ;;
  create) echo "mock-container" ;;
  cp)
    dest="${*: -1}"
    mkdir -p "$(dirname "$dest")"
    echo "dummy" > "$dest"
    ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_dir/docker"
  export FAKE_DOCKER_LOG="$log_file"
  export PATH="$fake_dir:$PATH"
  unset RDC_ALLOW_MOCK

  run generate_service_extract_configuration_example "$WS" redmine 6.1.2
  [ "$status" -eq 0 ]
  [ "$(rdw_read_state "$WS" base_image_digest)" = "sha256:localimageid333444" ]
  grep -qF -- "inspect --format={{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}" "$log_file"
}

# RDC-REQ-F1413: docker cp で取得した VERSION の内容を redmine_version として .rdc_state へ保存する
@test "[RDC-REQ-F1413] GenerateService: docker cp した VERSION の内容を redmine_version として保存する" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=latest" "init_status=done" "dbdump_status=done" \
    "generate_status=pending"
  local fake_dir
  fake_dir=$(mktemp -d)
  cat > "$fake_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  pull) exit 0 ;;
  inspect) echo "sha256:unused" ;;
  create) echo "mock-container" ;;
  cp)
    dest="${*: -1}"
    case "$dest" in
      *VERSION)
        mkdir -p "$(dirname "$dest")"
        printf '7.0.4' > "$dest"
        ;;
      *lib/redmine/version.rb|*lib/redmica/version.rb)
        exit 1
        ;;
      *)
        # configuration.yml.example / additional_environment.rb.example（本テストの対象外）
        mkdir -p "$(dirname "$dest")"
        echo "dummy" > "$dest"
        ;;
    esac
    ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_dir/docker"
  export PATH="$fake_dir:$PATH"
  unset RDC_ALLOW_MOCK

  run generate_service_extract_configuration_example "$WS" redmine latest
  [ "$status" -eq 0 ]
  [ "$(rdw_read_state "$WS" redmine_version)" = "7.0.4" ]
}

# RDC-REQ-F1413: モックスキップ経路（RDC_MOCK_SKIP_IMAGE_EXTRACT）では unknown を保存する
@test "[RDC-REQ-F1413] GenerateService: RDC_MOCK_SKIP_IMAGE_EXTRACT 時は redmine_version/base_image_digest ともに unknown" {
  rdw_init_state "$WS" \
    "workspace_initialized=true" "mode=passenger" "product=redmine" \
    "target_image_tag=6.1.2" "init_status=done" "dbdump_status=done" \
    "generate_status=pending"
  export RDC_ALLOW_MOCK=1
  export RDC_MOCK_SKIP_IMAGE_EXTRACT=1

  run generate_service_extract_configuration_example "$WS" redmine 6.1.2
  [ "$status" -eq 0 ]
  [ "$(rdw_read_state "$WS" redmine_version)" = "unknown" ]
  [ "$(rdw_read_state "$WS" base_image_digest)" = "unknown" ]
  unset RDC_ALLOW_MOCK RDC_MOCK_SKIP_IMAGE_EXTRACT
}

# ---- ManifestBuilder#build_success ----

# RDC-REQ-F0912B: 成功 manifest に必要な情報が含まれる
@test "[RDC-REQ-F0912B] ManifestBuilder: 成功 manifest に base_image_digest, migrate, check, target 情報が含まれる" {
  rdw_full_state_passenger "$WS"
  run manifest_builder_build_success "$WS" "sha256:abc123" "redmineup_tags@unknown"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"base_image_digest": "sha256:abc123"'
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

# ---- ComposeRenderer: extra-config-mount ----

# RDC-REQ-F1301: RDC_EXTRA_CONFIG_MOUNTS 指定時に該当 volumes 行が含まれる
@test "[RDC-REQ-F1301] ComposeRenderer: RDC_EXTRA_CONFIG_MOUNTS=queue.yml のとき compose に bind mount 行が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_EXTRA_CONFIG_MOUNTS="queue.yml"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "config/queue.yml:/usr/src/redmine/config/queue.yml"
}

# RDC-REQ-F1301: カンマ区切り複数指定で両方の volumes 行が含まれる
@test "[RDC-REQ-F1301] ComposeRenderer: RDC_EXTRA_CONFIG_MOUNTS=queue.yml,recurring.yml のとき両方が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_EXTRA_CONFIG_MOUNTS="queue.yml,recurring.yml"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "config/queue.yml:/usr/src/redmine/config/queue.yml"
  echo "$output" | grep -q "config/recurring.yml:/usr/src/redmine/config/recurring.yml"
}

# RDC-REQ-F1301: RDC_EXTRA_CONFIG_MOUNTS 未設定のとき追加行が含まれない
@test "[RDC-REQ-F1301] ComposeRenderer: RDC_EXTRA_CONFIG_MOUNTS 未設定のとき追加 volumes 行が含まれない" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_EXTRA_CONFIG_MOUNTS=""
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "/usr/src/redmine/config/queue.yml"
}

# ---- ComposeRenderer: additional_environment.rb (F1308) ----

# RDC-REQ-F1308: additional_environment.rb の bind mount 行が常に含まれる
@test "[RDC-REQ-F1308] ComposeRenderer: additional_environment.rb の bind mount 行が常に含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "config/additional_environment.rb:/usr/src/redmine/config/additional_environment.rb"
}

# ---- GenerateService: write_additional_environment_rb (F1307) ----

# RDC-REQ-F1307: 未存在時にプレースホルダを生成する
@test "[RDC-REQ-F1307] GenerateService: additional_environment.rb 未存在時にプレースホルダを生成する" {
  mkdir -p "$WS/config"
  run generate_service_write_additional_environment_rb "$WS/config"
  [ "$status" -eq 0 ]
  [ -f "$WS/config/additional_environment.rb" ]
}

# RDC-REQ-F1307: 既存ファイルを上書きしない
@test "[RDC-REQ-F1307] GenerateService: additional_environment.rb 既存時は上書きしない" {
  mkdir -p "$WS/config"
  echo "config.log_level = :debug" > "$WS/config/additional_environment.rb"
  run generate_service_write_additional_environment_rb "$WS/config"
  [ "$status" -eq 0 ]
  grep -q "config.log_level = :debug" "$WS/config/additional_environment.rb"
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

# ---- ComposeRenderer: assets:precompile (RDC-REQ-F0303G / F0303H) ----

# RDC-REQ-F0303G: テーマパスが /usr/src/redmine/themes のとき Dockerfile に assets:precompile が含まれる
@test "[RDC-REQ-F0303G] ComposeRenderer: themes=/usr/src/redmine/themes のとき Dockerfile に assets:precompile が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_THEMES_CONTAINER_PATH="/usr/src/redmine/themes"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "assets:precompile"
}

# RDC-REQ-F0303G: テーマパスが /usr/src/redmine/themes のとき Dockerfile に ARG RAILS_RELATIVE_URL_ROOT が含まれる
@test "[RDC-REQ-F0303G] ComposeRenderer: themes=/usr/src/redmine/themes のとき Dockerfile に ARG RAILS_RELATIVE_URL_ROOT が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_THEMES_CONTAINER_PATH="/usr/src/redmine/themes"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ARG RAILS_RELATIVE_URL_ROOT"
}

# RDC-REQ-F0303G: テーマパスが /usr/src/redmine/public/themes のとき Dockerfile に assets:precompile が含まれない
@test "[RDC-REQ-F0303G] ComposeRenderer: themes=/usr/src/redmine/public/themes のとき Dockerfile に assets:precompile が含まれない" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_THEMES_CONTAINER_PATH="/usr/src/redmine/public/themes"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "assets:precompile"
}

# RDC-REQ-F0303G: --deployment 時もテーマパスが /usr/src/redmine/themes なら Dockerfile に assets:precompile が含まれる
@test "[RDC-REQ-F0303G] ComposeRenderer: deployment=true かつ themes=/usr/src/redmine/themes のとき Dockerfile に assets:precompile が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_THEMES_CONTAINER_PATH="/usr/src/redmine/themes"
  export RDC_DEPLOYMENT_BUILD="true"
  run compose_renderer_render_dockerfile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "assets:precompile"
  unset RDC_DEPLOYMENT_BUILD
}

# RDC-REQ-F0303H: テーマパスが /usr/src/redmine/themes のとき compose に build.args と secret_key_base が含まれる
@test "[RDC-REQ-F0303H] ComposeRenderer: themes=/usr/src/redmine/themes のとき compose に RAILS_RELATIVE_URL_ROOT args と secret_key_base が含まれる" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_THEMES_CONTAINER_PATH="/usr/src/redmine/themes"
  export RDC_RELATIVE_URL_ROOT=""
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "RAILS_RELATIVE_URL_ROOT"
  echo "$output" | grep -q "secret_key_base"
}

# RDC-REQ-F0303H: テーマパスが /usr/src/redmine/public/themes のとき compose に build.args と secrets が含まれない
@test "[RDC-REQ-F0303H] ComposeRenderer: themes=/usr/src/redmine/public/themes のとき compose に secret_key_base が含まれない" {
  export RDC_WORKSPACE_PATH="$WS"
  export RDC_THEMES_CONTAINER_PATH="/usr/src/redmine/public/themes"
  export RDC_RELATIVE_URL_ROOT=""
  run compose_renderer_render_compose
  [ "$status" -eq 0 ]
  echo "$output" | grep -qv "secret_key_base"
}

# ---- docker_is_rootless() ----

# RDC-REQ-F1010: RDC_MOCK_DOCKER_ROOTLESS=true のとき rootless (成功) と判定する
@test "[RDC-REQ-F1010] docker_is_rootless: RDC_MOCK_DOCKER_ROOTLESS=true のとき成功(rootless)を返す" {
  RDC_MOCK_DOCKER_ROOTLESS=true run docker_is_rootless
  [ "$status" -eq 0 ]
}

# RDC-REQ-F1010: RDC_MOCK_DOCKER_ROOTLESS=false のとき rootful (失敗) と判定する
@test "[RDC-REQ-F1010] docker_is_rootless: RDC_MOCK_DOCKER_ROOTLESS=false のとき失敗(rootful)を返す" {
  RDC_MOCK_DOCKER_ROOTLESS=false run docker_is_rootless
  [ "$status" -eq 1 ]
}

# RDC-REQ-F1010: モック未指定・RDC_ALLOW_MOCK=1 のときは既存テストとの後方互換のため rootful (失敗) 扱いにする
@test "[RDC-REQ-F1010] docker_is_rootless: RDC_ALLOW_MOCK=1 かつ個別モック未指定のとき rootful (失敗) 扱いになる" {
  RDC_ALLOW_MOCK=1 run docker_is_rootless
  [ "$status" -eq 1 ]
}
