#!/usr/bin/env bash
# Base commit for one private SHA when it is an open PR head.
# Prefer a PR whose base ref is main. Not a PR: leave base empty.
# The scan script then uses the first parent, or -1 when there is no parent.
# Stdout is PASS/FAIL. The base is written to GITHUB_OUTPUT and is not printed.
set -euo pipefail

PRIVATE_REPO="zysicyj-xxc/zysicyj"

is_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# True when every character is 0. Avoid embedding a 40-zero literal.
is_zero_sha() {
  local s="$1" rest
  [ "${#s}" -eq 40 ] || return 1
  rest=$(printf '%s' "$s" | tr -d '0')
  [ -z "$rest" ]
}

norm_sha() {
  printf '%s' "$1" | tr 'A-F' 'a-f' | tr -d '[:space:]'
}

resolve_range() {
  local sha head base ref chosen=""
  sha=$(norm_sha "$1")
  if ! is_sha "$sha" || is_zero_sha "$sha"; then
    echo "FAIL range"
    return 1
  fi

  while IFS=$'\t' read -r head base ref || [ -n "${head:-}" ]; do
    [ -n "${head:-}" ] || continue
    head=$(norm_sha "$head")
    base=$(norm_sha "$base")
    [ "$head" = "$sha" ] || continue
    is_sha "$base" || continue
    is_zero_sha "$base" && continue
    if [ "$ref" = "main" ]; then
      chosen=$base
      break
    fi
    if [ -z "$chosen" ]; then
      chosen=$base
    fi
  done < <(GH_TOKEN="$GH_TOKEN" gh api --paginate \
    "repos/${PRIVATE_REPO}/commits/${sha}/pulls" \
    --jq '.[] | select(.state=="open") | [.head.sha, .base.sha, .base.ref] | @tsv' 2>/dev/null || true)

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'base=%s\n' "$chosen" >>"$GITHUB_OUTPUT"
  fi
  echo "PASS range"
}

selftest() {
  local root dir ghbin out rc zeros
  root=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
  dir=$(mktemp -d)
  zeros=$(python3 -c 'print("0"*40)')
  if grep -Fq "$zeros" "$root/gitleaks-range.sh" "$root/gitleaks-gate.sh" \
    "$root/../workflows/gitleaks.yml"; then
    echo "FAIL selftest-zero"
    exit 1
  fi

  ghbin="$dir/gh"
  cat >"$ghbin" <<'EOF'
#!/bin/bash
set -euo pipefail
url=""
for a in "$@"; do
  case "$a" in
    repos/*) url=$a ;;
  esac
done
sha=$(printf '%s' "$url" | sed -n 's|.*/commits/\([0-9a-f]\{40\}\).*|\1|p')
mode=${FAKE_MODE:-none}
case "$mode" in
  pr)
    if [[ "$url" == *"/pulls" ]]; then
      printf '%s\t%s\t%s\n' "$sha" "${FAKE_BASE:?}" "feature"
      exit 0
    fi
    ;;
  pr-main)
    if [[ "$url" == *"/pulls" ]]; then
      printf '%s\t%s\t%s\n' "$sha" "${FAKE_OTHER:?}" "feature"
      printf '%s\t%s\t%s\n' "$sha" "${FAKE_BASE:?}" "main"
      exit 0
    fi
    ;;
  none)
    if [[ "$url" == *"/pulls" ]]; then
      exit 0
    fi
    ;;
esac
exit 1
EOF
  chmod +x "$ghbin"

  run_case() {
    local id="$1"
    export GITHUB_OUTPUT="$dir/out-$id"
    export GH_TOKEN='ghp_selftestsecretvalue'
    : >"$GITHUB_OUTPUT"
    set +e
    out=$(PATH="$dir:$PATH" SHA="$FAKE_SHA" bash "$root/gitleaks-range.sh" 2>"$dir/err-$id")
    rc=$?
    set -e
    if [ -s "$dir/err-$id" ]; then
      echo "FAIL selftest-${id}-stderr"
      exit 1
    fi
    if printf '%s' "$out" | grep -F -q -e "$FAKE_SHA" -e "$GH_TOKEN" -e "$zeros"; then
      echo "FAIL selftest-${id}-leak"
      exit 1
    fi
    if [ -n "${FAKE_BASE:-}" ] && printf '%s' "$out" | grep -F -q "$FAKE_BASE"; then
      echo "FAIL selftest-${id}-leak"
      exit 1
    fi
  }

  export FAKE_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  export FAKE_BASE='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  export FAKE_MODE=pr
  run_case pr
  if [ "$rc" -ne 0 ] || [ "$out" != "PASS range" ] \
    || [ "$(cat "$GITHUB_OUTPUT")" != "base=${FAKE_BASE}" ]; then
    echo "FAIL selftest-pr"
    exit 1
  fi

  export FAKE_OTHER='cccccccccccccccccccccccccccccccccccccccc'
  export FAKE_MODE=pr-main
  run_case pr-main
  if [ "$rc" -ne 0 ] || [ "$(cat "$GITHUB_OUTPUT")" != "base=${FAKE_BASE}" ]; then
    echo "FAIL selftest-pr-main"
    exit 1
  fi

  export FAKE_MODE=none
  unset FAKE_BASE || true
  run_case none
  if [ "$rc" -ne 0 ] || [ "$out" != "PASS range" ] \
    || [ "$(cat "$GITHUB_OUTPUT")" != "base=" ]; then
    echo "FAIL selftest-none"
    exit 1
  fi

  export FAKE_SHA='not-a-sha'
  export FAKE_MODE=none
  run_case bad
  if [ "$rc" -eq 0 ] || [ "$out" != "FAIL range" ]; then
    echo "FAIL selftest-bad"
    exit 1
  fi

  rm -rf "$dir"
  echo "PASS selftest"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

: "${GH_TOKEN:?}"
: "${SHA:?}"
: "${GITHUB_OUTPUT:?}"
resolve_range "$SHA"
