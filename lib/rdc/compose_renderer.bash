#!/usr/bin/env bash
# lib/rdc/compose_renderer.bash
# Dockerfile / docker-compose.yml / .env を生成する Domain モジュール
# 根拠要件: RDC-REQ-F0302, RDC-REQ-F0303A, RDC-REQ-F0303B

# _compose_renderer_redmica_official_eol()
# RedMica の tag が公式イメージ終了バージョン (3.2.0) 以降かどうかを判定する
# 3.2.0 以降は futuremine/redmica を使用する
# args: tag
# returns: 0 if >= 3.2.0 (use futuremine), 1 if < 3.2.0 (use redmica/redmica)
_compose_renderer_redmica_official_eol() {
  local tag="${1:?tag required}"
  local eol="3.2.0"
  # 非 semver タグ (latest 等) は EOL 以降として扱う
  if [[ ! "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9] ]]; then
    return 0
  fi
  local lower
  lower=$(printf '%s\n%s\n' "$eol" "$tag" | sort -V | head -1)
  [[ "$lower" == "$eol" ]]
}

# compose_renderer_resolve_image_name()
# product 名から Docker Hub イメージ名を解決する
# RedMica 3.2.0 以降は公式イメージが終了したため futuremine/redmica を使用する
# args: product, tag
# stdout: image_name (e.g. redmica/redmica:3.1.7, futuremine/redmica:3.2.0)
compose_renderer_resolve_image_name() {
  local product="${1:?product required}"
  local tag="${2:?tag required}"
  case "$product" in
    explicit) echo "$tag" ;;
    redmica)
      if _compose_renderer_redmica_official_eol "$tag"; then
        echo "futuremine/redmica:${tag}"
      else
        echo "redmica/redmica:${tag}"
      fi
      ;;
    *)  echo "${product}:${tag}" ;;
  esac
}

# compose_renderer_render_dockerfile()
# Dockerfile 内容を標準出力へ返す
# context env vars: RDC_WORKSPACE_PATH, RDC_PRODUCT, RDC_TARGET_IMAGE_TAG, RDC_DEPLOYMENT_BUILD
compose_renderer_render_dockerfile() {
  local workspace_path="${RDC_WORKSPACE_PATH:-$PWD}"
  local product="${RDC_PRODUCT:-redmine}"
  local tag="${RDC_TARGET_IMAGE_TAG:-latest}"
  local base_image
  base_image=$(compose_renderer_resolve_image_name "$product" "$tag")
  local generate_id="${RDC_GENERATE_ID:-}"
  local deployment_build="${RDC_DEPLOYMENT_BUILD:-false}"

  if [[ "$deployment_build" == "true" ]]; then
    cat <<EOF
FROM ${base_image}

COPY Gemfile.lock /usr/src/redmine/Gemfile.lock

# bundle install --deployment with Gemfile.lock for reproducible builds (RDC-REQ-F0207)
RUN --mount=type=bind,source=plugins,target=/usr/src/redmine/plugins \
  --mount=type=bind,source=config/database.yml,target=/usr/src/redmine/config/database.yml,readonly \
    bundle install --deployment --without development test
${generate_id:+
LABEL io.github.futuremine-tech.rdc.generate-id="${generate_id}"
}
EOF
  else
    cat <<EOF
FROM ${base_image}

# bundle install with plugins available at build time (RDC-REQ-F0303A)
# plugins/ and config/database.yml are bind-mounted from build context (workspace root)
# so Gemfile can resolve adapter-specific dependencies (e.g. pg for postgresql).
RUN --mount=type=bind,source=plugins,target=/usr/src/redmine/plugins \
  --mount=type=bind,source=config/database.yml,target=/usr/src/redmine/config/database.yml,readonly \
    bundle install --without development test
${generate_id:+
LABEL io.github.futuremine-tech.rdc.generate-id="${generate_id}"
}
EOF
  fi
}

# compose_renderer_render_compose()
# docker-compose.yml 内容を標準出力へ返す
# context env vars: RDC_WORKSPACE_PATH, RDC_PRODUCT, RDC_TARGET_IMAGE_TAG,
#                   RDC_REDMINE_BIND (e.g. 127.0.0.1:38080), RDC_PG_PUBLISH_PORT (optional)
compose_renderer_render_compose() {
  local workspace_path="${RDC_WORKSPACE_PATH:-$PWD}"
  local product="${RDC_PRODUCT:-redmine}"
  local tag="${RDC_TARGET_IMAGE_TAG:-latest}"
  local redmine_bind="${RDC_REDMINE_BIND:-127.0.0.1:38080}"
  local pg_publish_port="${RDC_PG_PUBLISH_PORT:-}"
  local relative_url_root="${RDC_RELATIVE_URL_ROOT:-}"
  local themes_container_path="${RDC_THEMES_CONTAINER_PATH:-/usr/src/redmine/themes}"
  local project_name
  project_name="$(basename "$workspace_path")"

  # Build postgres ports section
  local pg_ports_section=""
  if [[ -n "$pg_publish_port" ]]; then
    pg_ports_section="    ports:
      - \"${pg_publish_port}:5432\""
  fi

  # Build environment section (DB password mapping + optional RAILS_RELATIVE_URL_ROOT)
  local env_entries="      REDMINE_DB_POSTGRES: db
      REDMINE_DB_DATABASE: redmine
      REDMINE_DB_USERNAME: redmine
      REDMINE_DB_PASSWORD: \${DB_PASSWORD}"
  if [[ -n "$relative_url_root" ]]; then
    env_entries="${env_entries}
      RAILS_RELATIVE_URL_ROOT: \"${relative_url_root}\""
  fi
  local env_section="    environment:
${env_entries}"

  # Build optional Rackup override mount for relative-url-root routing
  local rackup_mount_section=""
  if [[ -n "$relative_url_root" ]]; then
    rackup_mount_section="      - \"${workspace_path}/rdc-config.ru:/usr/src/redmine/config.ru:ro\""
  fi

  cat <<EOF
services:
  redmine:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${project_name}-redmine
    env_file: .env
${env_section}
    ports:
      - "${redmine_bind}:3000"
    volumes:
      - "${workspace_path}/plugins:/usr/src/redmine/plugins"
      - "${workspace_path}/files:/usr/src/redmine/files"
      - "${workspace_path}/log:/usr/src/redmine/log"
      - "${workspace_path}/tmp:/usr/src/redmine/tmp"
      - "${workspace_path}/themes:${themes_container_path}"
      - "${workspace_path}/config/configuration.yml:/usr/src/redmine/config/configuration.yml"
      - "${workspace_path}/config/database.yml:/usr/src/redmine/config/database.yml"
${rackup_mount_section:+${rackup_mount_section}
}    labels:
      io.github.futuremine-tech.rdc.workspace-path: "${workspace_path}"
    depends_on:
      - db
    restart: unless-stopped
  db:
    image: postgres:14-alpine
    env_file: .env
    environment:
      POSTGRES_DB: redmine
      POSTGRES_USER: redmine
      POSTGRES_PASSWORD: \${DB_PASSWORD}
${pg_ports_section:+${pg_ports_section}
}    volumes:
      - db_data:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  db_data:
EOF
}

# compose_renderer_render_rackup()
# relative-url-root 用の Rackup 設定を標準出力へ返す
# context env vars: RDC_RELATIVE_URL_ROOT
compose_renderer_render_rackup() {
  local relative_url_root="${RDC_RELATIVE_URL_ROOT:-}"

  cat <<EOF
# This file is generated by redmine-docker-workspace.
require_relative 'config/environment'

relative_url = ENV.fetch('RAILS_RELATIVE_URL_ROOT', '').strip
if relative_url.empty?
  run Rails.application
else
  map relative_url do
    run Rails.application
  end
end
EOF
}

# compose_renderer_render_env()
# .env 内容を標準出力へ返す
# context env vars: RDC_PRODUCT, RDC_TARGET_IMAGE_TAG, RDC_DB_PASSWORD
compose_renderer_render_env() {
  local product="${RDC_PRODUCT:-redmine}"
  local tag="${RDC_TARGET_IMAGE_TAG:-latest}"
  local db_password="${RDC_DB_PASSWORD:-redmine}"

  cat <<EOF
DB_PASSWORD=${db_password}
EOF
}
