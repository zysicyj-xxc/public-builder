#!/usr/bin/env bash
# Run private-repo .ci/*.tests.sh and staging-deployer go tests.
# Prints only PASS/FAIL/SKIP summary lines. Detail goes to stdout of the
# commands and is captured by quiet.sh when this file is the QUIET_CMD inner
# worker; this script itself writes detail to a file and prints summaries.
set -euo pipefail

detail="${DETAIL_LOG:-${RUNNER_TEMP:-/tmp}/ci-scripts-detail.log}"
: >"$detail"
failed=0
ran=0
skipped=0

run_one() {
  local name="$1"
  shift
  local log
  log=$(mktemp)
  set +e
  "$@" >"$log" 2>&1
  local rc=$?
  set -e
  cat "$log" >>"$detail"
  if [ "$rc" -ne 0 ] && grep -q 'unshare' "$log" && grep -Eq 'not permitted|Operation not permitted|cannot unshare|Invalid argument' "$log"; then
    echo "SKIP unshare ${name}"
    skipped=$((skipped + 1))
    rm -f "$log"
    return 0
  fi
  ran=$((ran + 1))
  if [ "$rc" -ne 0 ]; then
    echo "FAIL ${name}"
    failed=$((failed + 1))
  else
    echo "PASS ${name}"
  fi
  rm -f "$log"
}

shopt -s nullglob
scripts=(.ci/*.tests.sh)
shopt -u nullglob
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "FAIL ci-scripts no-shell-tests"
  exit 1
fi
for f in "${scripts[@]}"; do
  base=$(basename "$f" .tests.sh)
  base=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')
  run_one "$base" bash "$f"
done

mapfile -t mods < <(find . -type d -name '*staging-deployer*' -print | sort)
if [ "${#mods[@]}" -eq 0 ]; then
  echo "FAIL ci-scripts no-staging-deployer"
  failed=$((failed + 1))
else
  for d in "${mods[@]}"; do
    if [ ! -f "${d}/go.mod" ]; then
      continue
    fi
    run_one "staging-deployer" bash -lc "cd $(printf '%q' "$d") && go test ./... -count=1 -p 1 -json"
  done
fi

if [ "$failed" -ne 0 ]; then
  echo "FAIL ci-scripts failed=${failed} ran=${ran} skipped=${skipped}"
  exit 1
fi
echo "PASS ci-scripts failed=0 ran=${ran} skipped=${skipped}"
