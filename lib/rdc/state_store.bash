#!/usr/bin/env bash
# lib/rdc/state_store.bash
# .rdc_state の読み書きを担う Model モジュール
# 根拠要件: RDC-REQ-F0606〜RDC-REQ-F0611

# state_store_load()
# ワークスペースパス配下の .rdc_state を読み込み、環境変数 RDC_STATE_* に展開する
# args: workspace_path
# returns: 0 on success, 1 if not found or invalid
state_store_load() {
  local workspace_path="${1:?workspace_path required}"
  local state_file="$workspace_path/.rdc_state"
  if [[ ! -f "$state_file" ]]; then
    return 1
  fi
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    export "RDC_STATE_${key}=${value}"
  done < "$state_file"
  return 0
}

# state_store_save()
# .rdc_state の単一キーを更新する
# args: workspace_path, key, value
state_store_save() {
  local workspace_path="${1:?workspace_path required}"
  local key="${2:?key required}"
  local value="${3?value required}"
  local state_file="$workspace_path/.rdc_state"
  touch "$state_file"
  if grep -q "^${key}=" "$state_file" 2>/dev/null; then
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${key}=" "$state_file" > "$tmpfile"
    echo "${key}=${value}" >> "$tmpfile"
    mv "$tmpfile" "$state_file"
  else
    echo "${key}=${value}" >> "$state_file"
  fi
}

# state_store_save_many()
# .rdc_state の複数キーを一括更新する
# args: workspace_path, key=value ...
state_store_save_many() {
  local workspace_path="${1:?workspace_path required}"
  shift
  for pair in "$@"; do
    local key="${pair%%=*}"
    local value="${pair#*=}"
    state_store_save "$workspace_path" "$key" "$value"
  done
}

# state_store_reset_after_reinit()
# 同一モード再 init 時に下流ステップ状態を pending へ戻す
# 別モードの場合は失敗し clean を案内する
# args: workspace_path [new_mode]
state_store_reset_after_reinit() {
  local workspace_path="${1:?workspace_path required}"
  local new_mode="${2:-}"
  local state_file="$workspace_path/.rdc_state"

  if [[ ! -f "$state_file" ]]; then
    return 0
  fi

  # A cleaned workspace (clean_status=done) allows re-init with any mode
  local clean_status
  clean_status=$(grep "^clean_status=" "$state_file" 2>/dev/null | cut -d= -f2- || true)
  if [[ "$clean_status" == "done" ]]; then
    rm -f "$state_file"
    return 0
  fi

  local current_mode
  current_mode=$(grep "^mode=" "$state_file" 2>/dev/null | cut -d= -f2- || true)

  if [[ -n "$new_mode" && -n "$current_mode" && "$new_mode" != "$current_mode" ]]; then
    echo "ERROR: Cannot reinit with different mode (current: ${current_mode}, new: ${new_mode}). Run 'clean' first to reset the workspace." >&2
    return 1
  fi

  state_store_save_many "$workspace_path" \
    "generate_status=pending" \
    "import_status=pending" \
    "migrate_status=pending" \
    "check_status=pending"
  return 0
}

# state_store_remove()
# .rdc_state ファイルを削除する（clean 時）
# args: workspace_path
state_store_remove() {
  local workspace_path="${1:?workspace_path required}"
  rm -f "$workspace_path/.rdc_state"
}

# state_store_find_workspace_root()
# カレントディレクトリから上位に向かって .rdc_state を探し、
# ワークスペースルートの絶対パスを標準出力へ返す
# returns: 0 on success, 1 if not found
state_store_find_workspace_root() {
  local dir="${PWD}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -f "${dir}/.rdc_state" ]]; then
      echo "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  if [[ -f "/.rdc_state" ]]; then
    echo "/"
    return 0
  fi
  return 1
}
