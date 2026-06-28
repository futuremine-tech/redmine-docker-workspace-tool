#!/usr/bin/env bash
# lib/rdc/status_service.bash
# .rdc_state 読み取り、ステップ一覧表示、次アクション案内を担う Service（読み取り専用）
# 根拠要件: RDC-REQ-F1001〜RDC-REQ-F1005, RDC-REQ-F0814, RDC-REQ-F0920〜F0923

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"

# status_service_run()
# status サブコマンド全体を実行する（読み取り専用：.rdc_state を変更しない）
# args: argv...
# returns: exit_code
status_service_run() {
  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: redmine-docker-workspace status"
        echo ""
        echo "Display workspace step status and next recommended action."
        return 0
        ;;
      -v|--verbose) export RDC_VERBOSE=true ;;
    esac
  done

  if [[ ! -f "$workspace/.rdc_state" ]]; then
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  fi

  local clean_status
  clean_status=$(grep "^clean_status=" "$workspace/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
  if [[ "$clean_status" == "done" ]]; then
    echo "Workspace has been cleaned. Run 'init' to re-initialize." >&2
    return 1
  fi

  state_store_load "$workspace"
  status_service_load_and_display_steps "$workspace"
  echo ""
  status_service_list_plugins "$workspace"
  echo ""
  status_service_resolve_next_action "$workspace"
  return 0
}

# status_service_display_after_subcommand()
# 他 Service が成功終了時に呼び出す薄いラッパー。status と同一のステップ一覧 +
# プラグイン一覧 + 次アクション表示を行い、.rdc_state は変更しない（読み取り専用）。
# args: workspace_path
status_service_display_after_subcommand() {
  local workspace="${1:?workspace_path required}"
  state_store_load "$workspace"
  echo ""
  status_service_load_and_display_steps "$workspace"
  echo ""
  status_service_list_plugins "$workspace"
  echo ""
  status_service_resolve_next_action "$workspace"
  return 0
}

# status_service_check_docker_daemon_reachable()
# Docker デーモンへの疎通を確認する。image/compose 確認系の関数は、実際に
# docker コマンドを呼び出す直前にこの結果を確認し、疎通不可なら pending/stopped
# ではなく unknown（exit code 2）を返す。
# returns: 0 if reachable, 1 if not
status_service_check_docker_daemon_reachable() {
  if [[ "${RDC_MOCK_DOCKER_DAEMON_REACHABLE:-}" == "true" ]]; then return 0; fi
  if [[ "${RDC_MOCK_DOCKER_DAEMON_REACHABLE:-}" == "false" ]]; then return 1; fi
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then return 0; fi
  command -v docker > /dev/null 2>&1 || return 1
  docker info > /dev/null 2>&1
}

# status_service_load_and_display_steps()
# .rdc_state の各ステップ状態を整形して標準出力へ出力する
# args: workspace_path
status_service_load_and_display_steps() {
  local workspace_path="${1:?workspace_path required}"

  local mode="${RDC_STATE_mode:-}"
  local product="${RDC_STATE_product:-}"
  local tag="${RDC_STATE_target_image_tag:-}"
  local image_ref="${RDC_STATE_image_ref:-}"
  local image_source="${RDC_STATE_image_source:-}"
  local generate_display="${RDC_STATE_generate_status:-pending}"
  local prepare_db_display="${RDC_STATE_import_status:-pending}"
  local migrate_display="${RDC_STATE_migrate_status:-pending}"
  local check_display="${RDC_STATE_check_status:-pending}"

  echo "=== Workspace Status ==="
  echo "mode:    ${mode}"
  if [[ "$image_source" == "explicit" ]]; then
    echo "image:   ${image_ref} (explicit)"
  elif [[ -n "$product" ]]; then
    echo "product: ${product}:${tag}"
  fi
  echo ""
  # External manual steps (reference only)
  local build_state="n/a"
  local up_state="n/a"
  local runtime_state="stopped"
  local runtime_names=""
  if [[ "${RDC_STATE_generate_status:-pending}" == "done" ]]; then
    local image_check_rc=0
    status_service_check_target_image_exists "$workspace_path" || image_check_rc=$?
    case "$image_check_rc" in
      0) build_state="done" ;;
      2) build_state="unknown (Docker daemon unreachable)" ;;
      *) build_state="pending" ;;
    esac
  fi
  if [[ "${RDC_STATE_migrate_status:-pending}" == "done" || "${RDC_STATE_check_status:-pending}" == "done" ]]; then
    local compose_running_rc=0
    status_service_check_compose_running "$workspace_path" || compose_running_rc=$?
    case "$compose_running_rc" in
      0) up_state="done" ;;
      2) up_state="unknown (Docker daemon unreachable)" ;;
      *) up_state="pending" ;;
    esac
  fi

  local runtime_rc=0
  runtime_names="$(status_service_get_compose_running_names "$workspace_path")" || runtime_rc=$?
  if [[ "$runtime_rc" -eq 2 ]]; then
    runtime_state="unknown (Docker daemon unreachable)"
  elif [[ -n "$runtime_names" ]]; then
    runtime_state="running"
  fi

  # If the current image is stale against the latest generate output, downstream migrate/check must be rerun.
  if [[ "$build_state" == "pending" && "$prepare_db_display" == "done" ]]; then
    migrate_display="pending"
    check_display="pending"
  fi

  local deployment_build="${RDC_STATE_deployment_build:-false}"
  local generate_suffix=""
  if [[ "$deployment_build" == "true" ]]; then
    generate_suffix=" [deployment build]"
  fi

  echo "Steps:"
  printf "  %-12s %s\n" "init"     "${RDC_STATE_init_status:-pending}"
  printf "  %-12s %s%s\n" "generate" "$generate_display" "$generate_suffix"
  printf "  %-12s %s\n" "prepare-db" "$prepare_db_display"
  printf "  %-12s %s\n" "migrate"  "$migrate_display"
  printf "  %-12s %s\n" "check"    "$check_display"

  echo ""
  echo "External (reference):"
  printf "  %-12s %s\n" "compose build" "$build_state"
  printf "  %-12s %s\n" "compose up -d" "$up_state"
  if [[ -n "$runtime_names" ]]; then
    printf "  %-12s %s (%s)\n" "compose runtime" "$runtime_state" "$runtime_names"
  else
    printf "  %-12s %s\n" "compose runtime" "$runtime_state"
  fi
}

# status_service_resolve_next_action()
# 現在の .rdc_state から次に実行すべき手順の文字列を返す
# args: workspace_path
# stdout: next action guidance string
# returns: 0 always (read-only, no side effects)
status_service_resolve_next_action() {
  local workspace_path="${1:?workspace_path required}"

  local init_status="${RDC_STATE_init_status:-pending}"
  local generate_status="${RDC_STATE_generate_status:-pending}"
  local prepare_db_status="${RDC_STATE_import_status:-pending}"
  local migrate_status="${RDC_STATE_migrate_status:-pending}"
  local check_status="${RDC_STATE_check_status:-pending}"
  local build_ready="false"

  echo "--- Next Action ---"

  # Stage 1: init not done
  if [[ "$init_status" != "done" ]]; then
    echo "Run: redmine-docker-workspace init [--mode MODE] ..."
    return 0
  fi

  # Stage 2: generate not done
  if [[ "$generate_status" != "done" ]]; then
    echo "Run: redmine-docker-workspace generate"
    return 0
  fi

  # Build state check (used below as a secondary gate)
  local image_check_rc=0
  status_service_check_target_image_exists "$workspace_path" || image_check_rc=$?
  if [[ "$image_check_rc" -eq 2 ]]; then
    echo "Docker デーモンに接続できません。Docker を起動してから再実行してください。"
    return 0
  fi
  if [[ "$image_check_rc" -eq 0 ]]; then
    build_ready="true"
  fi

  # Stage 3: prepare-db not done → show prepare-db options first; hint docker compose build next
  if [[ "$prepare_db_status" != "done" ]]; then
    local mode="${RDC_STATE_mode:-}"
    echo "Run one of:"
    echo "  redmine-docker-workspace prepare-db --import-from PATH"
    echo "  redmine-docker-workspace prepare-db --fresh-db"
    if [[ "$mode" == "passenger" ]]; then
      echo "  redmine-docker-workspace prepare-db --from-external-db"
    fi
    echo "  redmine-docker-workspace prepare-db --skip --reason TEXT"
    echo "Then: docker compose build (in $workspace_path)"
    return 0
  fi

  # Stage 4: prepare-db done, build not done
  if [[ "$build_ready" != "true" ]]; then
    echo "Run: docker compose build (in $workspace_path), then: redmine-docker-workspace migrate"
    return 0
  fi

  # Stage 4b: build done but plugins changed after image was built
  if status_service_check_build_needed_by_plugins "$workspace_path"; then
    echo "Warning: plugins have been changed after the image was built."
    echo "Run: docker compose build (in $workspace_path), then: redmine-docker-workspace migrate"
    return 0
  fi

  # Stage 5: prepare-db done, build done, migrate not done
  if [[ "$migrate_status" != "done" ]]; then
    echo "Run: redmine-docker-workspace migrate"
    return 0
  fi

  # Stage 8: migrate done, check not done
  if [[ "$check_status" != "done" ]]; then
    local compose_running_rc=0
    status_service_check_compose_running "$workspace_path" || compose_running_rc=$?
    if [[ "$compose_running_rc" -eq 2 ]]; then
      echo "Docker デーモンに接続できません。Docker を起動してから再実行してください。"
    elif [[ "$compose_running_rc" -eq 0 ]]; then
      echo "Run: redmine-docker-workspace check"
    else
      echo "Run: docker compose up -d (in $workspace_path), then: redmine-docker-workspace check"
    fi
    return 0
  fi

  # Stage 9: all done
  echo "完了 (complete): All steps finished."
  local bind="${RDC_STATE_redmine_bind:-127.0.0.1:38080}"
  local relative_url_root="${RDC_STATE_relative_url_root:-}"
  echo "Redmine is running at: http://${bind}${relative_url_root}/"
  return 0
}

# status_service_check_compose_running()
# redmine サービスが起動中かどうかを確認する
# args: workspace_path
# returns: 0 if running, 1 if not
status_service_check_compose_running() {
  local workspace_path="${1:?workspace_path required}"
  local compose_file="$workspace_path/docker-compose.yml"

  if [[ -n "${RDC_MOCK_REDMINE_RUNNING:-}" ]]; then
    [[ "${RDC_MOCK_REDMINE_RUNNING}" == "true" ]]
    return $?
  fi

  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "true" ]]; then return 0; fi
  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "false" ]]; then return 1; fi

  if [[ ! -f "$compose_file" ]]; then return 1; fi

  if ! status_service_check_docker_daemon_reachable; then return 2; fi

  local project_name
  project_name="$(basename "$workspace_path")"

  cd "$workspace_path" && \
    docker ps \
      --filter "label=com.docker.compose.project=${project_name}" \
      --filter "label=com.docker.compose.service=redmine" \
      --filter "status=running" \
      --format '{{.Names}}' 2>/dev/null | grep -q .
}

# status_service_get_compose_running_names()
# compose プロジェクト配下で起動中コンテナ名の一覧を返す
# args: workspace_path
# stdout: comma-separated container names, empty if none
status_service_get_compose_running_names() {
  local workspace_path="${1:?workspace_path required}"
  local compose_file="$workspace_path/docker-compose.yml"

  if [[ -n "${RDC_MOCK_COMPOSE_RUNNING_NAMES:-}" ]]; then
    echo "${RDC_MOCK_COMPOSE_RUNNING_NAMES}"
    return 0
  fi

  if [[ -n "${RDC_MOCK_COMPOSE_ANY_RUNNING:-}" ]]; then
    if [[ "${RDC_MOCK_COMPOSE_ANY_RUNNING}" == "true" ]]; then
      echo "mock-compose-container"
    fi
    return 0
  fi

  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "true" ]]; then
    echo "mock-redmine-container"
    return 0
  fi
  if [[ "${RDC_MOCK_COMPOSE_RUNNING:-}" == "false" ]]; then
    return 0
  fi

  if [[ ! -f "$compose_file" ]]; then
    return 0
  fi

  if ! status_service_check_docker_daemon_reachable; then return 2; fi

  local project_name
  project_name="$(basename "$workspace_path")"

  cd "$workspace_path" && \
    docker ps \
      --filter "label=com.docker.compose.project=${project_name}" \
      --filter "status=running" \
      --format '{{.Names}}' 2>/dev/null | paste -sd ', ' -
}

# status_service_check_target_image_exists()
# compose 定義から target image 名を取得し、generate 完了後に build されたかを確認する
# args: workspace_path
# returns: 0 if image exists, 1 if not
status_service_check_target_image_exists() {
  local workspace_path="${1:?workspace_path required}"

  local generate_completed_at
  generate_completed_at=$(grep "^generate_completed_at=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)

  # generate の完了時刻が残っていない古い state は build 未確認として扱う
  if [[ -z "$generate_completed_at" ]]; then
    return 1
  fi

  if [[ "${RDC_MOCK_IMAGE_EXISTS:-}" == "true" ]]; then
    if [[ -n "${RDC_MOCK_IMAGE_GENERATE_ID:-}" ]]; then
      [[ "${RDC_MOCK_IMAGE_GENERATE_ID}" == "$generate_completed_at" ]]
      return $?
    fi
    if [[ -z "${RDC_MOCK_IMAGE_CREATED_AT:-}" ]]; then
      return 0
    fi
    local mock_created_epoch mock_generate_epoch
    mock_created_epoch=$(date -d "${RDC_MOCK_IMAGE_CREATED_AT}" +%s 2>/dev/null || echo "")
    mock_generate_epoch=$(date -d "${generate_completed_at}" +%s 2>/dev/null || echo "")
    [[ -n "$mock_created_epoch" && -n "$mock_generate_epoch" && "$mock_created_epoch" -ge "$mock_generate_epoch" ]]
    return $?
  fi
  if [[ "${RDC_MOCK_IMAGE_EXISTS:-}" == "false" ]]; then
    return 1
  fi

  local compose_file="$workspace_path/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    return 1
  fi

  if ! status_service_check_docker_daemon_reachable; then return 2; fi

  # Extract image name from the redmine service block specifically
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
    # Fallback: build: service without image:, derive name from workspace dir
    image_name="$(basename "$workspace_path")-redmine"
  fi

  if ! docker image inspect "$image_name" > /dev/null 2>&1; then
    return 1
  fi

  local image_generate_id
  image_generate_id=$(docker image inspect --format '{{ index .Config.Labels "io.github.futuremine-tech.rdc.generate-id" }}' "$image_name" 2>/dev/null || true)
  if [[ -n "$image_generate_id" ]]; then
    [[ "$image_generate_id" == "$generate_completed_at" ]]
    return $?
  fi

  local image_created_at image_created_epoch generate_epoch
  image_created_at=$(docker image inspect --format '{{.Created}}' "$image_name" 2>/dev/null || true)
  image_created_epoch=$(date -d "$image_created_at" +%s 2>/dev/null || echo "")
  generate_epoch=$(date -d "$generate_completed_at" +%s 2>/dev/null || echo "")
  [[ -n "$image_created_epoch" && -n "$generate_epoch" && "$image_created_epoch" -ge "$generate_epoch" ]]
}

# status_service_check_target_image_fresh()
# Check if the built image was generated after the Dockerfile was last modified
# 要件: F0814A - target-image-fresh flag in status output
# args: workspace_path
# output: "true" if image is fresh, "false" if stale
# returns: 0 always
status_service_check_target_image_fresh() {
  local workspace_path="${1:?workspace_path required}"
  local compose_dir="$workspace_path"
  
  # Mock support for tests
  if [[ "${RDC_MOCK_IMAGE_FRESH:-}" == "true" ]]; then
    echo "true"
    return 0
  fi
  if [[ "${RDC_MOCK_IMAGE_FRESH:-}" == "false" ]]; then
    echo "false"
    return 0
  fi
  
  # Global mock: return true in test environments
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    echo "true"
    return 0
  fi
  
  if [[ ! -f "$compose_dir/docker-compose.yml" || ! -f "$compose_dir/Dockerfile" ]]; then
    echo "false"
    return 0
  fi
  
  # Get Dockerfile mtime
  local dockerfile_mtime
  dockerfile_mtime=$( stat -c '%Y' "$compose_dir/Dockerfile" 2>/dev/null || stat -f '%m' "$compose_dir/Dockerfile" 2>/dev/null || echo "0" )
  
  # Get image creation timestamp
  local project_name
  project_name="$(basename "$workspace_path")"
  local image_name="${project_name}-redmine"
  
  local image_created
  image_created=$( docker inspect -f '{{.Created}}' "$image_name" 2>/dev/null | xargs -I {} date -d {} +%s 2>/dev/null || echo "0" )
  
  if [[ "$image_created" > "$dockerfile_mtime" ]]; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# status_service_list_plugins()
# plugins/ ディレクトリを走査し、追跡情報あり・[manual] を区別してプラグイン一覧を表示する
# args: workspace_path
status_service_list_plugins() {
  local workspace_path="${1:?workspace_path required}"
  local plugins_dir="$workspace_path/plugins"

  echo "Plugins:"
  if [[ ! -d "$plugins_dir" ]]; then
    echo "  (no plugins installed)"
    return 0
  fi

  local count=0
  while IFS= read -r plugin_dir; do
    count=$((count + 1))
    local plugin_name
    plugin_name="$(basename "$plugin_dir")"
    local sidecar="$workspace_path/.rdc_plugins/$plugin_name"
    if [[ -f "$sidecar" ]]; then
      local git_url ref
      git_url=$(grep "^git_url=" "$sidecar" 2>/dev/null | cut -d= -f2- || true)
      ref=$(grep "^ref=" "$sidecar" 2>/dev/null | cut -d= -f2- || true)
      if [[ -n "$ref" ]]; then
        printf "  %-30s %s (ref: %s)\n" "$plugin_name" "$git_url" "$ref"
      else
        printf "  %-30s %s\n" "$plugin_name" "$git_url"
      fi
    else
      printf "  %-30s [manual]\n" "$plugin_name"
    fi
  done < <(find "$plugins_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

  if [[ "$count" -eq 0 ]]; then
    echo "  (no plugins installed)"
  fi
}

# status_service_check_build_needed_by_plugins()
# plugins_last_changed がイメージのビルド時刻より新しい場合に true を返す
# args: workspace_path
# returns: 0 if rebuild needed, 1 otherwise
status_service_check_build_needed_by_plugins() {
  local workspace_path="${1:?workspace_path required}"

  local plugins_last_changed
  plugins_last_changed=$(grep "^plugins_last_changed=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
  [[ -z "$plugins_last_changed" ]] && return 1

  # Mock: use RDC_MOCK_IMAGE_GENERATE_ID as the image build timestamp (simulates .Created)
  if [[ "${RDC_MOCK_IMAGE_EXISTS:-}" == "true" ]]; then
    local image_ts="${RDC_MOCK_IMAGE_GENERATE_ID:-}"
    [[ -z "$image_ts" ]] && return 1
    [[ "$plugins_last_changed" > "$image_ts" ]]
    return $?
  fi
  if [[ "${RDC_MOCK_IMAGE_EXISTS:-}" == "false" ]]; then
    return 1
  fi

  # Real: get generate-id label from docker image
  if ! status_service_check_docker_daemon_reachable 2>/dev/null; then return 1; fi

  local compose_file="$workspace_path/docker-compose.yml"
  [[ ! -f "$compose_file" ]] && return 1

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
  [[ -z "$image_name" ]] && image_name="$(basename "$workspace_path")-redmine"

  if ! docker image inspect "$image_name" > /dev/null 2>&1; then return 1; fi

  # generate-id ラベルはイメージが generate 後にビルドされたかを示すが、
  # プラグイン追加後のリビルド確認にはイメージの実際の作成時刻を使う必要がある。
  # generate-id はビルド時刻ではなく generate 実行時刻なので、
  # プラグイン追加（generate より後）と比較すると常に「再ビルド必要」になってしまう。
  local image_created_at plugins_epoch image_epoch
  image_created_at=$(docker image inspect --format '{{.Created}}' "$image_name" 2>/dev/null || true)
  [[ -z "$image_created_at" ]] && return 1
  plugins_epoch=$(date -d "$plugins_last_changed" +%s 2>/dev/null || echo "")
  image_epoch=$(date -d "$image_created_at" +%s 2>/dev/null || echo "")
  [[ -n "$plugins_epoch" && -n "$image_epoch" && "$plugins_epoch" -gt "$image_epoch" ]]
}
