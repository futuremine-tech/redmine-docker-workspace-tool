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

---

## `generate` — Generate Docker Configuration

```
redmine-docker-workspace generate [options]
```

Generates Dockerfile, docker-compose.yml, .env, and related files.

| Option | Description |
|--------|-------------|
| `--bind-host HOST` | Redmine bind host (default: 127.0.0.1) |
| `--bind-port PORT` | Host-published port for Redmine (default: auto-detected) |
| `--db-publish-port PORT` | Host-published port for PostgreSQL (default: not published — accessible only between containers within the Docker network) |
| `--relative-url-root PATH` | Sub-path for Redmine (e.g. `/redmine`) |
| `--deployment` | Use the workspace-root `Gemfile.lock` for `bundle install --deployment` (reproducible builds) |

When `--deployment` is specified, the generated Dockerfile contains `COPY Gemfile.lock` and runs `bundle install --deployment`. If `Gemfile.lock` is missing from the workspace root, the command fails with guidance to run [`export-gemfile-lock`](#export-gemfile-lock--extract-gemfilelock) first.

Re-running `generate` without `--deployment` reverts to the standard `bundle install` (`deployment_build` is reset to `false` in `.rdc_state`; take effect after `docker compose build`).

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
redmine-docker-workspace status
```

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

Next action: All steps complete. Run 'docker compose up -d' to start Redmine.
```

`[deployment build]` appears next to the generate step when built with `--deployment`. If a rebuild is needed after adding or removing plugins, `status` will prompt you to run `docker compose build`.

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
