# redmine-docker-workspace-tools

A CLI tool for building and managing Docker workspaces for Redmine/RedMica.

## Overview

`redmine-docker-workspace` is a Bash-based CLI that helps system administrators build and maintain Docker runtime environments (workspaces) for Redmine or RedMica.

**Problems it solves:**
- Migrating an existing Redmine environment running on Apache + Passenger to Docker
- Migrating or rebuilding an existing Docker workspace to another server
- Setting up a brand-new Redmine/RedMica Docker environment from scratch

The resulting environment is started and stopped with standard `docker compose` commands. This tool handles the initial setup as well as ongoing maintenance tasks such as plugin management and migrations.

## Target Users

- System administrators managing Redmine or RedMica
- Administrators looking to migrate from Passenger to Docker
- Developers who want to quickly spin up staging or development environments

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | Linux (bash 4.0 or later) |
| Docker | Docker Engine + `docker compose` plugin |
| Additional (passenger mode only) | Redmine running on Apache + Passenger (mod_passenger). Standalone Passenger (`passenger start`) is not supported |

## Installation

Clone the repository to any directory.

```bash
git clone <repository-url> ~/redmine-docker-workspace-tools
```

Source `activate-workspace-tool.sh` to add the tool to your current shell session's PATH.

```bash
source ~/redmine-docker-workspace-tools/activate-workspace-tool.sh
```

To avoid sourcing it every time, add it to your shell profile.

```bash
echo 'source "$HOME/redmine-docker-workspace-tools/activate-workspace-tool.sh"' >> ~/.bashrc
source ~/.bashrc
```

Verify the installation:

```bash
redmine-docker-workspace --help
```

---

## Usage

### Input Modes

Use `--mode` with the `init` command to specify where the workspace is created from.

| Mode | Purpose |
|------|---------|
| `passenger` | Migrate from a running Redmine on Apache + Passenger |
| `workspace` | Migrate or rebuild an existing Docker workspace |
| `new` | Build a brand-new environment from scratch |

### Standard Workflow

Run commands in the following order. Use `status` to check your progress at any point.

```
init → generate → docker compose build → prepare-db → migrate → docker compose up -d → check
```

### Step Details

#### 1. Initialize Workspace

```bash
# passenger mode (migrate from Apache + Passenger)
redmine-docker-workspace init \
  --target /srv/redmine-workspace \
  --mode passenger \
  --redmine-root /var/lib/redmine \
  --apache-config-dir /etc/apache2/sites-enabled \
  --redmine 6.0.3

# workspace mode (migrate existing Docker workspace)
redmine-docker-workspace init \
  --target /srv/redmine-workspace-new \
  --mode workspace \
  --source /srv/redmine-workspace-old

# new mode (fresh setup)
redmine-docker-workspace init \
  --target /srv/redmine-workspace \
  --mode new \
  --redmine 6.0.3
```

After `init` completes, run `source activate-workspace-tool.sh` from the workspace root to run subsequent commands from within the workspace.

#### 2. Generate Docker Configuration

```bash
cd /srv/redmine-workspace
redmine-docker-workspace generate \
  --bind-port 38080 \
  --relative-url-root /redmine   # if running under a sub-path
```

#### 3. Add/Remove Plugins (optional)

Manage plugins with `add-plugin` / `remove-plugin`. Adding plugins before the build step lets you include them in a single build. See [Plugin Management](#plugin-management) for details.

#### 4. Build Docker Image

```bash
docker compose build
```

#### 5. Prepare Database

```bash
# Import from Passenger's PostgreSQL database
redmine-docker-workspace prepare-db --import-from /path/to/dump.sql

# Fetch from an external database
redmine-docker-workspace prepare-db --from-external-db

# Start with an empty (fresh) database
redmine-docker-workspace prepare-db --fresh-db
```

#### 6. Run Migrations

```bash
redmine-docker-workspace migrate
```

#### 7. Start and Verify

```bash
docker compose up -d
redmine-docker-workspace check
```

#### 8. Configure Reverse Proxy (optional)

Redmine binds to localhost only by default (`--bind-host 127.0.0.1`). To allow external access, configure a reverse proxy such as Nginx or Apache.

---

## Plugin Management

### Adding a Plugin

```bash
# Basic (plugin name is resolved from the URL basename)
redmine-docker-workspace add-plugin https://github.com/example/redmine_agile.git

# Specify a version (tag or branch)
redmine-docker-workspace add-plugin https://github.com/example/redmine_agile.git \
  --ref v1.6.0
```

After adding, run `docker compose build` → `migrate` → `docker compose up -d` → `check` manually (`status` will guide you through the next steps).

**Adopting manually placed plugins:**
Plugins already placed in `plugins/` by manual copy or rsync can be brought under management by running `add-plugin`. The directory is preserved as-is; only the metadata file is written.

### Removing a Plugin

```bash
redmine-docker-workspace remove-plugin <plugin_name> --force
```

The tool automatically runs the reverse migration. After removal, run `docker compose build` (if an image rebuild is needed) → `docker compose up -d` → `check` manually (`status` will guide you).

---

## Workspace Structure

```
/srv/redmine-workspace/
├── .rdc_state                    # Tool state file (internal)
├── .rdc_plugins/                 # Plugin metadata (git URL, ref)
│   └── my_plugin
├── redmine-docker-workspace.log  # Operation log
├── activate-workspace-tool.sh    # PATH setup script
├── docker-compose.yml            # Generated file
├── Dockerfile                    # Generated file
├── .env                          # Generated file (DB password, etc.)
├── plugins/                      # Redmine plugins
│   └── my_plugin/
├── themes/                       # Redmine themes
├── files/                        # Redmine attachments
├── config/                       # configuration.yml, etc.
├── dbdump/                       # Database dump output
└── logs/                         # Redmine logs
```

---

## Logging

Every subcommand execution is recorded in `redmine-docker-workspace.log` in the workspace. A timestamped `[CMD]` line is written for each invocation.

---

## Documentation

- [Subcommand Reference](docs/REFERENCE.md) — Full option reference
- [Recipe Scripts](docs/RECIPES.md) — Sample setup scripts

---

## Support & Contact

For questions or bug reports, please use the [contact form at futuremine.jp](https://futuremine.jp/). As this is an individually developed and maintained project, we may not be able to respond to every request, but we will do our best within our capacity.

---

## License

Copyright (C) 2026 Futuremine Technologies

Distributed under the GNU General Public License v2 or later (GPL-2.0-or-later). See [LICENSE](LICENSE) for details.
