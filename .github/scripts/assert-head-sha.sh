#!/usr/bin/env bash
# Confirm the checked-out commit is the allowlisted sha. Prints the match
# result only, never file contents.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" config user.email "selftest@example.com"
  git -C "$tmp" config user.name "selftest"
  echo a > "$tmp/a.txt"
  git -C "$tmp" add a.txt
  git -C "$tmp" commit -q -m selftest
  sha=$(git -C "$tmp" rev-parse HEAD)
  script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  (cd "$tmp" && bash "$script" "$sha") >/dev/null
  if (cd "$tmp" && bash "$script" "0123456789abcdef0123456789abcdef01234567") >/dev/null 2>&1; then
    fail "mismatch should fail"
  fi
  echo "assert-head-sha selftest ok"
  exit 0
fi

sha="${1:-}"
if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
  fail "sha failed allowlist"
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "not a git checkout"
fi
head=$(git rev-parse HEAD)
head=$(printf '%s' "$head" | tr 'A-F' 'a-f' | tr -d '[:space:]')
if [ "$head" != "$sha" ]; then
  echo "ERROR: checked out commit does not match payload sha" >&2
  exit 1
fi
echo "sha ok"
