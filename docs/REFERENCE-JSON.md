# Machine-Readable (`--json`) Reference

This document covers the `--json` output of `info`, `status`, and `init --list`/`--list-all`. It's aimed at programmatic callers — external tooling that manages one or more workspaces (e.g. a registry, an orchestration agent) — rather than interactive human use. For everything else, see the [main Subcommand Reference](REFERENCE.md).

All JSON is written to stdout, one document per invocation, with no surrounding log lines. On error, JSON is still written to stdout (not stderr) with a non-zero exit code, so callers can parse the same way regardless of success or failure.

---

## `info --json` — Workspace Snapshot

```
redmine-docker-workspace info --json
```

Read-only snapshot of workspace information, intended for external tooling that tracks multiple workspaces (as opposed to `status`, which guides a human through the pipeline). Unlike most other subcommands, `info` does not require the Docker daemon: container runtime state is best-effort and reported as `unknown` if Docker is unreachable, while every other field is still populated and the command exits successfully.

**Example:**

```json
{
  "workspace_path": "/home/user/ws/myredmine",
  "mode": "passenger",
  "product": "redmine",
  "target_image_tag": "6.0.3",
  "redmine_version": "6.0.3",
  "image": "futuremine/redmine:6.0.3",
  "redmine_bind": "127.0.0.1:38080",
  "relative_url_root": "",
  "steps": {
    "init": "done",
    "generate": "done",
    "prepare-db": "done",
    "migrate": "done",
    "check": "done"
  },
  "verification": {
    "status": "passed",
    "verified_at": "2026-08-17T02:00:00Z",
    "base_image_digest": "sha256:abcd1234..."
  },
  "runtime": {
    "state": "running",
    "started_at": "2026-08-17T02:05:11Z"
  }
}
```

`redmine_version` reports the actually detected Redmine/RedMica version (see [Version and base image detection](REFERENCE.md#generate--generate-docker-configuration) in the main reference), falling back to `target_image_tag` when not yet detected (e.g. workspaces generated before this field existed). `verification` is omitted down to `{"status": "not_completed"}` before `check` has run. `runtime.state` is `running`, `stopped`, or `unknown` (Docker unreachable); `started_at` is present only when `state` is `running`.

**On error** (workspace not initialized, or cleaned):

```json
{"error": "workspace_not_initialized", "message": "Workspace not initialized. Run 'init' to start."}
```

---

## `status --json` — Pipeline Progress

```
redmine-docker-workspace status --json
```

Same content as the human-readable `status` output — pipeline step completion and the next recommended action — as JSON. Unlike `info`, `status --json` requires the Docker daemon (same as the human-readable form) and fails with an error if it's unreachable.

**Example:**

```json
{
  "steps": {
    "init": "done",
    "generate": "done",
    "prepare-db": "pending",
    "migrate": "pending",
    "check": "pending"
  },
  "external": {
    "compose_build": "pending",
    "compose_up": "pending",
    "compose_runtime": "stopped"
  },
  "url": "http://127.0.0.1:38081/redmine-auto/",
  "next_action": {
    "lines": [
      "Run one of:",
      "  redmine-docker-workspace prepare-db --import-from PATH",
      "  redmine-docker-workspace prepare-db --fresh-db",
      "Then: docker compose build (in /home/user/ws/myredmine)"
    ]
  }
}
```

`steps` mirrors `info`'s step names. `external` reports the three manual Docker Compose steps this tool doesn't run for you (`compose_build`, `compose_up`, `compose_runtime`), matching the "External (reference)" section of the human-readable output — values can include `unknown (Docker daemon unreachable)`. `next_action.lines` is the same guidance text `status` prints, delivered as an array of lines rather than structured fields — this text isn't guaranteed to stay stable and is intended for display, not parsing; poll `steps`/`external` to track progress programmatically.

`url` is the Redmine access URL constructed from `redmine_bind`/`relative_url_root`, once `generate` has completed — it's `null` before that. This field reflects *where Redmine would be served*, independent of whether it's actually reachable right now (check `external.compose_runtime` for that). Note that all pipeline steps showing `"done"` — including `check` — does **not** by itself mean Redmine is currently running: `check` records that verification succeeded at some point in the past, and nothing resets it if you later run `docker compose down`. `next_action` accounts for this: even with every step `done`, if `compose_runtime` isn't `running`, `next_action` still prompts `docker compose up -d` rather than declaring completion.

**On error** (workspace not initialized, cleaned, or Docker daemon unreachable):

```json
{"error": "workspace_not_initialized", "message": "Workspace not initialized. Run 'init' to start."}
```

```json
{"error": "docker_daemon_unreachable", "message": "Docker デーモンに接続できません。Docker を起動してから再実行してください。"}
```

---

## `init --list --json` / `init --list-all --json` — Available Image Tags

```
redmine-docker-workspace init --list --json
redmine-docker-workspace init --list-all --json
```

Same tag listing as the human-readable `--list`/`--list-all`, as JSON — intended for populating a version picker (e.g. a GUI) before running `auto` or `init`. `--list --json` applies the same semantic-version filtering and `futuremine/redmine` 7.0.0 threshold as the human-readable form (see [`init`](REFERENCE.md#init--initialize-workspace) in the main reference); `--list-all --json` includes every tag, unfiltered.

**Example:**

```json
{
  "repositories": [
    {
      "cli_option": "--redmine",
      "repo": "library/redmine",
      "label": "Redmine < 7.0.0 (official)",
      "images": ["library/redmine:6.0.3", "library/redmine:6.0.2"]
    },
    {
      "cli_option": "--redmine",
      "repo": "futuremine/redmine",
      "label": "Redmine >= 7.0.0 (futuremine)",
      "images": ["futuremine/redmine:7.0.0", "futuremine/redmine:6.1.3"]
    },
    {
      "cli_option": "--redmica",
      "repo": "redmica/redmica",
      "label": "RedMica < 3.2.0",
      "images": ["redmica/redmica:2.7.0"]
    },
    {
      "cli_option": "--redmica",
      "repo": "futuremine/redmica",
      "label": "RedMica >= 3.2.0",
      "images": ["futuremine/redmica:3.2.0"]
    }
  ]
}
```

`images` entries are full image references (`<repo>:<tag>`), ready to pass to `docker pull` or `--redmine`/`--redmica`/`--base-image` — unlike the human-readable output, the `library/` prefix is not stripped.

**Partial failure** (e.g. Docker Hub rate-limited for one repository): the failing repository is reported with `"error": "fetch_failed"` in place of `images`, while the others are still listed normally.

```json
{"repositories": [
  {"cli_option": "--redmine", "repo": "library/redmine", "label": "Redmine < 7.0.0 (official)", "error": "fetch_failed"},
  {"cli_option": "--redmine", "repo": "futuremine/redmine", "label": "Redmine >= 7.0.0 (futuremine)", "images": ["futuremine/redmine:7.0.0"]}
]}
```

**Full failure** (all four repositories unreachable):

```json
{"error": "fetch_failed", "message": "Failed to fetch tags for all repositories."}
```
