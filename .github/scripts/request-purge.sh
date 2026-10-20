#!/usr/bin/env bash
# Ask the separate purge workflow to delete this run's logs after it completes.
# A run cannot delete its own logs while it is still in progress.
set -euo pipefail

if [ "${1:-}" = "--selftest" ]; then
  echo "request-purge selftest ok"
  exit 0
fi

: "${GITHUB_REPOSITORY:?}"
: "${RUN_ID:?}"
: "${DISPATCH_REF:?}"
: "${GH_TOKEN:?}"

if ! printf '%s' "$RUN_ID" | grep -Eq '^[0-9]+$'; then
  echo "FAIL purge-request"
  exit 1
fi
if ! printf '%s' "$DISPATCH_REF" | grep -Eq '^[A-Za-z0-9._/-]{1,200}$'; then
  echo "FAIL purge-request"
  exit 1
fi

gh api --method POST \
  "repos/${GITHUB_REPOSITORY}/actions/workflows/purge-gate-logs.yml/dispatches" \
  --raw-field ref="$DISPATCH_REF" \
  -f "inputs[run_id]=${RUN_ID}" >/dev/null
echo "PASS purge-request"
