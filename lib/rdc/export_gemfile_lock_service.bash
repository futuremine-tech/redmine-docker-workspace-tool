#!/usr/bin/env bash
# lib/rdc/export_gemfile_lock_service.bash
# export-gemfile-lock サブコマンド: ビルド済みイメージから Gemfile.lock を抽出する
# 根拠要件: RDC-REQ-F1301〜F1305

_RDC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RDC_LIB_DIR/state_store.bash"
source "$_RDC_LIB_DIR/logger.bash"

# export_gemfile_lock_service_run()
# export-gemfile-lock サブコマンド全体を実行する
# args: argv...
# returns: exit_code
export_gemfile_lock_service_run() {
  # --force はグローバルパーサーが RDC_FORCE=true に変換する場合と
  # サブコマンド引数として渡される場合の両方に対応する
  local force=false
  [[ "${RDC_FORCE:-}" == "true" ]] && force=true

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        echo "Usage: redmine-docker-workspace export-gemfile-lock [--force]"
        echo ""
        echo "Extracts /usr/src/redmine/Gemfile.lock from the built Redmine image"
        echo "and places it in the workspace root."
        echo ""
        echo "Use this to obtain a pinned set of gem versions after 'docker compose build',"
        echo "then run 'generate --deployment' to build with exactly those versions."
        echo ""
        echo "Options:"
        echo "  --force  Overwrite existing Gemfile.lock without confirmation"
        return 0
        ;;
      --force) force=true ;;
    esac
  done

  local workspace
  workspace=$(state_store_find_workspace_root) || {
    echo "ERROR: Workspace not initialized. Run 'init' to start." >&2
    return 1
  }
  export RDC_LOG_FILE="$workspace/redmine-docker-workspace.log"

  if ! state_store_load "$workspace"; then
    logger_error "Workspace not initialized. Run 'init' first."
    return 1
  fi

  local dest="$workspace/Gemfile.lock"

  # 既存ファイルチェック (F1303)
  if [[ -f "$dest" && "$force" != "true" ]]; then
    echo "ERROR: Gemfile.lock は既にワークスペースルートに存在します。" >&2
    echo "上書きするには --force を指定してください:" >&2
    echo "  redmine-docker-workspace export-gemfile-lock --force" >&2
    return 1
  fi

  # モックサポート
  if [[ "${RDC_ALLOW_MOCK:-}" == "1" ]]; then
    if [[ "${RDC_MOCK_NO_IMAGE:-}" == "1" ]]; then
      echo "ERROR: ビルド済みイメージが見つかりません。先に 'docker compose build' を実行してください。" >&2
      return 1
    fi
    printf 'GEM\n  remote: https://rubygems.org/\n  specs:\n\nBUNDLED WITH\n  2.4.0\n' > "$dest"
    echo "Gemfile.lock を取り出しました: $dest"
    echo "次のステップ: 'redmine-docker-workspace generate --deployment' で再現性のあるビルドを実施してください。"
    return 0
  fi

  # 実環境: docker create + cp + rm パターン (F1301)
  local compose_file="$workspace/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    echo "ERROR: docker-compose.yml が見つかりません。先に 'generate' を実行してください。" >&2
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
    image_name="$(basename "$workspace")-redmine"
  fi

  if ! docker image inspect "$image_name" > /dev/null 2>&1; then
    echo "ERROR: イメージ '$image_name' が見つかりません。先に 'docker compose build' を実行してください。" >&2
    return 1
  fi

  local container_id
  container_id=$(docker create "$image_name" /bin/sh 2>/dev/null) || {
    echo "ERROR: $image_name から一時コンテナを作成できませんでした。" >&2
    return 1
  }

  local tmp_dest="${dest}.tmp.$$"
  if docker cp "$container_id:/usr/src/redmine/Gemfile.lock" "$tmp_dest" 2>/dev/null; then
    docker rm -f "$container_id" 2>/dev/null || true
    mv "$tmp_dest" "$dest"
    echo "Gemfile.lock を取り出しました: $dest"
    echo "次のステップ: 'redmine-docker-workspace generate --deployment' で再現性のあるビルドを実施してください。"
    return 0
  else
    docker rm -f "$container_id" 2>/dev/null || true
    rm -f "$tmp_dest"
    echo "ERROR: イメージ '$image_name' から Gemfile.lock を取り出せませんでした。" >&2
    return 1
  fi
}
