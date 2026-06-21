#!/usr/bin/env bash
# lib/rdc/add_plugin_service.bash
# add-plugin サブコマンド: git clone によるプラグイン追加と冪等性制御
# 根拠要件: RDC-REQ-F1201〜F1209, RDC-REQ-F0937〜F0949, RDC-REQ-F0953

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# add_plugin_service_run()
# add-plugin サブコマンド全体を実行する
# args: argv...
# returns: exit_code
add_plugin_service_run() {
  local git_url=""
  local name_option=""
  local ref_option=""
  local force=false
  [[ "${RDC_FORCE:-}" == "true" ]] && force=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        add_plugin_service_usage
        return 0
        ;;
      --name|-n)
        name_option="${2:?--name requires a value}"
        shift 2
        ;;
      --ref)
        ref_option="${2:?--ref requires a value}"
        shift 2
        ;;
      --force|-f)
        force=true
        shift
        ;;
      -*)
        echo "ERROR: Unknown option: $1" >&2
        add_plugin_service_usage >&2
        return 1
        ;;
      *)
        if [[ -z "$git_url" ]]; then
          git_url="$1"
        else
          echo "ERROR: Too many arguments" >&2
          add_plugin_service_usage >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$git_url" ]]; then
    echo "ERROR: <git_url> is required." >&2
    add_plugin_service_usage >&2
    return 1
  fi

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }

  local plugin_name
  plugin_name=$(add_plugin_service_resolve_plugin_name "$git_url" "$name_option")

  local plugin_dir="$workspace/plugins/$plugin_name"

  local case_code
  case_code=$(add_plugin_service_detect_existing_case "$workspace" "$plugin_name" "$git_url" "$ref_option")

  case "$case_code" in
    none)
      _add_plugin_do_clone "$workspace" "$plugin_name" "$plugin_dir" "$git_url" "$ref_option" || return $?
      _add_plugin_finalize_clone "$workspace" "$plugin_name" "$plugin_dir" "$git_url" "$ref_option"
      ;;

    match)
      echo "Plugin '$plugin_name' is already installed with matching URL and ref. Nothing to do."
      return 0
      ;;

    ref_diff)
      if [[ "$force" != "true" ]]; then
        echo "ERROR: Plugin '$plugin_name' is already installed with a different ref." >&2
        echo "  Recommended: run 'remove-plugin $plugin_name' first to safely reverse the DB migration," >&2
        echo "  then re-run 'add-plugin'. To bypass this check, use --force." >&2
        return 1
      fi
      rm -rf "$plugin_dir"
      _add_plugin_do_clone "$workspace" "$plugin_name" "$plugin_dir" "$git_url" "$ref_option" || return $?
      _add_plugin_finalize_clone "$workspace" "$plugin_name" "$plugin_dir" "$git_url" "$ref_option"
      ;;

    url_diff)
      echo "WARNING: Plugin '$plugin_name' is already installed from a different URL (different fork/repo)." >&2
      if [[ "$force" != "true" ]]; then
        echo "  Run 'remove-plugin $plugin_name' first, then re-run 'add-plugin'." >&2
        echo "  To bypass, use --force." >&2
        return 1
      fi
      rm -rf "$plugin_dir"
      _add_plugin_do_clone "$workspace" "$plugin_name" "$plugin_dir" "$git_url" "$ref_option" || return $?
      _add_plugin_finalize_clone "$workspace" "$plugin_name" "$plugin_dir" "$git_url" "$ref_option"
      ;;

    untracked)
      # ケース (d): サイドカーなし → メタデータ登録のみ（ディレクトリ保持、--force 不要）
      add_plugin_service_write_plugin_ref "$workspace" "$plugin_name" "$git_url" "$ref_option"
      local timestamp
      timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      state_store_save "$workspace" "plugins_last_changed" "$timestamp"
      echo "Plugin '$plugin_name' adopted into management (URL and ref recorded)."
      echo "Note: directory contents were not verified against the specified URL."
      state_store_load "$workspace"
      status_service_display_after_subcommand "$workspace"
      return 0
      ;;
  esac
}

# _add_plugin_do_clone()
# git clone を実行し失敗時はクリーンアップする
# args: workspace, plugin_name, plugin_dir, git_url, ref_option
_add_plugin_do_clone() {
  local workspace="$1" plugin_name="$2" plugin_dir="$3" git_url="$4" ref_option="$5"
  if ! add_plugin_service_run_git_clone "$git_url" "$plugin_dir" "$ref_option"; then
    echo "ERROR: git clone failed for: $git_url" >&2
    add_plugin_service_cleanup_failed_clone "$plugin_dir"
    return 1
  fi
}

# _add_plugin_finalize_clone()
# clone 成功後にサイドカー書き込みと state 更新を行い status 表示する
# args: workspace, plugin_name, plugin_dir, git_url, ref_option
_add_plugin_finalize_clone() {
  local workspace="$1" plugin_name="$2" plugin_dir="$3" git_url="$4" ref_option="$5"
  add_plugin_service_write_plugin_ref "$workspace" "$plugin_name" "$git_url" "$ref_option"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  state_store_save_many "$workspace" \
    "migrate_status=pending" \
    "check_status=pending" \
    "plugins_last_changed=$timestamp"
  echo "Plugin '$plugin_name' added successfully."
  echo "Next: docker compose build, migrate, docker compose up -d, check."
  state_store_load "$workspace"
  status_service_display_after_subcommand "$workspace"
}

# add_plugin_service_resolve_plugin_name()
# --name 指定があればその値、なければ URL basename から .git を除いた値を返す
# args: git_url, name_option
add_plugin_service_resolve_plugin_name() {
  local git_url="${1:?git_url required}"
  local name_option="${2:-}"
  if [[ -n "$name_option" ]]; then
    echo "$name_option"
  else
    local basename="${git_url##*/}"
    echo "${basename%.git}"
  fi
}

# add_plugin_service_detect_existing_case()
# プラグインディレクトリとサイドカーファイルを照合しケースコードを返す
# stdout: none | match | ref_diff | url_diff | untracked
add_plugin_service_detect_existing_case() {
  local workspace="${1:?}" plugin_name="${2:?}" git_url="${3:?}" ref="${4:-}"
  local plugin_dir="$workspace/plugins/$plugin_name"
  local sidecar="$workspace/.rdc_plugins/$plugin_name"

  if [[ ! -d "$plugin_dir" ]]; then
    echo "none"
    return 0
  fi

  if [[ ! -f "$sidecar" ]]; then
    echo "untracked"
    return 0
  fi

  local existing_url existing_ref
  existing_url=$(grep "^git_url=" "$sidecar" 2>/dev/null | cut -d= -f2- || true)
  existing_ref=$(grep "^ref=" "$sidecar" 2>/dev/null | cut -d= -f2- || true)

  if [[ "$existing_url" != "$git_url" ]]; then
    echo "url_diff"
    return 0
  fi

  if [[ "$existing_ref" == "$ref" ]]; then
    echo "match"
  else
    echo "ref_diff"
  fi
}

# add_plugin_service_write_plugin_ref()
# プラグインメタデータを .rdc_plugins/<plugin_name> へ書き込む
# args: workspace, plugin_name, git_url, ref
add_plugin_service_write_plugin_ref() {
  local workspace="${1:?}" plugin_name="${2:?}" git_url="${3:?}" ref="${4:-}"
  mkdir -p "$workspace/.rdc_plugins"
  printf 'git_url=%s\nref=%s\n' "$git_url" "$ref" > "$workspace/.rdc_plugins/$plugin_name"
}

# add_plugin_service_run_git_clone()
# git clone を実行する（モック対応）
# args: git_url, dest_path, ref_option
# returns: 0 on success, 1 on failure
add_plugin_service_run_git_clone() {
  local git_url="${1:?}" dest_path="${2:?}" ref_option="${3:-}"

  if [[ "${RDC_MOCK_GIT_CLONE_FAIL:-}" == "1" ]]; then
    echo "ERROR: (mock) git clone failed: $git_url" >&2
    return 1
  fi

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    mkdir -p "$dest_path"
    return 0
  fi

  if [[ -n "$ref_option" ]]; then
    git clone --branch "$ref_option" --depth 1 "$git_url" "$dest_path"
  else
    git clone --depth 1 "$git_url" "$dest_path"
  fi
}

# add_plugin_service_cleanup_failed_clone()
# 失敗した clone の不完全なディレクトリを削除する
# args: dest_path
add_plugin_service_cleanup_failed_clone() {
  local dest_path="${1:?}"
  [[ -d "$dest_path" ]] && rm -rf "$dest_path" || true
}

# add_plugin_service_usage()
add_plugin_service_usage() {
  echo "Usage: redmine-docker-workspace add-plugin <git_url> [--name <plugin_name>] [--ref <tag_or_branch>] [--force]"
  echo ""
  echo "Clone a Redmine plugin from a git repository into plugins/."
  echo ""
  echo "Arguments:"
  echo "  <git_url>              Git URL of the plugin repository"
  echo ""
  echo "Options:"
  echo "  --name <plugin_name>   Directory name under plugins/ (default: basename of git_url)"
  echo "  --ref <tag_or_branch>  Tag or branch to clone (default: remote default branch)"
  echo "  --force, -f            Force re-clone when URL or ref differs from recorded"
  echo "  --help, -h             Show this help"
  echo ""
  echo "After adding a plugin, run:"
  echo "  docker compose build"
  echo "  redmine-docker-workspace migrate"
  echo "  docker compose up -d"
  echo "  redmine-docker-workspace check"
}
