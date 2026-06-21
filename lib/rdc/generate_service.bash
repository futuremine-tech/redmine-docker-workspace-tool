#!/usr/bin/env bash
# lib/rdc/generate_service.bash
# Dockerfile / compose / env 生成、plugins 配置整備を担う Service
# 根拠要件: RDC-REQ-F0301〜RDC-REQ-F0313

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/compose_renderer.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# _generate_service_find_free_port()
# 指定ポートが使用中なら次の空きポートを返す
# args: start_port
_generate_service_port_in_use() {
  local port="${1:?port required}"

  local ss_cmd=""
  if command -v ss >/dev/null 2>&1; then
    ss_cmd="$(command -v ss)"
  elif [[ -x /usr/sbin/ss ]]; then
    ss_cmd="/usr/sbin/ss"
  elif [[ -x /usr/bin/ss ]]; then
    ss_cmd="/usr/bin/ss"
  fi

  if [[ -n "$ss_cmd" ]]; then
    "$ss_cmd" -tln 2>/dev/null | grep -q ":$port "
    return $?
  fi

  local netstat_cmd=""
  if command -v netstat >/dev/null 2>&1; then
    netstat_cmd="$(command -v netstat)"
  elif [[ -x /usr/sbin/netstat ]]; then
    netstat_cmd="/usr/sbin/netstat"
  elif [[ -x /usr/bin/netstat ]]; then
    netstat_cmd="/usr/bin/netstat"
  fi

  if [[ -n "$netstat_cmd" ]]; then
    "$netstat_cmd" -tln 2>/dev/null | grep -q ":$port "
    return $?
  fi

  # 2 means port check tools unavailable.
  return 2
}

_generate_service_find_free_port() {
  local port="${1:-38080}"
  while true; do
    _generate_service_port_in_use "$port"
    local rc=$?
    case "$rc" in
      0) ((port++)) ;;
      1)
        echo "$port"
        return 0
        ;;
      2)
        logger_error "Cannot detect used ports: neither ss nor netstat is available in PATH or standard locations."
        echo "ERROR: Port availability check failed (ss/netstat not found)." >&2
        return 1
        ;;
      *)
        logger_error "Unexpected error while checking port usage."
        echo "ERROR: Port availability check failed." >&2
        return 1
        ;;
    esac
  done
}

# generate_service_run()
# generate サブコマンド全体を実行する
# args: argv...
# returns: exit_code
generate_service_run() {
  # --help は workspace チェックより先に処理する
  for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      echo "Usage: redmine-docker-workspace generate [options]"
      echo ""
      echo "Generates Dockerfile, docker-compose.yml, and related configuration files"
      echo "in the workspace. bundle install is performed during 'docker compose build'."
      echo "Migration is separated to the 'migrate' subcommand."
      echo ""
      echo "Options:"
      echo "  --bind-host HOST     Redmine bind host (default: 127.0.0.1)"
      echo "  --bind-port PORT     Redmine host port (default: auto-detected 38080+)"
      echo "  --db-publish-port PORT  PostgreSQL host port (default: not published)"
      echo "  --relative-url-root PATH  Redmine subpath (e.g. /redmine). Omit for root (/)."
      echo "  --deployment         Use Gemfile.lock for reproducible bundle install (F0205)"
      echo "  -v, --verbose        Verbose output"
      echo ""
      echo "After generate, run in order:"
      echo "  1. redmine-docker-workspace prepare-db (--import-from PATH | --fresh-db | --from-external-db | --skip --reason TEXT)"
      echo "  2. docker compose build"
      echo "  3. redmine-docker-workspace migrate"
      echo "  4. docker compose up -d"
      echo "  5. redmine-docker-workspace check"
      echo ""
      echo "Note: --import-from, --fresh-db, --from-external-db, --skip, and --reason are prepare-db subcommand options, not generate."
      return 0
    fi
  done

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"
  local bind_host="127.0.0.1"
  local bind_port=""
  local pg_publish_port=""
  local relative_url_root=""
  local deployment_flag=false

  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --help|-h) ((i+=1)) ;;
      --bind-host) bind_host="${args[$((i+1))]}"; ((i+=2)) ;;
      --bind-host=*) bind_host="${args[$i]#--bind-host=}"; ((i+=1)) ;;
      --bind-port) bind_port="${args[$((i+1))]}"; ((i+=2)) ;;
      --bind-port=*) bind_port="${args[$i]#--bind-port=}"; ((i+=1)) ;;
      --db-publish-port) pg_publish_port="${args[$((i+1))]}"; ((i+=2)) ;;
      --db-publish-port=*) pg_publish_port="${args[$i]#--db-publish-port=}"; ((i+=1)) ;;
      --relative-url-root) relative_url_root="${args[$((i+1))]}"; ((i+=2)) ;;
      --relative-url-root=*) relative_url_root="${args[$i]#--relative-url-root=}"; ((i+=1)) ;;
      --deployment) deployment_flag=true; ((i+=1)) ;;
      -v|--verbose) export RDC_VERBOSE=true; ((i+=1)) ;;
      --redmine|--redmine=*|--redmica|--redmica=*)
        echo "ERROR: ${args[$i]%%=*} は init のオプションです。generate では指定できません。" >&2
        echo "イメージタグを変更するには init を再実行してください:" >&2
        echo "  redmine-docker-workspace init --target WORKSPACE ${args[$i]%%=*} TAG" >&2
        return 1
        ;;
      *) ((i+=1)) ;;
    esac
  done

  # Validate --relative-url-root (F0315)
  if [[ -n "$relative_url_root" ]]; then
    if [[ "$relative_url_root" == "/" ]] || \
       [[ ! "$relative_url_root" =~ ^/ ]] || \
       [[ "$relative_url_root" =~ /$ ]]; then
      echo "ERROR: Invalid --relative-url-root value: '${relative_url_root}'" >&2
      echo "  Expected: starts with '/', no trailing '/', not '/' alone." >&2
      echo "  Example:  --relative-url-root /redmine" >&2
      return 1
    fi
  fi

  # Load state
  if ! state_store_load "$workspace"; then
    logger_error "Workspace not initialized. Run 'init' first."
    return 1
  fi

  # Guard: workspace must be fully initialized (not just cleaned)
  if [[ "${RDC_STATE_init_status:-}" != "done" ]]; then
    logger_error "Workspace is not initialized. Run 'init' first."
    return 1
  fi

  # Guard: compose must not be running during generate (F0304A)
  if ! generate_service_ensure_compose_not_running "$workspace"; then
    return 1
  fi

  # --deployment: Gemfile.lock 存在チェック (F0206)
  if [[ "$deployment_flag" == "true" ]]; then
    if [[ ! -f "$workspace/Gemfile.lock" ]]; then
      echo "ERROR: Gemfile.lock が見つかりません。" >&2
      echo "先に 'redmine-docker-workspace export-gemfile-lock' を実行して取得してください。" >&2
      return 1
    fi
    export RDC_DEPLOYMENT_BUILD=true
  else
    export RDC_DEPLOYMENT_BUILD=false
  fi

  local mode="${RDC_STATE_mode:-}"
  local image_ref="${RDC_STATE_image_ref:-}"
  local image_source="${RDC_STATE_image_source:-}"
  local product="${RDC_STATE_product:-redmine}"
  local tag="${RDC_STATE_target_image_tag:-latest}"

  # Backward compatibility: if image_source is missing, treat as preset.
  if [[ -z "$image_source" ]]; then
    image_source="preset"
  fi

  if [[ "$image_source" == "explicit" ]]; then
    if [[ -z "$image_ref" ]]; then
      logger_error "image_source=explicit requires image_ref in .rdc_state"
      return 1
    fi
    # Override renderer input so Dockerfile uses explicit image directly.
    product="explicit"
    tag="$image_ref"
  elif [[ "$image_source" == "preset" ]]; then
    if [[ -z "$tag" ]]; then
      tag="latest"
    fi
    if [[ -z "$product" ]]; then
      product="redmine"
    fi
  else
    logger_error "Invalid image_source value: $image_source"
    return 1
  fi

  # Detect current generate status to determine if this is a re-generate
  local prev_gen="${RDC_STATE_generate_status:-pending}"
  # Destructive re-generate confirmation (F0003A/B/C)
  if [[ "$prev_gen" == "done" ]] && ! generate_service_confirm_destructive_regenerate "$workspace"; then
    return 1
  fi
  if [[ "$prev_gen" == "done" ]]; then
    # Re-generate after plugin change: reset downstream
    state_store_save_many "$workspace" \
      "migrate_status=pending" \
      "check_status=pending"
    logger_info "Re-generating: migrate and check states reset to pending."
  fi

  # Resolve ports
  if [[ -z "$bind_port" ]]; then
    bind_port=$(_generate_service_find_free_port 38080) || return 1
  fi

  local redmine_bind="${bind_host}:${bind_port}"

  logger_info "Generating Docker workspace files (product: $product, tag: $tag)"

  local generate_completed_at
  generate_completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

  # Export context for renderer
  export RDC_WORKSPACE_PATH="$workspace"
  export RDC_PRODUCT="$product"
  export RDC_TARGET_IMAGE_TAG="$tag"
  export RDC_REDMINE_BIND="$redmine_bind"
  export RDC_PG_PUBLISH_PORT="$pg_publish_port"
  export RDC_RELATIVE_URL_ROOT="$relative_url_root"
  export RDC_GENERATE_ID="$generate_completed_at"
  
  # Detect themes path from image (can be overridden via RDC_THEMES_CONTAINER_PATH for testing)
  local themes_container_path="${RDC_THEMES_CONTAINER_PATH:-}"
  if [[ -z "$themes_container_path" ]]; then
    if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
      themes_container_path="/usr/src/redmine/themes"
    else
      local themes_path
      themes_path=$(generate_service_detect_themes_path "$product" "$tag") || themes_path="/usr/src/redmine/themes"
      themes_container_path="$themes_path"
    fi
  fi
  export RDC_THEMES_CONTAINER_PATH="$themes_container_path"

  local compose_dir="$workspace"

  RDC_DB_PASSWORD_SOURCE=""
  RDC_DB_PASSWORD_VALUE=""
  if ! generate_service_resolve_db_password "$compose_dir"; then
    return 1
  fi
  local db_password="${RDC_DB_PASSWORD_VALUE:-}"

  compose_renderer_render_dockerfile > "$compose_dir/Dockerfile"
  compose_renderer_render_compose    > "$compose_dir/docker-compose.yml"

  if [[ "${RDC_DB_PASSWORD_SOURCE:-}" == "existing_env" ]]; then
    logger_info "Using DB_PASSWORD from existing .env"
    chmod 600 "$compose_dir/.env"
  else
    generate_service_write_db_password_to_env "$compose_dir/.env" "$db_password"
    chmod 600 "$compose_dir/.env"
  fi

  # For subpath routing, generate Rackup override mounted to /usr/src/redmine/config.ru
  if [[ -n "$relative_url_root" ]]; then
    compose_renderer_render_rackup > "$compose_dir/rdc-config.ru"
  else
    rm -f "$compose_dir/rdc-config.ru"
  fi

  # Prepare plugins
  generate_service_prepare_plugins "$workspace" "$mode"

  # Prepare themes and files from source (passenger/workspace modes)
  generate_service_prepare_themes "$workspace" "$mode"
  generate_service_prepare_files "$workspace" "$mode"

  # Extract configuration.yml.example from official image, then apply source configuration.yml if available
  generate_service_extract_configuration_example "$workspace" "$product" "$tag"
  generate_service_apply_source_configuration_yml "$workspace" "$mode"

  # Save port to state
  state_store_save_many "$workspace" \
    "redmine_bind=${redmine_bind}" \
    "postgres_publish_port=${pg_publish_port}" \
    "relative_url_root=${relative_url_root}" \
    "generate_completed_at=${generate_completed_at}" \
    "generate_status=done" \
    "deployment_build=${deployment_flag}"

  logger_info "generate completed. Compose files written to $compose_dir"
  echo "generate completed."

  status_service_display_after_subcommand "$workspace"
  return 0
}

# generate_service_resolve_db_password()
# .env / 環境変数 / 対話入力の優先順位で DB_PASSWORD を確定する
# args: compose_dir
# sets: RDC_DB_PASSWORD_SOURCE, RDC_DB_PASSWORD_VALUE
# returns: 0 on success, 1 on failure
generate_service_resolve_db_password() {
  local compose_dir="${1:?compose_dir required}"
  local env_file="$compose_dir/.env"

  local existing_password=""
  if [[ -f "$env_file" ]]; then
    existing_password=$(generate_service_read_db_password_from_env "$env_file")
    if [[ -n "$existing_password" ]]; then
      RDC_DB_PASSWORD_SOURCE="existing_env"
      RDC_DB_PASSWORD_VALUE="$existing_password"
      return 0
    fi
  fi

  if [[ -n "${DB_PASSWORD:-}" ]]; then
    RDC_DB_PASSWORD_SOURCE="process_env"
    RDC_DB_PASSWORD_VALUE="$DB_PASSWORD"
    return 0
  fi

  if [[ -t 0 ]]; then
    local entered_password=""
    local confirmed_password=""
    while true; do
      read -r -s -p "Enter DB_PASSWORD for .env: " entered_password
      echo
      if [[ -z "$entered_password" ]]; then
        echo "ERROR: DB_PASSWORD cannot be empty." >&2
        continue
      fi
      read -r -s -p "Confirm DB_PASSWORD: " confirmed_password
      echo
      if [[ "$entered_password" != "$confirmed_password" ]]; then
        echo "ERROR: Passwords do not match. Please retry." >&2
        continue
      fi
      RDC_DB_PASSWORD_SOURCE="prompt"
      RDC_DB_PASSWORD_VALUE="$entered_password"
      return 0
    done
  fi

  logger_error "Cannot determine DB_PASSWORD in non-interactive mode."
  echo "ERROR: DB_PASSWORD is not set and .env has no DB_PASSWORD." >&2
  echo "Create .env with DB_PASSWORD or set DB_PASSWORD in the environment." >&2
  return 1
}

# generate_service_read_db_password_from_env()
# .env から DB_PASSWORD を取得する
# args: env_file
# stdout: password (empty if not found)
generate_service_read_db_password_from_env() {
  local env_file="${1:?env_file required}"
  grep '^DB_PASSWORD=' "$env_file" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# generate_service_write_db_password_to_env()
# .env へ DB_PASSWORD を反映する（既存ファイルがあれば追記・更新）
# args: env_file, db_password
generate_service_write_db_password_to_env() {
  local env_file="${1:?env_file required}"
  local db_password="${2:?db_password required}"

  touch "$env_file"
  if grep -q '^DB_PASSWORD=' "$env_file" 2>/dev/null; then
    local tmpfile
    tmpfile=$(mktemp)
    grep -v '^DB_PASSWORD=' "$env_file" > "$tmpfile"
    echo "DB_PASSWORD=${db_password}" >> "$tmpfile"
    mv "$tmpfile" "$env_file"
  else
    echo "DB_PASSWORD=${db_password}" >> "$env_file"
  fi
}

# generate_service_resolve_publish_ports()
# Redmine / PostgreSQL の公開ポートを確定し PortPlan を返す
# stdout: PortPlan (key=value lines)
generate_service_resolve_publish_ports() {
  local bind_port
  bind_port=$(_generate_service_find_free_port 38080)
  echo "redmine_bind=127.0.0.1:${bind_port}"
  echo "postgres_publish_port="
}

# generate_service_prepare_plugins()
# mode ごとの plugins 配置を整える
# args: workspace_path, mode
generate_service_prepare_plugins() {
  local workspace_path="${1:?workspace_path required}"
  local mode="${2:-}"
  local plugins_dir="$workspace_path/plugins"
  mkdir -p "$plugins_dir"

  case "$mode" in
    passenger)
      # Copy from redmine_root/plugins if available
      local redmine_root="${RDC_STATE_redmine_root:-}"
      if [[ -n "$redmine_root" && -d "$redmine_root/plugins" ]]; then
        rsync -a --exclude='.gitkeep' "$redmine_root/plugins/" "$plugins_dir/" 2>/dev/null || \
          cp -r "$redmine_root/plugins/." "$plugins_dir/" 2>/dev/null || true
        logger_info "Plugins copied from $redmine_root/plugins"
      fi
      ;;
    workspace)
      # Copy from source workspace plugins if not already present
      local source_workspace="${RDC_STATE_source_workspace:-}"
      if [[ -n "$source_workspace" && -d "$source_workspace/plugins" ]]; then
        rsync -a --exclude='.gitkeep' "$source_workspace/plugins/" "$plugins_dir/" 2>/dev/null || \
          cp -r "$source_workspace/plugins/." "$plugins_dir/" 2>/dev/null || true
        logger_info "Plugins copied from source workspace"
      fi
      if [[ -n "$source_workspace" && -d "$source_workspace/.rdc_plugins" ]]; then
        mkdir -p "$workspace/.rdc_plugins"
        rsync -a "$source_workspace/.rdc_plugins/" "$workspace/.rdc_plugins/" 2>/dev/null || \
          cp -r "$source_workspace/.rdc_plugins/." "$workspace/.rdc_plugins/" 2>/dev/null || true
        logger_info "Plugin metadata copied from source workspace"
      fi
      ;;
    new|*)
      # No plugins to copy for new mode
      ;;
  esac
  return 0
}

# generate_service_prepare_themes()
# mode ごとの themes 配置を整える
# passenger: redmine_root/public/themes/（なければ themes/）→ workspace/themes/
# workspace: source_workspace/themes/ → workspace/themes/
# new: no-op
# args: workspace_path, mode
generate_service_prepare_themes() {
  local workspace_path="${1:?workspace_path required}"
  local mode="${2:-}"
  local themes_dir="$workspace_path/themes"
  mkdir -p "$themes_dir"

  case "$mode" in
    passenger)
      local redmine_root="${RDC_STATE_redmine_root:-}"
      if [[ -z "$redmine_root" ]]; then return 0; fi
      local src=""
      if [[ -d "$redmine_root/public/themes" ]]; then
        src="$redmine_root/public/themes"
      elif [[ -d "$redmine_root/themes" ]]; then
        src="$redmine_root/themes"
      fi
      if [[ -n "$src" ]]; then
        rsync -a --exclude='.gitkeep' "$src/" "$themes_dir/" 2>/dev/null || \
          cp -r "$src/." "$themes_dir/" 2>/dev/null || true
        logger_info "Themes copied from $src"
      fi
      ;;
    workspace)
      local source_workspace="${RDC_STATE_source_workspace:-}"
      if [[ -n "$source_workspace" && -d "$source_workspace/themes" ]]; then
        rsync -a --exclude='.gitkeep' "$source_workspace/themes/" "$themes_dir/" 2>/dev/null || \
          cp -r "$source_workspace/themes/." "$themes_dir/" 2>/dev/null || true
        logger_info "Themes copied from source workspace"
      fi
      ;;
    new|*)
      ;;
  esac
  return 0
}

# generate_service_prepare_files()
# mode ごとの files 配置を整える
# passenger: redmine_root/files/ → workspace/files/
# workspace: source_workspace/files/ → workspace/files/
# new: no-op
# args: workspace_path, mode
generate_service_prepare_files() {
  local workspace_path="${1:?workspace_path required}"
  local mode="${2:-}"
  local files_dir="$workspace_path/files"
  mkdir -p "$files_dir"

  case "$mode" in
    passenger)
      local redmine_root="${RDC_STATE_redmine_root:-}"
      if [[ -n "$redmine_root" && -d "$redmine_root/files" ]]; then
        rsync -a --exclude='.gitkeep' "$redmine_root/files/" "$files_dir/" 2>/dev/null || \
          cp -r "$redmine_root/files/." "$files_dir/" 2>/dev/null || true
        logger_info "Files copied from $redmine_root/files"
      fi
      ;;
    workspace)
      local source_workspace="${RDC_STATE_source_workspace:-}"
      if [[ -n "$source_workspace" && -d "$source_workspace/files" ]]; then
        rsync -a --exclude='.gitkeep' "$source_workspace/files/" "$files_dir/" 2>/dev/null || \
          cp -r "$source_workspace/files/." "$files_dir/" 2>/dev/null || true
        logger_info "Files copied from source workspace"
      fi
      ;;
    new|*)
      ;;
  esac
  return 0
}

# generate_service_apply_source_configuration_yml()
# passenger/workspace モードでコピー元の configuration.yml を優先適用する
# イメージ由来の example より後に呼ぶこと
# args: workspace_path, mode
generate_service_apply_source_configuration_yml() {
  local workspace_path="${1:?workspace_path required}"
  local mode="${2:-}"
  local dest="$workspace_path/config/configuration.yml"

  case "$mode" in
    passenger)
      local redmine_root="${RDC_STATE_redmine_root:-}"
      local src="$redmine_root/config/configuration.yml"
      if [[ -n "$redmine_root" && -f "$src" ]]; then
        cp "$src" "$dest"
        logger_info "configuration.yml copied from $src"
      fi
      ;;
    workspace)
      local source_workspace="${RDC_STATE_source_workspace:-}"
      local src="$source_workspace/config/configuration.yml"
      if [[ -n "$source_workspace" && -f "$src" ]]; then
        cp "$src" "$dest"
        logger_info "configuration.yml copied from source workspace"
      fi
      ;;
    new|*)
      ;;
  esac
  return 0
}

# generate_service_extract_configuration_example()
# 公式イメージから configuration.yml.example を抽出する
# args: workspace_path, product, image_tag
generate_service_extract_configuration_example() {
  local workspace_path="${1:?workspace_path required}"
  local product="${2:?product required}"
  local image_tag="${3:?image_tag required}"
  local config_dir="$workspace_path/config"
  local configuration_example_path="$config_dir/configuration.yml.example"
  local configuration_path="$config_dir/configuration.yml"
  
  mkdir -p "$config_dir"

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" && "${RDC_MOCK_SKIP_IMAGE_EXTRACT:-}" == "1" ]]; then
    generate_service_write_configuration_yml "$configuration_path"
    cp "$configuration_path" "$configuration_example_path"
    generate_service_write_database_yml "$config_dir"
    logger_info "Mock: skipping configuration extract from image (RDC_MOCK_SKIP_IMAGE_EXTRACT=1)"
    return 0
  fi
  
  local image_name
  image_name=$(compose_renderer_resolve_image_name "$product" "$image_tag")
  local container_id
  local pull_succeeded=true
  
  # Pull image: show full docker pull output even without -v so the first
  # fetch gives the user progress and tag resolution details.
  if ! docker pull "$image_name"; then
    logger_info "Warning: Could not pull image $image_name"
    pull_succeeded=false
  fi
  
  # Create temporary container and copy configuration.yml.example
  container_id=$(docker create "$image_name" /bin/sh 2>/dev/null) || {
    if [[ "$pull_succeeded" == "false" ]]; then
      logger_error "Image not available from registry and not found locally: $image_name"
      return 1
    fi
    logger_error "Could not create temporary container from $image_name"
    return 1
  }
  
  if [[ -n "$container_id" ]]; then
    if docker cp "$container_id:/usr/src/redmine/config/configuration.yml.example" "$configuration_example_path" 2>/dev/null; then
      logger_info "Extracted configuration.yml.example from $image_name"
      # Copy to configuration.yml so bind mount doesn't create a directory
      cp "$configuration_example_path" "$configuration_path"
    else
      logger_error "Could not extract configuration.yml.example from $image_name"
      docker rm -f "$container_id" 2>/dev/null || true
      return 1
    fi
    docker rm -f "$container_id" 2>/dev/null || true
  fi

  if [[ ! -f "$configuration_path" ]]; then
    generate_service_write_configuration_yml "$configuration_path"
  fi

  # Generate database.yml so compose bind-mount provides it reliably
  generate_service_write_database_yml "$config_dir"

  return 0
}

# generate_service_write_configuration_yml()
# config/configuration.yml のプレースホルダを生成する
# args: configuration_path
generate_service_write_configuration_yml() {
  local configuration_path="${1:?configuration_path required}"
  cat > "$configuration_path" <<'CFGEOF'
# Generated by redmine-docker-workspace.
# Add Redmine configuration overrides here when needed.
CFGEOF
}

# generate_service_write_database_yml()
# config/database.yml を生成する（ERB形式でパスワードを環境変数から読む）
# args: config_dir
generate_service_write_database_yml() {
  local config_dir="${1:?config_dir required}"
  cat > "$config_dir/database.yml" <<'DBEOF'
production:
  adapter: postgresql
  database: redmine
  host: db
  port: 5432
  username: redmine
  password: <%= ENV["REDMINE_DB_PASSWORD"] %>
  encoding: utf8
DBEOF
}

# generate_service_detect_themes_path()
# イメージ内の themes ディレクトリパスを検出する
# stdout: コンテナ内のパス（新しく順序で試行）
# args: product, image_tag
generate_service_detect_themes_path() {
  local product="${1:?product required}"
  local image_tag="${2:?image_tag required}"
  local image_name
  image_name=$(compose_renderer_resolve_image_name "$product" "$image_tag")

  # Probe inside the image without creating reusable containers.
  # Fall back to /usr/src/redmine/themes when the image is unavailable locally.
  local result
  result=$(docker run --rm "$image_name" sh -c \
    'if [ -d /usr/src/redmine/themes ]; then echo /usr/src/redmine/themes; elif [ -d /usr/src/redmine/public/themes ]; then echo /usr/src/redmine/public/themes; else echo /usr/src/redmine/themes; fi' 2>/dev/null) || result="/usr/src/redmine/themes"

  echo "$result"
  return 0
}

# generate_service_ensure_compose_not_running()
# compose が稼働中なら失敗し down を案内する
# args: workspace_path
# returns: 0 if not running, 1 if running
generate_service_ensure_compose_not_running() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"
  
  # Mock support for tests
  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "true" ]]; then
    logger_error "Compose project is running. Run 'docker compose down' in $compose_dir first."
    return 1
  fi
  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "false" ]]; then
    return 0
  fi
  # Global mock: bypass check in test environments
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    return 0
  fi
  
  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    return 0
  fi
  
  # Check if any container is running in this compose project
  if (cd "$compose_dir" && docker compose ps --services --filter "status=running" 2>/dev/null | grep -q .); then
    logger_error "Compose project is running. Configuration changes during execution may cause inconsistency."
    echo "ERROR: Compose containers are running. Please stop them first:" >&2
    echo "  docker compose down" >&2
    echo "Then retry 'generate'." >&2
    return 1
  fi
  return 0
}

# generate_service_confirm_destructive_regenerate()
# 逆行再生成時に確認プロンプトを制御する（非対話環境では --force 必須）
# args: workspace_path
# returns: 0 to proceed, 1 to cancel
generate_service_confirm_destructive_regenerate() {
  local workspace_path="${1:?workspace_path required}"
  
  local prev_check="${RDC_STATE_check_status:-pending}"
  # check が done 状態で再 generate される場合は逆行
  if [[ "$prev_check" != "done" ]]; then
    return 0
  fi
  
  # Already confirmed via --force
  if [[ "${RDC_FORCE:-}" == "true" ]]; then
    return 0
  fi
  
  # Non-interactive environment: require --force
  if [[ ! -t 0 ]]; then
    logger_error "Destructive regenerate in non-interactive mode requires --force flag."
    echo "ERROR: This operation would invalidate the current check status." >&2
    echo "In non-interactive environments, use --force to proceed:" >&2
    echo "  redmine-docker-workspace generate --force" >&2
    return 1
  fi
  
  # Interactive: show confirmation prompt
  echo "WARNING: This will regenerate Docker configuration and invalidate check status." >&2
  read -p "Proceed with regenerate? [y/N] " -n 1 -r -e
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    logger_info "Regenerate cancelled by user."
    return 1
  fi
  return 0
}
