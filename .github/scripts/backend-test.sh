#!/usr/bin/env bash
# go build and go test for the private backend. Stdout is go test -json only.
set -euo pipefail
go build ./... >"${RUNNER_TEMP:-/tmp}/go-build.txt" 2>&1 || {
  cat "${RUNNER_TEMP:-/tmp}/go-build.txt"
  exit 1
}
int=$(mktemp)
set +e
go test ./internal/integration/... -count=1 -p 1 -json >"$int"
int_rc=$?
set -e
cat "$int"
python3 - "$int" "$int_rc" <<'PY'
import json, sys
path, rc = sys.argv[1], int(sys.argv[2])
passed = skipped = 0
for line in open(path, encoding="utf-8", errors="replace"):
    if not line.strip().startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if "Test" not in ev:
        continue
    if ev.get("Action") == "pass":
        passed += 1
    elif ev.get("Action") == "skip":
        skipped += 1
if skipped:
    sys.exit(2)
if passed < 1:
    sys.exit(3)
if rc != 0:
    sys.exit(rc)
PY
mapfile -t pkgs < <(go list ./... | grep -Ev '/internal/integration($|/)')
if [ "${#pkgs[@]}" -eq 0 ]; then
  exit 0
fi
go test "${pkgs[@]}" -count=1 -p 1 -json
