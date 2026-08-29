#!/usr/bin/env bash
# lib/rdc/clean_service.bash
# 実行中 compose 検査、生成物削除、再 init 必須状態への移行を担う Service
# 根拠要件: RDC-REQ-F0501〜RDC-REQ-F0505

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"

# clean_service_run()
# clean サブコマンド全体を実行する
# args: argv...
# returns: exit_code
clean_service_run() {
  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: redmine-docker-workspace clean"
        echo ""
        echo "Remove Docker-related generated files and reset workspace state."
        echo "Preserves: logs/, plugins/, dbdump/"
        return 0
        ;;
      -v|--verbose) export RDC_VERBOSE=true ;;
    esac
  done

  if ! clean_service_ensure_compose_down "$workspace"; then
    return 1
  fi

  rm -f "$workspace/Dockerfile"
  rm -f "$workspace/docker-compose.yml"
  rm -f "$workspace/.env"
  rm -f "$workspace/rdc-config.ru"
  rm -f "$workspace/activate-workspace-tool.sh"
  [[ -e "$workspace/config/configuration.yml" ]] && rm -rf "$workspace/config/configuration.yml"
  [[ -e "$workspace/config/database.yml" ]] && rm -rf "$workspace/config/database.yml"
  rm -f "$workspace/verification/manifest.json"
  # autoが中断された場合に残りうるロックファイル(RDC-REQ-F1424関連)。cleanはauto自身のロック
  # チェック対象外(復旧手段として使えなくなるため)であり、削除は明示的にここで行う。
  rm -f "$workspace/.rdc_auto.lock"

  # Leave a minimal .rdc_state to mark this as a cleaned workspace
  # This allows 'init' (without --target) to re-initialize this directory
  printf 'clean_status=done\n' > "$workspace/.rdc_state"

  logger_info "clean completed. Workspace reset. Run 'init' to start over."
  echo "clean completed."
  return 0
}

# clean_service_ensure_compose_down()
# 起動中 compose の有無を確認し、起動中なら案内して停止する
# args: workspace_path
# returns: 0 if not running, 1 if running (exit with guidance)
clean_service_ensure_compose_down() {
  local workspace_path="${1:?workspace_path required}"

  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "true" ]]; then
    echo "ERROR: Docker Compose is running. Run 'docker compose down' first to stop services before cleaning." >&2
    return 1
  fi

  local compose_file="$workspace_path/docker-compose.yml"
  if [[ -f "$compose_file" ]]; then
    if ! status_service_check_docker_daemon_reachable; then
      clean_service_confirm_docker_unreachable || return 1
      return 0
    fi
    local running
    running=$(cd "$workspace_path" && docker compose ps --quiet 2>/dev/null | head -1 || true)
    if [[ -n "$running" ]]; then
      echo "ERROR: Docker Compose is running. Run 'docker compose down' in $workspace_path first." >&2
      return 1
    fi
  fi

  return 0
}

# clean_service_confirm_docker_unreachable()
# Docker デーモンに疎通できず Compose 起動状態を確認できない場合の続行確認 (RDC-REQ-F0012)
# --force指定時は確認省略、非対話環境では失敗、対話環境では [y/N] プロンプトを表示する
# returns: 0 to proceed, 1 to abort
clean_service_confirm_docker_unreachable() {
  if [[ "${RDC_FORCE:-}" == "true" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: Docker デーモンに接続できません。Compose が起動中か確認できません。" >&2
    echo "  非対話環境では --force での再実行が必要です。" >&2
    return 1
  fi
  echo "WARNING: Docker デーモンに接続できません。Compose が起動中か確認できません。" >&2
  read -p "確認できないまま処理を続行しますか？ [y/N] " -n 1 -r -e
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    logger_info "clean cancelled (Docker unreachable, user declined to proceed)."
    return 1
  fi
  return 0
}
