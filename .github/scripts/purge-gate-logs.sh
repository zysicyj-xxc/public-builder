#!/usr/bin/env bash
# Delete Actions logs for completed public-builder gate runs.
# RUN_ID set: wait until that run completes, then delete its logs.
# A 404 before the logs are readable is not success. Wait until GET
# logs returns 200 or 302, DELETE, then GET until 404. Retries are
# limited and back off. Giving up counts as failure.
# RUN_ID empty: sweep completed runs from the last 6 hours, one page of
# 100. purge-gate-logs and the watchdog are limited to the last hour so
# their own history cannot grow the sweep. A 404 on that pass is not a
# confirmed delete and not a failure; the next pass retries once the
# logs are readable. 403 or 429 stops the sweep immediately.
# DRY_RUN true: GET the actions runs API and count, without deleting.
# Output is counts and FAIL lines. No URLs, tokens, or presigned URLs.
set -euo pipefail

MAX_TRIES=10
BACKOFF_CAP=30
PAUSE_COUNT=0

gates=(
  poll-private-gates.yml
  poll-gates-watchdog.yml
  quality-analyze.yml
  flutter-test.yml
  daymica-test.yml
  ci-scripts.yml
  i18n-gate.yml
  visual-lint.yml
  domain-gate.yml
  scripts-gate.yml
  web-visual.yml
  utools-visual.yml
  gitleaks.yml
  admin-web-gate.yml
  staging-webhook-deploy.yml
  purge-gate-logs.yml
)

deleted=0
failed=0
would=0
dry=0
repo=""

backoff_seconds() {
  local try="$1" sec
  sec=$((2 ** try))
  if [ "$sec" -gt "$BACKOFF_CAP" ]; then
    sec=$BACKOFF_CAP
  fi
  printf '%s' "$sec"
}

pause_after() {
  local try="$1" sec
  if [ "$try" -ge "$MAX_TRIES" ]; then
    return 0
  fi
  PAUSE_COUNT=$((PAUSE_COUNT + 1))
  if [ "${PURGE_NO_SLEEP:-}" = "1" ]; then
    return 0
  fi
  sec=$(backoff_seconds "$try")
  sleep "$sec"
}

runs_http_code() {
  gh api "$@" -i 2>/dev/null | awk 'BEGIN{c=0} /^HTTP/{c=$2} END{print c+0}' || true
}

logs_code() {
  local method="$1" id="$2" api hdr code next
  case "$method" in
    GET|DELETE) ;;
    *) printf '0'; return 0 ;;
  esac
  if ! printf '%s' "$id" | grep -Eq '^[0-9]+$'; then
    printf '0'
    return 0
  fi
  if [ -n "${PURGE_CODE_QUEUE:-}" ]; then
    if [ -n "${PURGE_CODE_LOG:-}" ]; then
      printf '%s %s\n' "$method" "$id" >>"$PURGE_CODE_LOG"
    fi
    next=""
    if [ -s "$PURGE_CODE_QUEUE" ]; then
      next=$(head -n 1 "$PURGE_CODE_QUEUE")
      tail -n +2 "$PURGE_CODE_QUEUE" >"${PURGE_CODE_QUEUE}.next"
      mv "${PURGE_CODE_QUEUE}.next" "$PURGE_CODE_QUEUE"
    fi
    case "$next" in
      ''|*[!0-9]*) next=0 ;;
    esac
    printf '%s' "$next"
    return 0
  fi
  if [ -z "${GH_TOKEN:-}" ] || [ -z "$repo" ]; then
    printf '0'
    return 0
  fi
  if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    printf '0'
    return 0
  fi
  api="${GITHUB_API_URL:-https://api.github.com}"
  api="${api%/}"
  hdr=$(mktemp)
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\n' "$GH_TOKEN" >"$hdr"
  code=$(
    curl \
      --silent \
      --output /dev/null \
      --write-out '%{http_code}' \
      --request "$method" \
      --header @"$hdr" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --connect-timeout 15 \
      --max-time 30 \
      "${api}/repos/${repo}/actions/runs/${id}/logs" 2>/dev/null || true
  )
  rm -f "$hdr"
  case "$code" in
    ''|*[!0-9]*) code=0 ;;
  esac
  printf '%s' "$code"
}

note_fail() {
  local code="${1:-0}"
  case "$code" in
    ''|*[!0-9]*) code=0 ;;
  esac
  failed=$((failed + 1))
  echo "FAIL purge http=${code}" >&2
}

delete_logs() {
  local id="$1" try code del ready
  if [ "$dry" -eq 1 ]; then
    would=$((would + 1))
    return 0
  fi
  ready=0
  code=0
  for ((try = 1; try <= MAX_TRIES; try++)); do
    code=$(logs_code GET "$id")
    case "$code" in
      200|302)
        ready=1
        break
        ;;
      403|429)
        return 2
        ;;
    esac
    pause_after "$try"
  done
  if [ "$ready" -ne 1 ]; then
    note_fail "$code"
    return 0
  fi
  for ((try = 1; try <= MAX_TRIES; try++)); do
    del=$(logs_code DELETE "$id")
    case "$del" in
      403|429) return 2 ;;
    esac
    code=$(logs_code GET "$id")
    if [ -z "$code" ] || [ "$code" = "0" ]; then
      code=$del
    fi
    case "$code" in
      403|429) return 2 ;;
    esac
    if [ "$code" = "404" ]; then
      deleted=$((deleted + 1))
      return 0
    fi
    pause_after "$try"
  done
  note_fail "$code"
}

purge_one() {
  local id="$1" mode="$2" code
  if [ "$dry" -eq 1 ]; then
    would=$((would + 1))
    return 0
  fi
  case "$mode" in
    strict)
      if ! delete_logs "$id"; then
        echo "FAIL purge rate-limited"
        return 2
      fi
      return 0
      ;;
    sweep) ;;
    *)
      note_fail 0
      return 0
      ;;
  esac
  code=$(logs_code GET "$id")
  case "$code" in
    404) return 0 ;;
    403|429)
      echo "FAIL purge rate-limited"
      return 2
      ;;
  esac
  if ! delete_logs "$id"; then
    echo "FAIL purge rate-limited"
    return 2
  fi
}

gh_http_code() {
  local file="$1" code
  code=$(grep -Eo '\(HTTP [0-9]{3}\)' "$file" 2>/dev/null | head -n 1 | grep -Eo '[0-9]{3}' || true)
  printf '%s' "${code:-0}"
}

core_remaining() {
  local raw
  if [ -n "${PURGE_RATE_REMAINING:-}" ]; then
    printf '%s' "$PURGE_RATE_REMAINING"
    return 0
  fi
  if ! raw=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null); then
    printf ''
    return 0
  fi
  case "$raw" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$raw" ;;
  esac
}

list_completed_ids() {
  local wf="$1" hours="$2" since line code ids err parts
  if [ -n "${PURGE_LIST_QUEUE:-}" ]; then
    if [ ! -s "$PURGE_LIST_QUEUE" ]; then
      return 0
    fi
    line=$(head -n 1 "$PURGE_LIST_QUEUE")
    tail -n +2 "$PURGE_LIST_QUEUE" >"${PURGE_LIST_QUEUE}.next"
    mv "${PURGE_LIST_QUEUE}.next" "$PURGE_LIST_QUEUE"
    read -r -a parts <<<"$line"
    code="${parts[0]:-}"
    case "$code" in
      403|429) return 2 ;;
      200)
        if [ "${#parts[@]}" -gt 1 ]; then
          printf '%s\n' "${parts[@]:1}"
        fi
        return 0
        ;;
      *) return 1 ;;
    esac
  fi
  since=$(date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ)
  err=$(mktemp)
  if ids=$(gh api --method GET \
    "repos/${repo}/actions/workflows/${wf}/runs" \
    -f status=completed \
    -f per_page=100 \
    -f "created=>=${since}" \
    --jq '.workflow_runs[].id' 2>"$err"); then
    rm -f "$err"
    if [ -n "$ids" ]; then
      printf '%s\n' "$ids"
    fi
    return 0
  fi
  code=$(gh_http_code "$err")
  rm -f "$err"
  if [ "$code" = "403" ] || [ "$code" = "429" ]; then
    return 2
  fi
  note_fail "${code:-0}"
  return 1
}

sweep_one() {
  local id="$1" code
  if [ "$dry" -eq 1 ]; then
    would=$((would + 1))
    return 0
  fi
  code=$(logs_code GET "$id")
  case "$code" in
    404) return 0 ;;
    403|429)
      echo "FAIL purge rate-limited"
      return 2
      ;;
  esac
  if ! delete_logs "$id"; then
    echo "FAIL purge rate-limited"
    return 2
  fi
}

sweep_all() {
  local wf hours ids id remaining rc
  remaining=$(core_remaining)
  if [ -n "$remaining" ] && [ "$remaining" -lt 500 ]; then
    echo "FAIL purge rate-limited"
    return 0
  fi
  for wf in "${gates[@]}"; do
    case "$wf" in
      purge-gate-logs.yml|poll-gates-watchdog.yml) hours=1 ;;
      *) hours=6 ;;
    esac
    ids=""
    if ids=$(list_completed_ids "$wf" "$hours"); then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
      echo "FAIL purge rate-limited"
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      break
    fi
    while IFS= read -r id; do
      if ! printf '%s' "$id" | grep -Eq '^[0-9]+$'; then
        continue
      fi
      if ! sweep_one "$id"; then
        return 0
      fi
    done <<<"$ids"
  done
}

wait_until_completed() {
  local id="$1" i status err code line
  for ((i = 1; i <= 10; i++)); do
    status=""
    if [ -n "${PURGE_STATUS_QUEUE:-}" ]; then
      if [ -s "$PURGE_STATUS_QUEUE" ]; then
        line=$(head -n 1 "$PURGE_STATUS_QUEUE")
        tail -n +2 "$PURGE_STATUS_QUEUE" >"${PURGE_STATUS_QUEUE}.next"
        mv "${PURGE_STATUS_QUEUE}.next" "$PURGE_STATUS_QUEUE"
        status=$line
      fi
      if [ "$status" = "403" ] || [ "$status" = "429" ]; then
        echo "FAIL purge rate-limited"
        return 2
      fi
    else
      err=$(mktemp)
      if status=$(gh api "repos/${repo}/actions/runs/${id}" --jq .status 2>"$err"); then
        rm -f "$err"
      else
        code=$(gh_http_code "$err")
        rm -f "$err"
        status=""
        if [ "$code" = "403" ] || [ "$code" = "429" ]; then
          echo "FAIL purge rate-limited"
          return 2
        fi
      fi
    fi
    if [ "$status" = "completed" ]; then
      return 0
    fi
    if [ "$i" -lt 10 ] && [ "${PURGE_NO_SLEEP:-}" != "1" ]; then
      sleep 30
    fi
  done
  return 1
}

finish() {
  if [ "$dry" -eq 1 ]; then
    echo "dry_run would_delete=${would}"
  else
    echo "purge deleted=${deleted} failed=${failed}"
  fi
  [ "$failed" -eq 0 ]
}

selftest() {
  local queue calls errf outf portfile py authlog hitlog port out i
  local stdout srv_pid

  cleanup_selftest() {
    if [ -n "${srv_pid:-}" ]; then
      kill "$srv_pid" 2>/dev/null || true
      wait "$srv_pid" 2>/dev/null || true
    fi
    rm -f "${queue:-}" "${calls:-}" "${errf:-}" "${outf:-}" "${portfile:-}" \
      "${py:-}" "${authlog:-}" "${hitlog:-}"
  }
  trap cleanup_selftest EXIT

  repo=example/public-builder
  unset PURGE_CODE_QUEUE || true
  unset PURGE_CODE_LOG || true
  dry=0
  deleted=0
  failed=0
  would=0
  PURGE_NO_SLEEP=1
  export PURGE_NO_SLEEP
  export GH_TOKEN='ghp_selftestsecretvalue'
  export NO_PROXY='127.0.0.1,localhost'
  export no_proxy='127.0.0.1,localhost'
  unset GITHUB_API_URL || true

  if [ "$(backoff_seconds 1)" != 2 ] \
    || [ "$(backoff_seconds 2)" != 4 ] \
    || [ "$(backoff_seconds 3)" != 8 ] \
    || [ "$(backoff_seconds 4)" != 16 ] \
    || [ "$(backoff_seconds 5)" != 30 ] \
    || [ "$(backoff_seconds 9)" != 30 ]; then
    echo "FAIL selftest-backoff"
    exit 1
  fi

  queue=$(mktemp)
  calls=$(mktemp)
  errf=$(mktemp)
  outf=$(mktemp)
  portfile=$(mktemp)
  authlog=$(mktemp)
  hitlog=$(mktemp)
  py=$(mktemp)
  cat >"$py" <<'PY'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

auth_path = os.environ["AUTH_LOG"]
hit_path = os.environ["HIT_LOG"]

class Handler(BaseHTTPRequestHandler):
    def _hit(self):
        with open(hit_path, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (self.command, self.path))
        with open(auth_path, "a", encoding="utf-8") as fh:
            fh.write((self.headers.get("Authorization") or "") + "\n")

    def do_GET(self):
        self._hit()
        text = open(hit_path, encoding="utf-8").read()
        gets = text.count("GET ")
        if gets == 1:
            self.send_response(302)
            self.send_header("Location", "/presigned?sig=SECRETTOKEN")
            self.end_headers()
            return
        body = b"PRESIGNED_BODY_SECRETTOKEN"
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        self._hit()
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
  AUTH_LOG="$authlog" HIT_LOG="$hitlog" python3 "$py" >"$portfile" 2>/dev/null &
  srv_pid=$!
  port=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -s "$portfile" ]; then
      port=$(tr -cd '0-9' <"$portfile")
      break
    fi
    sleep 0.05
  done
  if [ -z "$port" ]; then
    echo "FAIL selftest-http"
    exit 1
  fi
  GITHUB_API_URL="http://127.0.0.1:${port}"
  export GITHUB_API_URL

  check_quiet() {
    local label="$1"
    shift
    if grep -E -q 'https?://|ghp_|SECRETTOKEN|presigned|refs/' "$@" ; then
      echo "FAIL selftest-${label}"
      exit 1
    fi
  }

  out=$(logs_code GET 1 2>"$errf")
  if [ "$out" != "302" ]; then
    echo "FAIL selftest-redirect"
    exit 1
  fi
  check_quiet redirect "$errf"
  out=$(logs_code GET 1 2>"$errf")
  if [ "$out" != "200" ]; then
    echo "FAIL selftest-body"
    exit 1
  fi
  check_quiet body "$errf"
  out=$(logs_code DELETE 1 2>"$errf")
  if [ "$out" != "204" ]; then
    echo "FAIL selftest-delete"
    exit 1
  fi
  check_quiet delete "$errf"
  if ! grep -q '/repos/example/public-builder/actions/runs/1/logs' "$hitlog" \
    || grep -q 'presigned\|SECRETTOKEN' "$hitlog"; then
    echo "FAIL selftest-redirect"
    exit 1
  fi
  if ! grep -q "Bearer ${GH_TOKEN}" "$authlog"; then
    echo "FAIL selftest-auth"
    exit 1
  fi
  unset GITHUB_API_URL
  PURGE_CODE_QUEUE=$queue
  PURGE_CODE_LOG=$calls
  export PURGE_CODE_QUEUE PURGE_CODE_LOG

  capture() {
    set +e
    "$@" >"$outf" 2>"$errf"
    CAP_RC=$?
    set -e
    stdout=$(cat "$outf")
  }

  setup_case() {
    deleted=0
    failed=0
    would=0
    PAUSE_COUNT=0
    : >"$calls"
    : >"$errf"
    : >"$queue"
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@" >"$queue"
    fi
  }

  assert_calls() {
    if [ -s "$calls" ] && grep -Ev '^(GET|DELETE) [0-9]+$' "$calls" | grep -q .; then
      echo "FAIL selftest-calls"
      exit 1
    fi
  }

  count_method() {
    awk -v m="$1" '$1 == m { n++ } END { print n + 0 }' "$calls"
  }

  # Logs are not readable yet, then become readable, then confirm 404.
  setup_case 404 503 302 204 404
  capture delete_logs 42
  assert_calls
  if [ -n "$stdout" ] || [ -s "$errf" ] || [ "$deleted" -ne 1 ] \
    || [ "$failed" -ne 0 ] || [ "$PAUSE_COUNT" -ne 2 ] \
    || [ "$(count_method DELETE)" -ne 1 ] || [ "$(count_method GET)" -ne 4 ]; then
    echo "FAIL selftest-wait"
    exit 1
  fi
  if ! awk '
      $1 == "DELETE" { if (gets < 3) bad = 1; dels++ }
      $1 == "GET" && dels == 0 { gets++ }
      END { exit (bad || dels != 1 || gets != 3) }
    ' "$calls"; then
    echo "FAIL selftest-wait"
    exit 1
  fi

  # Delete leaves the logs readable, so the delete is retried.
  setup_case 200 204 200 204 302 204 404
  capture delete_logs 42
  assert_calls
  if [ -n "$stdout" ] || [ -s "$errf" ] || [ "$deleted" -ne 1 ] \
    || [ "$failed" -ne 0 ] || [ "$PAUSE_COUNT" -ne 2 ] \
    || [ "$(count_method DELETE)" -ne 3 ]; then
    echo "FAIL selftest-retry"
    exit 1
  fi

  # Readable logs, one delete, confirm 404.
  setup_case 302 204 404
  capture delete_logs 42
  assert_calls
  if [ -n "$stdout" ] || [ -s "$errf" ] || [ "$deleted" -ne 1 ] \
    || [ "$failed" -ne 0 ] || [ "$PAUSE_COUNT" -ne 0 ] \
    || [ "$(count_method DELETE)" -ne 1 ] || [ "$(count_method GET)" -ne 2 ]; then
    echo "FAIL selftest-confirm"
    exit 1
  fi

  # Never becomes readable.
  setup_case
  for ((i = 1; i <= MAX_TRIES; i++)); do
    echo 404 >>"$queue"
  done
  capture delete_logs 42
  assert_calls
  if [ -n "$stdout" ] || [ "$deleted" -ne 0 ] || [ "$failed" -ne 1 ] \
    || [ "$(count_method DELETE)" -ne 0 ] \
    || [ "$PAUSE_COUNT" -ne $((MAX_TRIES - 1)) ] \
    || ! grep -Fxq 'FAIL purge http=404' "$errf"; then
    echo "FAIL selftest-exhaust"
    exit 1
  fi
  check_quiet exhaust "$errf" "$calls"

  # Stays readable until the retries run out.
  setup_case 200
  for ((i = 1; i <= MAX_TRIES; i++)); do
    printf '%s\n' 204 200 >>"$queue"
  done
  capture delete_logs 42
  assert_calls
  if [ -n "$stdout" ] || [ "$deleted" -ne 0 ] || [ "$failed" -ne 1 ] \
    || [ "$(count_method DELETE)" -ne "$MAX_TRIES" ] \
    || ! grep -Fxq 'FAIL purge http=200' "$errf"; then
    echo "FAIL selftest-exhaust-readable"
    exit 1
  fi
  check_quiet exhaust-readable "$errf" "$calls"

  # Sweep must not treat a bare 404 as a successful delete.
  setup_case 404
  capture purge_one 7 sweep
  assert_calls
  if [ -n "$stdout" ] || [ -s "$errf" ] || [ "$deleted" -ne 0 ] \
    || [ "$failed" -ne 0 ] || [ "$PAUSE_COUNT" -ne 0 ] \
    || [ "$(count_method DELETE)" -ne 0 ] || [ "$(count_method GET)" -ne 1 ]; then
    echo "FAIL selftest-sweep-absent"
    exit 1
  fi

  # Sweep still deletes logs that are already readable.
  setup_case 200 302 204 404
  capture purge_one 7 sweep
  assert_calls
  if [ -n "$stdout" ] || [ -s "$errf" ] || [ "$deleted" -ne 1 ] \
    || [ "$failed" -ne 0 ] || [ "$(count_method DELETE)" -ne 1 ]; then
    echo "FAIL selftest-sweep-ready"
    exit 1
  fi

  # A 403 while confirming a delete does not retry ten times.
  setup_case 200 403
  capture delete_logs 42
  assert_calls
  if [ "$CAP_RC" -ne 2 ] || [ "$(count_method GET)" -ne 1 ] \
    || [ "$(count_method DELETE)" -ne 1 ] || [ "$PAUSE_COUNT" -ne 0 ] \
    || [ -n "$stdout" ]; then
    echo "FAIL selftest-rate-delete"
    exit 1
  fi

  # Sweep stops on the first 403 and does not read the next workflow.
  listq=$(mktemp)
  printf '%s\n' '403' '200 11' >"$listq"
  PURGE_LIST_QUEUE=$listq
  PURGE_RATE_REMAINING=5000
  export PURGE_LIST_QUEUE PURGE_RATE_REMAINING
  setup_case
  capture sweep_all
  if [ "$stdout" != "FAIL purge rate-limited" ] || [ "$(count_method GET)" -ne 0 ] \
    || [ "$(count_method DELETE)" -ne 0 ] || ! grep -Fxq '200 11' "$listq"; then
    echo "FAIL selftest-sweep-rate"
    exit 1
  fi
  check_quiet sweep-rate "$outf" "$errf"

  # A readable run is inspected, then a 403 on the log GET stops the sweep.
  printf '%s\n' '200 11' >"$listq"
  setup_case 403
  capture sweep_all
  if [ "$stdout" != "FAIL purge rate-limited" ] || [ "$(count_method GET)" -ne 1 ] \
    || [ "$(count_method DELETE)" -ne 0 ]; then
    echo "FAIL selftest-sweep-log-rate"
    exit 1
  fi

  # Remaining under 500 skips the sweep before any list call.
  printf '%s\n' '200 11' >"$listq"
  PURGE_RATE_REMAINING=499
  setup_case 200
  capture sweep_all
  if [ "$stdout" != "FAIL purge rate-limited" ] || [ "$(count_method GET)" -ne 0 ] \
    || ! grep -Fxq '200 11' "$listq"; then
    echo "FAIL selftest-sweep-budget"
    exit 1
  fi
  unset PURGE_LIST_QUEUE
  unset PURGE_RATE_REMAINING

  # The list request is one page of recent runs, not a full pagination.
  ghlog=$(mktemp)
  ghdir=$(mktemp -d)
  cat >"$ghdir/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$PURGE_GH_LOG"
if [[ "$*" == *--paginate* ]]; then
  echo "paginated" >&2
  exit 1
fi
printf '%s\n' 11
exit 0
EOF
  chmod +x "$ghdir/gh"
  PURGE_GH_LOG=$ghlog
  export PURGE_GH_LOG
  PATH="$ghdir:$PATH"
  : >"$ghlog"
  list_completed_ids flutter-test.yml 6 >/dev/null
  list_completed_ids purge-gate-logs.yml 1 >/dev/null
  list_completed_ids poll-gates-watchdog.yml 1 >/dev/null
  if [ "$(wc -l <"$ghlog")" -ne 3 ] \
    || grep -q -- '--paginate' "$ghlog" \
    || ! grep -q 'per_page=100' "$ghlog" \
    || ! grep -q 'created=>=' "$ghlog" \
    || ! grep -q 'flutter-test.yml' "$ghlog" \
    || ! grep -q 'purge-gate-logs.yml' "$ghlog"; then
    echo "FAIL selftest-sweep-recent"
    exit 1
  fi
  six=$(sed -n '1s/.*created=>=//p' "$ghlog")
  one=$(sed -n '2s/.*created=>=//p' "$ghlog")
  if [ -z "$six" ] || [ -z "$one" ] || [[ "$one" < "$six" ]]; then
    echo "FAIL selftest-sweep-recent"
    exit 1
  fi
  PATH="${PATH#"$ghdir:"}"
  rm -rf "$ghdir"
  unset PURGE_GH_LOG

  # Waiting for one run stops on 403 instead of polling ten times.
  statq=$(mktemp)
  printf '%s\n' 403 completed >"$statq"
  PURGE_STATUS_QUEUE=$statq
  export PURGE_STATUS_QUEUE
  capture wait_until_completed 9
  if [ "$CAP_RC" -ne 2 ] || [ "$stdout" != "FAIL purge rate-limited" ] \
    || ! grep -Fxq completed "$statq"; then
    echo "FAIL selftest-wait-rate"
    exit 1
  fi
  : >"$statq"
  for ((i = 1; i <= 10; i++)); do
    echo in_progress >>"$statq"
  done
  capture wait_until_completed 9
  if [ "$CAP_RC" -ne 1 ] || [ -n "$stdout" ] || [ -s "$statq" ]; then
    echo "FAIL selftest-wait-budget"
    exit 1
  fi
  unset PURGE_STATUS_QUEUE
  rm -f "$listq" "$ghlog" "$statq"

  echo "PASS selftest"
  cleanup_selftest
  trap - EXIT
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

repo="${GITHUB_REPOSITORY:?}"
: "${GH_TOKEN:?}"

case "${DRY_RUN:-false}" in
  true|True|TRUE) dry=1 ;;
esac

if [ "$dry" -eq 1 ]; then
  code=$(runs_http_code "repos/${repo}/actions/runs?per_page=1")
  echo "permissions http=${code}"
  if [ "$code" != "200" ]; then
    echo "dry_run would_delete=0"
    exit 1
  fi
fi

if [ -n "${RUN_ID:-}" ]; then
  if ! printf '%s' "$RUN_ID" | grep -Eq '^[0-9]+$'; then
    note_fail 0
    would=0
    if finish; then
      exit 0
    fi
    exit 1
  fi
  if [ "$dry" -eq 1 ]; then
    would=1
    finish
    exit 0
  fi
  rc=0
  if wait_until_completed "$RUN_ID"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    exit 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "SKIP purge still-running"
    exit 0
  fi
  if ! purge_one "$RUN_ID" strict; then
    exit 0
  fi
  if finish; then
    exit 0
  fi
  exit 1
fi

sweep_all
finish
