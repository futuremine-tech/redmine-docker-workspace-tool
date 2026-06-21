#!/usr/bin/env bash
# lib/rdc/check_service.bash
# HTTP 検証、再試行、manifest 生成を担う Service
# 根拠要件: RDC-REQ-F0401〜RDC-REQ-F0410

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/manifest_builder.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# check_service_run()
# check サブコマンド全体を実行する
# args: argv...
# returns: exit_code
check_service_run() {
  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: redmine-docker-workspace check"
        echo ""
        echo "Probe the running Redmine to verify it is accessible."
        echo "Writes verification/manifest.json with the result."
        return 0
        ;;
      -v|--verbose) export RDC_VERBOSE=true ;;
    esac
  done

  if ! state_store_load "$workspace"; then
    logger_error "Workspace not initialized. Run 'init' first."
    return 1
  fi

  local migrate_status="${RDC_STATE_migrate_status:-pending}"
  if [[ "$migrate_status" != "done" ]]; then
    logger_error "migrate step not completed. Run 'migrate' first."
    return 1
  fi

  local probe_exit=0
  check_service_probe_http "$workspace" || probe_exit=$?

  if [[ $probe_exit -eq 0 ]]; then
    local proxy_probe_exit=1
    if check_service_probe_reverse_proxy "$workspace"; then
      proxy_probe_exit=0
    else
      proxy_probe_exit=$?
    fi

    check_service_write_manifest "$workspace" "passed"
    state_store_save "$workspace" "check_status" "done"
    logger_info "check completed: Redmine is accessible and verified."
    local bind="${RDC_STATE_redmine_bind:-127.0.0.1:38080}"
    local relative_url_root="${RDC_STATE_relative_url_root:-}"
    local access_url="http://${bind}${relative_url_root}/"
    local proxy_access_url
    proxy_access_url=$(check_service_build_proxy_url "$workspace")
    local proxy_from="${relative_url_root:-/}"
    local proxy_to="http://${bind}${relative_url_root}/"
    echo "check completed."
    echo ""
    echo "Redmine is running at: ${access_url}"
    echo ""
    if [[ $proxy_probe_exit -eq 0 ]]; then
      echo "Reverse proxy route is already reachable: ${proxy_access_url}"
    else
      echo "Reverse proxy route check failed: ${proxy_access_url}"
    fi
    echo ""
    echo "Note: Redmine is bound to ${bind%:*} (loopback only)."
    echo "To expose it externally, configure a reverse proxy. Apache example:"
    echo ""
    echo "  <VirtualHost *:80>"
    echo "      ServerName example.com"
    echo "      ProxyRequests Off"
    echo "      ProxyPreserveHost On"
    echo "      ProxyPass        ${proxy_from} ${proxy_to}"
    echo "      ProxyPassReverse ${proxy_from} ${proxy_to}"
    echo "  </VirtualHost>"
    echo ""
    status_service_display_after_subcommand "$workspace"
    return 0
  else
    check_service_write_manifest "$workspace" "failed"
    logger_error "check failed: Redmine is not accessible or verification failed."
    return 1
  fi
}

# check_service_probe_http()
# HTTP 応答を再試行付きで取得し CheckResult を返す
# args: workspace_path
# stdout: CheckResult (status=passed|failed, body=...)
check_service_probe_http() {
  local workspace_path="${1:?workspace_path required}"
  local max_attempts="${RDC_CHECK_HTTP_MAX_ATTEMPTS:-15}"
  local retry_interval_sec="${RDC_CHECK_HTTP_RETRY_INTERVAL_SEC:-6}"

  # Timeout mock
  if [[ "${RDC_MOCK_HTTP_STATUS:-}" == "timeout" ]]; then
    logger_debug "Mock: HTTP timeout"
    return 1
  fi

  local response=""
  if [[ -n "${RDC_MOCK_HTTP_RESPONSE:-}" ]]; then
    local bind
    bind=$(grep "^redmine_bind=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    [[ -z "$bind" ]] && bind="127.0.0.1:38080"
    local relative_url_root
    relative_url_root=$(grep "^relative_url_root=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    local url="http://${bind}${relative_url_root}/"
    logger_debug "HTTP probe URL: ${url}"
    logger_debug "HTTP probe attempt 1/${max_attempts}"
    logger_debug "Mock: HTTP response override"
    response="$RDC_MOCK_HTTP_RESPONSE"
  else
    local bind
    bind=$(grep "^redmine_bind=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    [[ -z "$bind" ]] && bind="127.0.0.1:38080"
    local relative_url_root
    relative_url_root=$(grep "^relative_url_root=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    local url="http://${bind}${relative_url_root}/"
    logger_debug "HTTP probe URL: ${url}"
    local attempts=0
    local printed_progress=false
    while [[ $attempts -lt $max_attempts ]]; do
      logger_debug "HTTP probe attempt $((attempts + 1))/${max_attempts}"
      if [[ "${RDC_VERBOSE:-}" != "true" ]]; then
        if [[ "$printed_progress" == "false" ]]; then
          echo -n "HTTP check in progress"
          printed_progress=true
        fi
        echo -n "."
      fi
      response=$(curl -sf --max-time 10 "$url" 2>/dev/null) && break || true
      attempts=$((attempts + 1))
      if [[ $attempts -lt $max_attempts ]]; then
        sleep "$retry_interval_sec"
      fi
    done
    if [[ "$printed_progress" == "true" ]]; then
      echo ""
    fi
    if [[ -z "$response" ]]; then
      logger_debug "HTTP probe failed after ${max_attempts} attempts"
      return 1
    fi
    logger_debug "HTTP probe succeeded"
  fi

  check_service_response_is_valid "$response"
}

# check_service_build_proxy_url()
# reverse proxy 到達確認用 URL を構築する
# args: workspace_path
# stdout: proxy url (http://localhost...)
check_service_build_proxy_url() {
  local workspace_path="${1:?workspace_path required}"
  local relative_url_root
  relative_url_root=$(grep "^relative_url_root=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
  echo "http://localhost${relative_url_root}/"
}

# check_service_probe_reverse_proxy()
# reverse proxy 経由 URL の到達確認を行う
# args: workspace_path
# returns: 0 if proxy route looks reachable, 1 otherwise
check_service_probe_reverse_proxy() {
  local workspace_path="${1:?workspace_path required}"
  local url
  url=$(check_service_build_proxy_url "$workspace_path")
  logger_debug "Reverse proxy probe URL: ${url}"

  if [[ "${RDC_MOCK_PROXY_HTTP_STATUS:-}" == "timeout" ]]; then
    logger_debug "Mock: reverse proxy HTTP timeout"
    return 1
  fi

  local response=""
  if [[ -n "${RDC_MOCK_PROXY_HTTP_RESPONSE:-}" ]]; then
    logger_debug "Mock: reverse proxy HTTP response override"
    response="$RDC_MOCK_PROXY_HTTP_RESPONSE"
  elif [[ -n "${RDC_MOCK_HTTP_RESPONSE:-}" ]]; then
    # In mock mode, avoid real network access unless proxy mock is explicitly set.
    logger_debug "Mock mode: reverse proxy probe treated as failed (no proxy mock provided)"
    return 1
  else
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
      logger_debug "Reverse proxy probe attempt $((attempts + 1))/3"
      response=$(curl -sf --max-time 10 "$url" 2>/dev/null) && break || true
      attempts=$((attempts + 1))
      sleep 2
    done
    if [[ -z "$response" ]]; then
      logger_debug "Reverse proxy probe failed after 3 attempts"
      return 1
    fi
    logger_debug "Reverse proxy probe succeeded"
  fi

  check_service_response_is_valid "$response"
}

# check_service_response_is_valid()
# check 用レスポンス文字列を要件に沿って成功判定する
# args: html_response
# returns: 0 if valid, 1 otherwise
check_service_response_is_valid() {
  local response="${1:-}"

  # Strip HTML tags for text-based detection
  local body_text
  body_text=$(echo "$response" | sed 's/<[^>]*>//g')

  if echo "$body_text" | grep -q "Powered by Redmine\|Powered by RedMica"; then
    return 0
  fi

  # fresh_db: accept welcome/sign-in page
  local fresh_db="${RDC_STATE_fresh_db_selected:-false}"
  if [[ "$fresh_db" == "true" ]]; then
    if echo "$body_text" | grep -q "Welcome to Redmine\|Sign in"; then
      return 0
    fi
  fi

  return 1
}

# check_service_write_manifest()
# verification/manifest.json を出力する
# args: workspace_path, check_result (passed|failed)
check_service_write_manifest() {
  local workspace_path="${1:?workspace_path required}"
  local check_result="${2:-failed}"

  local manifest_dir="$workspace_path/verification"
  mkdir -p "$manifest_dir"

  if [[ "$check_result" == "passed" ]]; then
    local image_digest
    image_digest=$(grep "^target_image_tag=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    if [[ -z "$image_digest" ]]; then
      image_digest=$(grep "^image_ref=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    fi
    if [[ -z "$image_digest" ]]; then
      image_digest="unknown"
    fi
    local plugins=""
    if [[ -d "$workspace_path/plugins" ]]; then
      plugins=$(ls "$workspace_path/plugins" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)
    fi
    manifest_builder_build_success "$workspace_path" "$image_digest" "$plugins" > "$manifest_dir/manifest.json"
  else
    manifest_builder_build_failure "$workspace_path" "HTTP check failed" > "$manifest_dir/manifest.json"
  fi
}
