#!/usr/bin/env bash
# Retry a gh api call when GitHub answers 403, 429, or 5xx.
# Waits 30, 60, 120, 240, then 300 seconds. A Retry-After value or an
# X-RateLimit-Reset delta replaces that slot and is capped at 300 seconds.
# status posts one commit status. If the retries run out, it posts error
# "report rate-limited" once so the next poll can dispatch again.
# post-limited does that one-shot write for each context. The caller already
# spent the backoff, so these posts are not retried.
# call runs gh api and prints only the response body.
# Logs are PASS/FAIL lines. Response bodies, URLs, and tokens stay off the log.
set -euo pipefail

PRIVATE_REPO="zysicyj-xxc/zysicyj"
BACKOFFS=(30 60 120 240 300)
MAX_SLEEP=300
ATTEMPTS=6

sleep_for() {
  local sec="$1"
  if [ "${API_RETRY_NO_SLEEP:-}" = "1" ]; then
    if [ -n "${API_RETRY_SLEEP_LOG:-}" ]; then
      printf '%s\n' "$sec" >>"$API_RETRY_SLEEP_LOG"
    fi
    return 0
  fi
  sleep "$sec"
}

http_code_of() {
  local file="$1" code
  code=$(awk '
    BEGIN { c = 0 }
    {
      sub(/\r/, "")
    }
    /^HTTP\// {
      c = $2
    }
    END {
      if (c ~ /^[0-9]+$/) print c
      else print 0
    }
  ' "$file")
  if [ "$code" != "0" ]; then
    printf '%s' "$code"
    return 0
  fi
  code=$(grep -Eo '\(HTTP [0-9]{3}\)' "$file" 2>/dev/null | grep -Eo '[0-9]{3}' | head -n 1 || true)
  printf '%s' "${code:-0}"
}

header_value() {
  local file="$1" name="$2"
  awk -v name="$name" '
    BEGIN { key = tolower(name) }
    {
      sub(/\r/, "")
      line = tolower($0)
      if (index(line, key ":") == 1) {
        sub(/^[^:]+:[[:space:]]*/, "")
        print
        exit
      }
    }
  ' "$file"
}

body_of() {
  awk '
    BEGIN { body = 0 }
    {
      sub(/\r/, "")
    }
    /^HTTP\// {
      body = 0
      next
    }
    body {
      print
    }
    /^$/ {
      body = 1
    }
  ' "$1"
}

choose_sleep() {
  local attempt="$1" file="$2" base ra reset now wait
  base="${BACKOFFS[$((attempt - 1))]}"
  ra=$(header_value "$file" "Retry-After" || true)
  reset=$(header_value "$file" "X-RateLimit-Reset" || true)
  if [ -z "$ra" ]; then
    ra=$(header_value "$file" "retry-after" || true)
  fi
  wait=""
  if printf '%s' "$ra" | grep -Eq '^[0-9]+$'; then
    wait=$ra
  elif printf '%s' "$reset" | grep -Eq '^[0-9]+$'; then
    now=$(date -u +%s)
    wait=$((reset - now))
    if [ "$wait" -lt 0 ]; then
      wait=0
    fi
  else
    wait=$base
  fi
  if [ "$wait" -gt "$MAX_SLEEP" ]; then
    wait=$MAX_SLEEP
  fi
  printf '%s' "$wait"
}

retryable_code() {
  local code="$1"
  case "$code" in
    403|429) return 0 ;;
  esac
  if printf '%s' "$code" | grep -Eq '^[0-9]+$' \
    && [ "$code" -ge 500 ] && [ "$code" -le 599 ]; then
    return 0
  fi
  return 1
}

# Runs gh api -i. Prints the body on success. On a retryable failure, waits
# and tries again. Returns 0, 1 (not retryable or bad invocation), or 2
# (retries exhausted).
gh_retry() {
  local attempt raw err code wait rc
  raw=$(mktemp)
  err=$(mktemp)
  chmod 600 "$raw" "$err"
  for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    : >"$raw"
    : >"$err"
    if gh api -i "$@" >"$raw" 2>"$err"; then
      rc=0
    else
      rc=$?
    fi
    code=$(http_code_of "$raw")
    if [ "$code" = "0" ]; then
      code=$(http_code_of "$err")
    fi
    if [ "$rc" -eq 0 ] && { [ "$code" = "0" ] || [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; }; then
      body_of "$raw"
      rm -f "$raw" "$err"
      return 0
    fi
    if ! retryable_code "$code"; then
      echo "FAIL api http=${code}" >&2
      rm -f "$raw" "$err"
      return 1
    fi
    if [ "$attempt" -ge "$ATTEMPTS" ]; then
      break
    fi
    wait=$(choose_sleep "$attempt" "$raw")
    if [ "$wait" = "0" ] && ! grep -Eq '^HTTP/' "$raw"; then
      wait=$(choose_sleep "$attempt" "$err")
    fi
    sleep_for "$wait"
  done
  rm -f "$raw" "$err"
  return 2
}

post_status_once() {
  local sha="$1" state="$2" ctx="$3" desc="$4" url="$5" quiet="${6:-}"
  if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "FAIL status" >&2
    return 1
  fi
  case "$state" in
    pending|success|failure|error) ;;
    *)
      echo "FAIL status" >&2
      return 1
      ;;
  esac
  if [ -z "$ctx" ] || printf '%s' "$ctx$desc" | grep -q '[[:cntrl:]]'; then
    echo "FAIL status" >&2
    return 1
  fi
  local rc=0
  if gh_retry --method POST "repos/${PRIVATE_REPO}/statuses/${sha}" \
    -f "state=${state}" \
    -f "target_url=${url}" \
    -f "description=${desc}" \
    -f "context=${ctx}" >/dev/null; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    if [ "$quiet" != "1" ]; then
      echo "PASS status"
    fi
    return 0
  fi
  return "$rc"
}

cmd_status() {
  local sha="$1" state="$2" ctx="$3" desc="$4" url="$5" rc
  set +e
  post_status_once "$sha" "$state" "$ctx" "$desc" "$url"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -ne 2 ]; then
    return "$rc"
  fi
  echo "FAIL report rate-limited"
  if [ "$state" = "error" ] && [ "$desc" = "report rate-limited" ]; then
    return 1
  fi
  # One shot on the status token. No further backoff.
  if API_RETRY_NO_SLEEP="${API_RETRY_NO_SLEEP:-}" post_fallback \
    "$sha" "$ctx" "$url"; then
    return 0
  fi
  return 1
}

post_fallback() {
  local sha="$1" ctx="$2" url="$3" raw err code rc
  raw=$(mktemp)
  err=$(mktemp)
  chmod 600 "$raw" "$err"
  if gh api --method POST "repos/${PRIVATE_REPO}/statuses/${sha}" \
    -f state="error" \
    -f "target_url=${url}" \
    -f description="report rate-limited" \
    -f "context=${ctx}" >"$raw" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  code=$(http_code_of "$err")
  if [ "$rc" -eq 0 ]; then
    rm -f "$raw" "$err"
    echo "PASS status"
    return 0
  fi
  rm -f "$raw" "$err"
  echo "FAIL api http=${code}" >&2
  return 1
}

cmd_post_limited() {
  local sha="$1" url="$2" ctx rc failed
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "FAIL status" >&2
    return 1
  fi
  echo "FAIL report rate-limited"
  failed=0
  for ctx in "$@"; do
    set +e
    post_fallback "$sha" "$ctx" "$url" >/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      failed=1
    fi
  done
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  echo "PASS status count=$#"
  return 0
}

cmd_call() {
  local rc=0
  if gh_retry "$@"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    echo "FAIL report rate-limited" >&2
  fi
  return "$rc"
}

selftest() {
  local dir log queue sleeps out err
  dir=$(mktemp -d)
  log="$dir/log"
  queue="$dir/queue"
  sleeps="$dir/sleeps"
  out="$dir/out"
  err="$dir/err"
  : >"$log"
  export API_RETRY_NO_SLEEP=1
  export API_RETRY_SLEEP_LOG="$sleeps"
  export GH_TOKEN='ghp_selftestsecretvalue'
  export PATH="$dir:$PATH"

  cat >"$dir/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
log="${FAKE_GH_LOG:?}"
queue="${FAKE_GH_QUEUE:?}"
printf '%s\n' "$*" >>"$log"
line=""
if [ -s "$queue" ]; then
  line=$(head -n 1 "$queue")
  tail -n +2 "$queue" >"${queue}.next"
  mv "${queue}.next" "$queue"
fi
code=${line%% *}
rest=${line#"$code"}
rest=${rest# }
case "$code" in
  ''|*[!0-9]*) code=500 ;;
esac
retry=""
reset=""
remain=""
for part in $rest; do
  case "$part" in
    retry=*) retry=${part#retry=} ;;
    reset=*) reset=${part#reset=} ;;
    remain=*) remain=${part#remain=} ;;
  esac
done
{
  printf 'HTTP/2.0 %s X\n' "$code"
  if [ -n "$retry" ]; then
    printf 'Retry-After: %s\n' "$retry"
  fi
  if [ -n "$reset" ]; then
    printf 'X-RateLimit-Reset: %s\n' "$reset"
  fi
  if [ -n "$remain" ]; then
    printf 'X-RateLimit-Remaining: %s\n' "$remain"
  fi
  printf '\n'
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    printf 'BODY_%s\n' "$code"
  else
    printf '{"message":"SECRETTOKEN"}\n'
  fi
}
if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
  exit 0
fi
echo "gh: failed (HTTP ${code})" >&2
exit 1
EOF
  chmod +x "$dir/gh"

  cleanup() {
    rm -rf "$dir"
  }
  trap cleanup EXIT

  fail() {
    echo "FAIL selftest-$1" >&2
    exit 1
  }

  assert_quiet() {
    local id="$1"
    if grep -E -q 'https?://|ghp_|SECRETTOKEN|repos/' "$out" "$err" "$log"; then
      fail "${id}-leak"
    fi
  }

  # Retry-After replaces the 30 second slot.
  export FAKE_GH_LOG="$log" FAKE_GH_QUEUE="$queue"
  printf '%s\n' '403 retry=7' '200' >"$queue"
  : >"$log"
  : >"$sleeps"
  if ! bash "$0" call rate_limit >"$out" 2>"$err"; then
    fail retry-after
  fi
  if [ "$(cat "$out")" != "BODY_200" ] || [ "$(wc -l <"$log")" -ne 2 ] \
    || [ "$(cat "$sleeps")" != "7" ]; then
    fail retry-after
  fi
  assert_quiet retry-after

  # A distant reset is capped at 300.
  now=$(date -u +%s)
  far=$((now + 9000))
  printf '%s\n' "429 reset=${far}" '200' >"$queue"
  : >"$log"
  : >"$sleeps"
  if ! bash "$0" call rate_limit >"$out" 2>"$err"; then
    fail reset-cap
  fi
  if [ "$(cat "$sleeps")" != "300" ]; then
    fail reset-cap
  fi
  assert_quiet reset-cap

  # 404 is not retried.
  printf '%s\n' '404' '200' >"$queue"
  : >"$log"
  : >"$sleeps"
  set +e
  bash "$0" call rate_limit >"$out" 2>"$err"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] || [ "$(wc -l <"$log")" -ne 1 ] || [ -s "$sleeps" ] \
    || ! grep -Fxq 'FAIL api http=404' "$err"; then
    fail http-404
  fi
  assert_quiet http-404

  # 5xx uses the backoff schedule and then gives up.
  : >"$queue"
  for _ in 1 2 3 4 5 6; do
    echo 503 >>"$queue"
  done
  : >"$log"
  : >"$sleeps"
  set +e
  bash "$0" call rate_limit >"$out" 2>"$err"
  rc=$?
  set -e
  if [ "$rc" -ne 2 ] || [ "$(wc -l <"$log")" -ne 6 ] \
    || [ "$(paste -sd, "$sleeps")" != "30,60,120,240,300" ] \
    || ! grep -Fxq 'FAIL report rate-limited' "$err"; then
    fail exhaust
  fi
  assert_quiet exhaust

  # A status write that is rate-limited posts the fallback marker.
  : >"$queue"
  for _ in 1 2 3 4 5 6; do
    echo 403 >>"$queue"
  done
  echo '201' >>"$queue"
  : >"$log"
  : >"$sleeps"
  sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  if ! bash "$0" status "$sha" success "ci-scripts" success "https://example.test/run" \
    >"$out" 2>"$err"; then
    fail status-fallback
  fi
  if ! grep -Fxq 'FAIL report rate-limited' "$out" \
    || ! grep -Fxq 'PASS status' "$out"; then
    fail status-fallback
  fi
  if ! grep -F -q 'description=report rate-limited' "$log" \
    || ! grep -F -q 'state=error' "$log"; then
    fail status-fallback
  fi
  if grep -E -q 'https?://|ghp_|SECRETTOKEN|example' "$out" "$err"; then
    fail status-fallback-leak
  fi

  # The first success does not fall back.
  printf '%s\n' '201' >"$queue"
  : >"$log"
  if ! bash "$0" status "$sha" failure "ci-scripts" failure "https://example.test/run" \
    >"$out" 2>"$err"; then
    fail status-ok
  fi
  if [ "$(cat "$out")" != "PASS status" ] || grep -F -q 'report rate-limited' "$log"; then
    fail status-ok
  fi

  # post-limited writes one error per context.
  printf '%s\n' '201' '201' >"$queue"
  : >"$log"
  if ! bash "$0" post-limited "$sha" "https://example.test/run" "ci-scripts" "gitleaks" \
    >"$out" 2>"$err"; then
    fail post-limited
  fi
  if ! grep -Fxq 'FAIL report rate-limited' "$out" \
    || ! grep -Fxq 'PASS status count=2' "$out" \
    || [ "$(grep -c 'description=report rate-limited' "$log")" -ne 2 ]; then
    fail post-limited
  fi
  if grep -E -q 'https?://|ghp_|SECRETTOKEN|example' "$out" "$err"; then
    fail post-limited-leak
  fi

  echo "PASS selftest"
  cleanup
  trap - EXIT
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

cmd="${1:-}"
shift || true
case "$cmd" in
  call) cmd_call "$@" ;;
  status)
    if [ "$#" -ne 5 ]; then
      echo "FAIL status" >&2
      exit 1
    fi
    cmd_status "$@"
    ;;
  post-limited)
    if [ "$#" -lt 3 ]; then
      echo "FAIL status" >&2
      exit 1
    fi
    cmd_post_limited "$@"
    ;;
  *)
    echo "FAIL api" >&2
    exit 1
    ;;
esac
