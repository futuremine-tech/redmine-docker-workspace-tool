#!/usr/bin/env bash
# lib/rdc/init_service.bash
# mode ごとの source 解決、workspace 初期化、前提検証を担う Service
# 根拠要件: RDC-REQ-F0101〜RDC-REQ-F0124

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/mode_resolver.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# _init_service_workspace_required_keys: workspace モードで必須の .rdc_state キー
_INIT_WORKSPACE_REQUIRED_KEYS=("workspace_initialized" "mode" "product" "target_image_tag" "init_status")

# _init_service_find_passenger()
# Apache 設定ディレクトリから PassengerAppRoot / DocumentRoot を抽出する
# args: apache_config_dir
# stdout: redmine_root (e.g. /var/lib/redmine)
# returns: 0 on success, 1 on not found
_init_service_find_passenger() {
  local apache_dir="${1:?apache_config_dir required}"
  local root=""

  # Search httpd.conf and conf.d/*.conf
  local files=()
  [[ -f "$apache_dir/httpd.conf" ]] && files+=("$apache_dir/httpd.conf")
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$apache_dir" -maxdepth 2 -name "*.conf" -print0 2>/dev/null)

  for f in "${files[@]}"; do
    # PassengerAppRoot takes priority
    root=$(grep -i "PassengerAppRoot" "$f" 2>/dev/null | awk '{print $2}' | head -1 | tr -d '"' || true)
    [[ -n "$root" ]] && echo "$root" && return 0
    # Fallback 1: DocumentRoot with Passenger settings nearby
    root=$(grep -i "DocumentRoot" "$f" 2>/dev/null | awk '{print $2}' | head -1 | tr -d '"' || true)
    if [[ -n "$root" ]] && grep -qi "Passenger" "$f" 2>/dev/null; then
      # DocumentRoot is usually /path/public; strip /public
      root="${root%/public}"
      echo "$root" && return 0
    fi

    # Fallback 2: <Directory ".../public"> with Passenger settings nearby
    local dir_line
    dir_line=$(grep -iE '<Directory[[:space:]]' "$f" 2>/dev/null | grep -i '/public' | head -1 || true)
    if [[ -n "$dir_line" ]] && grep -qi "Passenger" "$f" 2>/dev/null; then
      root=$(echo "$dir_line" | sed -E "s/.*<[Dd]irectory[[:space:]]+[\"']?([^\"'<> ]+)[\"']?>.*/\1/" | grep -i 'public$' | head -1 || true)
      if [[ -n "$root" ]]; then
        root="${root%/public}"
        echo "$root" && return 0
      fi
    fi
  done
  return 1
}

# _init_service_detect_product()
# REDMINE_ROOT から product と version を検出する
# args: redmine_root
# stdout: product=<redmine|redmica>\nversion=<x.x.x>
_init_service_detect_product() {
  local root="${1:?redmine_root required}"
  local product="redmine"
  local version="unknown"

  if [[ -f "$root/lib/redmica/version.rb" ]] || [[ -f "$root/redmica.gemspec" ]]; then
    product="redmica"
  fi

  # Try to detect version from VERSION file or version.rb.
  # For RedMica, prefer lib/redmica/version.rb over lib/redmine/version.rb
  # because the latter contains the upstream Redmine base version, not the RedMica version.
  if [[ -f "$root/VERSION" ]]; then
    version=$(cat "$root/VERSION" | tr -d '[:space:]')
  elif [[ "$product" == "redmica" && -f "$root/lib/redmica/version.rb" ]]; then
    version=$(grep -E "^\s*(MAJOR|MINOR|TINY)\s*=" "$root/lib/redmica/version.rb" 2>/dev/null | \
      awk '{print $NF}' | tr -d ',' | paste -sd '.' || echo "unknown")
  elif [[ -f "$root/lib/redmine/version.rb" ]]; then
    version=$(grep -E "^\s*(MAJOR|MINOR|TINY)\s*=" "$root/lib/redmine/version.rb" 2>/dev/null | \
      awk '{print $NF}' | tr -d ',' | paste -sd '.' || echo "unknown")
  fi

  echo "product=$product"
  echo "version=$version"
}

# _init_service_validate_source_workspace()
# source workspace の必須状態キーを検証する
# args: source_workspace_path
# returns: 0 on valid, 1 on invalid
_init_service_validate_source_workspace() {
  local src="${1:?source_workspace required}"
  local state_file="$src/.rdc_state"

  if [[ ! -f "$state_file" ]]; then
    echo "ERROR: Source workspace has no .rdc_state file: $src" >&2
    return 1
  fi

  for key in "${_INIT_WORKSPACE_REQUIRED_KEYS[@]}"; do
    local val
    val=$(grep "^${key}=" "$state_file" 2>/dev/null | cut -d= -f2- || true)
    if [[ -z "$val" ]]; then
      echo "ERROR: Source workspace state is missing required key: ${key}. State is invalid or incomplete." >&2
      return 1
    fi
  done
  return 0
}

# init_service_run()
# init サブコマンド全体を実行する
# args: argv...
# returns: exit_code
init_service_run() {
  local workspace=""
  local mode="" redmine_root="" apache_config_dir="" source_workspace=""
  local target_product="" target_tag=""
  local redmine_tag="" redmica_tag="" base_image=""
  local list_mode=""

  # Parse args
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --help|-h)
        echo "Usage: redmine-docker-workspace init --target PATH [--mode <passenger|workspace|new>] [options]"
        echo ""
        echo "Options:"
        echo "  --target PATH                       Workspace directory (required)"
        echo "  --mode <passenger|workspace|new>   Input mode (default: new)"
        echo "  --redmine-root PATH                 Redmine root dir (passenger mode)"
        echo "  --apache-config-dir PATH            Apache config dir (passenger mode)"
        echo "  --source PATH             Source workspace (workspace mode; default: current dir if it is a workspace)"
        echo "  --redmine TAG                       Target Redmine image tag"
        echo "  --redmica TAG                       Target RedMica image tag"
        echo "  --base-image REPO:TAG               Target base image (new mode only)"
        echo "  --list                              List supported images (x.y.z tags only) and exit"
        echo "  --list-all                          List all images (including derived tags) and exit"
        echo "  -v, --verbose                       Verbose output"
        echo ""
        echo "Note: When running as root, writable container directories (files/, log/, tmp/)"
        echo "  are created with owner UID/GID 999 (the 'redmine' user in official images)."
        echo "  When using --base-image, ensure the container user is also UID/GID 999."
        return 0
        ;;
      --list)     list_mode="semver"; ((i+=1)) ;;
      --list-all) list_mode="all";    ((i+=1)) ;;
      --mode) mode="${args[$((i+1))]}"; ((i+=2)) ;;
      --mode=*) mode="${args[$i]#--mode=}"; ((i+=1)) ;;
      --target) workspace="${args[$((i+1))]}"; ((i+=2)) ;;
      --target=*) workspace="${args[$i]#--target=}"; ((i+=1)) ;;
      --redmine-root) redmine_root="${args[$((i+1))]}"; ((i+=2)) ;;
      --redmine-root=*) redmine_root="${args[$i]#--redmine-root=}"; ((i+=1)) ;;
      --apache-config-dir) apache_config_dir="${args[$((i+1))]}"; ((i+=2)) ;;
      --apache-config-dir=*) apache_config_dir="${args[$i]#--apache-config-dir=}"; ((i+=1)) ;;
      --source) source_workspace="${args[$((i+1))]}"; ((i+=2)) ;;
      --source=*) source_workspace="${args[$i]#--source=}"; ((i+=1)) ;;
      --redmine) redmine_tag="${args[$((i+1))]}"; ((i+=2)) ;;
      --redmine=*) redmine_tag="${args[$i]#--redmine=}"; ((i+=1)) ;;
      --redmica) redmica_tag="${args[$((i+1))]}"; ((i+=2)) ;;
      --redmica=*) redmica_tag="${args[$i]#--redmica=}"; ((i+=1)) ;;
      --base-image) base_image="${args[$((i+1))]}"; ((i+=2)) ;;
      --base-image=*) base_image="${args[$i]#--base-image=}"; ((i+=1)) ;;
      -v|--verbose) export RDC_VERBOSE=true; ((i+=1)) ;;
      *) ((i+=1)) ;;
    esac
  done

  # --list / --list-all: イメージ一覧表示して即リターン
  if [[ -n "$list_mode" ]]; then
    init_service_list_tags "$list_mode"
    return $?
  fi

  # Resolve tag options
  if [[ -n "$redmine_tag" ]]; then
    target_product="redmine"
    target_tag="$redmine_tag"
  elif [[ -n "$redmica_tag" ]]; then
    target_product="redmica"
    target_tag="$redmica_tag"
  fi

  # Validate image option mutual exclusivity
  if [[ -n "$redmine_tag" && -n "$redmica_tag" ]]; then
    logger_error "--redmine and --redmica cannot be used together."
    return 1
  fi
  if [[ -n "$base_image" && -n "$redmine_tag" ]]; then
    logger_error "--base-image and --redmine cannot be used together."
    return 1
  fi
  if [[ -n "$base_image" && -n "$redmica_tag" ]]; then
    logger_error "--base-image and --redmica cannot be used together."
    return 1
  fi

  # Validate base-image mode/option conflicts and auto mode behavior
  if [[ -n "$base_image" ]]; then
    if [[ -n "$mode" && "$mode" != "new" ]]; then
      logger_error "--base-image is for --mode new only."
      return 1
    fi
    if [[ -n "$redmine_root" || -n "$apache_config_dir" ]]; then
      logger_error "--base-image cannot be used with passenger-specific options."
      return 1
    fi
    if [[ -n "$source_workspace" ]]; then
      logger_error "--base-image cannot be used with --source."
      return 1
    fi
    mode="new"
  fi

  # Resolve workspace path: --target is required, unless current dir is a cleaned workspace
  if [[ -z "$workspace" ]]; then
    local current_clean_status
    current_clean_status=$(grep "^clean_status=" "${PWD}/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    if [[ "$current_clean_status" == "done" ]]; then
      workspace="$PWD"
    else
      echo "ERROR: --target PATH is required." >&2
      echo "Usage: redmine-docker-workspace init --target PATH [--mode <passenger|workspace|new>] [options]" >&2
      return 1
    fi
  fi
  # Normalize to absolute path without requiring the path to exist
  if [[ "$workspace" != /* ]]; then
    workspace="${PWD}/${workspace}"
  fi

  # workspace モード: --source 省略時にカレントディレクトリを自動適用 (RDC-REQ-F0905F)
  if [[ "$mode" == "workspace" && -z "$source_workspace" && -f "${PWD}/.rdc_state" ]]; then
    source_workspace="$PWD"
  fi

  # Normalize source_workspace and redmine_root to absolute paths
  # These directories must already exist, so cd && pwd resolves . and .. correctly.
  if [[ -n "$source_workspace" && "$source_workspace" != /* ]]; then
    source_workspace="$(cd "$source_workspace" 2>/dev/null && pwd || echo "${PWD}/${source_workspace}")"
  fi
  if [[ -n "$redmine_root" && "$redmine_root" != /* ]]; then
    redmine_root="$(cd "$redmine_root" 2>/dev/null && pwd || echo "${PWD}/${redmine_root}")"
  fi

  # Reject the tool's own directory as workspace (RDC-REQ-F0103)
  local tool_root
  tool_root="$(cd "${_RDC_LIB_DIR}/../.." && pwd)"
  local abs_workspace
  abs_workspace="$(cd "$workspace" 2>/dev/null && pwd)" || abs_workspace="$workspace"
  if [[ "$abs_workspace" == "$tool_root" ]]; then
    echo "ERROR: Cannot use the tool's own directory as workspace: $abs_workspace" >&2
    echo "Please specify a different --target directory." >&2
    return 1
  fi

  # Resolve mode
  local resolved_mode
  resolved_mode=$(mode_resolver_resolve \
    ${mode:+--mode "$mode"} \
    ${redmine_root:+--redmine-root "$redmine_root"} \
    ${apache_config_dir:+--apache-config-dir "$apache_config_dir"} \
    ${source_workspace:+--source "$source_workspace"} \
    --target "$workspace") || return 1

  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"
  logger_info "Initializing workspace: $workspace (mode: $resolved_mode)"

  # Check write permission: walk up to find the first existing ancestor (RDC-REQ-F0103)
  local _check_dir="$workspace"
  while [[ ! -e "$_check_dir" && "$_check_dir" != "/" ]]; do
    _check_dir="$(dirname "$_check_dir")"
  done
  if [[ ! -w "$_check_dir" ]]; then
    logger_error "ERROR: No write permission on: $_check_dir"
    logger_error "Please check directory permissions or specify a writable --target path."
    return 1
  fi

  # Scaffold workspace directories (create if not exists, RDC-REQ-F0103)
  mkdir -p "$workspace/dbdump" "$workspace/plugins" \
           "$workspace/verification" "$workspace/themes" \
           "$workspace/files" "$workspace/log" "$workspace/tmp" \
           "$workspace/.rdc_plugins"
  # コンテナユーザー (redmine: UID/GID 999) が書き込めるよう権限を設定する。
  # root 実行時: chown で所有者を 999 に変更。
  # 非 root 実行時: group に書き込み権限を付与。compose の user: "999:<実行ユーザーGID>" と対で機能する。
  # --base-image 使用時は対象イメージのコンテナユーザーも UID 999 であること。
  if [[ "$(id -u)" == "0" ]]; then
    chown 999:999 "$workspace/files" "$workspace/log" "$workspace/tmp"
  else
    chmod g+w "$workspace/files" "$workspace/log" "$workspace/tmp"
  fi

  # Handle reinit: reset downstream if same mode
  if [[ -f "$workspace/.rdc_state" ]]; then
    state_store_reset_after_reinit "$workspace" "$resolved_mode" || return 1
  fi

  case "$resolved_mode" in
    passenger)
      # Find Redmine root from Passenger config
      if [[ -z "$redmine_root" ]]; then
        local search_dir="${apache_config_dir:-/etc/httpd}"
        redmine_root=$(_init_service_find_passenger "$search_dir") || {
          logger_error "Cannot find Passenger configuration in: $search_dir. Is Apache/Passenger installed?"
          return 1
        }
      fi
      logger_info "Detected Redmine root: $redmine_root"

      # Detect product and version
      local detected_product="redmine" detected_version="unknown"
      if [[ -d "$redmine_root" ]]; then
        local detection
        detection=$(_init_service_detect_product "$redmine_root")
        detected_product=$(echo "$detection" | grep "^product=" | cut -d= -f2-)
        detected_version=$(echo "$detection" | grep "^version=" | cut -d= -f2-)
      fi

      # User-specified tag overrides detection
      local final_product="${target_product:-$detected_product}"
      local final_tag="${target_tag:-$detected_version}"

      state_store_save_many "$workspace" \
        "workspace_initialized=true" \
        "mode=passenger" \
        "product=$final_product" \
        "target_image_tag=$final_tag" \
        "redmine_root=$redmine_root" \
        "init_status=done" \
        "generate_status=pending" \
        "import_status=pending" \
        "migrate_status=pending" \
        "check_status=pending"
      ;;

    workspace)
      # Validate source workspace
      _init_service_validate_source_workspace "$source_workspace" || return 1

      local src_product src_tag
      src_product=$(grep "^product=" "$source_workspace/.rdc_state" | cut -d= -f2-)
      src_tag=$(grep "^target_image_tag=" "$source_workspace/.rdc_state" | cut -d= -f2-)

      local final_product="${target_product:-$src_product}"
      local final_tag="${target_tag:-$src_tag}"

      state_store_save_many "$workspace" \
        "workspace_initialized=true" \
        "mode=workspace" \
        "product=$final_product" \
        "target_image_tag=$final_tag" \
        "source_workspace=$source_workspace" \
        "init_status=done" \
        "generate_status=pending" \
        "import_status=pending" \
        "migrate_status=pending" \
        "check_status=pending"
      ;;

    new)
      local final_product="${target_product:-redmine}"
      local final_tag="${target_tag:-latest}"

      if [[ -n "$base_image" ]]; then
        state_store_save_many "$workspace" \
          "workspace_initialized=true" \
          "mode=new" \
          "image_ref=$base_image" \
          "image_source=explicit" \
          "product=" \
          "target_image_tag=" \
          "init_status=done" \
          "dbdump_status=pending" \
          "generate_status=pending" \
          "import_status=pending" \
          "migrate_status=pending" \
          "check_status=pending"
      else
        state_store_save_many "$workspace" \
          "workspace_initialized=true" \
          "mode=new" \
          "product=$final_product" \
          "target_image_tag=$final_tag" \
          "image_ref=${final_product}:${final_tag}" \
          "image_source=preset" \
          "init_status=done" \
          "dbdump_status=pending" \
          "generate_status=pending" \
          "import_status=pending" \
          "migrate_status=pending" \
          "check_status=pending"
      fi
      ;;
  esac

  # Determine tool_dir for PATH hint (RDC-REQ-F0107)
  local tool_dir
  tool_dir="$(cd "${_RDC_LIB_DIR}/../.." && pwd)/bin"

  # Save tool_bin_dir to .rdc_state for workspace activate-workspace-tool.sh
  state_store_save "$workspace" "tool_bin_dir" "$tool_dir"

  # Copy activate-workspace-tool.sh from repository root (RDC-REQ-F0107B)
  local repo_activate_script
  repo_activate_script="$(cd "${_RDC_LIB_DIR}/../.." && pwd)/activate-workspace-tool.sh"
  cp "$repo_activate_script" "$workspace/activate-workspace-tool.sh"

  logger_info "Workspace initialized successfully."
  echo ""
  echo "Workspace initialized: $workspace"
  echo "  mode   : $resolved_mode"
  echo ""
  echo "To use redmine-docker-workspace from anywhere, add the following to your shell profile:"
  echo "  export PATH=\"${tool_dir}:\$PATH\""
  echo ""
  echo "Or activate for this session only by sourcing the workspace script:"
  echo "  source \"${workspace}/activate-workspace-tool.sh\""
  echo ""
  echo "Subcommands can be run from any subdirectory under the workspace."
  echo "(.rdc_state is searched upward automatically)"

  status_service_display_after_subcommand "$workspace"
  return 0
}

# init_service_resolve_context()
# mode、source、target、product、tag を確定し InitContext を返す
# args: argv...
# stdout: InitContext (key=value lines)
# returns: 0 on success, 1 on failure
init_service_resolve_context() {
  # Delegate to run for context resolution (simplified)
  init_service_run "$@"
}

# init_service_reset_downstream_states_if_reinit()
# 同一モード再実行時に下流ステップ状態を pending に戻す
# args: workspace_path
init_service_reset_downstream_states_if_reinit() {
  local workspace_path="${1:?workspace_path required}"
  state_store_reset_after_reinit "$workspace_path"
}

# init_service_list_tags()
# 対応 3 リポジトリのタグ一覧を表示する
# args: filter_mode (semver|all)
# returns: 0 on success, 1 if all repos failed
init_service_list_tags() {
  local filter="${1:-semver}"
  local any_error=false

  _init_service_fetch_repo_tags "library/redmine"    "Redmine (official)           --redmine TAG" "$filter"  || any_error=true
  _init_service_fetch_repo_tags "redmica/redmica"    "RedMica < 3.2.0              --redmica TAG" "$filter"  || any_error=true
  _init_service_fetch_repo_tags "futuremine/redmica" "RedMica >= 3.2.0             --redmica TAG" "$filter"  || any_error=true

  [[ "$any_error" == "true" ]] && return 1
  return 0
}

# _init_service_fetch_repo_tags()
# 1 リポジトリ分のタグを全ページ取得してフィルタ・ソート・表示する
# args: repo (e.g. library/redmine), label, filter_mode (semver|all)
# returns: 0 on success, 1 on fetch error
_init_service_fetch_repo_tags() {
  local repo="${1:?repo required}"
  local label="${2:?label required}"
  local filter="${3:-semver}"

  echo ""
  echo "=== $label ==="

  local url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&ordering=last_updated"
  local all_tags=()
  local fetch_failed=false

  while true; do
    local response
    response=$(_init_service_hub_get "$url") || {
      echo "  (ERROR: failed to fetch tags)" >&2
      fetch_failed=true
      break
    }

    local page_tags
    if [[ "$filter" == "semver" ]]; then
      page_tags=$(python3 -c "
import json, sys, re
for r in json.load(sys.stdin).get('results', []):
    if re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', r['name']):
        print(r['name'])
" <<< "$response" 2>/dev/null)
    else
      page_tags=$(python3 -c "
import json, sys
for r in json.load(sys.stdin).get('results', []):
    print(r['name'])
" <<< "$response" 2>/dev/null)
    fi

    while IFS= read -r t; do
      [[ -n "$t" ]] && all_tags+=("$t")
    done <<< "$page_tags"

    local next_url
    next_url=$(python3 -c "
import json, sys
print(json.load(sys.stdin).get('next') or '')
" <<< "$response" 2>/dev/null)
    [[ -z "$next_url" ]] && break
    url="$next_url"
  done

  if [[ "$fetch_failed" == "true" ]]; then
    return 1
  fi

  if [[ ${#all_tags[@]} -eq 0 ]]; then
    echo "  (no matching tags)"
    return 0
  fi

  local image_prefix="${repo#library/}"
  printf '%s\n' "${all_tags[@]}" | sort -V -r | sed "s|^|  ${image_prefix}:|"
}

# _init_service_hub_get()
# Docker Hub API へ HTTP GET する（テスト用モック境界）
# RDC_ALLOW_MOCK=1 時は URL パターンに応じたハードコード JSON を返す
# args: url
# stdout: JSON response
_init_service_hub_get() {
  local url="${1:?url required}"

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    if [[ "$url" == *"library/redmine"* ]]; then
      printf '{"results":[{"name":"6.0.3"},{"name":"6.0.3-alpine"},{"name":"6.0.2"},{"name":"6.0.2-alpine"},{"name":"latest"}],"next":null}'
    elif [[ "$url" == *"redmica/redmica"* ]]; then
      printf '{"results":[{"name":"2.7.0"},{"name":"2.7.0-alpine"},{"name":"2.6.0"}],"next":null}'
    elif [[ "$url" == *"futuremine/redmica"* ]]; then
      printf '{"results":[{"name":"3.2.0"},{"name":"3.2.0-alpine"},{"name":"3.1.0"}],"next":null}'
    else
      printf '{"results":[],"next":null}'
    fi
    return 0
  fi

  curl -fsSL "$url" 2>/dev/null
}
