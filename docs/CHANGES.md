# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.9.1] - 2026-08-12

### Added

- `--extra-config-mount FILENAME` option for `generate`: bind mounts `config/FILENAME` into the container at `/usr/src/redmine/config/FILENAME` (repeatable). Intended for plugin-specific config files that Redmine core doesn't ship an example for (e.g. `config/queue.yml` for the `redmine_solid_queue` plugin).
- `generate` now always bind mounts `config/additional_environment.rb` into the container, alongside `configuration.yml` and `database.yml` — no option needed. If the file doesn't already exist in the workspace, it is scaffolded from the image's `additional_environment.rb.example` (all-comment, safe no-op default); an existing file is never overwritten.
- Automatic theme asset precompilation for Redmine 6.x: when the theme container path is not under `public/themes/`, the generated Dockerfile now runs `assets:precompile` during `docker compose build`. `SECRET_KEY_BASE` is read from `.env` via a Docker build secret and is never stored in image layers. `status` now lists installed themes and prompts a rebuild after theme changes on 6.x.

### Fixed

- Fixed a build failure (`bundle install` exiting with code 15) on Bundler 4.x, which removed the `--without` command-line flag. The generated Dockerfile now uses `bundle config set --local without '...'` before `bundle install`.
