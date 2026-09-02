# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.9.7] - 2026-09-02

### Added

- New `auto` subcommand: runs `init`, `generate`, `prepare-db`, `docker compose build`, `migrate`, `docker compose up -d`, and `check` in sequence as a single command, for new-generation-mode workspaces. Supports `--add-plugin URL[#ref]` (repeatable) to install plugins before the build step. Generates `DB_PASSWORD` automatically instead of prompting. Refuses to run twice concurrently on the same workspace (`.rdc_auto.lock`); while it's running, `init`/`generate`/`prepare-db`/`migrate`/`check` also refuse to run against that workspace directly. See the [Subcommand Reference](../docs/REFERENCE.md#auto--build-a-new-workspace-in-one-command).
- `status --json`: the same step/progress information as the human-readable `status` output, as JSON. Includes a `url` field (the Redmine access URL, once `generate` has completed) independent of whether Redmine is currently running.
- `init --list --json` / `init --list-all --json`: the same tag listing as JSON, for populating a version picker before `auto`/`init`.
- New [Machine-Readable Reference](../docs/REFERENCE-JSON.md) documenting the `--json` output of `info`, `status`, and `init --list`/`--list-all`.
- `generate`'s automatic port selection (when `--bind-port` is omitted) now also avoids ports already reserved by sibling workspace directories (recorded in their `.rdc_state`), even if those workspaces' containers aren't currently running — not just ports currently in use on the host.
- `info`, `status`, and `check`'s verification manifest now include `base_image_tag` — the full reference of the base image actually used (e.g. `futuremine/redmine:7.0.0`), resolved the same way regardless of which input mode (`--redmine`/`--redmica`/`--base-image`) created the workspace.

### Changed

- `auto`'s `--add-plugin` now runs after `generate` instead of before it (there was never a technical requirement for the previous order; this only matters if you were relying on the exact internal sequencing).
- `info`'s `--json` and human-readable output no longer include `target_image_tag`; use the new `base_image_tag` field instead. `status`'s human-readable output now shows the same `base_image_tag`-based `image:` line regardless of input mode (previously `--base-image` workspaces showed a distinct `image: ... (explicit)` form). The verification manifest's `target` field is now `base_image_tag` instead of `<product>:<target_image_tag>`.

### Fixed

- `status` (and `status --json`) no longer reports "All steps complete" / a running Redmine when every pipeline step is `done` but the Redmine container isn't currently running (e.g. after `docker compose down`). It now prompts `docker compose up -d` in that case, matching what `external.compose_runtime` already showed.
- `--base-image` workspaces no longer report the underlying Redmine version instead of the actual RedMica version (or vice versa) in `redmine_version`; `info`'s `product` field is now populated for `--base-image` workspaces too instead of staying blank.

## [0.9.5] - 2026-08-27

### Fixed

- Fixed the Redmine 6.x `assets:precompile` build step not bind mounting `plugins`, so plugin assets (CSS, images, etc.) were silently excluded from the compiled output. Plugins such as View Customize would then fail at runtime with `ActionController::RoutingError (No route matches [GET] "/assets/plugin_assets/<plugin>/...")`. The generated Dockerfile now bind mounts `plugins` into this step, matching the `bundle install` step.

## [0.9.4] - 2026-08-22

### Added

- New `info` subcommand: outputs a read-only, machine-readable snapshot of workspace state (product, image, bind address, pipeline step status, verification summary, container runtime state) as text or JSON (`--json`), for external tooling.
- `generate` now detects the actual Redmine/RedMica version from inside the pulled base image and reports it via `info`, so a moving tag like `latest` still shows the real version.
- Rootless Docker support: workspace files use group ID 0 when a rootless Docker daemon is detected.
- Docker-unreachable handling is now consistent across subcommands: `info` and other Docker-independent commands still work when Docker is unreachable.

### Fixed

- The verification manifest's digest field was actually a copy of the target image tag, not a real Docker image digest. It's now the actual base image digest, renamed to `base_image_digest`.

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
