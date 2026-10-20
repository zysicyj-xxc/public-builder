#!/usr/bin/env bash
# Run a gate command and print only PASS/FAIL/SKIP summary lines.
# Full output stays in a temp file. On failure, if GATE_LOG_KEY is set, that
# file is encrypted into ${RUNNER_TEMP}/gate-encrypted and then deleted.
# If GATE_LOG_KEY is empty, the detail file is deleted and nothing is uploaded.
set -euo pipefail

safe_line() {
  printf '%s' "$1" | grep -Eq '^(PASS|FAIL|SKIP) [A-Za-z0-9 ._+=,()-]{0,160}$'
}

summarize() {
  local kind="$1" label="$2" log="$3" rc="$4"
  python3 - "$kind" "$label" "$log" "$rc" <<'PY'
import json, sys
kind, label, path, rc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
text = open(path, encoding="utf-8", errors="replace").read().splitlines()
safe = []
for line in text:
    line = line.strip()
    if line.startswith(("PASS ", "FAIL ", "SKIP ")) and all(c not in line for c in "/:\\"):
        if len(line) <= 180:
            safe.append(line)

def emit(line):
    if all(c not in line for c in "/:\\") and line.startswith(("PASS ", "FAIL ", "SKIP ")):
        print(line[:180])

if kind == "flutter-test":
    passed = failed = skipped = 0
    for line in text:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") != "testDone":
            continue
        result = ev.get("result")
        if result == "success":
            passed += 1
        elif result == "skipped":
            skipped += 1
        else:
            failed += 1
    state = "PASS" if rc == 0 and failed == 0 else "FAIL"
    emit(f"{state} {label} failed={failed} passed={passed} skipped={skipped}")
elif kind == "flutter-analyze":
    errors = 0
    for line in text:
        if "error •" in line or line.strip().startswith("error -"):
            errors += 1
    state = "PASS" if rc == 0 and errors == 0 else "FAIL"
    emit(f"{state} {label} errors={errors}")
elif kind == "go-test":
    passed = failed = skipped = 0
    pkgs = []
    for line in text:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        action = ev.get("Action")
        if "Test" in ev:
            if action == "pass":
                passed += 1
            elif action == "skip":
                skipped += 1
            elif action == "fail":
                failed += 1
        elif action == "fail" and ev.get("Package"):
            name = ev["Package"].rsplit("/", 1)[-1]
            if name and name not in pkgs and len(name) <= 40:
                pkgs.append(name)
    state = "PASS" if rc == 0 and failed == 0 else "FAIL"
    shown = ",".join(pkgs[:8])
    extra = f" packages={shown}" if shown else ""
    emit(f"{state} {label} failed={failed} passed={passed} skipped={skipped}{extra}")
else:
    if safe:
        for line in safe[:20]:
            emit(line)
    else:
        emit(("PASS " if rc == 0 else "FAIL ") + label)
PY
}

run_cmd() {
  local log="$1"
  bash -c "${QUIET_CMD:?QUIET_CMD empty}" >"$log" 2>&1
}

if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  export RUNNER_TEMP="$tmp"
  export QUIET_LABEL="demo"
  export QUIET_KIND="generic"
  export QUIET_CMD='echo "panic lib/foo.dart:12 stack"; echo "branch feature/secret"; echo "FAIL demo failed=1"; exit 1'
  set +e
  out=$(bash "$0")
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "selftest expected nonzero" >&2
    exit 1
  fi
  if printf '%s\n' "$out" | grep -Eq 'foo.dart|feature/|stack|panic'; then
    echo "selftest leaked detail" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if [ "$out" != "FAIL demo failed=1" ]; then
    echo "selftest summary mismatch" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  export QUIET_KIND="flutter-test"
  export QUIET_LABEL="box"
  export QUIET_CMD='printf "%s\n" "{\"type\":\"testDone\",\"result\":\"error\",\"test\":{\"name\":\"secret at lib/a.dart:3\"}}" "{\"type\":\"testDone\",\"result\":\"success\"}"; exit 1'
  set +e
  out=$(bash "$0")
  set -e
  if printf '%s\n' "$out" | grep -Eq 'secret|a.dart'; then
    echo "selftest flutter leak" >&2
    exit 1
  fi
  case "$out" in
    "FAIL box failed=1 passed=1 skipped=0") ;;
    *) echo "selftest flutter summary mismatch" >&2; printf '%s\n' "$out" >&2; exit 1 ;;
  esac
  echo "quiet selftest ok"
  exit 0
fi

label="${QUIET_LABEL:-gate}"
kind="${QUIET_KIND:-generic}"
if ! printf '%s' "$label" | grep -Eq '^[A-Za-z0-9 ._+=,()-]{1,80}$'; then
  echo "FAIL label"
  exit 1
fi
if ! printf '%s' "$kind" | grep -Eq '^(generic|flutter-test|flutter-analyze|go-test)$'; then
  echo "FAIL kind"
  exit 1
fi

root="${RUNNER_TEMP:-/tmp}"
mkdir -p "$root/gate-encrypted"
log=$(mktemp "$root/quiet.XXXXXX")
set +e
run_cmd "$log"
rc=$?
set -e
summarize "$kind" "$label" "$log" "$rc" || echo "$( [ "$rc" -eq 0 ] && echo PASS || echo FAIL ) ${label}"
if [ "$rc" -ne 0 ] && [ -n "${GATE_LOG_KEY:-}" ]; then
  safe=$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '-')
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
    -pass env:GATE_LOG_KEY \
    -in "$log" \
    -out "$root/gate-encrypted/${safe}.bin"
fi
rm -f "$log"
exit "$rc"
