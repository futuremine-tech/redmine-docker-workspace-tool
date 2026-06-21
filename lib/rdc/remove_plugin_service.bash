#!/usr/bin/env bash
# lib/rdc/remove_plugin_service.bash
# remove-plugin サブコマンド: 逆マイグレーション後にプラグインディレクトリを削除する
# 根拠要件: RDC-REQ-F1101〜F1109, RDC-REQ-F0930〜F0936, RDC-REQ-F0952

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# remove_plugin_service_run()
# remove-plugin サブコマンド全体を実行する
# args: argv...
# returns: exit_code
remove_plugin_service_run() {
  local plugin_name=""
  local force=false
  [[ "${RDC_FORCE:-}" == "true" ]] && force=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        remove_plugin_service_usage
        return 0
        ;;
      --force|-f)
        force=true
        shift
        ;;
      -*)
        echo "ERROR: Unknown option: $1" >&2
        remove_plugin_service_usage >&2
        return 1
        ;;
      *)
        if [[ -z "$plugin_name" ]]; then
          plugin_name="$1"
        else
          echo "ERROR: Too many arguments" >&2
          remove_plugin_service_usage >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$plugin_name" ]]; then
    echo "ERROR: <plugin_name> is required." >&2
    remove_plugin_service_usage >&2
    return 1
  fi

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }

  local plugin_dir="$workspace/plugins/$plugin_name"

  if [[ ! -d "$plugin_dir" ]]; then
    echo "ERROR: Plugin directory not found: $plugin_dir" >&2
    return 1
  fi

  # Redmine 実行中ガード
  local compose_running_rc=0
  status_service_check_compose_running "$workspace" 2>/dev/null || compose_running_rc=$?
  if [[ "$compose_running_rc" -eq 0 ]]; then
    echo "ERROR: Redmine is running. Stop it first:" >&2
    echo "  docker compose down (in $workspace)" >&2
    return 1
  fi

  # 非対話環境では --force 必須
  if [[ "$force" != "true" ]] && ! [[ -t 0 ]]; then
    echo "ERROR: This operation removes a plugin and its DB migrations." >&2
    echo "  Use --force to confirm: redmine-docker-workspace remove-plugin $plugin_name --force" >&2
    return 1
  fi

  # 逆マイグレーション実行
  if ! remove_plugin_service_run_reverse_migrate "$workspace" "$plugin_name"; then
    echo "ERROR: Reverse migration failed. Plugin directory preserved." >&2
    return 1
  fi

  rm -rf "$plugin_dir"
  rm -f "$workspace/.rdc_plugins/$plugin_name"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  state_store_save_many "$workspace" \
    "migrate_status=pending" \
    "check_status=pending" \
    "plugins_last_changed=$timestamp"

  echo "Plugin '$plugin_name' removed successfully."

  state_store_load "$workspace"
  status_service_display_after_subcommand "$workspace"
  return 0
}

# remove_plugin_service_usage()
remove_plugin_service_usage() {
  echo "Usage: redmine-docker-workspace remove-plugin <plugin_name> [--force]"
  echo ""
  echo "Remove a Redmine plugin by running reverse DB migration and deleting the plugin directory."
  echo ""
  echo "Arguments:"
  echo "  <plugin_name>   Name of the plugin directory under plugins/"
  echo ""
  echo "Options:"
  echo "  --force, -f     Skip confirmation prompt"
  echo "  --help, -h      Show this help"
  echo ""
  echo "After removal, run:"
  echo "  docker compose build"
  echo "  redmine-docker-workspace migrate"
  echo "  docker compose up -d"
  echo "  redmine-docker-workspace check"
}

# remove_plugin_service_run_reverse_migrate()
# 逆マイグレーションを実行する
# args: workspace, plugin_name
# returns: 0 on success, 1 on failure
remove_plugin_service_run_reverse_migrate() {
  local workspace="${1:?workspace required}"
  local plugin_name="${2:?plugin_name required}"

  if [[ "${RDC_MOCK_REVERSE_MIGRATE_FAIL:-}" == "1" ]]; then
    echo "ERROR: (mock) Reverse migration failed for plugin: $plugin_name" >&2
    return 1
  fi

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    return 0
  fi

  cd "$workspace" && \
    docker compose run --rm redmine \
      bundle exec rake "redmine:plugin:migrate VERSION=0 NAME='${plugin_name}' RAILS_ENV=production"
}
