# Subcommand Reference

## Global Options

```
redmine-docker-workspace [--force] [--verbose] <subcommand> [...]
```

| Option | Description |
|--------|-------------|
| `-f`, `--force` | Skip confirmation prompts for destructive operations |
| `-v`, `--verbose` | Enable verbose/debug output |
| `-V`, `--version` | Show version information |
| `-h`, `--help` | Show help |

Most subcommands (`dbdump`, `prepare-db`, `migrate`, `export-gemfile-lock`, `status`, `auto`) require the Docker daemon to be running and fail immediately with an error if it isn't (`init`, `check`, and `add-plugin` don't touch Docker and are unaffected). `clean` and `remove-plugin` don't strictly need Docker for their own deletion work, but can't verify it's safe to proceed (e.g. whether Redmine is still running) without it — see their sections below. `info` also doesn't require Docker: it makes a best-effort attempt for container runtime state only, reporting `unknown` if unreachable — see its section below.

While `auto` is running against a workspace, `init`, `generate`, `prepare-db`, `migrate`, and `check` all refuse to run against that same workspace (a different workspace is unaffected) — see [`auto`](#auto--build-a-new-workspace-in-one-command) below.

For `--json` output of `info`, `status`, and `init --list`/`--list-all`, see the [Machine-Readable Reference](REFERENCE-JSON.md).

---

## `auto` — Build a New Workspace in One Command

```
redmine-docker-workspace auto (--redmine TAG | --redmica TAG | --base-image IMAGE_REF) (--fresh-db | --import-from PATH) [options]
```

Runs `init`, `generate`, `prepare-db`, `docker compose build`, `migrate`, `docker compose up -d`, and `check` in sequence — the entire pipeline in a single command.

**Scope**: new-generation-mode inputs only. Passenger mode and existing-workspace mode are not supported by `auto`; use the individual subcommands (starting with `init --mode passenger` or `init --mode workspace`) for those.

| Option | Description |
|--------|-------------|
| `--redmine TAG` | Target Redmine image tag (exactly one of `--redmine`/`--redmica`/`--base-image` is required) |
| `--redmica TAG` | Target RedMica image tag |
| `--base-image IMAGE_REF` | Target base image |
| `--target PATH` | Workspace directory (default: same as [`init`](#init--initialize-workspace)) |
| `--fresh-db` | Initialize an empty database (exactly one of `--fresh-db`/`--import-from` is required) |
| `--import-from PATH` | Restore from the specified dump file |
| `--relative-url-root PATH` | Sub-path for Redmine (e.g. `/redmine`), passed through to `generate` |
| `--bind-port PORT` | Host-published port for Redmine (default: auto-detected), passed through to `generate` |
| `--lang LANG` | Language for loading default data (default: `ja`), passed through to `migrate` |
| `--add-plugin URL[#ref]` | Add a plugin before the build step (repeatable — specify multiple times for multiple plugins) |

`--add-plugin` accepts a plain git URL, or `URL#ref` to pin a specific tag or branch (e.g. `--add-plugin https://github.com/example/redmine_agile.git#v1.6.0`); without `#ref`, the plugin repository's default branch is used, and re-running `auto` later may pick up a different commit if the plugin repository has since been updated. This is a shorthand for [`add-plugin`](#add-plugin--add-plugin)'s `URL --ref REF` — its `--name`/`--force` options aren't available through `auto`.

If any step fails, `auto` stops immediately, reports which step failed and why, and doesn't proceed further. Completed steps remain recorded in `.rdc_state`, so you can inspect progress with `status` and decide whether to retry individual subcommands; there's no automatic resume. To start over cleanly, run `clean` and re-run `auto`.

`auto` refuses to run twice concurrently on the same workspace: it holds a PID lock file (`.rdc_auto.lock`) for the duration of the run, released automatically on completion (success or failure). If `auto` is killed abruptly (e.g. Ctrl-C, `kill`), the lock file can be left behind — run `clean` to remove it before retrying.

`auto` always generates a random `DB_PASSWORD` itself and never prompts interactively — unlike running `generate` directly from a terminal, which may prompt for `DB_PASSWORD` if it can't otherwise be determined.

---

## `init` — Initialize Workspace

```
redmine-docker-workspace init --target PATH [--mode <passenger|workspace|new>] [options]
```

| Option | Description |
|--------|-------------|
| `--target PATH` | Workspace directory (required) |
| `--mode MODE` | Input mode (default: `new`) |
| `--redmine TAG` | Redmine image tag |
| `--redmica TAG` | RedMica image tag |
| `--base-image REPO:TAG` | Custom base image (new mode only) |
| `--redmine-root PATH` | Redmine root directory (passenger mode) |
| `--apache-config-dir PATH` | Apache configuration directory (passenger mode) |
| `--source PATH` | Source workspace to migrate from (workspace mode) |
| `--list` | List supported images and exit — `x.y.z` tags only, `--target` not required |
| `--list-all` | List supported images and exit — all tags including derived, `--target` not required |
| `--json` | With `--list`/`--list-all`, output the list as JSON instead — see the [Machine-Readable Reference](REFERENCE-JSON.md) |

`--redmine TAG` automatically selects the image repository based on the tag version: `7.0.0` and later (and non-semver tags such as `latest`) use `futuremine/redmine:TAG`, which applies OS package security patches and bundles Pandoc (required for Redmine 7.0+'s attachment preview feature). Tags below `7.0.0` use the official `redmine:TAG`. To force the official image regardless of version, use `--base-image redmine:TAG` instead — this bypasses the automatic selection. If the resolved `futuremine/redmine:TAG` isn't available (these tags are built on demand and may not cover every release yet), `generate` fails with a hint to re-run with `--base-image`. `--redmica TAG` selects between `redmica/redmica:TAG` (below `3.2.0`) and `futuremine/redmica:TAG` (`3.2.0` and later, since the official image stopped publishing new tags at that version) the same way.

---

## `generate` — Generate Docker Configuration

```
redmine-docker-workspace generate [options]
```

Generates Dockerfile, docker-compose.yml, .env, and related files.

| Option | Description |
|--------|-------------|
| `--bind-host HOST` | Redmine bind host (default: 127.0.0.1) |
| `--bind-port PORT` | Host-published port for Redmine (default: auto-detected — see below) |
| `--db-publish-port PORT` | Host-published port for PostgreSQL (default: not published — accessible only between containers within the Docker network) |
| `--relative-url-root PATH` | Sub-path for Redmine (e.g. `/redmine`) |
| `--extra-config-mount FILENAME` | Bind mount `config/FILENAME` into the container at `/usr/src/redmine/config/FILENAME` (repeatable). `FILENAME` must be a relative path under `config/` (no `..`, must not start with `/`), and the file must already exist in the workspace. |
| `--deployment` | Use the workspace-root `Gemfile.lock` for `bundle install --deployment` (reproducible builds) |
| `--log-stdout` | Write Redmine logs to STDOUT (view with `docker compose logs redmine`). When omitted, logs go to `log/production.log` (default) |

When `--deployment` is specified, the generated Dockerfile contains `COPY Gemfile.lock` and runs `bundle install --deployment`. If `Gemfile.lock` is missing from the workspace root, the command fails with guidance to run [`export-gemfile-lock`](#export-gemfile-lock--extract-gemfilelock) first.

Re-running `generate` without `--deployment` reverts to the standard `bundle install` (`deployment_build` is reset to `false` in `.rdc_state`; take effect after `docker compose build`).

`--extra-config-mount` only wires up the bind mount — it does not generate or scaffold the file's contents. This is intended for plugin-specific config files that Redmine core doesn't ship an example for (e.g. `config/queue.yml` for the `redmine_solid_queue` plugin's Solid Queue configuration). Create the file under `config/` before running `generate`.

`generate` also always bind mounts `config/additional_environment.rb` into the container, alongside `configuration.yml` and `database.yml` — no option needed. This file is Redmine's official extension point for Rails initializer statements (see the comments in the generated `config/additional_environment.rb.example`, e.g. `config.active_job.queue_adapter = :inline`). If `config/additional_environment.rb` doesn't already exist, `generate` scaffolds it from the image's `additional_environment.rb.example` (all-comment, a safe no-op default); an existing file is never overwritten.

Without `--log-stdout` (default), the generated docker-compose.yml sets `RAILS_LOG_TO_STDOUT: ""`, overriding the official image default and enabling file-based logging to `log/production.log` in the workspace. Specifying `--log-stdout` switches to `RAILS_LOG_TO_STDOUT: "true"`.

**Port auto-detection and sibling workspaces**: when `--bind-port` is omitted, `generate` picks the first free port starting at 38080. "Free" is checked two ways: (1) no process is currently listening on it on the host, and (2) no sibling workspace directory (i.e. another directory alongside this one, one level up) has already reserved it — read from that workspace's `.rdc_state` `redmine_bind`, even if that workspace's containers aren't currently running. This avoids two workspaces picking the same port when one of them hasn't been started (or has been stopped) yet, as long as they share a common parent directory; workspaces nested more than one level apart, or scattered across unrelated locations, aren't checked. An explicit `--bind-port` skips auto-detection entirely and this check doesn't apply — an explicitly requested port that's already in use fails outright rather than being silently changed.

**Theme asset precompilation (Redmine 6.x and later)**: Redmine 6.x serves theme CSS through the asset pipeline, so `assets:precompile` is required. When the theme container path is not under `/usr/src/redmine/public/themes` (i.e. Redmine 6.x), the Dockerfile generated by `generate` automatically runs `assets:precompile` during `docker compose build`. `SECRET_KEY_BASE` is read from `.env` via a Docker build secret and is never stored in image layers. After placing themes in `workspace/themes/`, run `docker compose build && docker compose up -d` to apply them. For Redmine 5.x (themes under `public/themes/`), no precompilation is performed.

**Version and base image detection**: `generate` also detects the actual Redmine/RedMica version from inside the pulled base image and records it in `.rdc_state`, along with the base image's digest. This matters when the target tag is a moving one like `latest`: [`info`](#info--show-workspace-information) reports the real version that was actually pulled, not just the tag string you specified. The base image digest is a snapshot taken at `generate` time — it does not change when you later run `docker compose build` (which layers plugins/gems on top), so it identifies which upstream base image the workspace was built from, not the exact built artifact (image digests produced by local builds are not reproducible across builds, even with identical plugins, so they aren't tracked).

---

## `prepare-db` — Prepare Database

```
redmine-docker-workspace prepare-db (--import-from PATH | --fresh-db | --from-external-db | --skip --reason TEXT)
```

Exactly one option is required.

| Option | Description |
|--------|-------------|
| `--import-from PATH` | Import from a SQL dump file |
| `--fresh-db` | Create an empty database |
| `--from-external-db` | Fetch and import from an external PostgreSQL instance |
| `--skip --reason TEXT` | Skip this step and record the reason |

---

## `migrate` — Run Migrations

```
redmine-docker-workspace migrate
```

Runs `db:migrate` and `redmine:plugins:migrate` inside the container.

---

## `check` — Verify Running Instance

```
redmine-docker-workspace check
```

Verifies HTTP access to the running Redmine instance.

---

## `dbdump` — Dump Database

```
redmine-docker-workspace dbdump [--dump-filename FILENAME]
```

Runs `pg_dump` from the workspace's `db` container and saves the output to `./dbdump/`. This is not a required pipeline step and can be run at any time.

---

## `status` — Show Workspace Status

```
redmine-docker-workspace status [--json]
```

| Option | Description |
|--------|-------------|
| `--json` | Output the same step/progress information as JSON to stdout — see the [Machine-Readable Reference](REFERENCE-JSON.md) |

Displays the current pipeline progress, installed plugin list, and the next recommended action.

**Example output:**

```
[init]       done
[generate]   done [deployment build]
[prepare-db] done
[migrate]    done
[check]      done

Plugins:
  redmine_agile              https://github.com/example/redmine_agile.git (ref: v1.6.0)
  my_custom_plugin           https://github.com/example/my_custom_plugin.git
  legacy_plugin              [manual]

Themes:
  farend_fancy               (manual)

Next action: All steps complete. Redmine is running at http://127.0.0.1:38080/.
```

`[deployment build]` appears next to the generate step when built with `--deployment`. If a rebuild is needed after adding or removing plugins, or after adding or updating themes on Redmine 6.x, `status` will prompt you to run `docker compose build`.

All steps showing `done` — including `check` — doesn't by itself mean Redmine is currently running: `check` records that verification succeeded at some point, and nothing resets it if you later run `docker compose down`. `status` accounts for this: if every step is `done` but the Redmine container isn't currently running, it prompts `docker compose up -d` instead of declaring completion.

If Docker is running in rootful mode (e.g. via `docker` group membership, which effectively grants root-equivalent access), `status` displays a security warning. Consider switching to [rootless Docker](https://docs.docker.com/engine/security/rootless/).

---

## `info` — Show Workspace Information

```
redmine-docker-workspace info [--json]
```

| Option | Description |
|--------|-------------|
| `--json` | Output the same information as JSON to stdout — see the [Machine-Readable Reference](REFERENCE-JSON.md) |

Read-only snapshot of workspace information intended for external tooling (e.g. a registry that tracks multiple workspaces), as opposed to `status`, which guides a human through the pipeline. Includes the product, `base_image_tag` (the full reference of the base image actually used, e.g. `futuremine/redmine:7.0.0` — the same regardless of which input mode created the workspace), the actually detected Redmine/RedMica version (`redmine_version` — see [Version and base image detection](#generate--generate-docker-configuration) above), bind address, `relative_url_root`, workspace path, pipeline step status, a verification summary (from `check`'s manifest, including `base_image_digest`), and container runtime state. Unlike most other subcommands, `info` does not require the Docker daemon: runtime state is best-effort and reported as `unknown` if Docker is unreachable, while all other fields are still shown and the command exits successfully.

If the workspace hasn't been initialized (or has been cleaned), `info` fails; with `--json`, the failure is reported as JSON on stdout instead of plain text on stderr, so scripts can parse either the success or the error shape the same way.

---

## `add-plugin` — Add Plugin

```
redmine-docker-workspace add-plugin URL [--ref REF] [--name NAME] [--force]
```

| Option | Description |
|--------|-------------|
| `URL` | Git repository URL of the plugin (required) |
| `--ref REF` | Tag or branch (default: repository default branch) |
| `--name NAME` | Installation directory name (default: basename of URL) |
| `--force` | Force re-clone over an existing directory |

---

## `remove-plugin` — Remove Plugin

```
redmine-docker-workspace remove-plugin <plugin_name> --force
```

Runs the reverse migration (`redmine:plugin:migrate VERSION=0`) and then deletes the plugin directory. `--force` is required.

If the Docker daemon can't be reached, `remove-plugin` can't verify whether Redmine is still running. It warns and asks for confirmation before proceeding; `--force` skips the prompt.

---

## `export-gemfile-lock` — Extract Gemfile.lock

```
redmine-docker-workspace export-gemfile-lock [--force]
```

Extracts `/usr/src/redmine/Gemfile.lock` from the built Redmine image and places it in the workspace root. This is not a required pipeline step and can be run at any time after `docker compose build`.

| Option | Description |
|--------|-------------|
| `--force` | Overwrite an existing `Gemfile.lock` without confirmation |

**Typical workflow:**

```
# 1. Build the image to resolve gem versions
docker compose build

# 2. Extract the resolved Gemfile.lock
redmine-docker-workspace export-gemfile-lock

# 3. Use it for reproducible future builds
redmine-docker-workspace generate --deployment
docker compose build
```

Fails with an error if the image has not been built yet (`docker compose build` not run).

---

## `clean` — Reset Workspace

```
redmine-docker-workspace clean
```

Removes generated files and resets the workspace state. Start over from `generate` after cleaning.

If the Docker daemon can't be reached, `clean` can't verify whether Compose is still running. It warns and asks for confirmation before proceeding; `--force` skips the prompt.
