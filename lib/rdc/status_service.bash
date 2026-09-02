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
  local json_mode=false
  for arg in "$@"; do
    [[ "$arg" == "--json" ]] && json_mode=true
  done

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    if [[ "$json_mode" == "true" ]]; then
      status_service_render_error_json "workspace_not_initialized" "Workspace not initialized. Run 'init' to start."
    else
      echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    fi
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: redmine-docker-workspace status [--json]"
        echo ""
        echo "Display workspace step status and next recommended action."
        echo ""
        echo "Options:"
        echo "  --json    Output the same information (steps, external state, next action) in JSON format"
        return 0
        ;;
      -v|--verbose) export RDC_VERBOSE=true ;;
    esac
  done

  if [[ ! -f "$workspace/.rdc_state" ]]; then
    if [[ "$json_mode" == "true" ]]; then
      status_service_render_error_json "workspace_not_initialized" "Workspace not initialized. Run 'init' to start."
    else
      echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    fi
    return 1
  fi

  local clean_status
  clean_status=$(grep "^clean_status=" "$workspace/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
  if [[ "$clean_status" == "done" ]]; then
    if [[ "$json_mode" == "true" ]]; then
      status_service_render_error_json "workspace_not_initialized" "Workspace has been cleaned. Run 'init' to re-initialize."
    else
      echo "Workspace has been cleaned. Run 'init' to re-initialize." >&2
    fi
    return 1
  fi

  status_service_check_docker_daemon_reachable || {
    if [[ "$json_mode" == "true" ]]; then
      status_service_render_error_json "docker_daemon_unreachable" "Docker デーモンに接続できません。Docker を起動してから再実行してください。"
    else
      echo "ERROR: Docker デーモンに接続できません。Docker を起動してから再実行してください。" >&2
    fi
    return 1
  }

  state_store_load "$workspace"

  if [[ "$json_mode" == "true" ]]; then
    status_service_render_json "$workspace"
    return 0
  fi

  status_service_load_and_display_steps "$workspace"
  status_service_display_rootless_warning
  echo ""
  status_service_list_plugins "$workspace"
  echo ""
  status_service_list_themes "$workspace"
  echo ""
  status_service_resolve_next_action "$workspace"
  return 0
}

# status_service_display_after_subcommand()
# 他 Service が成功終了時に呼び出す薄いラッパー。status と同一のステップ一覧 +
# プラグイン一覧 + テーマ一覧 + 次アクション表示を行い、.rdc_state は変更しない（読み取り専用）。
# args: workspace_path
status_service_display_after_subcommand() {
  local workspace="${1:?workspace_path required}"
  state_store_load "$workspace"
  echo ""
  status_service_load_and_display_steps "$workspace"
  status_service_display_rootless_warning
  echo ""
  status_service_list_plugins "$workspace"
  echo ""
  status_service_list_themes "$workspace"
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

# docker_is_rootless()
# 現在使用している Docker デーモンが rootless モードで動作しているかを判定する
# (RDC-REQ-F1010)。rootless Docker では `docker info` の SecurityOptions に
# "name=rootless" が含まれる（docs.docker.com/engine/security/rootless/）。
# RDC_ALLOW_MOCK=1 のみ指定時は、rootful を前提とした既存テストとの後方互換のため
# rootful (1) を返す。
# returns: 0 if rootless, 1 if rootful (or undetermined)
docker_is_rootless() {
  if [[ "${RDC_MOCK_DOCKER_ROOTLESS:-}" == "true" ]]; then return 0; fi
  if [[ "${RDC_MOCK_DOCKER_ROOTLESS:-}" == "false" ]]; then return 1; fi
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then return 1; fi
  docker info --format '{{json .SecurityOptions}}' 2> /dev/null | grep -q '"name=rootless"'
}

# status_service_display_rootless_warning()
# rootful Docker使用時に、docker グループ所属等によるセキュリティ上のリスクがある旨を
# 警告する (RDC-REQ-F1010)。Docker デーモンに疎通できない場合は rootful/rootless の
# 判定ができないため、何も表示しない。
# args: (none)
status_service_display_rootless_warning() {
  status_service_check_docker_daemon_reachable || return 0
  docker_is_rootless && return 0
  echo "Warning: Docker is running in rootful mode. Members of the 'docker' group effectively have root-equivalent access to this host."
  echo "Consider switching to rootless Docker: https://docs.docker.com/engine/security/rootless/"
}

# status_service_load_and_display_steps()
# .rdc_state の各ステップ状態を整形して標準出力へ出力する
# args: workspace_path
status_service_load_and_display_steps() {
  local workspace_path="${1:?workspace_path required}"

  local mode="${RDC_STATE_mode:-}"
  local base_image_tag="${RDC_STATE_base_image_tag:-}"
  local generate_display="${RDC_STATE_generate_status:-pending}"
  local prepare_db_display="${RDC_STATE_import_status:-pending}"
  local migrate_display="${RDC_STATE_migrate_status:-pending}"
  local check_display="${RDC_STATE_check_status:-pending}"

  echo "=== Workspace Status ==="
  echo "mode:    ${mode}"
  if [[ -n "$base_image_tag" ]]; then
    echo "image:   ${base_image_tag}"
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

  # Stage 4c: build done but themes changed after image was built (RDC-REQ-F1009)
  if status_service_check_build_needed_by_themes "$workspace_path"; then
    echo "Warning: themes have been added or updated after the image was built."
    echo "Run: docker compose build && docker compose up -d (in $workspace_path)"
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

  # Stage 9: all done (RDC-REQ-F1442: check_status=done は「過去に検証成功した」という
  # 履歴フラグに過ぎないため、完了と案内する前に現在の起動状態を確認する)
  local compose_running_rc=0
  status_service_check_compose_running "$workspace_path" || compose_running_rc=$?
  if [[ "$compose_running_rc" -eq 2 ]]; then
    echo "Docker デーモンに接続できません。Docker を起動してから再実行してください。"
    return 0
  fi
  if [[ "$compose_running_rc" -ne 0 ]]; then
    echo "All pipeline steps are complete, but Redmine is not currently running."
    echo "Run: docker compose up -d (in $workspace_path)"
    return 0
  fi

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

# status_service_get_target_image_name()
# docker-compose.yml の redmine サービスから image 名を抽出する（Docker非依存）。
# 抽出できない場合は workspace basename からのフォールバック名を返す。
# args: workspace_path
# stdout: image name
# returns: 0 always
status_service_get_target_image_name() {
  local workspace_path="${1:?workspace_path required}"
  local compose_file="$workspace_path/docker-compose.yml"

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
  echo "$image_name"
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

  local image_name
  image_name=$(status_service_get_target_image_name "$workspace_path")

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

# status_service_list_themes()
# themes/ ディレクトリを走査し、インストール済みテーマ一覧を表示する (RDC-REQ-F1008)
# args: workspace_path
status_service_list_themes() {
  local workspace_path="${1:?workspace_path required}"
  local themes_dir="$workspace_path/themes"

  echo "Themes:"
  if [[ ! -d "$themes_dir" ]]; then
    echo "  (no themes installed)"
    return 0
  fi

  local count=0
  while IFS= read -r theme_dir; do
    count=$((count + 1))
    local theme_name
    theme_name="$(basename "$theme_dir")"
    printf "  %s\n" "$theme_name"
  done < <(find "$themes_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

  if [[ "$count" -eq 0 ]]; then
    echo "  (no themes installed)"
  fi
}

# status_service_check_build_needed_by_themes()
# workspace/themes/ 配下のファイルがイメージビルド時刻より新しい場合に true を返す (RDC-REQ-F1009)
# テーマ管理 CLI がないため plugins_last_changed のような state 変数は使わず、
# ファイルシステムの mtime を直接参照してイメージビルド時刻と比較する。
# args: workspace_path
# returns: 0 if rebuild needed (themes newer than image), 1 otherwise
status_service_check_build_needed_by_themes() {
  local workspace_path="${1:?workspace_path required}"

  # Mock support for tests
  if [[ "${RDC_MOCK_THEMES_CHANGED:-}" == "true" ]]; then return 0; fi
  if [[ "${RDC_MOCK_THEMES_CHANGED:-}" == "false" ]]; then return 1; fi
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then return 1; fi

  # Redmine 6.x系（themes が public/ 配下でない）のみ対象
  local themes_container_path
  themes_container_path=$(grep "^themes_container_path=" "$workspace_path/.rdc_state" 2>/dev/null | cut -d= -f2- || true)
  if [[ -z "$themes_container_path" || "$themes_container_path" == */public/themes ]]; then
    return 1
  fi

  local themes_dir="$workspace_path/themes"
  if [[ ! -d "$themes_dir" ]]; then return 1; fi

  # themes/ 配下にファイルが存在しない場合はスキップ
  local file_count
  file_count=$(find "$themes_dir" -type f 2>/dev/null | wc -l)
  [[ "${file_count:-0}" -eq 0 ]] && return 1

  if ! status_service_check_docker_daemon_reachable; then return 1; fi

  local compose_file="$workspace_path/docker-compose.yml"
  [[ ! -f "$compose_file" ]] && return 1

  local image_name
  image_name=$(status_service_get_target_image_name "$workspace_path")

  if ! docker image inspect "$image_name" > /dev/null 2>&1; then return 1; fi

  local image_created_at image_epoch theme_mtime
  image_created_at=$(docker image inspect --format '{{.Created}}' "$image_name" 2>/dev/null || true)
  [[ -z "$image_created_at" ]] && return 1
  image_epoch=$(date -d "$image_created_at" +%s 2>/dev/null || echo "")
  [[ -z "$image_epoch" ]] && return 1

  # themes/ 配下全ファイルの最新 mtime（テーマCSS等を確実に捕捉するため深さ制限なし）
  theme_mtime=$(find "$themes_dir" -type f -printf '%T@\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d. -f1 || echo "0")

  [[ -n "$theme_mtime" && "$theme_mtime" -gt "$image_epoch" ]]
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
  image_name=$(status_service_get_target_image_name "$workspace_path")

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

# ---- status --json (RDC-REQ-F1412〜F1414) ----
# 設計: develop/docs/1A-DESIGN-F1415-auto-and-json-outputs.md 2節
#
# status_service_load_and_display_steps() の計算部分（build_state/up_state/runtime_state等の
# 算出）と本節の status_service_collect_step_states() はロジックが並行しているが、実際の判定
# （image存在確認・compose起動確認）自体は status_service_check_target_image_exists() 等の共通
# ヘルパーへ委譲しているため、分岐ロジック自体の二重管理には当たらない
# （次アクション案内は次アクション自体を再構成せずテキストをそのままJSON化しており、こちらは
# 完全に単一情報源。1A-DESIGN 2.2節設計判断2参照）。

# status_service_collect_step_states()
# JSON/人間可読どちらの出力にも使う状態一式を key=value の行として出力する
# args: workspace_path
# stdout: key=value lines
status_service_collect_step_states() {
  local workspace_path="${1:?workspace_path required}"

  local generate_display="${RDC_STATE_generate_status:-pending}"
  local prepare_db_display="${RDC_STATE_import_status:-pending}"
  local migrate_display="${RDC_STATE_migrate_status:-pending}"
  local check_display="${RDC_STATE_check_status:-pending}"

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

  if [[ "$build_state" == "pending" && "$prepare_db_display" == "done" ]]; then
    migrate_display="pending"
    check_display="pending"
  fi

  echo "init=${RDC_STATE_init_status:-pending}"
  echo "generate=${generate_display}"
  echo "prepare-db=${prepare_db_display}"
  echo "migrate=${migrate_display}"
  echo "check=${check_display}"
  echo "compose_build=${build_state}"
  echo "compose_up=${up_state}"
  echo "compose_runtime=${runtime_state}"
}

# status_service_render_steps_json()
# 標準入力（status_service_collect_step_states の出力）から steps/external の
# JSONフラグメントを組み立てる（先頭・末尾に波括弧を持たない、呼び出し側で連結する断片）
# stdin: key=value lines
# stdout: "steps": {...},\n  "external": {...}
status_service_render_steps_json() {
  local init generate prepare_db migrate check compose_build compose_up compose_runtime
  while IFS='=' read -r key value; do
    case "$key" in
      init) init="$value" ;;
      generate) generate="$value" ;;
      prepare-db) prepare_db="$value" ;;
      migrate) migrate="$value" ;;
      check) check="$value" ;;
      compose_build) compose_build="$value" ;;
      compose_up) compose_up="$value" ;;
      compose_runtime) compose_runtime="$value" ;;
    esac
  done

  cat <<EOF
"steps": {
    "init": "${init}",
    "generate": "${generate}",
    "prepare-db": "${prepare_db}",
    "migrate": "${migrate}",
    "check": "${check}"
  },
  "external": {
    "compose_build": "${compose_build}",
    "compose_up": "${compose_up}",
    "compose_runtime": "${compose_runtime}"
  }
EOF
}

# status_service_render_next_action_json()
# resolve_next_action() の出力（見出し行を除く）を JSON 文字列配列として出力する
# args: workspace_path
# stdout: "next_action": {"lines": [...]}
status_service_render_next_action_json() {
  local workspace_path="${1:?workspace_path required}"
  local raw_lines
  raw_lines=$(status_service_resolve_next_action "$workspace_path" | tail -n +2)

  local json_lines="" first=true escaped
  while IFS= read -r line; do
    escaped="${line//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if [[ "$first" == "true" ]]; then
      json_lines="\"${escaped}\""
      first=false
    else
      json_lines="${json_lines}, \"${escaped}\""
    fi
  done <<< "$raw_lines"

  printf '"next_action": {"lines": [%s]}\n' "$json_lines"
}

# status_service_render_url_json()
# generate完了後はRedmineアクセスURLを、未完了ならnullを出力する (RDC-REQ-F1443)
# RDC_STATE_* を直接参照する（呼び出し前に state_store_load 済みであること）。
# 現在の起動状態（compose_runtime）とは独立に、generate完了後は常に出力する
# （「アクセスすべきURL」と「現在アクセス可能か」を分離する）。
# stdout: "url": "http://..." または "url": null
status_service_render_url_json() {
  if [[ "${RDC_STATE_generate_status:-pending}" != "done" ]]; then
    printf '"url": null'
    return 0
  fi
  local bind="${RDC_STATE_redmine_bind:-127.0.0.1:38080}"
  local relative_url_root="${RDC_STATE_relative_url_root:-}"
  printf '"url": "http://%s%s/"' "$bind" "$relative_url_root"
}

# status_service_render_json()
# args: workspace_path
# stdout: status --json の全体出力
status_service_render_json() {
  local workspace_path="${1:?workspace_path required}"

  local steps_json
  steps_json=$(status_service_collect_step_states "$workspace_path" | status_service_render_steps_json)

  local url_json
  url_json=$(status_service_render_url_json)

  local next_action_json
  next_action_json=$(status_service_render_next_action_json "$workspace_path")

  printf '{\n  %s,\n  %s,\n  %s\n}\n' "$steps_json" "$url_json" "$next_action_json"
}

# status_service_render_error_json()
# args: error_code, message
# stdout: {"error": "...", "message": "..."}
status_service_render_error_json() {
  local error_code="${1:?error_code required}"
  local message="${2:?message required}"
  local escaped_message="${message//\\/\\\\}"
  escaped_message="${escaped_message//\"/\\\"}"
  printf '{"error": "%s", "message": "%s"}\n' "$error_code" "$escaped_message"
}
