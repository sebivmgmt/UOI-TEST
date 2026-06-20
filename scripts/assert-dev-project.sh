#!/usr/bin/env bash
set -euo pipefail

DEV_REF="colkilearqxuyldzjutw"
LIVE_REF="clxfsghyasjmfoxmhpxv"
REF_FILE="supabase/.temp/project-ref"

if [[ ! -f "$REF_FILE" ]]; then
  echo "No linked Supabase project found at $REF_FILE." >&2
  echo "Run: supabase link --project-ref $DEV_REF" >&2
  exit 1
fi

ACTUAL_REF="$(tr -d '[:space:]' < "$REF_FILE")"

if [[ "$ACTUAL_REF" == "$LIVE_REF" ]]; then
  echo "REFUSING: repository is linked to LIVE ($LIVE_REF)." >&2
  exit 1
fi

if [[ "$ACTUAL_REF" != "$DEV_REF" ]]; then
  echo "REFUSING: expected DEV $DEV_REF, found $ACTUAL_REF." >&2
  exit 1
fi

echo "Confirmed DEV Supabase project: $ACTUAL_REF"
