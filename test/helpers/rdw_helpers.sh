#!/usr/bin/env bash
# test/helpers/rdw_helpers.sh
# redmine-docker-workspace テスト用ヘルパー関数群

RDW_BIN="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)/bin/redmine-docker-workspace"
RDW_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
RDW_FIXTURES="$RDW_TEST_ROOT/fixtures"

# rdw()
# redmine-docker-workspace バイナリを呼び出すラッパー
rdw() {
  bash "$RDW_BIN" "$@"
}

# rdw_make_workspace()
# テスト用一時ワークスペースを作成し、パスを返す
# stdout: workspace directory path
rdw_make_workspace() {
  local ws
  ws=$(mktemp -d)
  mkdir -p "$ws/dbdump" "$ws/plugins" "$ws/compose" "$ws/verification" \
            "$ws/files" "$ws/log" "$ws/tmp"
  echo "$ws"
}

# rdw_init_state()
# .rdc_state を指定の key=value で初期化する
# args: workspace_path, key=value ...
rdw_init_state() {
  local ws="${1:?workspace_path required}"
  shift
  local state_file="$ws/.rdc_state"
  : > "$state_file"
  local has_generate_status_done=false
  local has_generate_completed_at=false
  for pair in "$@"; do
    [[ "$pair" == "generate_status=done" ]] && has_generate_status_done=true
    [[ "$pair" == generate_completed_at=* ]] && has_generate_completed_at=true
    echo "$pair" >> "$state_file"
  done
  if [[ "$has_generate_status_done" == true && "$has_generate_completed_at" == false ]]; then
    echo "generate_completed_at=2026-01-01T00:00:00Z" >> "$state_file"
  fi
}

# rdw_read_state()
# .rdc_state から指定キーの値を返す
# args: workspace_path, key
# stdout: value
rdw_read_state() {
  local ws="${1:?workspace_path required}"
  local key="${2:?key required}"
  grep "^${key}=" "$ws/.rdc_state" 2>/dev/null | cut -d= -f2- || true
}

# rdw_full_state()
# passenger モード全ステップ完了の .rdc_state を生成する
# args: workspace_path
rdw_full_state_passenger() {
  local ws="${1:?workspace_path required}"
  rdw_init_state "$ws" \
    "workspace_initialized=true" \
    "mode=passenger" \
    "product=redmine" \
    "target_image_tag=6.1.2" \
    "init_status=done" \
    "dbdump_status=done" \
    "generate_status=done" \
    "import_status=done" \
    "migrate_status=done" \
    "check_status=done"
}

# rdw_partial_state_until_generate()
# generate 完了・import 未完了の .rdc_state（passenger モード）
# args: workspace_path
rdw_partial_state_until_generate() {
  local ws="${1:?workspace_path required}"
  rdw_init_state "$ws" \
    "workspace_initialized=true" \
    "mode=passenger" \
    "product=redmine" \
    "target_image_tag=6.1.2" \
    "init_status=done" \
    "dbdump_status=done" \
    "generate_status=done" \
    "import_status=pending" \
    "migrate_status=pending" \
    "check_status=pending"
}
