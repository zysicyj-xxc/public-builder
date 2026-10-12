#!/usr/bin/env bash
# Allowlist flutter-test scopes from an untrusted dispatch.
# Empty scopes keep the path-filter behavior (explicit=false).
# Known scopes: flutter (shared_package, footprint, eye-care, admin-app),
# daymica, mailbox (alias mail-box).
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

emit() {
  local flutter="$1" daymica="$2" mailbox="$3" explicit="$4"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "flutter=$flutter"
      echo "daymica=$daymica"
      echo "mailbox=$mailbox"
      echo "explicit=$explicit"
    } >> "$GITHUB_OUTPUT"
  else
    printf 'flutter=%s\ndaymica=%s\nmailbox=%s\nexplicit=%s\n' \
      "$flutter" "$daymica" "$mailbox" "$explicit"
  fi
}

parse() {
  local raw="${1:-}"
  if [ "${#raw}" -gt 80 ] || [ "$raw" != "${raw//[[:cntrl:]]/}" ]; then
    fail "scopes failed allowlist"
  fi
  local scopes="${raw,,}"
  scopes="${scopes//[[:space:]]/}"
  if [ -z "$scopes" ]; then
    emit false false false false
    return 0
  fi
  if ! printf '%s' "$scopes" | grep -Eq '^[a-z,-]+$'; then
    fail "scopes failed allowlist"
  fi
  local flutter=false daymica=false mailbox=false any=false
  local -a parts=()
  IFS=',' read -r -a parts <<< "$scopes"
  local p
  for p in "${parts[@]}"; do
    case "$p" in
      '') ;;
      flutter) flutter=true; any=true ;;
      daymica) daymica=true; any=true ;;
      mailbox|mail-box) mailbox=true; any=true ;;
      *) fail "unknown scope: $p" ;;
    esac
  done
  if [ "$any" != true ]; then
    fail "no scopes selected"
  fi
  emit "$flutter" "$daymica" "$mailbox" true
}

if [ "${1:-}" = "--selftest" ]; then
  out=$(RAW_SCOPES= bash "$0")
  printf '%s\n' "$out" | grep -qx 'flutter=false' || fail "empty flutter"
  printf '%s\n' "$out" | grep -qx 'explicit=false' || fail "empty explicit"
  out=$(RAW_SCOPES='daymica, mail-box' bash "$0")
  printf '%s\n' "$out" | grep -qx 'daymica=true' || fail "daymica"
  printf '%s\n' "$out" | grep -qx 'mailbox=true' || fail "mailbox"
  printf '%s\n' "$out" | grep -qx 'flutter=false' || fail "flutter off"
  printf '%s\n' "$out" | grep -qx 'explicit=true' || fail "explicit"
  out=$(RAW_SCOPES='flutter,mailbox' bash "$0")
  printf '%s\n' "$out" | grep -qx 'flutter=true' || fail "flutter on"
  printf '%s\n' "$out" | grep -qx 'mailbox=true' || fail "mailbox alias"
  if RAW_SCOPES='website' bash "$0" >/dev/null 2>&1; then
    fail "unknown scope should fail"
  fi
  if RAW_SCOPES=$'flutter\n' bash "$0" >/dev/null 2>&1; then
    fail "control char should fail"
  fi
  echo "flutter_test_scopes selftest ok"
  exit 0
fi

parse "${RAW_SCOPES:-}"
