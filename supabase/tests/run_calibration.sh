#!/usr/bin/env bash
# Run the score_v2 calibration snapshot suite against DEV Supabase.
#
# Required env var:
#   SUPABASE_ACCESS_TOKEN   — Management API token (sbp_…)
#
# Optional env var:
#   SUPABASE_PROJECT_REF    — project reference (defaults to DEV)
#
# Usage:
#   SUPABASE_ACCESS_TOKEN=<token> ./supabase/tests/run_calibration.sh
set -euo pipefail

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  echo "Error: SUPABASE_ACCESS_TOKEN is not set." >&2
  exit 1
fi

PROJECT_REF="${SUPABASE_PROJECT_REF:-colkilearqxuyldzjutw}"
SQL_FILE="$(dirname "$0")/calibration_score_v2_curve.sql"

echo "=== IOU DEV Calibration Runner ==="
echo "Project : $PROJECT_REF"
echo "Suite   : $SQL_FILE"
echo ""

SQL=$(cat "$SQL_FILE")

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

HTTP_STATUS="$(
  curl -sS \
    -o "$BODY_FILE" \
    -w '%{http_code}' \
    -X POST "https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query" \
    -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$SQL" '{query: $q}')"
)" || { echo "❌ HTTP request failed." >&2; exit 1; }

BODY="$(cat "$BODY_FILE")"

echo "HTTP $HTTP_STATUS"
echo ""

if [[ "$HTTP_STATUS" != 2* ]]; then
  MSG=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','unknown error'))" 2>/dev/null || echo "(no response body)")
  echo "❌ Calibration suite FAILED (HTTP $HTTP_STATUS):" >&2
  echo "$MSG" >&2
  exit 1
fi

# The Management API returns [] on success, or {"message":"..."} on SQL error.
if echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) else 1)" 2>/dev/null; then
  echo "✅ Calibration suite PASSED (snapshot unchanged)"
  exit 0
else
  MSG=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','unknown error'))" 2>/dev/null || echo "$BODY")
  echo "❌ Calibration suite FAILED (function behavior drifted):"
  echo "$MSG"
  exit 1
fi
