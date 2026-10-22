#!/usr/bin/env bash
# gitleaks 8.30.1: `gitleaks git --config .gitleaks.toml`.
# With no --log-opts this is `git log -p -U0 --full-history --all`,
# and only added lines are scanned. Checkout must be fetch-depth 0.
# --redact and the json report do not change that scan. The public line
# is a leak count. The report follows only on failure so quiet.sh can
# encrypt it and drop paths and secret text.
set -euo pipefail

run_scan() {
  local n rc report err
  if [ ! -f .gitleaks.toml ]; then
    echo "FAIL gitleaks config=0"
    return 1
  fi
  echo "PASS config=1"

  report=$(mktemp)
  err=$(mktemp)
  set +e
  gitleaks git --config .gitleaks.toml \
    --redact --no-banner --exit-code 1 \
    --report-format json --report-path "$report" >"$err" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "FAIL gitleaks leaks=0"
    cat "$err"
    rm -f "$report" "$err"
    return 1
  fi
  n=0
  if [ -s "$report" ]; then
    n=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(0)
    raise SystemExit
print(len(d) if isinstance(d, list) else 0)' "$report" 2>/dev/null || echo 0)
  fi
  if ! printf '%s' "$n" | grep -Eq '^[0-9]+$'; then
    n=0
  fi
  if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ]; then
    echo "PASS gitleaks leaks=0"
    rm -f "$report" "$err"
    return 0
  fi
  echo "FAIL gitleaks leaks=${n}"
  if [ -s "$report" ]; then
    cat "$report"
  fi
  if [ -s "$err" ]; then
    cat "$err"
  fi
  rm -f "$report" "$err"
  return 1
}

selftest() {
  local root repo dir out rc zeros
  root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
  zeros=$(python3 -c 'print("0"*40)')
  if grep -Fq "$zeros" \
    "$root/.github/scripts/gitleaks-gate.sh" \
    "$root/.github/workflows/gitleaks.yml"; then
    echo "FAIL selftest-zero"
    exit 1
  fi

  repo=$(mktemp -d)
  dir=$(mktemp -d)
  printf 'title = "local"\n' >"$repo/.gitleaks.toml"

  cat >"$dir/gitleaks" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GITLEAKS_LOG:?}"
if [ "${1:-}" != "git" ]; then
  exit 2
fi
case " $* " in
  *" --log-opts"*|*" detect "*) exit 2 ;;
esac
case " $* " in
  *" --config .gitleaks.toml "*) ;;
  *) exit 2 ;;
esac
report=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--report-path" ]; then
    report=$a
  fi
  prev=$a
done
if [ "${FAKE_LEAKS:-0}" != 0 ]; then
  printf '%s\n' '[{"File":"apps/secret/key.env","Secret":"supersecretvalue","StartLine":12}]' >"$report"
  exit 1
fi
printf '%s\n' '[]' >"$report"
exit 0
EOF
  chmod +x "$dir/gitleaks"
  export FAKE_GITLEAKS_LOG="$dir/gitleaks.log"
  : >"$FAKE_GITLEAKS_LOG"

  run_quiet() {
    local label="$1"
    set +e
    out=$(
      cd "$repo"
      PATH="$dir:$PATH" \
        RUNNER_TEMP="$dir" \
        GATE_LOG_KEY='selftest-key' \
        QUIET_LABEL=gitleaks \
        QUIET_KIND=generic \
        QUIET_CMD="$2" \
        bash "$root/.github/scripts/quiet.sh"
    )
    rc=$?
    set -e
    if printf '%s\n' "$out" | grep -F -q -e 'supersecretvalue' -e 'key.env' -e "$zeros"; then
      echo "FAIL selftest-${label}-leak"
      exit 1
    fi
  }

  export FAKE_LEAKS=0
  run_quiet clean "bash '$root/.github/scripts/gitleaks-gate.sh'"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'PASS config=1' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS gitleaks leaks=0' \
    || ! grep -qx 'git --config .gitleaks.toml --redact --no-banner --exit-code 1 --report-format json --report-path .*' "$FAKE_GITLEAKS_LOG"; then
    echo "FAIL selftest-clean"
    exit 1
  fi

  export FAKE_LEAKS=1
  run_quiet leak "bash '$root/.github/scripts/gitleaks-gate.sh'"
  if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -qx 'FAIL gitleaks leaks=1'; then
    echo "FAIL selftest-leak-count"
    exit 1
  fi
  if ! find "$dir/gate-encrypted" -type f -name '*.bin' | grep -q .; then
    echo "FAIL selftest-encrypted"
    exit 1
  fi

  rm -f "$repo/.gitleaks.toml"
  : >"$FAKE_GITLEAKS_LOG"
  run_quiet noconfig "bash '$root/.github/scripts/gitleaks-gate.sh'"
  if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -qx 'FAIL gitleaks config=0' \
    || [ -s "$FAKE_GITLEAKS_LOG" ]; then
    echo "FAIL selftest-config"
    exit 1
  fi

  rm -rf "$repo" "$dir"
  echo "PASS selftest"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_scan
