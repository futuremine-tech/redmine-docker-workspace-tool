#!/usr/bin/env bash
# lib/rdc/prepare_db_service.bash
# DB 準備（--import-from / --fresh-db / --from-external-db / --skip）を担う Service
# 根拠要件: RDC-REQ-F0351〜RDC-REQ-F0362, RDC-REQ-F0351B

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"
source "$_RDC_LIB_DIR/status_service.bash"

# prepare_db_service_run()
# prepare-db サブコマンド全体を実行する
# args: argv...
# returns: exit_code
prepare_db_service_run() {
  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  local import_from=""
  local fresh_db=false
  local from_external_db=false
  local skip_db=false
  local skip_reason=""

  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --help|-h)
        echo "Usage: redmine-docker-workspace prepare-db [options]"
        echo ""
        echo "Choose exactly one DB preparation route:"
        echo "  --import-from PATH      Restore from the specified dump file"
        echo "  --fresh-db              Initialize an empty database"
        echo "  --from-external-db      Dump and restore from the external Passenger DB (passenger mode only)"
        echo "  --skip --reason TEXT    Skip DB changes and mark as prepared (operator responsibility)"
        echo ""
        echo "Options:"
        echo "  --import-from PATH      Use only the specified dump file"
        echo "  --fresh-db              Recreate DB container and prepare empty DB"
        echo "  --from-external-db      Read DB connection from .rdc_state redmine_root → database.yml, pg_dump → restore"
        echo "  --skip                  Do not modify DB; only advance state"
        echo "  --reason TEXT           Required when --skip is used"
        echo "  -v, --verbose           Verbose output"
        echo ""
        echo "Notes:"
        echo "  - --import-from, --fresh-db, --from-external-db, and --skip are mutually exclusive."
        echo "  - Dump auto-discovery is not supported."
        echo ""
        echo "Next steps after prepare-db:"
        echo "  1. docker compose build"
        echo "  2. redmine-docker-workspace migrate"
        echo "  3. docker compose up -d"
        echo "  4. redmine-docker-workspace check"
        return 0
        ;;
      --import-from)
        if [[ $((i+1)) -ge ${#args[@]} ]]; then
          echo "ERROR: --import-from requires a PATH argument." >&2
          return 1
        fi
        import_from="${args[$((i+1))]}"
        ((i+=2))
        ;;
      --import-from=*)
        import_from="${args[$i]#--import-from=}"
        ((i+=1))
        ;;
      --fresh-db)
        fresh_db=true
        ((i+=1))
        ;;
      --from-external-db)
        from_external_db=true
        ((i+=1))
        ;;
      --skip)
        skip_db=true
        ((i+=1))
        ;;
      --reason)
        if [[ $((i+1)) -ge ${#args[@]} ]]; then
          echo "ERROR: --reason requires TEXT." >&2
          return 1
        fi
        skip_reason="${args[$((i+1))]}"
        ((i+=2))
        ;;
      --reason=*)
        skip_reason="${args[$i]#--reason=}"
        ((i+=1))
        ;;
      -v|--verbose)
        export RDC_VERBOSE=true
        ((i+=1))
        ;;
      *)
        ((i+=1))
        ;;
    esac
  done

  local selected_count=0
  [[ -n "$import_from" ]] && ((selected_count+=1))
  [[ "$fresh_db" == true ]] && ((selected_count+=1))
  [[ "$from_external_db" == true ]] && ((selected_count+=1))
  [[ "$skip_db" == true ]] && ((selected_count+=1))

  if [[ $selected_count -eq 0 ]]; then
    logger_error "No DB preparation route selected."
    echo "ERROR: No input route selected." >&2
    echo "Specify exactly one of: --import-from PATH, --fresh-db, --from-external-db, --skip --reason TEXT" >&2
    return 1
  fi

  if [[ $selected_count -ne 1 ]]; then
    logger_error "Conflicting DB preparation routes."
    echo "ERROR: --import-from PATH, --fresh-db, --from-external-db, and --skip are mutually exclusive." >&2
    echo "Specify exactly one route." >&2
    return 1
  fi

  if [[ "$skip_db" == true && -z "$skip_reason" ]]; then
    logger_error "--skip requires --reason TEXT"
    echo "ERROR: --skip requires --reason TEXT." >&2
    return 1
  fi

  # Validate import path if selected
  if [[ -n "$import_from" ]]; then
    # When RDC_ALLOW_MOCK=1, skip validation for relative paths (test environments)
    local _skip_file_validate=false
    if [[ "${RDC_ALLOW_MOCK:-}" == "1" && "$import_from" != /* ]]; then
      _skip_file_validate=true
    fi
    if [[ "$_skip_file_validate" != "true" ]]; then
      if [[ ! -e "$import_from" ]]; then
        logger_error "Dump file not found: $import_from"
        echo "ERROR: Dump file does not exist: $import_from" >&2
        return 1
      fi
      if [[ ! -f "$import_from" ]]; then
        logger_error "Not a regular file: $import_from"
        echo "ERROR: Not a readable regular file: $import_from" >&2
        return 1
      fi
      if [[ ! -r "$import_from" ]]; then
        logger_error "Cannot read dump file: $import_from"
        echo "ERROR: Cannot read dump file: $import_from" >&2
        return 1
      fi
    fi
  fi

  if ! state_store_load "$workspace"; then
    logger_error "Workspace not initialized. Run 'init' first."
    return 1
  fi

  if ! prepare_db_service_ensure_preconditions "$workspace"; then
    return 1
  fi

  if ! prepare_db_service_ensure_redmine_not_running "$workspace"; then
    return 1
  fi

  if ! prepare_db_service_confirm_destructive_reprepare_db "$workspace"; then
    logger_info "prepare-db cancelled."
    return 1
  fi

  if [[ "$skip_db" == true ]]; then
    prepare_db_service_mark_skip_with_reason "$workspace" "$skip_reason" || return 1
    echo "WARNING: DB contents were not verified by this tool (--skip)."
    echo "Please perform manual DB validation as needed before migrate/check."
  elif [[ "$from_external_db" == true ]]; then
    prepare_db_service_reset_db_volume "$workspace" || return 1
    prepare_db_service_prepare_from_external_db "$workspace" || return 1
    state_store_save "$workspace" "fresh_db_selected" "false"
    state_store_save_many "$workspace" \
      "import_mode=from-external-db" \
      "import_skip_reason=" \
      "import_skipped_at="
  elif [[ "$fresh_db" == true ]]; then
    prepare_db_service_reset_db_volume "$workspace" || return 1
    prepare_db_service_initialize_fresh_db "$workspace" || return 1
    state_store_save "$workspace" "fresh_db_selected" "true"
    state_store_save_many "$workspace" \
      "import_mode=fresh-db" \
      "import_skip_reason=" \
      "import_skipped_at="
  else
    prepare_db_service_reset_db_volume "$workspace" || return 1
    prepare_db_service_restore_dump "$import_from" "$workspace" || return 1
    state_store_save "$workspace" "fresh_db_selected" "false"
    state_store_save_many "$workspace" \
      "import_mode=import-from" \
      "import_skip_reason=" \
      "import_skipped_at="
  fi

  state_store_save "$workspace" "import_status" "done"
  state_store_save "$workspace" "migrate_status" "pending"
  state_store_save "$workspace" "check_status" "pending"

  logger_info "prepare-db completed."
  echo "prepare-db completed."

  status_service_display_after_subcommand "$workspace"
  return 0
}

# prepare_db_service_reset_db_volume()
# 同一 compose プロジェクトの DB ボリュームを初期化する
# args: workspace_path
prepare_db_service_reset_db_volume() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    logger_info "Mock: skipping DB volume reset (RDC_ALLOW_MOCK=1)"
    return 0
  fi

  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    logger_error "docker-compose.yml not found. Run 'generate' first."
    return 1
  fi

  local project_name
  project_name="$(basename "$workspace_path")"
  local volume_name="${project_name}_db_data"

  logger_info "Resetting DB volume: $volume_name"

  # Ensure containers are stopped so volume can be detached safely.
  (cd "$compose_dir" && docker compose down --remove-orphans >/dev/null 2>&1) || true

  if docker volume inspect "$volume_name" >/dev/null 2>&1; then
    if ! docker volume rm "$volume_name" >/dev/null 2>&1; then
      logger_error "Failed to remove DB volume: $volume_name"
      echo "ERROR: Failed to reset DB volume '$volume_name'." >&2
      echo "Stop related containers and retry (or remove the volume manually)." >&2
      return 1
    fi
  fi

  return 0
}

# prepare_db_service_restore_dump()
# dump を DB へリストアする
# args: dump_path, workspace_path
prepare_db_service_restore_dump() {
  local dump_path="${1:?dump_path required}"
  local workspace_path="${2:?workspace_path required}"
  local compose_dir="$workspace_path"

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    logger_info "Mock: skipping docker DB restore (RDC_ALLOW_MOCK=1)"
    return 0
  fi

  logger_info "Restoring dump: $dump_path"

  if [[ -f "$compose_dir/docker-compose.yml" ]]; then
    (cd "$compose_dir" && docker compose up -d db) || true
    local retries=0
    while ! (cd "$compose_dir" && docker compose exec -T db pg_isready -U redmine -d redmine) 2>/dev/null; do
      ((retries++))
      [[ $retries -gt 12 ]] && { logger_error "DB container did not become ready."; return 1; }
      sleep 5
    done
    echo "Importing dump: $(basename "$dump_path") ..."
    local restore_ok=false
    local restore_stderr
    restore_stderr=$(mktemp)

    # Custom format (-Fc) restore.
    # -c --if-exists: 既存オブジェクト（public スキーマ等）を安全にドロップしてから再作成。
    #   空 DB では IF EXISTS により "does not exist" エラーが出ない。
    # --no-owner --no-acl: 移行元と Docker のユーザー差異を吸収する。
    local pg_restore_rc=0
    (cd "$compose_dir" && docker compose exec -T db \
        pg_restore --no-owner --no-acl -c --if-exists -U redmine -d redmine) \
        < "$dump_path" 2>"$restore_stderr" || pg_restore_rc=$?

    if [[ "$pg_restore_rc" -eq 0 ]]; then
      restore_ok=true
    else
      # pg_restore は軽微な警告でも exit 1 を返す。
      # "pg_restore: error:" で始まる行が 0 件なら警告のみ → 成功扱い。
      local fatal_count
      fatal_count=$(grep -c "^pg_restore: error:" "$restore_stderr" || true)
      if [[ "$fatal_count" -eq 0 ]]; then
        restore_ok=true
        [[ "${RDC_VERBOSE:-}" == "true" || "${RDC_VERBOSE:-}" == "1" ]] && \
          cat "$restore_stderr" >&2 || true
      else
        # 致命的エラーあり: stderr を表示して原因のヒントを追加する
        cat "$restore_stderr" >&2
        # バージョン不一致の場合は具体的な対処法を案内する
        if grep -q "unsupported version" "$restore_stderr"; then
          local dump_ver docker_pg_ver
          dump_ver=$(grep -oE "\([0-9]+\.[0-9]+\)" "$restore_stderr" | head -1 || true)
          docker_pg_ver=$(cd "$compose_dir" && \
            docker compose exec -T db pg_restore --version 2>/dev/null | \
            grep -oE "[0-9]+\.[0-9]+" | head -1 || echo "unknown")
          echo "ERROR: pg_restore version mismatch." >&2
          echo "  Dump format version: ${dump_ver:-unknown}" >&2
          echo "  pg_restore version in container: ${docker_pg_ver}" >&2
          echo "  The dump was created with a newer PostgreSQL than the Docker container." >&2
          echo "  Solution: Change the db service image in docker-compose.yml to a newer" >&2
          echo "    PostgreSQL version and re-run generate + prepare-db, OR" >&2
          echo "    dump the source DB using pg_dump from the same PG version as the container." >&2
        fi
      fi
    fi
    rm -f "$restore_stderr"

    # Plain SQL format fallback (--import-from でテキスト形式ダンプを渡した場合)
    if [[ "$restore_ok" != "true" ]]; then
      local psql_rc=0
      (cd "$compose_dir" && cat "$dump_path" | \
          docker compose exec -T db psql -U redmine -d redmine) \
          >/dev/null 2>&1 || psql_rc=$?
      if [[ "$psql_rc" -eq 0 ]]; then
        restore_ok=true
      fi
    fi

    if [[ "$restore_ok" != "true" ]]; then
      logger_error "Dump restore failed. Run with -v for details."
      return 1
    fi
  else
    logger_error "docker-compose.yml not found. Run 'generate' first."
    return 1
  fi
  return 0
}

# prepare_db_service_initialize_fresh_db()
# 空 DB 準備を行う（DB コンテナを起動するだけで migration は migrate に委ねる）
# args: workspace_path
prepare_db_service_initialize_fresh_db() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    logger_info "Mock: skipping fresh DB initialization (RDC_ALLOW_MOCK=1)"
    return 0
  fi

  logger_info "Initializing fresh database..."

  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    logger_error "compose/docker-compose.yml not found. Run 'generate' first."
    return 1
  fi

  if ! (cd "$compose_dir" && docker compose up -d --force-recreate db); then
    logger_error "Failed to start DB container. Check docker compose logs for details."
    return 1
  fi
  local retries=0
  while ! (cd "$compose_dir" && docker compose exec -T db pg_isready -U redmine -d redmine) 2>/dev/null; do
    ((retries++))
    [[ $retries -gt 12 ]] && { logger_error "DB container did not become ready."; return 1; }
    sleep 5
  done
  return 0
}

# prepare_db_service_mark_skip_with_reason()
# --skip --reason 実行時の補助状態を保存する
# args: workspace_path, reason
prepare_db_service_mark_skip_with_reason() {
  local workspace_path="${1:?workspace_path required}"
  local reason="${2:?reason required}"
  local skipped_at
  skipped_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

  state_store_save_many "$workspace_path" \
    "fresh_db_selected=false" \
    "import_mode=skip" \
    "import_skip_reason=${reason}" \
    "import_skipped_at=${skipped_at}"

  logger_info "prepare-db --skip recorded with reason: $reason"
}

# prepare_db_service_prepare_from_external_db()
# .rdc_state の redmine_root から database.yml を読み取り、外部 PostgreSQL から pg_dump → compose db へリストアする
# args: workspace_path
# returns: exit_code
prepare_db_service_prepare_from_external_db() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"

  local redmine_root="${RDC_STATE_redmine_root:-}"
  if [[ -z "$redmine_root" ]]; then
    logger_error "--from-external-db requires redmine_root in .rdc_state. This option is only available in passenger mode."
    echo "ERROR: External DB connection info not found. --from-external-db is only available in passenger mode." >&2
    echo "Hint: redmine_root was not set during 'init'. Check that you used --mode passenger." >&2
    return 1
  fi

  local db_yml="$redmine_root/config/database.yml"
  if [[ ! -f "$db_yml" ]]; then
    logger_error "database.yml not found: $db_yml"
    echo "ERROR: database.yml not found at: $db_yml" >&2
    return 1
  fi

  local db_name db_user db_host db_password
  db_name=$(grep -A10 "^production:" "$db_yml" | grep "^\s*database:" | head -1 | awk '{print $2}' | tr -d '"' || echo "redmine")
  db_user=$(grep -A10 "^production:" "$db_yml" | grep "^\s*username:" | head -1 | awk '{print $2}' | tr -d '"' || echo "postgres")
  db_host=$(grep -A10 "^production:" "$db_yml" | grep "^\s*host:" | head -1 | awk '{print $2}' | tr -d '"' || echo "localhost")
  db_password=$(grep -A10 "^production:" "$db_yml" | grep "^\s*password:" | head -1 | awk '{print $2}' | tr -d "\"'" || true)

  [[ -z "$db_name" ]] && db_name="redmine"
  [[ -z "$db_user" ]] && db_user="postgres"
  [[ -z "$db_host" ]] && db_host="localhost"
  [[ "$db_password" == "~" || "$db_password" == "null" || "$db_password" == "Null" ]] && db_password=""

  local ts
  ts=$(date +"%Y%m%d-%H%M%S")
  local dump_filename="external_db_${db_name}_${ts}.dump"
  local dump_path="$workspace_path/dbdump/$dump_filename"
  mkdir -p "$workspace_path/dbdump"

  logger_info "Dumping external DB: $db_name@$db_host as $db_user"

  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    logger_info "Mock: skipping external pg_dump + restore (RDC_ALLOW_MOCK=1)"
    touch "$dump_path"
    return 0
  fi

  # Try pg_dump with password if available, fallback to sudo -u postgres
  local dump_ok=false
  if [[ -n "$db_password" ]]; then
    if PGPASSWORD="$db_password" pg_dump -h "$db_host" -U "$db_user" -Fc "$db_name" -f "$dump_path" 2>/dev/null; then
      dump_ok=true
    fi
  else
    if pg_dump -h "$db_host" -U "$db_user" -Fc "$db_name" -f "$dump_path" 2>/dev/null; then
      dump_ok=true
    fi
  fi
  if [[ "$dump_ok" != "true" ]]; then
    if sudo -u postgres pg_dump -h "$db_host" -Fc "$db_name" 2>/dev/null > "$dump_path"; then
      dump_ok=true
    fi
  fi

  if [[ "$dump_ok" != "true" ]]; then
    rm -f "$dump_path"
    logger_error "pg_dump from external DB failed."
    echo "ERROR: pg_dump failed for $db_name@$db_host. Check DB access and credentials." >&2
    return 1
  fi

  logger_info "Restoring dump from external DB: $dump_filename"
  prepare_db_service_restore_dump "$dump_path" "$workspace_path" || return 1

  logger_info "External DB dump and restore completed."
  return 0
}

# prepare_db_service_ensure_preconditions()
# prepare-db に必要な前提（generate 完了）が満たされているか確認する
# args: workspace_path
prepare_db_service_ensure_preconditions() {
  local workspace_path="${1:?workspace_path required}"

  local gen_status="${RDC_STATE_generate_status:-pending}"
  if [[ "$gen_status" != "done" ]]; then
    logger_error "generate has not been completed. Run 'generate' first."
    echo "ERROR: generate must be completed before prepare-db." >&2
    echo "Run: redmine-docker-workspace generate" >&2
    return 1
  fi
  return 0
}

# prepare_db_service_ensure_redmine_not_running()
# Redmine コンテナが実行中ではないことを確認する
# args: workspace_path
prepare_db_service_ensure_redmine_not_running() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"

  if [[ "${RDC_MOCK_REDMINE_RUNNING:-}" == "true" ]]; then
    logger_error "Redmine container is running. Run 'docker compose down' in $compose_dir first."
    return 1
  fi
  if [[ "${RDC_MOCK_REDMINE_RUNNING:-}" == "false" ]]; then
    return 0
  fi
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    return 0
  fi

  if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
    return 0
  fi

  if (cd "$compose_dir" && docker compose ps redmine 2>/dev/null | grep -q "Up"); then
    logger_error "Redmine container is running. Database operations cannot proceed while app is active."
    local _container_id _container_ws
    _container_id=$(cd "$compose_dir" && docker compose ps -q redmine 2>/dev/null | head -1 || true)
    if [[ -n "$_container_id" ]]; then
      _container_ws=$(docker inspect "$_container_id" \
        --format '{{index .Config.Labels "io.github.futuremine-tech.rdc.workspace-path"}}' \
        2>/dev/null || true)
    fi
    if [[ -n "${_container_ws:-}" && "$_container_ws" != "$workspace_path" ]]; then
      echo "ERROR: The running container belongs to a different workspace:" >&2
      echo "  $_container_ws" >&2
      echo "Stop it with:" >&2
      echo "  docker compose down   # run in $_container_ws" >&2
    else
      echo "ERROR: Redmine container must be stopped:" >&2
      echo "  docker compose down" >&2
    fi
    echo "Then retry 'prepare-db'." >&2
    return 1
  fi
  return 0
}

# prepare_db_service_confirm_destructive_reprepare_db()
# 逆行再 prepare-db 時に確認プロンプトを制御する
# args: workspace_path
prepare_db_service_confirm_destructive_reprepare_db() {
  local workspace_path="${1:?workspace_path required}"

  local prev_check="${RDC_STATE_check_status:-pending}"
  if [[ "$prev_check" != "done" ]]; then
    return 0
  fi

  if [[ "${RDC_FORCE:-}" == "true" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    logger_error "Destructive reprepare-db in non-interactive mode requires --force flag."
    echo "ERROR: This operation would invalidate the current check status." >&2
    echo "In non-interactive environments, use --force to proceed:" >&2
    echo "  redmine-docker-workspace prepare-db --force ..." >&2
    return 1
  fi

  echo "WARNING: This will prepare DB again and invalidate check status." >&2
  read -p "Proceed with prepare-db? [y/N] " -n 1 -r -e
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    logger_info "prepare-db cancelled by user."
    return 1
  fi
  return 0
}

# prepare_db_service_target_image_exists()
# 次手順案内のため、target image が利用可能かを判定する
# args: workspace_path
# returns: 0 if image exists and is current enough, 1 otherwise
prepare_db_service_target_image_exists() {
  local workspace_path="${1:?workspace_path required}"

  # Reuse status判定が利用可能なら同じロジックを使う
  if declare -F status_service_check_target_image_exists > /dev/null; then
    status_service_check_target_image_exists "$workspace_path"
    return $?
  fi

  local compose_file="$workspace_path/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    return 1
  fi

  local image_name
  image_name=$(awk '
    /^  redmine:/ { in_svc=1; next }
    /^  [a-zA-Z_]/ { in_svc=0 }
    in_svc && /image:/ {
      sub(/.*image:[[:space:]]*/, "")
      gsub(/"/, "")
      print; exit
    }
  ' "$compose_file" 2>/dev/null || true)

  if [[ -z "$image_name" ]]; then
    image_name="$(basename "$workspace_path")-redmine"
  fi

  docker image inspect "$image_name" > /dev/null 2>&1
}
