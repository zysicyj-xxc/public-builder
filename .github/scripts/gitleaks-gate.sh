#!/usr/bin/env bash
# gitleaks 8.30.1, added lines in one range, not full history.
# Open PR: BASE..HEAD. Otherwise the first parent..HEAD.
# No parent: -1 HEAD (one commit). Same shape as the private workflow's
# `gitleaks git --config .gitleaks.toml --log-opts=... --redact --no-banner .`
# The json report is only so the public line can be a count.
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
  local base head parent range n rc report err
  if [ ! -f .gitleaks.toml ]; then
    echo "FAIL gitleaks config=0"
    return 1
  fi
  echo "PASS config=1"

  head=$(norm_sha "${HEAD_SHA:-}")
  if ! is_sha "$head" || is_zero_sha "$head"; then
    echo "FAIL gitleaks leaks=0"
    return 1
  fi
  if ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
    echo "FAIL gitleaks leaks=0"
    return 1
  fi

  base=$(norm_sha "${BASE:-}")
  if [ -n "$base" ]; then
    if ! is_sha "$base" || is_zero_sha "$base" \
      || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
      echo "FAIL gitleaks leaks=0"
      return 1
    fi
    range="${base}..${head}"
  else
    parent=$(git rev-parse --verify --quiet "${head}^" 2>/dev/null || true)
    parent=$(norm_sha "$parent")
    if is_sha "$parent" && ! is_zero_sha "$parent"; then
      range="${parent}..${head}"
    else
      range="-1 ${head}"
    fi
  fi

  report=$(mktemp)
  err=$(mktemp)
  set +e
  gitleaks git --config .gitleaks.toml \
    --log-opts="$range" \
    --redact --no-banner \
    --report-format json --report-path "$report" \
    . >"$err" 2>&1
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
  local root repo dir out rc zeros rootsha mid head
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
  echo one >"$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -q -m one
  rootsha=$(git -C "$repo" rev-parse HEAD)
  echo two >"$repo/f"
  git -C "$repo" commit -q -am two
  mid=$(git -C "$repo" rev-parse HEAD)
  echo three >"$repo/f"
  git -C "$repo" commit -q -am three
  head=$(git -C "$repo" rev-parse HEAD)
  printf 'title = "local"\n' >"$repo/.gitleaks.toml"

  cat >"$dir/gitleaks" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >>"${FAKE_GITLEAKS_LOG:?}"
if [ "${1:-}" != "git" ]; then
  exit 2
fi
report=""
prev=""
saw_config=0
saw_redact=0
saw_banner=0
saw_dot=0
opts=""
for a in "$@"; do
  if [ "$prev" = "--config" ] && [ "$a" = ".gitleaks.toml" ]; then
    saw_config=1
  fi
  if [ "$a" = "--redact" ]; then
    saw_redact=1
  fi
  if [ "$a" = "--no-banner" ]; then
    saw_banner=1
  fi
  case "$a" in
    --log-opts=*) opts=${a#--log-opts=} ;;
    --log-opts) ;;
    .) saw_dot=1 ;;
  esac
  if [ "$prev" = "--log-opts" ]; then
    opts=$a
  fi
  if [ "$prev" = "--report-path" ]; then
    report=$a
  fi
  prev=$a
done
if [ "$saw_config" -ne 1 ] || [ "$saw_redact" -ne 1 ] || [ "$saw_banner" -ne 1 ] || [ "$saw_dot" -ne 1 ]; then
  exit 2
fi
if [ -z "$opts" ] || printf '%s' "$opts" | grep -q 'full-history\|--all'; then
  exit 2
fi
printf '%s\n' "$opts" >"${FAKE_GITLEAKS_LOG:?}.opts"
if [ "${FAKE_LEAKS:-0}" != 0 ]; then
  printf '%s\n' '[{"File":"apps/secret/key.env","Secret":"supersecretvalue","StartLine":12}]' >"$report"
  exit 1
fi
printf '%s\n' '[]' >"$report"
exit 0
EOF
  chmod +x "$dir/gitleaks"
  export FAKE_GITLEAKS_LOG="$dir/gitleaks.log"

  run_quiet() {
    local label="$1"
    : >"$FAKE_GITLEAKS_LOG"
    rm -f "${FAKE_GITLEAKS_LOG}.opts"
    set +e
    out=$(
      cd "$repo"
      PATH="$dir:$PATH" \
        RUNNER_TEMP="$dir" \
        GATE_LOG_KEY='selftest-key' \
        QUIET_LABEL=gitleaks \
        QUIET_KIND=generic \
        BASE="$2" \
        HEAD_SHA="$3" \
        QUIET_CMD="bash '$root/.github/scripts/gitleaks-gate.sh'" \
        bash "$root/.github/scripts/quiet.sh"
    )
    rc=$?
    set -e
    if printf '%s\n' "$out" | grep -F -q -e 'supersecretvalue' -e 'key.env' -e "$rootsha" -e "$mid" -e "$head" -e "$zeros"; then
      echo "FAIL selftest-${label}-leak"
      exit 1
    fi
  }

  export FAKE_LEAKS=0
  run_quiet pr "$rootsha" "$head"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'PASS config=1' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS gitleaks leaks=0' \
    || [ "$(cat "${FAKE_GITLEAKS_LOG}.opts")" != "${rootsha}..${head}" ]; then
    echo "FAIL selftest-pr"
    exit 1
  fi

  run_quiet parent "" "$head"
  if [ "$rc" -ne 0 ] || [ "$(cat "${FAKE_GITLEAKS_LOG}.opts")" != "${mid}..${head}" ]; then
    echo "FAIL selftest-parent"
    exit 1
  fi

  run_quiet root "" "$rootsha"
  if [ "$rc" -ne 0 ] || [ "$(cat "${FAKE_GITLEAKS_LOG}.opts")" != "-1 ${rootsha}" ]; then
    echo "FAIL selftest-root"
    exit 1
  fi

  export FAKE_LEAKS=1
  run_quiet leak "$rootsha" "$head"
  if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -qx 'FAIL gitleaks leaks=1'; then
    echo "FAIL selftest-leak-count"
    exit 1
  fi
  if ! find "$dir/gate-encrypted" -type f -name '*.bin' | grep -q .; then
    echo "FAIL selftest-encrypted"
    exit 1
  fi

  rm -f "$repo/.gitleaks.toml"
  export FAKE_LEAKS=0
  run_quiet noconfig "" "$head"
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
