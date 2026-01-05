commit and push# Integration checks for Guidepost API ✅

Purpose
- Small set of manual, executable integration checks for the Guidepost API.
- Designed for quick smoke-testing of a local development instance.

Prerequisites
- bash and curl available on your PATH.
- Optional: `jq` (for stricter JSON validation).
- A running Guidepost webserver (Apache + mod_perl2) with `handler/Guidepost/Table.pm` mounted (see root `README.md`).

Usage
```bash
chmod +x scripts/tests/integration_checks.sh
# Basic (default):
BASE="http://localhost/table/1" ./scripts/tests/integration_checks.sh
# With Host header for vhosts:
BASE="http://localhost/table/1" HOST_HEADER="api.openstreetmap.social" ./scripts/tests/integration_checks.sh
```

What the script checks
1. GET /ping → expects `pong`
2. GET /count → expects a numeric result
3. GET /all?output=geojson&limit=1 → expects a GeoJSON FeatureCollection (skipped or relaxed if DB empty)
4. GET /licenseinfo → expects the response to mention "license"

Notes
- These checks are read-only and safe to run against a development server. They may return reduced output or be skipped if an empty DB is installed.
- To add write/modify checks (e.g., `tags`, `project`), set up a disposable test DB and credentials and add assertions that clean up after themselves.
- If you add more checks, keep them idempotent and document any required test data in this README.

Extending the tests
- The tests are a single Bash script; add new steps (curl + simple validation) or convert to a small test harness (e.g., bats or a short Python script) if you want more structured assertions and reporting.

Feedback
- Open an issue or send a PR to expand/modify tests. Include required DB setup instructions and example curl commands for reproducibility.
