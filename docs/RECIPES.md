# Recipe Scripts

You can automate and reproduce the setup process by combining commands into a shell script. With `set -euo pipefail`, the script stops immediately if any step fails.

## Migrate from Passenger Mode

```bash
#!/usr/bin/env bash
set -euo pipefail

source ~/redmine-docker-workspace-tool/activate-workspace-tool.sh

WORKSPACE=/srv/redmine-workspace

redmine-docker-workspace init \
  --target "$WORKSPACE" \
  --mode passenger \
  --redmine-root /var/lib/redmine \
  --apache-config-dir /etc/apache2/sites-enabled \
  --redmine 6.0.3

cd "$WORKSPACE"

redmine-docker-workspace generate --bind-port 38080

docker compose build

redmine-docker-workspace prepare-db --import-from /path/to/dump.sql

redmine-docker-workspace migrate

docker compose up -d

redmine-docker-workspace check
```

## Fresh Setup (new mode)

```bash
#!/usr/bin/env bash
set -euo pipefail

source ~/redmine-docker-workspace-tool/activate-workspace-tool.sh

WORKSPACE=/srv/redmine-workspace

redmine-docker-workspace init \
  --target "$WORKSPACE" \
  --mode new \
  --redmine 6.0.3

cd "$WORKSPACE"

redmine-docker-workspace generate --bind-port 38080

docker compose build

redmine-docker-workspace prepare-db --fresh-db

redmine-docker-workspace migrate

docker compose up -d

redmine-docker-workspace check
```

## Reproducible Build with Gemfile.lock

Use `--deployment` to pin gem versions for reproducible builds across environments or rebuilds.

**Step 1 — Build once and extract Gemfile.lock:**

```bash
cd "$WORKSPACE"

# First build: gem versions are resolved and locked inside the image
redmine-docker-workspace generate --bind-port 38080
docker compose build

# Extract Gemfile.lock from the built image
redmine-docker-workspace export-gemfile-lock
```

**Step 2 — Rebuild with pinned versions:**

```bash
# Regenerate using the extracted Gemfile.lock
redmine-docker-workspace generate --deployment --bind-port 38080

# Rebuild the image — bundle install --deployment is used
docker compose build
```

From this point forward, run `generate --deployment` + `docker compose build` whenever you need to rebuild the image. The same gem versions will be used each time.

To revert to standard `bundle install` (re-resolve gem versions on next build), run `generate` without `--deployment` and rebuild.
