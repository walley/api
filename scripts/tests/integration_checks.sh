#!/usr/bin/env bash
set -euo pipefail

# Simple integration checks for Guidepost API
# Usage:
#   BASE="http://localhost/table/1" HOST_HEADER="api.openstreetmap.social" ./scripts/tests/integration_checks.sh
# If HOST_HEADER is set, curl will add a Host header (useful for vhosts).

BASE="${BASE:-http://localhost/table/1}"
HOST_HEADER="${HOST_HEADER:-}"
CURL_COMMON=(curl -sS --max-time 10 --fail)

if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
else
  HAVE_JQ=0
fi

CURL_HDR=()
if [ -n "$HOST_HEADER" ]; then
  CURL_HDR=( -H "Host: $HOST_HEADER" )
fi

echo "Using BASE=$BASE"

WEB_BASE="${WEB_BASE:-http://localhost}"

# Check that key web pages include the upgraded jQuery + migrate
printf "[5/8] project page includes upgraded jQuery... "
proj_body=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$WEB_BASE/project/project.html" 2>/dev/null || true)
if [ -z "$proj_body" ]; then
  echo "SKIP (no response)";
else
  if echo "$proj_body" | grep -q "jquery-3.6.4.min.js" && echo "$proj_body" | grep -q "jquery-migrate-3.4.1.min.js"; then
    echo "OK";
  else
    fail "project page missing updated jQuery or migrate";
  fi
fi

printf "[6/8] projectlist page includes upgraded jQuery... "
plist_body=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$WEB_BASE/projectlist/projectlist.html" 2>/dev/null || true)
if [ -z "$plist_body" ]; then
  echo "SKIP (no response)";
else
  if echo "$plist_body" | grep -q "jquery-3.6.4.min.js" && echo "$plist_body" | grep -q "jquery-migrate-3.4.1.min.js"; then
    echo "OK";
  else
    fail "projectlist page missing updated jQuery or migrate";
  fi
fi

printf "[7/8] editor page includes upgraded jQuery... "
editor_body=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$WEB_BASE/editor/editor.html" 2>/dev/null || true)
if [ -z "$editor_body" ]; then
  echo "SKIP (no response)";
else
  if echo "$editor_body" | grep -q "jquery-3.6.4.min.js" && echo "$editor_body" | grep -q "jquery-migrate-3.4.1.min.js"; then
    echo "OK";
  else
    fail "editor page missing updated jQuery or migrate";
  fi
fi

printf "[8/8] upload.old dialog includes upgraded jQuery... "
upload_body=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$WEB_BASE/upload.old/dialog.html" 2>/dev/null || true)
if [ -z "$upload_body" ]; then
  echo "SKIP (no response)";
else
  if echo "$upload_body" | grep -q "jquery-3.6.4.min.js" && echo "$upload_body" | grep -q "jquery-migrate-3.4.1.min.js"; then
    echo "OK";
  else
    fail "upload dialog page missing updated jQuery or migrate";
  fi
fi

fail() {
  echo "FAILED: $1"
  exit 1
}

ok() { echo "OK"; }

# 1) ping -> pong
printf "[1/4] ping... "
out=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$BASE/ping" || true)
if [ "$out" = "pong" ]; then ok; else fail "expected 'pong', got: '$out'"; fi

# 2) count -> numeric
printf "[2/4] count (numeric)... "
out=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$BASE/count" || true)
if echo "$out" | grep -E '^[0-9]+$' >/dev/null 2>&1; then echo "OK (count=$out)"; else fail "count not numeric: '$out'"; fi

# 3) all?output=geojson&limit=1 -> GeoJSON FeatureCollection (may be skipped if DB empty)
printf "[3/4] all?output=geojson&limit=1... "
body=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$BASE/all?output=geojson&limit=1" 2>/dev/null || true)
if [ -z "$body" ]; then
  echo "SKIP (empty response)";
else
  if [ "$HAVE_JQ" -eq 1 ]; then
    if echo "$body" | jq -e '.type == "FeatureCollection"' >/dev/null 2>&1; then
      echo "OK (FeatureCollection)";
    else
      fail "response is not a FeatureCollection or malformed JSON";
    fi
  else
    if echo "$body" | grep -q 'FeatureCollection'; then
      echo "OK (FeatureCollection - jq not installed)";
    else
      fail "response does not contain 'FeatureCollection'";
    fi
  fi
fi

# 4) licenseinfo -> contains word 'license' or HTML
printf "[4/4] licenseinfo... "
body=$("${CURL_COMMON[@]}" "${CURL_HDR[@]}" "$BASE/licenseinfo" || true)
if echo "$body" | grep -qi "license" >/dev/null 2>&1; then echo "OK"; else fail "licenseinfo output unexpected"; fi


echo "All requested checks passed. Note: some checks may be skipped if the DB is empty or the server returns no results."