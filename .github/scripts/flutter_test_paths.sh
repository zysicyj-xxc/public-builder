#!/usr/bin/env bash
# Classify changed paths for the mail-box flutter test.
# stdin: one filename per line. Prints mail_box=0|1, shared_package=0|1, run=true|false.
# Does not echo the paths.
set -euo pipefail

root_of() {
  case "$1" in
    apps/mail-box|apps/mail-box/*) printf '%s' mail-box ;;
    apps/shared_package|apps/shared_package/*) printf '%s' shared_package ;;
    *) printf '' ;;
  esac
}

if [ "${1:-}" = "--selftest" ]; then
  assert_run() {
    local want="$1"
    shift
    local got
    if [ "$#" -eq 0 ]; then
      got=$(printf '' | bash "$0" | awk -F= '$1=="run"{print $2}')
    else
      got=$(printf '%s\n' "$@" | bash "$0" | awk -F= '$1=="run"{print $2}')
    fi
    if [ "$got" != "$want" ]; then
      echo "selftest failed: want run=$want got ${got:-empty}" >&2
      exit 1
    fi
  }
  assert_run true apps/mail-box apps/mail-box/lib/a.dart apps/mail-box/test/a_test.dart
  assert_run true apps/shared_package apps/shared_package/test/goldens/a.png
  assert_run true apps/daymica/lib/a.dart apps/shared_package/lib/a.dart
  assert_run false apps/daymica/lib/a.dart apps/mail-box-extra/x apps/shared_package.bak/x
  assert_run false
  echo "flutter_test_paths selftest ok"
  exit 0
fi

mail_box=0
shared_package=0
while IFS= read -r path || [ -n "$path" ]; do
  path=${path%$'\r'}
  [ -n "$path" ] || continue
  case "$(root_of "$path")" in
    mail-box) mail_box=1 ;;
    shared_package) shared_package=1 ;;
  esac
done

run=false
if [ "$mail_box" = 1 ] || [ "$shared_package" = 1 ]; then
  run=true
fi
printf 'mail_box=%s\nshared_package=%s\nrun=%s\n' "$mail_box" "$shared_package" "$run"
