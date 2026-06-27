#!/usr/bin/env bash
# lib/rdc/migrate_service.bash
# DB / plugin migration 実行を担う Service
# 根拠要件: RDC-REQ-F0381〜RDC-REQ-F0388

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# migrate_service_run()
# migrate サブコマンド全体を実行する
# args: argv...
# returns: exit_code
migrate_service_run() {
  # --help は workspace チェックより先に処理する
  for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      echo "Usage: redmine-docker-workspace migrate [--lang <LANG>]"
      echo ""
      echo "Runs db:migrate and redmine:plugins:migrate inside the app container."
      echo ""
      echo "Options:"
      echo "  --lang <LANG>    Language for loading default data (default: ja)"
      echo "                   Only applies when mode=new and prepare-db used --fresh-db"
      echo ""
      echo "Next steps after migrate:"
      echo "  1. docker compose up -d  (start the Redmine application)"
      echo "  2. redmine-docker-workspace check"
      return 0
    fi
  done

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  local lang="ja"
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --help|-h) ((i+=1)) ;;
      -v|--verbose) export RDC_VERBOSE=true; ((i+=1)) ;;
      --lang) lang="${args[$((i+1))]:-ja}"; ((i+=2)) ;;
      *) ((i+=1)) ;;
    esac
  done

  # Load state
  if ! state_store_load "$workspace"; then
    logger_error "Workspace not initialized. Run 'init' first."
    return 1
  fi

  # Guard: ensure generate and prepare-db have completed
  if ! migrate_service_ensure_migrate_preconditions "$workspace"; then
    return 1
  fi

  # Guard: ensure Redmine is not running
  if ! migrate_service_ensure_redmine_not_running "$workspace"; then
    return 1
  fi

  # Guard: confirm destructive remigration
  if ! migrate_service_confirm_destructive_remigrate "$workspace"; then
    logger_info "migrate cancelled."
    return 1
  fi

  local compose_dir="$workspace"
  local mode="${RDC_STATE_mode:-}"
  local import_mode="${RDC_STATE_import_mode:-}"
  local run_load_default_data=false
  if [[ "$mode" == "new" && "$import_mode" == "fresh-db" ]]; then
    run_load_default_data=true
  fi

  # Ensure built image exists (or mock)
  migrate_service_ensure_built_image "$workspace" || return 1

  # Mock: skip actual migrations in test environments
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    logger_info "Starting database and plugin migrations (single container run)"
    logger_info "Starting generate_secret_token"
    logger_info "generate_secret_token completed."
    logger_info "Starting db:migrate (this may take a while)"
    logger_info "db:migrate completed."
    logger_info "Starting redmine:plugins:migrate (this may take a while)"
    logger_info "redmine:plugins:migrate completed."
    if [[ "$run_load_default_data" == "true" ]]; then
      logger_info "Starting redmine:load_default_data (REDMINE_LANG=${lang})"
      logger_info "redmine:load_default_data completed."
    fi
    logger_info "Mock: skipping docker compose migrations (RDC_ALLOW_MOCK=1)"
    state_store_save "$workspace" "migrate_status" "done"
    state_store_save "$workspace" "check_status" "pending"
    logger_info "migrate completed."
    echo "migrate completed."

    status_service_display_after_subcommand "$workspace"
    return 0
  fi

  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    logger_error "docker-compose.yml not found. Run 'generate' first."
    return 1
  fi

  logger_info "Starting database and plugin migrations"
  if ! migrate_service_run_rakes "$compose_dir"; then
    logger_error "migrate failed."
    return 1
  fi

  if [[ "$run_load_default_data" == "true" ]]; then
    if ! migrate_service_run_load_default_data "$compose_dir" "$lang"; then
      logger_error "redmine:load_default_data failed."
      return 1
    fi
  fi

  state_store_save "$workspace" "migrate_status" "done"

  # Reset check status to pending (migration invalidates any previous check)
  state_store_save "$workspace" "check_status" "pending"

  logger_info "migrate completed."
  echo "migrate completed."

  status_service_display_after_subcommand "$workspace"
  return 0
}

# migrate_service_run_rakes()
# 1回の compose run で db:migrate と redmine:plugins:migrate を順に実行する
# args: compose_dir
# returns: 0 on success, 1 on failure
migrate_service_run_rakes() {
  local compose_dir="${1:?compose_dir required}"

  local migrate_script
  read -r -d '' migrate_script <<'EOF' || true
set -e
echo "Starting generate_secret_token"
bundle exec rake generate_secret_token RAILS_ENV=production
echo "generate_secret_token completed."
echo "Starting db:migrate (this may take a while)"
bundle exec rake db:migrate RAILS_ENV=production
echo "db:migrate completed."
echo "Starting redmine:plugins:migrate (this may take a while)"
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
echo "redmine:plugins:migrate completed."
EOF

  if [[ "${RDC_VERBOSE:-}" == "true" ]]; then
    if ! (cd "$compose_dir" && docker compose run --rm redmine bash -lc "$migrate_script"); then
      return 1
    fi
  else
    local tmp_log
    tmp_log=$(mktemp)
    echo "Running migrate in compact mode... (use -v for full output)"

    pushd "$compose_dir" > /dev/null
    docker compose run --rm redmine bash -lc "$migrate_script" > "$tmp_log" 2>&1 &
    local docker_pid=$!
    logger_show_spinner "$docker_pid" "Migrating"
    wait "$docker_pid"
    local docker_exit=$?
    popd > /dev/null

    # 非verboseモード: 主要マイルストーンのみ表示
    grep -E '^(Starting|.* completed\.)' "$tmp_log" || true

    if [[ $docker_exit -ne 0 ]]; then
      echo "--- Full output (migrate failed) ---" >&2
      cat "$tmp_log" >&2
      rm -f "$tmp_log"
      return 1
    fi
    rm -f "$tmp_log"
  fi
}

# migrate_service_run_load_default_data()
# redmine:load_default_data を実行して日本語等の初期データを登録する（RDC-REQ-F0389）
# mode=new かつ import_mode=fresh-db のときのみ呼び出すこと
# args: compose_dir, lang
# returns: 0 on success, 1 on failure
migrate_service_run_load_default_data() {
  local compose_dir="${1:?compose_dir required}"
  local lang="${2:-ja}"

  logger_info "Starting redmine:load_default_data (REDMINE_LANG=${lang})"

  if [[ "${RDC_VERBOSE:-}" == "true" ]]; then
    if ! (cd "$compose_dir" && docker compose run --rm \
        -e REDMINE_LANG="${lang}" \
        redmine bash -lc "bundle exec rake redmine:load_default_data RAILS_ENV=production"); then
      return 1
    fi
  else
    local tmp_log
    tmp_log=$(mktemp)
    pushd "$compose_dir" > /dev/null
    docker compose run --rm \
      -e REDMINE_LANG="${lang}" \
      redmine bash -lc "bundle exec rake redmine:load_default_data RAILS_ENV=production" \
      > "$tmp_log" 2>&1 &
    local docker_pid=$!
    logger_show_spinner "$docker_pid" "Loading default data"
    wait "$docker_pid"
    local docker_exit=$?
    popd > /dev/null

    if [[ $docker_exit -ne 0 ]]; then
      echo "--- Full output (load_default_data failed) ---" >&2
      cat "$tmp_log" >&2
      rm -f "$tmp_log"
      return 1
    fi
    rm -f "$tmp_log"
  fi

  logger_info "redmine:load_default_data completed."
  echo "redmine:load_default_data completed."
}

# migrate_service_ensure_built_image()
# build 済みイメージの存在を確認する（未 build なら案内して停止）
# args: workspace_path
# returns: 0 if image exists, 1 if not
migrate_service_ensure_built_image() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"

  # Mock support for tests
  if [[ "${RDC_MOCK_IMAGE_EXISTS:-}" == "true" ]]; then
    return 0
  fi
  if [[ "${RDC_MOCK_IMAGE_EXISTS:-}" == "false" ]]; then
    logger_error "Image not found. Run 'docker compose build' in $compose_dir first."
    return 1
  fi
  # Global mock: bypass image check in test environments
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    return 0
  fi

  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    logger_error "docker-compose.yml not found. Run 'generate' first."
    return 1
  fi

  # Check if image has been built via docker images
  local project_name
  project_name="$(basename "$workspace_path")"
  local image_name="${project_name}-redmine"

  if docker image inspect "${image_name}" &>/dev/null 2>&1 || \
     (cd "$compose_dir" && docker compose images -q redmine 2>/dev/null | grep -q "."); then
    return 0
  fi

  logger_error "Built image not found. Run 'docker compose build' in $compose_dir first."
  echo "ERROR: Image not found. Please run: cd $compose_dir && docker compose build" >&2
  return 1
}

# migrate_service_ensure_migrate_preconditions()
# migrate に必要な前提条件（generate + prepare-db 完了）が満たされているか確認する
# args: workspace_path
# returns: 0 if ok, 1 if preconditions not met
migrate_service_ensure_migrate_preconditions() {
  local workspace_path="${1:?workspace_path required}"
  
  local gen_status="${RDC_STATE_generate_status:-pending}"
  if [[ "$gen_status" != "done" ]]; then
    logger_error "generate has not been completed. Run 'generate' first."
    echo "ERROR: generate must be completed before migrate." >&2
    echo "Run: redmine-docker-workspace generate" >&2
    return 1
  fi
  
  local imp_status="${RDC_STATE_import_status:-pending}"
  if [[ "$imp_status" != "done" ]]; then
    logger_error "prepare-db has not been completed. Run 'prepare-db' first."
    echo "ERROR: prepare-db must be completed before migrate." >&2
    echo "Run: redmine-docker-workspace prepare-db" >&2
    return 1
  fi
  return 0
}

# migrate_service_ensure_redmine_not_running()
# Redmine コンテナが実行中ではないことを確認する
# args: workspace_path
# returns: 0 if not running, 1 if running
migrate_service_ensure_redmine_not_running() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"
  
  # Mock support for tests
  if [[ "${RDC_MOCK_REDMINE_RUNNING:-}" == "true" ]]; then
    logger_error "Redmine container is running. Run 'docker compose down' in $compose_dir first."
    return 1
  fi
  if [[ "${RDC_MOCK_REDMINE_RUNNING:-}" == "false" ]]; then
    return 0
  fi
  # Global mock: bypass check in test environments
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    return 0
  fi
  
  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    return 0
  fi
  
  # Check if redmine container is running
  if (cd "$compose_dir" && docker compose ps redmine 2>/dev/null | grep -q "Up"); then
    logger_error "Redmine container is running. Migration cannot proceed while app is active."
    echo "ERROR: Redmine container must be stopped:" >&2
    echo "  docker compose down" >&2
    echo "Then retry 'migrate'." >&2
    return 1
  fi
  return 0
}

# migrate_service_confirm_destructive_remigrate()
# 逆行再 migrate 時に確認プロンプトを制御する（非対話環境では --force 必須）
# args: workspace_path
# returns: 0 to proceed, 1 to cancel
migrate_service_confirm_destructive_remigrate() {
  local workspace_path="${1:?workspace_path required}"
  
  local prev_check="${RDC_STATE_check_status:-pending}"
  # check が done 状態で再 migrate される場合は逆行
  if [[ "$prev_check" != "done" ]]; then
    return 0
  fi
  
  # Already confirmed via --force
  if [[ "${RDC_FORCE:-}" == "true" ]]; then
    return 0
  fi
  
  # Non-interactive environment: require --force
  if [[ ! -t 0 ]]; then
    logger_error "Destructive remigration in non-interactive mode requires --force flag."
    echo "ERROR: This operation would invalidate the current check status." >&2
    echo "In non-interactive environments, use --force to proceed:" >&2
    echo "  redmine-docker-workspace migrate --force ..." >&2
    return 1
  fi
  
  # Interactive: show confirmation prompt
  echo "WARNING: This will remigrate and invalidate check status." >&2
  read -p "Proceed with remigration? [y/N] " -n 1 -r -e
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    logger_info "Remigration cancelled by user."
    return 1
  fi
  return 0
}
