#!/usr/bin/env bash
# lib/rdc/mode_resolver.bash
# --mode と専用オプションの整合性判定を担う Domain モジュール
# 根拠要件: RDC-REQ-F0901〜RDC-REQ-F0908A

# mode_resolver_resolve()
# argv から mode を確定し、矛盾・未指定時は失敗する
# args: argv...
# stdout: resolved mode string (passenger | workspace | new)
# returns: 0 on success, 1 on conflict or missing required option
mode_resolver_resolve() {
  local mode=""
  local redmine_root=""
  local apache_config_dir=""
  local source_workspace=""
  local target_ws="${PWD}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)          mode="$2";              shift 2 ;;
      --mode=*)        mode="${1#--mode=}";    shift ;;
      --redmine-root)  redmine_root="$2";      shift 2 ;;
      --redmine-root=*) redmine_root="${1#--redmine-root=}"; shift ;;
      --apache-config-dir) apache_config_dir="$2"; shift 2 ;;
      --apache-config-dir=*) apache_config_dir="${1#--apache-config-dir=}"; shift ;;
      --source) source_workspace="$2"; shift 2 ;;
      --source=*) source_workspace="${1#--source=}"; shift ;;
      --target) target_ws="$2"; shift 2 ;;
      --target=*) target_ws="${1#--target=}"; shift ;;
      *) shift ;;
    esac
  done

  # mode 専用入力がある場合は --mode 明示を要求
  if [[ -z "$mode" ]]; then
    if [[ -n "$redmine_root" || -n "$apache_config_dir" ]]; then
      echo "ERROR: --redmine-root / --apache-config-dir requires --mode passenger. Please specify --mode." >&2
      return 1
    fi
    if [[ -n "$source_workspace" ]]; then
      echo "ERROR: --source requires --mode workspace. Please specify --mode." >&2
      return 1
    fi
    # 既定値 new
    echo "new"
    return 0
  fi

  case "$mode" in
    passenger)
      echo "passenger"
      return 0
      ;;
    workspace)
      if [[ -z "$source_workspace" ]]; then
        echo "ERROR: --mode workspace requires --source. Please specify --source." >&2
        return 1
      fi
      # source と target が同一パスかチェック（target が未作成でも parent+basename で解決）
      local abs_source abs_target
      abs_source="$(cd "$source_workspace" 2>/dev/null && pwd || echo "$source_workspace")"
      if [[ -d "$target_ws" ]]; then
        abs_target="$(cd "$target_ws" 2>/dev/null && pwd || echo "$target_ws")"
      else
        abs_target="$(cd "$(dirname "$target_ws")" 2>/dev/null && pwd)/$(basename "$target_ws")" || abs_target="$target_ws"
      fi
      if [[ "$abs_source" == "$abs_target" ]]; then
        echo "ERROR: --source and target workspace must not be the same path." >&2
        return 1
      fi
      echo "workspace"
      return 0
      ;;
    new)
      echo "new"
      return 0
      ;;
    *)
      echo "ERROR: Unknown mode: $mode. Valid modes are: passenger, workspace, new." >&2
      return 1
      ;;
  esac
}
