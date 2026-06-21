#!/usr/bin/env bash
# lib/rdc/manifest_builder.bash
# verification/manifest.json を構築する Domain モジュール
# 根拠要件: RDC-REQ-F0407, RDC-REQ-F0408, RDC-REQ-NF0010

# manifest_builder_build_success()
# 成功時の manifest JSON 文字列を返す
# args: workspace_path, image_digest, plugin_inventory (space-separated)
# stdout: JSON string
manifest_builder_build_success() {
  local workspace_path="${1:?workspace_path required}"
  local image_digest="${2:?image_digest required}"
  local plugin_inventory="${3:-}"

  local state_file="$workspace_path/.rdc_state"
  local product="" tag="" migrate_status="" check_status="" timestamp=""
  product=$(grep "^product=" "$state_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
  tag=$(grep "^target_image_tag=" "$state_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
  migrate_status=$(grep "^migrate_status=" "$state_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
  check_status=$(grep "^check_status=" "$state_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

  # Build plugins JSON array
  local plugins_json="[]"
  if [[ -n "$plugin_inventory" ]]; then
    local arr=""
    for p in $plugin_inventory; do
      arr="${arr:+$arr, }\"$p\""
    done
    plugins_json="[${arr}]"
  fi

  cat <<EOF
{
  "status": "passed",
  "target": "${product}:${tag}",
  "image_digest": "${image_digest}",
  "migrate": "${migrate_status}",
  "check": "${check_status}",
  "plugins": ${plugins_json},
  "timestamp": "${timestamp}"
}
EOF
}

# manifest_builder_build_failure()
# 失敗時の manifest JSON 文字列を返す
# args: workspace_path, failure_reason
# stdout: JSON string
manifest_builder_build_failure() {
  local workspace_path="${1:?workspace_path required}"
  local failure_reason="${2:?failure_reason required}"

  local state_file="$workspace_path/.rdc_state"
  local product="" tag="" timestamp=""
  product=$(grep "^product=" "$state_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
  tag=$(grep "^target_image_tag=" "$state_file" 2>/dev/null | cut -d= -f2- || echo "unknown")
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

  cat <<EOF
{
  "status": "failed",
  "target": "${product}:${tag}",
  "reason": "${failure_reason}",
  "timestamp": "${timestamp}"
}
EOF
}
