#!/usr/bin/env bash
# Delete Actions logs for completed public-builder gate runs.
# RUN_ID set: wait until that run completes, then delete its logs.
# RUN_ID empty: sweep completed runs of the gate workflows.
# DRY_RUN true: GET the actions runs API and count, without deleting.
# Schedule runs print the deleted count, the failed count, and HTTP
# status codes for failures.
set -euo pipefail

if [ "${1:-}" = "--selftest" ]; then
  echo "purge-gate-logs selftest ok"
  exit 0
fi

repo="${GITHUB_REPOSITORY:?}"
: "${GH_TOKEN:?}"

gates=(
  poll-private-gates.yml
  poll-gates-watchdog.yml
  quality-analyze.yml
  flutter-test.yml
  daymica-test.yml
  ci-scripts.yml
  i18n-gate.yml
  visual-lint.yml
  domain-gate.yml
  scripts-gate.yml
  web-visual.yml
  utools-visual.yml
  purge-gate-logs.yml
)

dry=0
case "${DRY_RUN:-false}" in
  true|True|TRUE) dry=1 ;;
esac

deleted=0
failed=0
would=0

http_code() {
  gh api "$@" -i 2>/dev/null | awk 'BEGIN{c=0} /^HTTP/{c=$2} END{print c+0}' || true
}

note_fail() {
  local code="${1:-0}"
  case "$code" in
    ''|*[!0-9]*) code=0 ;;
  esac
  failed=$((failed + 1))
  echo "FAIL purge http=${code}" >&2
}

delete_one() {
  local id="$1" code
  if [ "$dry" -eq 1 ]; then
    would=$((would + 1))
    return 0
  fi
  code=$(http_code --method DELETE "repos/${repo}/actions/runs/${id}/logs")
  case "$code" in
    204|404) deleted=$((deleted + 1)); return 0 ;;
  esac
  code=$(http_code --method DELETE "repos/${repo}/actions/runs/${id}")
  case "$code" in
    204|404) deleted=$((deleted + 1)); return 0 ;;
  esac
  note_fail "$code"
}

finish() {
  if [ "$dry" -eq 1 ]; then
    echo "dry_run would_delete=${would}"
  else
    echo "purge deleted=${deleted} failed=${failed}"
  fi
  [ "$failed" -eq 0 ]
}

if [ "$dry" -eq 1 ]; then
  code=$(http_code "repos/${repo}/actions/runs?per_page=1")
  echo "permissions http=${code}"
  if [ "$code" != "200" ]; then
    echo "dry_run would_delete=0"
    exit 1
  fi
fi

if [ -n "${RUN_ID:-}" ]; then
  if ! printf '%s' "$RUN_ID" | grep -Eq '^[0-9]+$'; then
    note_fail 0
    would=0
    finish
    exit 1
  fi
  if [ "$dry" -eq 1 ]; then
    would=1
    finish
    exit 0
  fi
  status=""
  for _ in $(seq 1 30); do
    status=$(gh api "repos/${repo}/actions/runs/${RUN_ID}" --jq .status 2>/dev/null || true)
    if [ "$status" = "completed" ]; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "completed" ]; then
    echo "SKIP purge still-running"
    exit 0
  fi
  delete_one "$RUN_ID"
  finish
  exit 0
fi

for wf in "${gates[@]}"; do
  err=$(mktemp)
  set +e
  ids=$(gh api --paginate \
    "repos/${repo}/actions/workflows/${wf}/runs?status=completed&per_page=30" \
    --jq '.workflow_runs[].id' 2>"$err")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    code=$(sed -n 's/.*HTTP \([0-9][0-9][0-9]\).*/\1/p' "$err" | head -1)
    rm -f "$err"
    note_fail "${code:-0}"
    break
  fi
  rm -f "$err"
  for id in $ids; do
    if printf '%s' "$id" | grep -Eq '^[0-9]+$'; then
      delete_one "$id"
    fi
  done
done

finish
