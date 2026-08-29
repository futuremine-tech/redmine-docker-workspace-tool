#!/usr/bin/env bash
# lib/rdc/auto_service.bash
# init〜check・docker compose build/up -d を新規生成モード限定で一気通貫実行する Service
# 根拠要件: RDC-REQ-F1415〜F1426, F1415A, F1435（機能要件）、
#           RDC-REQ-F1427〜F1430, F1434, F1436（受け入れ基準のうちauto関連分）、
#           RDC-REQ-F0982〜F0993（テスト要件）
# 設計: develop/docs/1A-DESIGN-F1415-auto-and-json-outputs.md 4節

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/status_service.bash"
source "$_RDC_LIB_DIR/init_service.bash"
source "$_RDC_LIB_DIR/generate_service.bash"
source "$_RDC_LIB_DIR/prepare_db_service.bash"
source "$_RDC_LIB_DIR/migrate_service.bash"
source "$_RDC_LIB_DIR/check_service.bash"
source "$_RDC_LIB_DIR/add_plugin_service.bash"

# auto_service_show_usage()
auto_service_show_usage() {
  echo "Usage: redmine-docker-workspace auto (--redmine TAG | --redmica TAG | --base-image IMAGE_REF)"
  echo "         (--fresh-db | --import-from PATH) [options]"
  echo ""
  echo "Runs init, generate, prepare-db, docker compose build, migrate, docker compose up -d,"
  echo "and check in sequence, to build and start a new Redmine workspace in one command."
  echo ""
  echo "Scope: new-generation-mode inputs only (Passenger mode and existing-workspace mode are"
  echo "not supported by 'auto'). Use the individual subcommands for those inputs."
  echo ""
  echo "Options:"
  echo "  --redmine TAG                Target Redmine image tag (mutually exclusive with below)"
  echo "  --redmica TAG                Target RedMica image tag"
  echo "  --base-image IMAGE_REF       Target base image"
  echo "  --target PATH                Workspace directory (default: same as 'init')"
  echo "  --fresh-db                   Initialize an empty database"
  echo "  --import-from PATH           Restore from the specified dump file"
  echo "  --relative-url-root PATH     Redmine subpath (e.g. /redmine)"
  echo "  --bind-port PORT             Redmine host port (default: auto-detected)"
  echo "  --lang <LANG>                Language for loading default data (default: ja)"
  echo "  --add-plugin <git_url>[#ref] Add a plugin before generate (repeatable)"
  echo "  -v, --verbose                Verbose output"
}

# auto_service_split_plugin_spec()
# --add-plugin の値を git_url と ref (#以降) に分割する (RDC-REQ-F1437A)
# args: spec (例: "https://github.com/x/y.git#v1.0.0" または "https://github.com/x/y.git")
# stdout: 1行目 git_url、2行目 ref（無ければ空行）
auto_service_split_plugin_spec() {
  local spec="${1:?spec required}"
  if [[ "$spec" == *"#"* ]]; then
    echo "${spec%%#*}"
    echo "${spec#*#}"
  else
    echo "$spec"
    echo ""
  fi
}

# auto_service_validate_static()
# init を含むどのサブコマンドも呼び出す前の静的検証 (RDC-REQ-F1435, F1415A, F1416)
# args: redmine_tag, redmica_tag, base_image, fresh_db(true/false), import_from
# returns: 0 valid, 1 invalid (エラーメッセージを標準エラー出力へ出力する)
auto_service_validate_static() {
  local redmine_tag="$1" redmica_tag="$2" base_image="$3" fresh_db="$4" import_from="$5"

  local product_count=0
  [[ -n "$redmine_tag" ]] && ((product_count += 1))
  [[ -n "$redmica_tag" ]] && ((product_count += 1))
  [[ -n "$base_image" ]] && ((product_count += 1))
  if [[ "$product_count" -ne 1 ]]; then
    echo "ERROR: Specify exactly one of --redmine, --redmica, --base-image." >&2
    return 1
  fi

  local db_count=0
  [[ "$fresh_db" == "true" ]] && ((db_count += 1))
  [[ -n "$import_from" ]] && ((db_count += 1))
  if [[ "$db_count" -ne 1 ]]; then
    echo "ERROR: Specify exactly one of --fresh-db, --import-from PATH." >&2
    return 1
  fi

  if [[ -n "$import_from" && ! -f "$import_from" ]]; then
    echo "ERROR: --import-from file not found: $import_from" >&2
    return 1
  fi

  return 0
}

# auto_service_generate_random_password()
# DB_PASSWORDとして使うランダムな英数字(16進)文字列を生成する。auto実行中に
# generate_service_run が対話プロンプト（TTY接続時）や失敗（非対話・DB_PASSWORD未設定時）に
# 陥らないよう、autoは常にこの関数で生成した値を明示的にDB_PASSWORDとして渡す
# （generate_service_resolve_db_password()の既存優先順位: 既存.env > 環境変数DB_PASSWORD >
# 対話入力、のうち2番目の経路をそのまま利用する。generate_service.bash側は無改修）。
# generate_service_ensure_secret_key_base()と同じopensslを使い生成方式を統一する。
# stdout: password
auto_service_generate_random_password() {
  openssl rand -hex 24
}

# auto_service_acquire_lock()
# ワークスペース単位のPIDロックファイルを取得する (RDC-REQ-F1424)
# 生存中の他プロセスが既にロックを保持している場合は失敗する。プロセスが既に終了している
# 古いロックは自動的に上書きして続行する。
# args: workspace_path
# returns: 0 取得成功, 1 他プロセスが実行中
auto_service_acquire_lock() {
  local workspace_path="${1:?workspace_path required}"

  local existing_pid
  existing_pid=$(state_store_check_auto_lock "$workspace_path") || {
    echo "ERROR: another 'auto' run is already in progress for this workspace (pid: $existing_pid)." >&2
    return 1
  }

  echo "$$" > "$workspace_path/.rdc_auto.lock"
  return 0
}

# auto_service_release_lock()
# args: workspace_path
auto_service_release_lock() {
  local workspace_path="${1:?workspace_path required}"
  rm -f "$workspace_path/.rdc_auto.lock"
}

# auto_service_run_pipeline()
# init〜check・docker compose build/up -d を順に実行する (RDC-REQ-F1415, F1421〜F1423)
# 失敗した最初のステップで停止し、後続ステップは実行しない。
# args: workspace_path, redmine_tag, redmica_tag, base_image, fresh_db(true/false),
#       import_from, relative_url_root, bind_port, lang, plugin_spec...
#       （plugin_specは可変長。9個の固定引数の後にshiftで受け取る）
# returns: 0 全ステップ成功, 1 いずれかのステップが失敗
auto_service_run_pipeline() {
  local workspace_path="$1" redmine_tag="$2" redmica_tag="$3" base_image="$4"
  local fresh_db="$5" import_from="$6" relative_url_root="$7" bind_port="$8" lang="$9"
  shift 9
  local plugin_specs=("$@")

  local init_args=(--target "$workspace_path")
  [[ -n "$redmine_tag" ]] && init_args+=(--redmine "$redmine_tag")
  [[ -n "$redmica_tag" ]] && init_args+=(--redmica "$redmica_tag")
  [[ -n "$base_image" ]] && init_args+=(--base-image "$base_image")
  init_service_run "${init_args[@]}" || { echo "auto: failed at step 'init'" >&2; return 1; }

  local spec git_url ref add_plugin_args
  for spec in "${plugin_specs[@]}"; do
    git_url=$(auto_service_split_plugin_spec "$spec" | sed -n '1p')
    ref=$(auto_service_split_plugin_spec "$spec" | sed -n '2p')
    add_plugin_args=("$git_url")
    [[ -n "$ref" ]] && add_plugin_args+=(--ref "$ref")
    ( cd "$workspace_path" && add_plugin_service_run "${add_plugin_args[@]}" ) \
      || { echo "auto: failed at step 'add-plugin' ($git_url)" >&2; return 1; }
  done

  local generate_args=()
  [[ -n "$relative_url_root" ]] && generate_args+=(--relative-url-root "$relative_url_root")
  [[ -n "$bind_port" ]] && generate_args+=(--bind-port "$bind_port")
  local auto_db_password
  auto_db_password=$(auto_service_generate_random_password)
  ( cd "$workspace_path" && DB_PASSWORD="$auto_db_password" generate_service_run "${generate_args[@]}" ) \
    || { echo "auto: failed at step 'generate'" >&2; return 1; }

  local prepare_db_args=()
  [[ "$fresh_db" == "true" ]] && prepare_db_args=(--fresh-db)
  [[ -n "$import_from" ]] && prepare_db_args=(--import-from "$import_from")
  ( cd "$workspace_path" && prepare_db_service_run "${prepare_db_args[@]}" ) \
    || { echo "auto: failed at step 'prepare-db'" >&2; return 1; }

  ( cd "$workspace_path" && docker compose build ) \
    || { echo "auto: failed at step 'docker compose build'" >&2; return 1; }

  local migrate_args=()
  [[ -n "$lang" ]] && migrate_args+=(--lang "$lang")
  ( cd "$workspace_path" && migrate_service_run "${migrate_args[@]}" ) \
    || { echo "auto: failed at step 'migrate'" >&2; return 1; }

  ( cd "$workspace_path" && docker compose up -d ) \
    || { echo "auto: failed at step 'docker compose up -d'" >&2; return 1; }

  ( cd "$workspace_path" && check_service_run ) \
    || { echo "auto: failed at step 'check'" >&2; return 1; }

  return 0
}

# auto_service_run()
# auto サブコマンド全体を実行する
# args: argv...
# returns: exit_code
auto_service_run() {
  local target="" redmine_tag="" redmica_tag="" base_image=""
  local fresh_db=false import_from="" relative_url_root="" bind_port="" lang=""
  local plugin_specs=()

  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --help|-h) auto_service_show_usage; return 0 ;;
      --target) target="${args[$((i+1))]}"; ((i+=2)) ;;
      --target=*) target="${args[$i]#--target=}"; ((i+=1)) ;;
      --redmine) redmine_tag="${args[$((i+1))]}"; ((i+=2)) ;;
      --redmine=*) redmine_tag="${args[$i]#--redmine=}"; ((i+=1)) ;;
      --redmica) redmica_tag="${args[$((i+1))]}"; ((i+=2)) ;;
      --redmica=*) redmica_tag="${args[$i]#--redmica=}"; ((i+=1)) ;;
      --base-image) base_image="${args[$((i+1))]}"; ((i+=2)) ;;
      --base-image=*) base_image="${args[$i]#--base-image=}"; ((i+=1)) ;;
      --fresh-db) fresh_db=true; ((i+=1)) ;;
      --import-from) import_from="${args[$((i+1))]}"; ((i+=2)) ;;
      --import-from=*) import_from="${args[$i]#--import-from=}"; ((i+=1)) ;;
      --relative-url-root) relative_url_root="${args[$((i+1))]}"; ((i+=2)) ;;
      --relative-url-root=*) relative_url_root="${args[$i]#--relative-url-root=}"; ((i+=1)) ;;
      --bind-port) bind_port="${args[$((i+1))]}"; ((i+=2)) ;;
      --bind-port=*) bind_port="${args[$i]#--bind-port=}"; ((i+=1)) ;;
      --lang) lang="${args[$((i+1))]}"; ((i+=2)) ;;
      --lang=*) lang="${args[$i]#--lang=}"; ((i+=1)) ;;
      --add-plugin) plugin_specs+=("${args[$((i+1))]}"); ((i+=2)) ;;
      --add-plugin=*) plugin_specs+=("${args[$i]#--add-plugin=}"); ((i+=1)) ;;
      -v|--verbose) export RDC_VERBOSE=true; ((i+=1)) ;;
      *) ((i+=1)) ;;
    esac
  done

  # RDC-REQ-F1435: init を含むどのサブコマンドも呼び出す前に静的検証を行う
  auto_service_validate_static "$redmine_tag" "$redmica_tag" "$base_image" "$fresh_db" "$import_from" || return 1

  # RDC-REQ-F1417: ワークスペースパス解決。省略時は init の既定 [RDC-REQ-F0101] に従う
  local workspace="$target"
  if [[ -z "$workspace" ]]; then
    local current_clean_status
    current_clean_status=$(grep "^clean_status=" "${PWD}/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
    if [[ "$current_clean_status" == "done" ]]; then
      workspace="$PWD"
    else
      echo "ERROR: --target PATH is required." >&2
      return 1
    fi
  fi
  if [[ "$workspace" != /* ]]; then
    workspace="${PWD}/${workspace}"
  fi

  # RDC-REQ-F1425: Docker疎通確認。疎通できない場合は内部処理を一切行わずエラー終了する
  status_service_check_docker_daemon_reachable || {
    echo "ERROR: Docker デーモンに接続できません。Docker を起動してから再実行してください。" >&2
    return 1
  }

  # RDC-REQ-F1424: 多重実行検知（PIDロックファイル）
  auto_service_acquire_lock "$workspace" || return 1

  if auto_service_run_pipeline "$workspace" "$redmine_tag" "$redmica_tag" "$base_image" \
      "$fresh_db" "$import_from" "$relative_url_root" "$bind_port" "$lang" "${plugin_specs[@]}"; then
    auto_service_release_lock "$workspace"
    return 0
  else
    auto_service_release_lock "$workspace"
    return 1
  fi
}
