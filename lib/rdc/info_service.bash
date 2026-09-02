#!/usr/bin/env bash
# lib/rdc/info_service.bash
# ワークスペース基本情報を機械可読（JSON）/ 人間可読形式で出力する Service（読み取り専用）
# 根拠要件: RDC-REQ-F1401〜RDC-REQ-F1409, RDC-REQ-F1410〜RDC-REQ-F1411, RDC-REQ-F0972〜RDC-REQ-F0979

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# info_service_run()
# info サブコマンド全体を実行する（読み取り専用：.rdc_state を変更しない）
# Docker 操作は不要。稼働状態取得のみベストエフォート（RDC-REQ-F0001 の対象外）。
# args: argv...
# returns: exit_code
info_service_run() {
  local json_mode=false

  for arg in "$@"; do
    case "$arg" in
      --json) json_mode=true ;;
      --help|-h)
        info_service_show_usage
        return 0
        ;;
    esac
  done

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    info_service_emit_not_initialized_error "$json_mode"
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  if [[ ! -f "$workspace/.rdc_state" ]]; then
    info_service_emit_not_initialized_error "$json_mode"
    return 1
  fi

  state_store_load "$workspace"

  if [[ "${RDC_STATE_clean_status:-}" == "done" ]]; then
    info_service_emit_not_initialized_error "$json_mode"
    return 1
  fi

  info_service_collect_fields "$workspace"

  if [[ "$json_mode" == true ]]; then
    info_service_render_json
  else
    info_service_render_human
  fi
  return 0
}

# info_service_show_usage()
# info の Usage を表示する (RDC-REQ-F1408, F1409)
info_service_show_usage() {
  echo "Usage: redmine-docker-workspace info [--json]"
  echo ""
  echo "Display read-only workspace information: product/image, bind address,"
  echo "relative_url_root, pipeline step status, verification summary, and"
  echo "container runtime state. Unlike status, info does not require Docker"
  echo "(runtime state is best-effort and falls back to 'unknown')."
  echo ""
  echo "Options:"
  echo "  --json      Output the same information as JSON to stdout"
  echo "  -h, --help  Show this help"
}

# info_service_emit_not_initialized_error()
# .rdc_state が存在しない/クリーン済みの場合のエラーを出力する (RDC-REQ-F1405, F1411)
# args: json_mode (true/false)
info_service_emit_not_initialized_error() {
  local json_mode="${1:-false}"
  if [[ "$json_mode" == "true" ]]; then
    cat <<'EOF'
{
  "error": "workspace_not_initialized",
  "message": "Workspace not initialized. Run 'init' to start."
}
EOF
  else
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
  fi
}

# info_service_collect_fields()
# 表示に必要な各フィールドを INFO_* グローバル変数へ集約する
# args: workspace_path
info_service_collect_fields() {
  local workspace_path="${1:?workspace_path required}"

  INFO_WORKSPACE_PATH="$workspace_path"
  INFO_MODE="${RDC_STATE_mode:-}"
  INFO_PRODUCT="${RDC_STATE_product:-}"
  INFO_TAG="${RDC_STATE_target_image_tag:-}"
  INFO_BASE_IMAGE_TAG="${RDC_STATE_base_image_tag:-}"
  INFO_BIND="${RDC_STATE_redmine_bind:-127.0.0.1:38080}"
  INFO_RELATIVE_URL_ROOT="${RDC_STATE_relative_url_root:-}"

  # RDC-REQ-F1414: redmine_version が未保存（Passengerモード・本機能実装前に generate 済みの
  # ワークスペース・検出失敗時）は target_image_tag へフォールバックする
  INFO_REDMINE_VERSION="${RDC_STATE_redmine_version:-}"
  if [[ -z "$INFO_REDMINE_VERSION" || "$INFO_REDMINE_VERSION" == "unknown" ]]; then
    INFO_REDMINE_VERSION="$INFO_TAG"
  fi

  INFO_STEP_INIT="${RDC_STATE_init_status:-pending}"
  INFO_STEP_GENERATE="${RDC_STATE_generate_status:-pending}"
  INFO_STEP_PREPARE_DB="${RDC_STATE_import_status:-pending}"
  INFO_STEP_MIGRATE="${RDC_STATE_migrate_status:-pending}"
  INFO_STEP_CHECK="${RDC_STATE_check_status:-pending}"

  if [[ -f "$workspace_path/docker-compose.yml" ]]; then
    INFO_IMAGE="$(status_service_get_target_image_name "$workspace_path")"
  else
    INFO_IMAGE=""
  fi

  INFO_VERIFICATION_STATUS=""
  INFO_VERIFICATION_TIMESTAMP=""
  INFO_VERIFICATION_BASE_IMAGE_DIGEST=""
  if [[ "$INFO_STEP_CHECK" == "done" ]]; then
    info_service_load_manifest_summary "$workspace_path"
  fi

  local runtime_lines
  mapfile -t runtime_lines < <(info_service_get_runtime_state "$workspace_path")
  INFO_RUNTIME_STATE="${runtime_lines[0]:-unknown}"
  INFO_RUNTIME_STARTED_AT="${runtime_lines[1]:-}"
}

# info_service_load_manifest_summary()
# verification/manifest.json から検証日時・base_image_digest・status を読み取る (RDC-REQ-F1403)
# args: workspace_path
info_service_load_manifest_summary() {
  local workspace_path="${1:?workspace_path required}"
  local manifest_file="$workspace_path/verification/manifest.json"
  [[ -f "$manifest_file" ]] || return 0

  # grep が対象キー不一致で exit 1 を返しても、bin/redmine-docker-workspace の
  # set -euo pipefail によりコマンド全体が異常終了しないよう、各抽出は `|| true` で保護する。
  INFO_VERIFICATION_STATUS=$( (grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest_file" || true) | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  INFO_VERIFICATION_TIMESTAMP=$( (grep -o '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest_file" || true) | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  INFO_VERIFICATION_BASE_IMAGE_DIGEST=$( (grep -o '"base_image_digest"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest_file" || true) | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
}

# info_service_get_runtime_state()
# redmine サービスコンテナ単体の稼働状態・起動日時をベストエフォートで取得する (RDC-REQ-F1404)
# args: workspace_path
# stdout: 1行目 state(running/stopped/unknown), 2行目 started_at（running時のみ）
# returns: 0 always
info_service_get_runtime_state() {
  local workspace_path="${1:?workspace_path required}"

  if [[ -n "${RDC_MOCK_CONTAINER_STARTED_AT:-}" ]]; then
    echo "running"
    echo "${RDC_MOCK_CONTAINER_STARTED_AT}"
    return 0
  fi
  if [[ -n "${RDC_MOCK_REDMINE_RUNNING:-}" ]]; then
    if [[ "${RDC_MOCK_REDMINE_RUNNING}" == "true" ]]; then
      echo "running"
      echo ""
    else
      echo "stopped"
    fi
    return 0
  fi
  if [[ -n "${RDC_MOCK_COMPOSE_RUNNING:-}" ]]; then
    if [[ "${RDC_MOCK_COMPOSE_RUNNING}" == "true" ]]; then
      echo "running"
      echo ""
    else
      echo "stopped"
    fi
    return 0
  fi

  if ! status_service_check_docker_daemon_reachable; then
    echo "unknown"
    return 0
  fi

  local compose_running_rc=0
  status_service_check_compose_running "$workspace_path" || compose_running_rc=$?
  if [[ "$compose_running_rc" -ne 0 ]]; then
    echo "stopped"
    return 0
  fi

  local project_name container_id started_at
  project_name="$(basename "$workspace_path")"
  container_id=$(cd "$workspace_path" && docker ps \
    --filter "label=com.docker.compose.project=${project_name}" \
    --filter "label=com.docker.compose.service=redmine" \
    --filter "status=running" \
    --format '{{.ID}}' 2>/dev/null | head -1)
  started_at=""
  if [[ -n "$container_id" ]]; then
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container_id" 2>/dev/null || true)
  fi
  echo "running"
  echo "$started_at"
}

# info_service_render_human()
# 集約済み INFO_* 変数を人間可読形式で標準出力へ出力する
info_service_render_human() {
  echo "=== Workspace Info ==="
  echo "workspace:  ${INFO_WORKSPACE_PATH}"
  echo "mode:       ${INFO_MODE}"
  if [[ -n "$INFO_PRODUCT" ]]; then
    echo "product:    ${INFO_PRODUCT}"
  fi
  if [[ -n "$INFO_BASE_IMAGE_TAG" ]]; then
    echo "base_image: ${INFO_BASE_IMAGE_TAG}"
  fi
  echo "version:    ${INFO_REDMINE_VERSION}"
  if [[ -n "$INFO_IMAGE" ]]; then
    echo "image:      ${INFO_IMAGE}"
  else
    echo "image:      (not generated yet)"
  fi
  echo "bind:       http://${INFO_BIND}${INFO_RELATIVE_URL_ROOT}/"
  echo ""
  echo "Steps:"
  printf "  %-12s %s\n" "init"       "$INFO_STEP_INIT"
  printf "  %-12s %s\n" "generate"   "$INFO_STEP_GENERATE"
  printf "  %-12s %s\n" "prepare-db" "$INFO_STEP_PREPARE_DB"
  printf "  %-12s %s\n" "migrate"    "$INFO_STEP_MIGRATE"
  printf "  %-12s %s\n" "check"      "$INFO_STEP_CHECK"
  echo ""
  echo "Verification:"
  if [[ "$INFO_STEP_CHECK" == "done" ]]; then
    echo "  status:             ${INFO_VERIFICATION_STATUS}"
    echo "  verified_at:        ${INFO_VERIFICATION_TIMESTAMP}"
    echo "  base_image_digest:  ${INFO_VERIFICATION_BASE_IMAGE_DIGEST}"
  else
    echo "  (check not completed)"
  fi
  echo ""
  echo "Runtime:"
  echo "  state:        ${INFO_RUNTIME_STATE}"
  if [[ "$INFO_RUNTIME_STATE" == "running" && -n "$INFO_RUNTIME_STARTED_AT" ]]; then
    echo "  started_at:   ${INFO_RUNTIME_STARTED_AT}"
  fi
}

# info_service_render_json()
# 集約済み INFO_* 変数を JSON 形式で標準出力へ出力する (jq 不使用、文字列連結)
info_service_render_json() {
  local image_json="null"
  [[ -n "$INFO_IMAGE" ]] && image_json="\"${INFO_IMAGE}\""

  local verification_json
  if [[ "$INFO_STEP_CHECK" == "done" ]]; then
    verification_json="    \"status\": \"${INFO_VERIFICATION_STATUS}\",
    \"verified_at\": \"${INFO_VERIFICATION_TIMESTAMP}\",
    \"base_image_digest\": \"${INFO_VERIFICATION_BASE_IMAGE_DIGEST}\""
  else
    verification_json="    \"status\": \"not_completed\""
  fi

  local runtime_json
  if [[ "$INFO_RUNTIME_STATE" == "running" ]]; then
    runtime_json="    \"state\": \"running\",
    \"started_at\": \"${INFO_RUNTIME_STARTED_AT}\""
  else
    runtime_json="    \"state\": \"${INFO_RUNTIME_STATE}\""
  fi

  cat <<EOF
{
  "workspace_path": "${INFO_WORKSPACE_PATH}",
  "mode": "${INFO_MODE}",
  "product": "${INFO_PRODUCT}",
  "base_image_tag": "${INFO_BASE_IMAGE_TAG}",
  "redmine_version": "${INFO_REDMINE_VERSION}",
  "image": ${image_json},
  "redmine_bind": "${INFO_BIND}",
  "relative_url_root": "${INFO_RELATIVE_URL_ROOT}",
  "steps": {
    "init": "${INFO_STEP_INIT}",
    "generate": "${INFO_STEP_GENERATE}",
    "prepare-db": "${INFO_STEP_PREPARE_DB}",
    "migrate": "${INFO_STEP_MIGRATE}",
    "check": "${INFO_STEP_CHECK}"
  },
  "verification": {
${verification_json}
  },
  "runtime": {
${runtime_json}
  }
}
EOF
}
