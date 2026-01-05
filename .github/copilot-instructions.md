# GitHub Copilot instructions for the Guidepost "api" repository

Goal: Give an AI coding agent the minimal, actionable context to be immediately productive in this codebase (fix bugs, add small features, and write tests/docs). Keep it short and specific to this project.

## Big picture
- This repo implements the Guidepost API (spatial image DB). Core code runs as mod_perl2 handlers under Apache; web frontends live in `webapps/` and call the API endpoints. See `README.md` for a short overview and Apache config snippet.
- Main runtime components:
  - `handler/Guidepost/Table.pm` — central REST-like request dispatcher and core logic (DB access, output formats, routing). Read this first to understand endpoints.
  - `handler/Guidepost/Upload.pm` and `handler/Guidepost/Commons.pm` — upload & commons-specific handlers.
  - `webapps/` — static web frontends (e.g., `webapps/simplemap/`, `webapps/upload.*/`) that interact with the handlers via HTTP.
  - `scripts/` — utility scripts for data ingestion and maintenance (e.g., `scripts/insert/processdir.pl`, `scripts/commons/*`).

## How the API is organized (patterns you will rely on)
- URL structure: requests are routed by path segments in `Table.pm`:
  `/v/<request>/<param...>` where the second and later path pieces determine the action (e.g. `all`, `id`, `tags`, `project`, `close`). Read `handler/Guidepost/Table.pm` for the full dispatch table.
- HTTP method mapping matters: many endpoints interpret GET, POST and DELETE differently (example: `projectlist` and `tags`). Check the `if ($r->method() eq ...)` blocks.
- Output formats selectable via `?output=`: `html` (default), `geojson`, `json`, `gpx`, `kml`. Handlers set `Content-Type` accordingly.
- Common query params and behavior: `bbox`, `limit`, `offset`, `project`. `bbox` parsing happens early in `Table.pm` and affects spatial queries.
- Database: SQLite accessed through `DBI` using a file at `dbpath` (configured via Apache `PerlSetVar dbpath`). Default/legacy filenames used in scripts: `guidepost` and `commons`.

## Development & debugging workflow (practical steps)
- Requirements: Apache + mod_perl2, Perl modules used in `handler/*.pm` (DBI, Geo::JSON, Image::ExifTool, etc.) — see `use` lines.
- Local dev approach:
  - Configure Apache to `PerlRequire /path/to/handler/startup.pl` and add `PerlResponseHandler Guidepost::Table` under a `<Location>` block (see `README.md` example).
  - Set `PerlSetVar` for `dbpath`, `githubclientid`, `githubclientsecret`, and optional Nextcloud vars in Apache config.
  - For quick testing, run curl commands against your local Apache vhost and set Host header appropriately; many frontend files hardcode remote hosts, so update them if needed for local testing.
- Logs & runtime info: handlers call syslog (via `wsyslog`/`openlog`); check system logs (`/var/log/syslog` or `journalctl`) for handler output.
- Database inspection: use `sqlite3 guidepost "SELECT ..."` to inspect or `sqlite3 guidepost ".schema"` to view schema.
- Scripts & manual checks: data ingestion scripts are runnable directly (e.g., `scripts/insert/processdir.pl`), they expect files & DB presence and may reference `jhead` and other system tools. A small set of executable curl-based integration checks lives at `scripts/tests/integration_checks.sh`; run them with `BASE=http://localhost/table/1 [HOST_HEADER="api.openstreetmap.social"] chmod +x scripts/tests/integration_checks.sh && ./scripts/tests/integration_checks.sh`.

## Project-specific conventions
- Minimal tests: there are no automated unit or integration tests in the repo. When adding behavior, prefer lightweight, verifiable examples and document expected curl commands for manual verification.
- DB-first logic: many operations are direct SQL against the SQLite files — follow the exact column names (see schema in `README.md`) when writing or fixing SQL.
- Backwards-compatibility: several webapps or scripts include hardcoded remote hostnames (e.g., `api.openstreetmap.cz`, `api.openstreetmap.social`). Update references when making local testing instructions or changes.
- Output formatting: some endpoints return HTML fragments used by frontends — be careful changing HTML output shape without updating consumers.

## Common change examples (copyable snippets)
- Add a new endpoint in `Table.pm`:
  - Add a new `elsif ($api_request eq "mycall") { ... }` branch in the main dispatcher.
  - Use `&parse_query_string($r)` and `$post_data{...}` like other handlers.
  - Use `$r->content_type('text/plain; charset=utf-8')` and `$r->print($output)` to return data.
- Debugging an API route: `curl -v 'http://localhost/table/1/get/123?output=json' -H 'Host: api.openstreetmap.social'` (adjust host/port).
- Run a script against the DB: `sqlite3 guidepost "SELECT * FROM guidepost LIMIT 5;"` or execute a maintenance script: `perl scripts/insert/processdir.pl /path/to/images username /static/uploads/ "ref" "note" "CCBYSA4"`.

## Key files to inspect when making changes
- `handler/Guidepost/Table.pm` (start here for request routing and DB access) ✅
- `handler/Guidepost/Upload.pm` and `handler/Guidepost/Commons.pm` (uploads/commons flows)
- `handler/startup.pl` (simple lib path setup used by Apache)
- `README.md` (project overview + Apache config snippet)
- `webapps/` (frontends — update these when changing API JSON/HTML shape)
- `scripts/` (data ingestion and maintenance utilities)

## PR & code style hints
- Keep changes small and focused; many consumers rely on exact URL shapes and output formats.
- Add or update manual test instructions (curl commands) when changing endpoints rather than adding heavy test frameworks.

---
If anything here is ambiguous or you'd like more details about a specific area (e.g., OAuth flow in `Table.pm`, or how `tags` and `projects` are stored), tell me which part and I will expand or add concrete examples and curl-based tests.
