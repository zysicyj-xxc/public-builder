#!/usr/bin/env bash
# Fail when poll-private-gates.yml has not started a run in 30 minutes.
# Dispatch that workflow once, then open or update one fixed-title issue.
# When the latest run is fresh and that issue is open, comment once and close it.
# stdout is only PASS or FAIL lines. No refs, tags, URLs, or tokens.
set -euo pipefail

WORKFLOW=poll-private-gates.yml
ISSUE_TITLE='poll-private-gates schedule stale'
RECOVER_COMMENT='poll-private-gates.yml 已在 30 分钟内再次运行，关闭此告警。'
STALE_SECONDS=1800

export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1

gh_rc=0
gh_out=""

stale_age() {
  local age="$1"
  if [ -z "$age" ]; then
    return 0
  fi
  if [ "$age" -gt "$STALE_SECONDS" ]; then
    return 0
  fi
  return 1
}

gh_call() {
  local out err
  out=$(mktemp)
  err=$(mktemp)
  set +e
  gh "$@" >"$out" 2>"$err"
  gh_rc=$?
  set -e
  if [ "$gh_rc" -eq 0 ]; then
    gh_out=$(cat "$out")
  else
    gh_out=""
  fi
  rm -f "$out" "$err"
}

list_stale_issues() {
  local repo="$1"
  gh_call issue list --repo "$repo" --state open --limit 50 \
    --search "${ISSUE_TITLE} in:title" \
    --json number,title \
    --jq '.[] | select(.title=="poll-private-gates schedule stale") | .number'
}

close_open_issues() {
  local repo="$1" note num closed
  list_stale_issues "$repo"
  if [ "$gh_rc" -ne 0 ]; then
    echo "FAIL close"
    exit 1
  fi
  note=$(mktemp)
  printf '%s\n' "$RECOVER_COMMENT" >"$note"
  closed=0
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    gh_call issue comment "$num" --repo "$repo" --body-file "$note"
    if [ "$gh_rc" -ne 0 ]; then
      rm -f "$note"
      echo "FAIL close"
      exit 1
    fi
    gh_call issue close "$num" --repo "$repo"
    if [ "$gh_rc" -ne 0 ]; then
      rm -f "$note"
      echo "FAIL close"
      exit 1
    fi
    closed=1
  done < <(printf '%s\n' "$gh_out" | awk '/^[0-9]+$/ { print $1 }' | sort -n)
  rm -f "$note"
  if [ "$closed" -eq 1 ]; then
    echo "PASS close"
  fi
}

write_body() {
  local minutes="$1" dispatch_state="$2" file="$3"
  if ! printf '%s' "$minutes" | grep -Eq '^[0-9]+$'; then
    minutes=none
  fi
  case "$dispatch_state" in
    requested|failed|skipped) ;;
    *) dispatch_state=failed ;;
  esac
  printf '%s\n' \
    'poll-private-gates.yml 超过 30 分钟没有新的运行。' \
    "stale_minutes=${minutes}" \
    "dispatch=${dispatch_state}" >"$file"
}

main() {
  : "${GH_TOKEN:?}"
  : "${GITHUB_REPOSITORY:?}"
  : "${DISPATCH_REF:?}"

  local repo created age now run_epoch minutes num body
  local dispatch_state issue_failed
  repo="$GITHUB_REPOSITORY"
  if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "FAIL api"
    exit 1
  fi

  gh_call api --jq '.workflow_runs[0].created_at // ""' \
    "repos/${repo}/actions/workflows/${WORKFLOW}/runs?per_page=1"
  if [ "$gh_rc" -ne 0 ]; then
    echo "FAIL api"
    exit 1
  fi

  created=$(printf '%s' "$gh_out" | tr -d '[:space:]')
  age=""
  if [ -n "$created" ]; then
    if ! printf '%s' "$created" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'; then
      echo "FAIL api"
      exit 1
    fi
    if ! run_epoch=$(date -u -d "$created" +%s 2>/dev/null); then
      echo "FAIL api"
      exit 1
    fi
    now=$(date -u +%s)
    age=$((now - run_epoch))
  fi

  if ! stale_age "$age"; then
    echo "PASS poll"
    close_open_issues "$repo"
    exit 0
  fi

  minutes=""
  if [ -n "$age" ] && [ "$age" -gt 0 ]; then
    minutes=$(((age + 59) / 60))
  fi

  dispatch_state=skipped
  if printf '%s' "$DISPATCH_REF" | grep -Eq '^[A-Za-z0-9._/-]{1,200}$'; then
    gh_call api --method POST \
      "repos/${repo}/actions/workflows/${WORKFLOW}/dispatches" \
      --raw-field "ref=${DISPATCH_REF}"
    if [ "$gh_rc" -eq 0 ]; then
      dispatch_state=requested
    else
      dispatch_state=failed
      echo "FAIL dispatch"
    fi
  else
    echo "FAIL dispatch"
  fi

  body=$(mktemp)
  trap 'rm -f "$body"' EXIT
  write_body "$minutes" "$dispatch_state" "$body"

  issue_failed=0
  list_stale_issues "$repo"
  if [ "$gh_rc" -ne 0 ]; then
    issue_failed=1
  else
    num=$(printf '%s\n' "$gh_out" | awk '/^[0-9]+$/ { if (n == "" || ($1 + 0) < n) n = $1 } END { if (n != "") print n }')
    if [ -n "$num" ]; then
      gh_call issue edit "$num" --repo "$repo" --body-file "$body"
    else
      gh_call issue create --repo "$repo" --title "$ISSUE_TITLE" --body-file "$body"
    fi
    if [ "$gh_rc" -ne 0 ]; then
      issue_failed=1
    fi
  fi
  if [ "$issue_failed" -eq 1 ]; then
    echo "FAIL issue"
  fi
  echo "FAIL stale"
  exit 1
}

selftest() {
  local script_dir wf_dir purge_sh epoch body f
  script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
  wf_dir="$script_dir/../workflows"
  purge_sh="$script_dir/purge-gate-logs.sh"

  if ! grep -Fq "cron: '3,13,23,33,43,53 * * * *'" "$wf_dir/poll-private-gates.yml"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  if grep -Fq "cron: '*/5 * * * *'" "$wf_dir/poll-private-gates.yml"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  if ! grep -Fq "cron: '8,38 * * * *'" "$wf_dir/poll-gates-watchdog.yml"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  if ! grep -Fq "cron: '6,16,26,36,46,56 * * * *'" "$wf_dir/purge-gate-logs.yml"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  if grep -Fq "cron: '*/5 * * * *'" "$wf_dir/purge-gate-logs.yml"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  for purge_min in 6 16 26 36 46 56; do
    for other_min in 3 13 23 33 43 53 8 38; do
      if [ "$purge_min" = "$other_min" ]; then
        echo "FAIL selftest-cron"
        exit 1
      fi
    done
  done
  if grep -Eq '^[[:space:]]*(pull_request|pull_request_target|push|fork|issues|issue_comment):[[:space:]]*$' \
    "$wf_dir/poll-gates-watchdog.yml"; then
    echo "FAIL selftest-trigger"
    exit 1
  fi
  if ! grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' \
    "$wf_dir/poll-gates-watchdog.yml"; then
    echo "FAIL selftest-pin"
    exit 1
  fi
  if ! grep -Fq 'actions: write' "$wf_dir/poll-gates-watchdog.yml" \
    || ! grep -Fq 'issues: write' "$wf_dir/poll-gates-watchdog.yml"; then
    echo "FAIL selftest-perm"
    exit 1
  fi
  if ! grep -Fq 'poll-private-gates.yml' "$purge_sh" \
    || ! grep -Fq 'poll-gates-watchdog.yml' "$purge_sh"; then
    echo "FAIL selftest-purge"
    exit 1
  fi

  if stale_age 1800; then
    echo "FAIL selftest-boundary"
    exit 1
  fi
  if ! stale_age 1801; then
    echo "FAIL selftest-boundary"
    exit 1
  fi
  if ! stale_age ""; then
    echo "FAIL selftest-boundary"
    exit 1
  fi

  f=$(mktemp)
  write_body 12 requested "$f"
  if ! grep -Fxq 'poll-private-gates.yml 超过 30 分钟没有新的运行。' "$f" \
    || ! grep -Fxq 'stale_minutes=12' "$f" \
    || ! grep -Fxq 'dispatch=requested' "$f"; then
    echo "FAIL selftest-body"
    exit 1
  fi
  write_body '12;rm' skipped "$f"
  if ! grep -Fxq 'stale_minutes=none' "$f" \
    || ! grep -Fxq 'dispatch=skipped' "$f"; then
    echo "FAIL selftest-body"
    exit 1
  fi
  rm -f "$f"

  export GH_TOKEN='ghp_selftestsecretvalue'
  export GITHUB_REPOSITORY='example/public-builder'
  export DISPATCH_REF='main'
  export FAKE_CREATED=''
  export FAKE_ISSUES=''
  export FAKE_API_RC=0
  export FAKE_LIST_RC=0
  export FAKE_CREATE_RC=0
  export FAKE_EDIT_RC=0
  export FAKE_DISPATCH_RC=0
  export FAKE_COMMENT_RC=0
  export FAKE_CLOSE_RC=0

  reset_fakes() {
    FAKE_CREATED=''
    FAKE_ISSUES=''
    FAKE_API_RC=0
    FAKE_LIST_RC=0
    FAKE_CREATE_RC=0
    FAKE_EDIT_RC=0
    FAKE_DISPATCH_RC=0
    FAKE_COMMENT_RC=0
    FAKE_CLOSE_RC=0
    DISPATCH_REF='main'
  }

  run_main() {
    TEST_DIR=$(mktemp -d)
    export GH_ACTIONS="$TEST_DIR/actions"
    export GH_BODY="$TEST_DIR/body"
    cat >"$TEST_DIR/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
actions="${GH_ACTIONS:?}"
body_dest="${GH_BODY:?}"
record() { printf '%s\n' "$1" >>"$actions"; }
save_body() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "--body-file" ]; then
      cp "$a" "$body_dest"
    fi
    prev="$a"
  done
}
joined=$(printf '%s ' "$@")
if printf '%s' "$joined" | grep -q 'runs?per_page=1'; then
  record runs
  if [ "${FAKE_API_RC:-0}" -ne 0 ]; then
    exit "$FAKE_API_RC"
  fi
  printf '%s' "${FAKE_CREATED-}"
  exit 0
fi
if printf '%s' "$joined" | grep -q 'issue list'; then
  record list
  if [ "${FAKE_LIST_RC:-0}" -ne 0 ]; then
    exit "$FAKE_LIST_RC"
  fi
  printf '%s' "${FAKE_ISSUES-}"
  exit 0
fi
if printf '%s' "$joined" | grep -q 'issue create'; then
  record create
  save_body "$@"
  exit "${FAKE_CREATE_RC:-0}"
fi
if printf '%s' "$joined" | grep -q 'issue edit'; then
  record edit
  save_body "$@"
  for a in "$@"; do
    case "$a" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "editnum=$a" >>"$actions"; break ;;
    esac
  done
  exit "${FAKE_EDIT_RC:-0}"
fi
if printf '%s' "$joined" | grep -q 'issue comment'; then
  record comment
  save_body "$@"
  for a in "$@"; do
    case "$a" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "commentnum=$a" >>"$actions"; break ;;
    esac
  done
  exit "${FAKE_COMMENT_RC:-0}"
fi
if printf '%s' "$joined" | grep -q 'issue close'; then
  record close
  for a in "$@"; do
    case "$a" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "closenum=$a" >>"$actions"; break ;;
    esac
  done
  exit "${FAKE_CLOSE_RC:-0}"
fi
if printf '%s' "$joined" | grep -q 'dispatches'; then
  record dispatch
  exit "${FAKE_DISPATCH_RC:-0}"
fi
record unexpected
exit 1
EOF
    chmod +x "$TEST_DIR/gh"
    : >"$TEST_DIR/actions"
    TEST_OUT="$TEST_DIR/out"
    TEST_ERR="$TEST_DIR/err"
    set +e
    (
      hash -r
      export PATH="$TEST_DIR:$PATH"
      main
    ) >"$TEST_OUT" 2>"$TEST_ERR"
    TEST_RC=$?
    set -e
  }

  check_logs() {
    local id="$1" line files
    if [ -s "$TEST_ERR" ]; then
      echo "FAIL selftest-${id}-stderr"
      exit 1
    fi
    if [ ! -s "$TEST_OUT" ]; then
      echo "FAIL selftest-${id}-empty"
      exit 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      if ! printf '%s' "$line" | grep -Eq '^(PASS|FAIL) [A-Za-z0-9._+=,()-]+$'; then
        echo "FAIL selftest-${id}-log"
        exit 1
      fi
    done <"$TEST_OUT"
    files=("$TEST_OUT" "$TEST_ERR" "$TEST_DIR/actions")
    if [ -f "$TEST_DIR/body" ]; then
      files+=("$TEST_DIR/body")
    fi
    if grep -F -q "$GH_TOKEN" "${files[@]}" \
      || grep -E -q 'https?://|refs/' "${files[@]}"; then
      echo "FAIL selftest-${id}-secret"
      exit 1
    fi
  }

  count_action() {
    grep -cx "$1" "$TEST_DIR/actions" || true
  }

  epoch=$(date -u +%s)

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 600))" +%Y-%m-%dT%H:%M:%S.123Z)
  run_main
  check_logs fresh
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll' "$TEST_OUT"; then
    echo "FAIL selftest-fresh"
    exit 1
  fi
  if [ "$(count_action runs)" -ne 1 ] || [ "$(count_action list)" -ne 1 ] \
    || [ "$(count_action dispatch)" -ne 0 ] || [ "$(count_action create)" -ne 0 ] \
    || [ "$(count_action edit)" -ne 0 ] || [ "$(count_action comment)" -ne 0 ] \
    || [ "$(count_action close)" -ne 0 ] || grep -Fxq 'PASS close' "$TEST_OUT"; then
    echo "FAIL selftest-fresh"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 600))" +%Y-%m-%dT%H:%M:%SZ)
  FAKE_ISSUES=$'9\n3\n'
  run_main
  check_logs recover
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll' "$TEST_OUT" \
    || ! grep -Fxq 'PASS close' "$TEST_OUT"; then
    echo "FAIL selftest-recover"
    exit 1
  fi
  if [ "$(count_action comment)" -ne 2 ] || [ "$(count_action close)" -ne 2 ] \
    || [ "$(count_action dispatch)" -ne 0 ] || [ "$(count_action create)" -ne 0 ] \
    || ! grep -Fxq 'commentnum=3' "$TEST_DIR/actions" \
    || ! grep -Fxq 'closenum=3' "$TEST_DIR/actions" \
    || ! grep -Fxq 'commentnum=9' "$TEST_DIR/actions" \
    || ! grep -Fxq 'closenum=9' "$TEST_DIR/actions"; then
    echo "FAIL selftest-recover"
    exit 1
  fi
  if ! grep -Fxq 'poll-private-gates.yml 已在 30 分钟内再次运行，关闭此告警。' "$TEST_DIR/body"; then
    echo "FAIL selftest-recover"
    exit 1
  fi
  if grep -E -q 'https?://|refs/|ghp_' "$TEST_DIR/body"; then
    echo "FAIL selftest-recover"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 600))" +%Y-%m-%dT%H:%M:%SZ)
  FAKE_ISSUES='7'
  FAKE_COMMENT_RC=1
  run_main
  check_logs comment
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'PASS poll' "$TEST_OUT" \
    || ! grep -Fxq 'FAIL close' "$TEST_OUT" \
    || [ "$(count_action comment)" -ne 1 ] || [ "$(count_action close)" -ne 0 ]; then
    echo "FAIL selftest-comment"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 600))" +%Y-%m-%dT%H:%M:%SZ)
  FAKE_ISSUES='7'
  FAKE_CLOSE_RC=1
  run_main
  check_logs closefail
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL close' "$TEST_OUT" \
    || [ "$(count_action comment)" -ne 1 ] || [ "$(count_action close)" -ne 1 ]; then
    echo "FAIL selftest-closefail"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 2400))" +%Y-%m-%dT%H:%M:%SZ)
  DISPATCH_REF='feature-secret-ref'
  run_main
  check_logs stale
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL stale' "$TEST_OUT"; then
    echo "FAIL selftest-stale"
    exit 1
  fi
  files=("$TEST_OUT" "$TEST_ERR")
  if [ -f "$TEST_DIR/body" ]; then
    files+=("$TEST_DIR/body")
  fi
  if grep -F -q 'feature-secret-ref' "${files[@]}"; then
    echo "FAIL selftest-stale-ref"
    exit 1
  fi
  if [ "$(count_action dispatch)" -ne 1 ] || [ "$(count_action create)" -ne 1 ] \
    || [ "$(count_action edit)" -ne 0 ]; then
    echo "FAIL selftest-stale"
    exit 1
  fi
  if ! grep -Fxq 'dispatch=requested' "$TEST_DIR/body"; then
    echo "FAIL selftest-stale"
    exit 1
  fi
  body=$(awk -F= '$1=="stale_minutes" {print $2}' "$TEST_DIR/body")
  if ! printf '%s' "$body" | grep -Eq '^[0-9]+$' || [ "$body" -lt 40 ]; then
    echo "FAIL selftest-stale-minutes"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=''
  run_main
  check_logs missing
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'stale_minutes=none' "$TEST_DIR/body"; then
    echo "FAIL selftest-missing"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 2400))" +%Y-%m-%dT%H:%M:%SZ)
  FAKE_ISSUES=$'12\n4\n'
  run_main
  check_logs edit
  if [ "$(count_action edit)" -ne 1 ] || [ "$(count_action create)" -ne 0 ] \
    || ! grep -Fxq 'editnum=4' "$TEST_DIR/actions"; then
    echo "FAIL selftest-edit"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 2400))" +%Y-%m-%dT%H:%M:%SZ)
  DISPATCH_REF='bad ref'
  run_main
  check_logs badref
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL dispatch' "$TEST_OUT" \
    || [ "$(count_action dispatch)" -ne 0 ] \
    || ! grep -Fxq 'dispatch=skipped' "$TEST_DIR/body"; then
    echo "FAIL selftest-badref"
    exit 1
  fi
  files=("$TEST_OUT" "$TEST_ERR")
  if [ -f "$TEST_DIR/body" ]; then
    files+=("$TEST_DIR/body")
  fi
  if grep -F -q 'bad ref' "${files[@]}"; then
    echo "FAIL selftest-badref"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_API_RC=1
  FAKE_CREATED=$(date -u -d "@$((epoch - 2400))" +%Y-%m-%dT%H:%M:%SZ)
  run_main
  check_logs api
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL api' "$TEST_OUT" \
    || [ "$(count_action dispatch)" -ne 0 ] || [ "$(count_action list)" -ne 0 ]; then
    echo "FAIL selftest-api"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED='2026-13-40T99:99:99Z'
  run_main
  check_logs clock
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL api' "$TEST_OUT" \
    || [ "$(count_action dispatch)" -ne 0 ]; then
    echo "FAIL selftest-clock"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 2400))" +%Y-%m-%dT%H:%M:%SZ)
  FAKE_DISPATCH_RC=1
  run_main
  check_logs dispatch
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL dispatch' "$TEST_OUT" \
    || ! grep -Fxq 'dispatch=failed' "$TEST_DIR/body"; then
    echo "FAIL selftest-dispatch"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  reset_fakes
  FAKE_CREATED=$(date -u -d "@$((epoch - 2400))" +%Y-%m-%dT%H:%M:%SZ)
  FAKE_LIST_RC=1
  run_main
  check_logs list
  if [ "$TEST_RC" -ne 1 ] || ! grep -Fxq 'FAIL issue' "$TEST_OUT" \
    || [ "$(count_action create)" -ne 0 ] || [ "$(count_action dispatch)" -ne 1 ]; then
    echo "FAIL selftest-list"
    exit 1
  fi
  rm -rf "$TEST_DIR"

  echo "PASS selftest"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi
main
