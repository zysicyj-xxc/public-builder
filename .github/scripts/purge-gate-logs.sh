#!/usr/bin/env bash
# Delete Actions logs for completed public-builder gate runs.
# RUN_ID set: wait until that run completes, then delete its logs.
# RUN_ID empty: sweep completed runs of the gate workflows.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?}"

gates=(
  poll-private-gates.yml
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

delete_logs() {
  local id="$1"
  local code
  code=$(gh api --method DELETE "repos/${repo}/actions/runs/${id}/logs" -i 2>/dev/null | awk 'BEGIN{c=0} /^HTTP/{c=$2} END{print c}')
  case "$code" in
    204|404) echo "PASS purge" ;;
    *)
      code=$(gh api --method DELETE "repos/${repo}/actions/runs/${id}" -i 2>/dev/null | awk 'BEGIN{c=0} /^HTTP/{c=$2} END{print c}')
      case "$code" in
        204|404) echo "PASS purge" ;;
        *) echo "FAIL purge"; return 1 ;;
      esac
      ;;
  esac
}

if [ -n "${RUN_ID:-}" ]; then
  if ! printf '%s' "$RUN_ID" | grep -Eq '^[0-9]+$'; then
    echo "FAIL purge"
    exit 1
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
  delete_logs "$RUN_ID"
  exit 0
fi

fail=0
for wf in "${gates[@]}"; do
  ids=$(gh api --paginate "repos/${repo}/actions/workflows/${wf}/runs?status=completed&per_page=30" \
    --jq '.workflow_runs[].id' 2>/dev/null || true)
  for id in $ids; do
    if ! printf '%s' "$id" | grep -Eq '^[0-9]+$'; then
      continue
    fi
    if ! delete_logs "$id"; then
      fail=1
    fi
  done
done
exit "$fail"
