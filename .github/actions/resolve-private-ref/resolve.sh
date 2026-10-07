#!/usr/bin/env bash
# Allowlist an untrusted ref/sha, then resolve it to a commit on
# zysicyj-xxc/zysicyj. stdout of the normalize helpers is the cleaned value.
# RESOLVE_SELFTEST=1 checks the allowlist without calling GitHub.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

normalize_ref() {
  local raw="$1"
  if [ -z "$raw" ]; then
    return 0
  fi
  if [ "${#raw}" -gt 200 ] || [ "$raw" != "${raw//[[:cntrl:]]/}" ]; then
    fail "ref failed allowlist"
  fi
  raw="${raw#"${raw%%[! ]*}"}"
  raw="${raw%"${raw##*[! ]}"}"
  if [ -z "$raw" ]; then
    return 0
  fi
  if printf '%s' "$raw" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf '%s' "$raw" | tr 'A-F' 'a-f'
    return 0
  fi
  local full="$raw"
  if ! printf '%s' "$full" | grep -Eq '^refs/'; then
    if ! printf '%s' "$full" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$'; then
      fail "ref failed allowlist: $full"
    fi
    full="refs/heads/$full"
  fi
  case "$full" in
    *..*) fail "ref failed allowlist: $full" ;;
  esac
  if printf '%s' "$full" | grep -Eq '^refs/pull/[0-9]+/(head|merge)$'; then
    printf '%s' "$full"
    return 0
  fi
  local rest=""
  if printf '%s' "$full" | grep -Eq '^refs/heads/.+'; then
    rest=${full#refs/heads/}
  elif printf '%s' "$full" | grep -Eq '^refs/tags/.+'; then
    rest=${full#refs/tags/}
  else
    fail "ref failed allowlist: $full"
  fi
  local -a segs=()
  IFS='/' read -r -a segs <<< "$rest"
  local joined s
  joined=$(IFS=/; printf '%s' "${segs[*]}")
  if [ "$joined" != "$rest" ] || [ "${#segs[@]}" -eq 0 ]; then
    fail "ref failed allowlist: $full"
  fi
  for s in "${segs[@]}"; do
    if ! printf '%s' "$s" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      fail "ref failed allowlist: $full"
    fi
  done
  printf '%s' "$full"
}

normalize_sha() {
  local raw="$1"
  if [ -z "$raw" ]; then
    return 0
  fi
  if [ "${#raw}" -gt 64 ] || [ "$raw" != "${raw//[[:cntrl:]]/}" ]; then
    fail "sha failed allowlist"
  fi
  raw="${raw#"${raw%%[! ]*}"}"
  raw="${raw%"${raw##*[! ]}"}"
  raw=$(printf '%s' "$raw" | tr 'A-F' 'a-f')
  if ! printf '%s' "$raw" | grep -Eq '^[0-9a-f]{40}$'; then
    fail "sha failed allowlist"
  fi
  printf '%s' "$raw"
}

if [ "${RESOLVE_SELFTEST:-}" = 1 ]; then
  eq() {
    local got
    got=$(normalize_ref "$1")
    if [ "$got" != "$2" ]; then
      echo "ref '$1' => '$got', want '$2'" >&2
      exit 1
    fi
  }
  eq_sha() {
    local got
    got=$(normalize_sha "$1")
    if [ "$got" != "$2" ]; then
      echo "sha '$1' => '$got', want '$2'" >&2
      exit 1
    fi
  }
  reject_ref() {
    if (normalize_ref "$1") >/dev/null 2>&1; then
      echo "ref should fail: $1" >&2
      exit 1
    fi
  }
  reject_sha() {
    if (normalize_sha "$1") >/dev/null 2>&1; then
      echo "sha should fail: $1" >&2
      exit 1
    fi
  }

  sha40=0123456789abcdef0123456789abcdef01234567
  eq "main" "refs/heads/main"
  eq "refs/heads/main" "refs/heads/main"
  eq "refs/tags/daymica/2026.3.56-1786847848" "refs/tags/daymica/2026.3.56-1786847848"
  eq "refs/pull/12/head" "refs/pull/12/head"
  eq "refs/pull/12/merge" "refs/pull/12/merge"
  eq "$sha40" "$sha40"
  eq "  feature/x " "refs/heads/feature/x"
  eq_sha "$sha40" "$sha40"
  eq_sha "ABCDEF${sha40:6}" "$(printf '%s' "ABCDEF${sha40:6}" | tr 'A-F' 'a-f')"
  eq_sha "" ""
  reject_ref "refs/heads/../x"
  reject_ref "refs/heads/main;touch"
  reject_ref $'refs/heads/main\n'
  reject_ref "refs/remotes/origin/main"
  reject_sha "abc"
  reject_sha "${sha40}0"
  reject_sha $'0123456789abcdef0123456789abcdef01234567\n'
  echo "resolve-private-ref selftest ok"
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ]; then
  fail "PRIVATE_REPO_ACCESS_TOKEN is empty"
fi
if [ -z "${GITHUB_OUTPUT:-}" ]; then
  fail "GITHUB_OUTPUT is empty"
fi

REF_NORM=$(normalize_ref "${RAW_REF:-}")
SHA_NORM=$(normalize_sha "${RAW_SHA:-}")

if [ -n "$SHA_NORM" ]; then
  TARGET=$SHA_NORM
elif [ -n "$REF_NORM" ]; then
  TARGET=$REF_NORM
else
  fail "ref or sha required"
fi
if ! printf '%s' "$TARGET" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
  fail "ref failed allowlist"
fi

SHA=$(gh api "repos/zysicyj-xxc/zysicyj/commits/${TARGET}" --jq .sha)
SHA=$(printf '%s' "$SHA" | tr 'A-F' 'a-f' | tr -d '[:space:]')
if ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$'; then
  fail "could not resolve commit"
fi

{
  echo "ref=${REF_NORM:-$SHA}"
  echo "sha=$SHA"
} >> "$GITHUB_OUTPUT"
echo "OK ref=${REF_NORM:-} sha=$SHA"
