# todo extensions

An extension is **any executable** placed in `~/.todo/extensions/`. Write one
in any language — shell, Python, Zig, anything that can read stdin and print
JSON. The filename is the extension's identity (its *name*).

`<name>.toml` files in the same directory are the extensions' config files and
are skipped during discovery.

## Lifecycle

```
todo ext list                                  # discover + show manifests
todo ext config  <name> [key=value ...]        # global config (~/.todo/extensions/<name>.toml)
todo ext setup   <name>                        # interactive setup (e.g. OAuth)
todo ext link    <space> <project> <name> [key=value ...]
todo ext import  <space> <project>             # pull remote tasks into the project
todo ext export  <space> <project>             # push the project's tasks out
todo ext unlink  <space> <project>
```

In the TUI: settings (`s`) → **Extensions** tab lists installed extensions and
lets you edit their config. In the main view, `i` imports and `I` exports the
current project.

## Protocol

The app invokes the extension as `<executable> <command>` and exchanges JSON:
the request arrives on **stdin**, the response is printed to **stdout**.
Anything written to **stderr** is shown to the user when the extension fails.
A non-zero exit code or an `{"error": "..."}` response marks failure.

### `manifest`

No stdin. Print the extension's description:

```json
{
  "name": "linear",
  "version": "1.0.0",
  "description": "Import and export Linear issues assigned to you",
  "capabilities": ["import", "export", "setup"],
  "config": [
    {"key": "api_key", "label": "Linear API key", "secret": true},
    {"key": "team_id", "label": "Team ID"}
  ]
}
```

- `capabilities` — any of `import`, `export`, `setup`.
- `config` — declares the keys the app should offer in its config UI.
  `secret: true` masks the value when displayed.

### `import`

stdin:

```json
{
  "config":  {"api_key": "…", "team_id": "…"},
  "space":   "work",
  "project": "api"
}
```

`config` is the extension's global config overlaid with the project's
per-project values (project wins).

stdout:

```json
{
  "tasks": [
    {
      "external_id": "abc-123",
      "title":       "Fix the bug",
      "description": "…",
      "status":      "todo | in-progress | in-review | done",
      "priority":    "low | medium | high | urgent",
      "due":         "2026-07-01",
      "url":         "https://…"
    }
  ]
}
```

`external_id` and `title` are required; everything else is optional. The app
merges by `(extension name, external_id)`: existing linked tasks are updated
(remote wins on title/status/priority; a substantially longer local
description is preserved), unknown ids create new tasks. Re-importing is
idempotent.

### `export`

stdin: same as `import` plus the project's tasks:

```json
{
  "config": {…}, "space": "work", "project": "api",
  "tasks": [
    {"id": 1, "external_id": "abc-123", "source": "linear",
     "title": "…", "description": "…", "status": "done",
     "priority": "high", "due": "", "url": "…"}
  ]
}
```

The extension should only touch tasks whose `source` matches its own name and
whose `external_id` is non-empty, counting everything else as skipped.

stdout:

```json
{"exported": 3, "skipped": 2}
```

### `setup` (optional)

For interactive authentication (e.g. an OAuth device flow). The user's
terminal is attached to stdin/stderr, so the extension can print instructions
and prompt. Current global config is provided as JSON in the
`TODO_EXT_CONFIG` environment variable. Print the config values to save:

```json
{"config": {"token": "ghp_…"}}
```

## Minimal example (shell)

```sh
#!/bin/sh
# ~/.todo/extensions/demo  (chmod +x)
case "$1" in
  manifest)
    echo '{"name":"demo","description":"Demo","capabilities":["import"],"config":[]}' ;;
  import)
    cat > /dev/null   # consume the request
    echo '{"tasks":[{"external_id":"d1","title":"Hello from demo"}]}' ;;
  *)
    echo '{"error":"unsupported command"}'; exit 1 ;;
esac
```

## Bundled extensions

`linear`, `github` and `trello` live in `extensions/` in this repo and build
to `zig-out/extensions/`:

```sh
zig build
cp zig-out/extensions/* ~/.todo/extensions/
```

| extension | capabilities | global config | per-project config (via `ext link`) |
|-----------|-------------|---------------|--------------------------------------|
| linear    | import, export | `api_key`, `team_id` | `team_id` (enables status export) |
| github    | import, export, setup | `token`, `client_id` | `owner`, `repo` |
| trello    | import | `api_key`, `token` | `board_id`, `list_todo`, `list_in_progress`, `list_in_review`, `list_done` |

GitHub setup (`todo ext setup github`) runs the OAuth device flow in the
terminal; it needs `client_id` configured first.
