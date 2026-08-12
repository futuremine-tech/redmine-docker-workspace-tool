# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.9.3] - 2026-08-12

### Added

- `--redmine TAG` now automatically selects the image repository based on the tag version: `7.0.0` and later (and non-semver tags such as `latest`) use `futuremine/redmine:TAG`, which applies OS package security patches and bundles Pandoc (required for Redmine 7.0+'s attachment preview feature). Tags below `7.0.0` continue to use the official `redmine:TAG`. To force the official image regardless of version, use `--base-image redmine:TAG` instead. If the resolved `futuremine/redmine:TAG` isn't available, `generate` fails with a hint to re-run with `--base-image` (no automatic fallback).
- `init --list` now shows `futuremine/redmine` tags (`>= 7.0.0`) alongside the official `redmine` tags (`< 7.0.0`), matching the new selection behavior. `init --list-all` shows the full tag set from both repositories without this version filtering.

## [0.9.2] - 2026-08-12

### Fixed

- Fixed the Redmine 6.x `assets:precompile` build step (introduced in 0.9.1) failing with `Permission denied` when reading the `secret_key_base` build secret. The generated Dockerfile now mounts the secret with `mode=0444` so the non-root `redmine` user can read it.
- Fixed the same `assets:precompile` step aborting with `Please configure your config/database.yml first`. The generated Dockerfile now bind mounts `config/database.yml` into this step, matching the `bundle install` step.

## [0.9.1] - 2026-08-12

### Added

- `--extra-config-mount FILENAME` option for `generate`: bind mounts `config/FILENAME` into the container at `/usr/src/redmine/config/FILENAME` (repeatable). Intended for plugin-specific config files that Redmine core doesn't ship an example for (e.g. `config/queue.yml` for the `redmine_solid_queue` plugin).
- `generate` now always bind mounts `config/additional_environment.rb` into the container, alongside `configuration.yml` and `database.yml` — no option needed. If the file doesn't already exist in the workspace, it is scaffolded from the image's `additional_environment.rb.example` (all-comment, safe no-op default); an existing file is never overwritten.
- Automatic theme asset precompilation for Redmine 6.x: when the theme container path is not under `public/themes/`, the generated Dockerfile now runs `assets:precompile` during `docker compose build`. `SECRET_KEY_BASE` is read from `.env` via a Docker build secret and is never stored in image layers. `status` now lists installed themes and prompts a rebuild after theme changes on 6.x.

### Fixed

- Fixed a build failure (`bundle install` exiting with code 15) on Bundler 4.x, which removed the `--without` command-line flag. The generated Dockerfile now uses `bundle config set --local without '...'` before `bundle install`.
