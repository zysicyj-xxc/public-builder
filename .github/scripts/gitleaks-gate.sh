#!/usr/bin/env bash
# gitleaks 8.30.1 over BASE..HEAD. Empty BASE scans the one checked-out commit.
# Config is .gitleaks.toml, else gitleaks.toml, else the 8.30.1 built-in rules.
# The public line is a leak count. A redacted report follows only on failure
# so quiet.sh can encrypt it and drop paths and secret text.
set -euo pipefail

is_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

is_zero_sha() {
  local s="$1" rest
  [ "${#s}" -eq 40 ] || return 1
  rest=$(printf '%s' "$s" | tr -d '0')
  [ -z "$rest" ]
}

norm_sha() {
  printf '%s' "$1" | tr 'A-F' 'a-f' | tr -d '[:space:]'
}

run_scan() {
  local base head opts n rc report err
  local -a cfg=()
  base=$(norm_sha "${BASE:-}")
  head=$(norm_sha "${HEAD_SHA:-}")
  if ! is_sha "$head" || is_zero_sha "$head"; then
    echo "FAIL gitleaks leaks=0"
    return 1
  fi
  if [ -n "$base" ] && { ! is_sha "$base" || is_zero_sha "$base"; }; then
    echo "FAIL gitleaks leaks=0"
    return 1
  fi

  if [ -f .gitleaks.toml ]; then
    cfg=(--config .gitleaks.toml)
    echo "PASS config=1"
  elif [ -f gitleaks.toml ]; then
    cfg=(--config gitleaks.toml)
    echo "PASS config=1"
  else
    echo "PASS config=0"
  fi

  if [ -n "$base" ]; then
    if ! git cat-file -e "${base}^{commit}" 2>/dev/null \
      || ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
      echo "FAIL gitleaks leaks=0"
      return 1
    fi
    opts="${base}..${head}"
  else
    opts="-n 1"
  fi

  report=$(mktemp)
  err=$(mktemp)
  set +e
  gitleaks detect --source . "${cfg[@]}" --log-opts="$opts" \
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
  local root repo dir out rc zeros base head
  root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
  zeros=$(python3 -c 'print("0"*40)')
  if grep -Fq "$zeros" \
    "$root/.github/scripts/gitleaks-gate.sh" \
    "$root/.github/scripts/gitleaks-range.sh" \
    "$root/.github/workflows/gitleaks.yml"; then
    echo "FAIL selftest-zero"
    exit 1
  fi

  repo=$(mktemp -d)
  dir=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config user.email "selftest@example.com"
  git -C "$repo" config user.name "selftest"
  git -C "$repo" config commit.gpgsign false
  echo "one" >"$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -q -m one
  base=$(git -C "$repo" rev-parse HEAD)
  echo "two" >"$repo/f"
  git -C "$repo" commit -q -am two
  head=$(git -C "$repo" rev-parse HEAD)
  printf 'title = "local"\n' >"$repo/.gitleaks.toml"

  cat >"$dir/gitleaks" <<'EOF'
#!/bin/bash
set -euo pipefail
report=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--report-path" ]; then
    report=$a
  fi
  prev=$a
done
if [ ! -f .gitleaks.toml ] && [ ! -f gitleaks.toml ]; then
  if printf '%s\n' "$@" | grep -q -- '--config'; then
    exit 2
  fi
fi
if [ "${FAKE_LEAKS:-0}" != 0 ]; then
  printf '%s\n' '[{"File":"apps/secret/key.env","Secret":"supersecretvalue","StartLine":12}]' >"$report"
  exit 1
fi
printf '%s\n' '[]' >"$report"
exit 0
EOF
  chmod +x "$dir/gitleaks"

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
    if printf '%s\n' "$out" | grep -F -q -e 'supersecretvalue' -e 'key.env' -e "$base" -e "$head" -e "$zeros"; then
      echo "FAIL selftest-${label}-leak"
      exit 1
    fi
  }

  export FAKE_LEAKS=0
  run_quiet clean "BASE='$base' HEAD_SHA='$head' bash '$root/.github/scripts/gitleaks-gate.sh'"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'PASS config=1' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS gitleaks leaks=0'; then
    echo "FAIL selftest-clean"
    exit 1
  fi

  export FAKE_LEAKS=1
  run_quiet leak "BASE='$base' HEAD_SHA='$head' bash '$root/.github/scripts/gitleaks-gate.sh'"
  if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -qx 'FAIL gitleaks leaks=1'; then
    echo "FAIL selftest-leak-count"
    exit 1
  fi
  if ! find "$dir/gate-encrypted" -type f -name '*.bin' | grep -q .; then
    echo "FAIL selftest-encrypted"
    exit 1
  fi

  export FAKE_LEAKS=0
  run_quiet one "BASE='' HEAD_SHA='$head' bash '$root/.github/scripts/gitleaks-gate.sh'"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'PASS gitleaks leaks=0'; then
    echo "FAIL selftest-one"
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
