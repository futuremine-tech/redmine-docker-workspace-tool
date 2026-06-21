#!/usr/bin/env bash
# lib/rdc/dbdump_service.bash
# 自ワークスペースの compose db コンテナから pg_dump を実行するスタンドアロンユーティリティ
# 根拠要件: RDC-REQ-F0201, RDC-REQ-F0201A, RDC-REQ-F0202, RDC-REQ-F0203, RDC-REQ-F0204

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"

# dbdump_service_run()
# dbdump サブコマンド全体を実行する
# args: argv...
# returns: exit_code
dbdump_service_run() {
  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"
  local dump_filename=""

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: redmine-docker-workspace dbdump [--dump-filename NAME]"
        echo ""
        echo "Dump the compose db container's PostgreSQL database to ./dbdump/."
        echo "Works in all modes (passenger, workspace, new)."
        echo "The compose db container must be running."
        echo ""
        echo "Options:"
        echo "  --dump-filename NAME   Output filename (default: auto-generated)"
        echo "  -v, --verbose          Verbose output"
        return 0
        ;;
    esac
  done

  local i=0
  local args=("$@")
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --dump-filename) dump_filename="${args[$((i+1))]}"; ((i+=2)) ;;
      --dump-filename=*) dump_filename="${args[$i]#--dump-filename=}"; ((i+=1)) ;;
      -v|--verbose) export RDC_VERBOSE=true; ((i+=1)) ;;
      *) ((i+=1)) ;;
    esac
  done

  if ! state_store_load "$workspace"; then
    logger_error "Workspace not initialized. Run 'init' first."
    return 1
  fi

  dbdump_service_ensure_compose_db_running "$workspace" || return 1

  if [[ -z "$dump_filename" ]]; then
    local product="${RDC_STATE_product:-redmine}"
    local tag="${RDC_STATE_target_image_tag:-unknown}"
    local ts
    ts=$(date +"%Y%m%d-%H%M%S")
    dump_filename="dbdump_${product}_${tag}_${ts}.dump"
  fi

  dbdump_service_dump_from_compose_db "$workspace" "$dump_filename" || return 1

  # パイプライン状態を変更しない（スタンドアロンユーティリティ）
  state_store_save "$workspace" "dbdump_filename" "$dump_filename"
  logger_info "dbdump completed: $dump_filename"
  echo "dbdump completed: $dump_filename"
  return 0
}

# dbdump_service_ensure_compose_db_running()
# compose 定義の存在と db コンテナ起動を確認する
# args: workspace_path
# returns: 0 if ok, 1 if not
dbdump_service_ensure_compose_db_running() {
  local workspace_path="${1:?workspace_path required}"

  # Test mock: compose not defined (explicit false overrides ALLOW_MOCK)
  if [[ "${RDC_MOCK_COMPOSE_DEFINED:-}" == "false" ]]; then
    logger_error "Compose definition not found. Run 'generate' first."
    echo "ERROR: docker-compose.yml not found. Run 'generate' first to set up the compose definition." >&2
    return 1
  fi

  # Test mock: db not running (explicit false overrides ALLOW_MOCK)
  if [[ "${RDC_MOCK_DB_RUNNING:-}" == "false" ]]; then
    logger_error "Compose db container is not running."
    echo "ERROR: The compose db container is not running. Start it with 'docker compose up -d db' first." >&2
    return 1
  fi

  # When RDC_ALLOW_MOCK=1, skip real docker checks
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    return 0
  fi

  # Real check: compose definition must exist
  if [[ ! -f "$workspace_path/docker-compose.yml" ]]; then
    logger_error "docker-compose.yml not found in workspace."
    echo "ERROR: docker-compose.yml not found. Run 'generate' first to set up the compose definition." >&2
    return 1
  fi

  # Real check: db container must be running
  local db_running
  db_running=$(cd "$workspace_path" && docker compose ps --quiet db 2>/dev/null | head -1 || true)
  if [[ -z "$db_running" ]]; then
    logger_error "Compose db container is not running."
    echo "ERROR: The compose db container is not running. Start it with 'docker compose up -d db' first." >&2
    return 1
  fi

  return 0
}

# dbdump_service_dump_from_compose_db()
# compose db コンテナから pg_dump を実行して ./dbdump/ に書き出す
# args: workspace_path, dump_filename
# returns: exit_code
dbdump_service_dump_from_compose_db() {
  local workspace_path="${1:?workspace_path required}"
  local dump_filename="${2:?dump_filename required}"
  local out_path="$workspace_path/dbdump/$dump_filename"

  mkdir -p "$workspace_path/dbdump"

  logger_info "Running pg_dump from compose db container..."

  # Mock support for tests
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    logger_info "Mock: skipping pg_dump (RDC_ALLOW_MOCK=1)"
    touch "$out_path"
    return 0
  fi

  if (cd "$workspace_path" && docker compose exec -T db pg_dump -U redmine -Fc redmine) > "$out_path" 2>/dev/null; then
    logger_info "pg_dump completed: $dump_filename"
    return 0
  fi

  rm -f "$out_path"
  logger_error "pg_dump from compose db container failed."
  echo "ERROR: pg_dump failed. Check that the db container is running and accessible." >&2
  return 1
}
