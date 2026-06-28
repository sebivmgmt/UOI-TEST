#!/usr/bin/env bash
# Run Score v2.2 official-read cutover regression suites against DEV Supabase.
#
# Required env var:
#   SUPABASE_ACCESS_TOKEN   — Management API token (sbp_…)
#
# Optional env var:
#   SUPABASE_PROJECT_REF    — project ref (defaults to DEV: colkilearqxuyldzjutw)
#
# Usage:
#   SUPABASE_ACCESS_TOKEN=<token> ./supabase/tests/run_score_v22_cutover_regression.sh
#
# Runs:
#   1. score_v22_official_read_cutover_regression.sql   (cutover correctness + security)
#   2. score_v22_official_read_cutover_rollback_regression.sql  (rollback correctness)
#
# Both suites run in BEGIN/ROLLBACK transactions — DEV data is not modified.
set -euo pipefail

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  echo "Error: SUPABASE_ACCESS_TOKEN is not set." >&2
  exit 1
fi

PROJECT_REF="${SUPABASE_PROJECT_REF:-colkilearqxuyldzjutw}"
TESTS_DIR="$(dirname "$0")"

_post_sql_to_api() (
  local label="$1"
  local sql="$2"
  local body_file http_status body msg

  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT

  http_status="$(
    curl -sS \
      -o "$body_file" \
      -w '%{http_code}' \
      -X POST "https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query" \
      -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg q "$sql" '{query: $q}')"
  )" || { echo "❌ HTTP request failed." >&2; return 1; }

  body="$(cat "$body_file")"
  echo "HTTP $http_status"
  echo ""

  if [[ "$http_status" != 2* ]]; then
    msg=$(echo "$body" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('message','unknown error'))" \
      2>/dev/null || echo "$body")
    echo "❌ FAILED (HTTP $http_status): $msg" >&2
    return 1
  fi

  if echo "$body" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) else 1)" \
    2>/dev/null; then
    echo "✅ PASSED"
    return 0
  else
    msg=$(echo "$body" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('message','unknown error'))" \
      2>/dev/null || echo "$body")
    echo "❌ FAILED: $msg"
    return 1
  fi
)

run_suite() {
  local label="$1"
  local sql_file="$2"

  echo "──────────────────────────────────────────"
  echo "Suite : $label"
  echo "File  : $sql_file"
  echo ""

  local sql
  sql="$(cat "$sql_file")"
  _post_sql_to_api "$label" "$sql"
}

# Assembles the rollback regression transaction dynamically:
#   begin; + regression file (with sentinel replaced by actual rollback SQL) + rollback;
# This proves the actual rollback file works, not an inline copy.
run_rollback_suite() {
  local label="$1"
  local regression_file="$2"
  local rollback_file="$3"

  echo "──────────────────────────────────────────"
  echo "Suite   : $label"
  echo "Test    : $regression_file"
  echo "Rollback: $rollback_file"
  echo ""

  if [[ ! -f "$rollback_file" ]]; then
    echo "❌ Rollback file not found: $rollback_file" >&2
    return 1
  fi

  local sql
  sql=$(python3 - "$regression_file" "$rollback_file" <<'PYEOF'
import sys

with open(sys.argv[1]) as f:
    regression = f.read()

with open(sys.argv[2]) as f:
    rollback = f.read()

sentinel = '-- <<INJECT_ROLLBACK_FILE>>'
lines = regression.splitlines(keepends=True)
matches = [
    index
    for index, line in enumerate(lines)
    if line.strip() == sentinel
]

if len(matches) != 1:
    print(
        f"ERROR: expected exactly one standalone rollback sentinel in {sys.argv[1]}, found {len(matches)}",
        file=sys.stderr,
    )
    sys.exit(1)

index = matches[0]
assembled = (
    ''.join(lines[:index])
    + rollback.rstrip()
    + '\n'
    + ''.join(lines[index + 1:])
)

print(assembled, end='')
PYEOF
  ) || { echo "❌ Failed to assemble rollback test SQL (sentinel missing or file unreadable)." >&2; return 1; }

  _post_sql_to_api "$label" "$sql"
}

echo "=== Score v2.2 Cutover Regression Runner ==="
echo "Project : $PROJECT_REF"
echo ""

FAILED=0

run_suite \
  "Cutover correctness + security" \
  "$TESTS_DIR/score_v22_official_read_cutover_regression.sql" \
  || FAILED=1

run_rollback_suite \
  "Rollback correctness" \
  "$TESTS_DIR/score_v22_official_read_cutover_rollback_regression.sql" \
  "$(dirname "$TESTS_DIR")/rollbacks/20260627018000_score_v22_official_read_cutover_rollback.sql" \
  || FAILED=1

echo ""
echo "══════════════════════════════════════════"
if [[ "$FAILED" -eq 0 ]]; then
  echo "✅ All suites passed"
else
  echo "❌ One or more suites failed"
  exit 1
fi
