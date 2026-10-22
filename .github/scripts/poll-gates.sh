#!/usr/bin/env bash
# List open PR head SHAs. Also consider the private repo default-branch
# head once: if that commit has no public-builder commit status, dispatch
# the same gates as a PR head. Pending counts as present. Release
# contexts do not. The gitleaks commit status does. A check-run name
# such as "gitleaks / scan" is not a commit status. Does not print
# branch names, titles, or paths.
set -euo pipefail

PRIVATE_REPO="zysicyj-xxc/zysicyj"
PB_REPO=""

only=""
tmpdir=""

want() {
  [ -z "$only" ] || [ "$only" = "$1" ]
}

# Contexts this poll writes back. build-check and push-dockerhub are not
# quality-gate statuses and must not suppress a head run. gitleaks and
# validate-admin-web are commit statuses from public-builder. Check-run
# display names are not matched here; this function only sees statuses.
is_builder_context() {
  local ctx="$1"
  case "$ctx" in
    quality/backend|quality/website|quality/flutter-analyze)
      return 0 ;;
    ci-scripts|tokens|web-shared|website|export-diff)
      return 0 ;;
    gitleaks|validate-admin-web)
      return 0 ;;
    "assert domain registry"|"layout + domain gates")
      return 0 ;;
  esac
  printf '%s' "$ctx" | grep -Eq \
    '^(flutter-test|i18n-gate|visual-lint|golden-tests|gate) \(.+\)$' \
    && return 0
  printf '%s' "$ctx" | grep -Eq \
    '^scripts/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.tests\.ps1$' \
    && return 0
  return 1
}

has_builder_status() {
  local file="$1" ctx state
  while IFS=$'\t' read -r ctx state || [ -n "${ctx:-}" ]; do
    [ -n "$ctx" ] || continue
    if is_builder_context "$ctx"; then
      return 0
    fi
  done <"$file"
  return 1
}

post_pending() {
  local sha="$1" ctx="$2"
  GH_TOKEN="$GH_TOKEN" gh api --method POST "repos/${PRIVATE_REPO}/statuses/${sha}" \
    -f state="pending" \
    -f target_url="$RUN_URL" \
    -f description="queued" \
    -f context="$ctx" >/dev/null
}

DISPATCH_OK=0
dispatch() {
  local wf="$1"
  local body="$2"
  DISPATCH_OK=0
  if ! GH_TOKEN="$DISPATCH_TOKEN" gh api --method POST \
    "repos/${PB_REPO}/actions/workflows/${wf}/dispatches" \
    --input - <<<"$body" >/dev/null; then
    echo "FAIL dispatch ${wf}"
    DISPATCH_OK=1
    return 0
  fi
  echo "PASS dispatch ${wf}"
}

mark_dispatch_failed() {
  local sha="$1"
  shift
  local ctx
  for ctx in "$@"; do
    GH_TOKEN="$GH_TOKEN" gh api --method POST "repos/${PRIVATE_REPO}/statuses/${sha}" \
      -f state="error" \
      -f target_url="$RUN_URL" \
      -f description="dispatch failed" \
      -f context="$ctx" >/dev/null || echo "FAIL status"
  done
}

latest_states() {
  local sha="$1" out="$2"
  : >"$out"
  GH_TOKEN="$GH_TOKEN" gh api --paginate \
    "repos/${PRIVATE_REPO}/commits/${sha}/statuses?per_page=100" \
    --jq '.[] | [.context, .state] | @tsv' >"$out.raw" || true
  awk -F '\t' 'NF>=2 && !seen[$1]++ { print $1 "\t" $2 }' "$out.raw" >"$out"
  rm -f "$out.raw"
}

state_of() {
  local file="$1" ctx="$2"
  awk -F '\t' -v c="$ctx" '$1==c { print $2; exit }' "$file"
}

missing() {
  local file="$1" ctx="$2" st
  st=$(state_of "$file" "$ctx")
  [ -z "$st" ]
}

cleanup_poll() {
  case "${tmpdir:-}" in
    /tmp/*) rm -rf "$tmpdir" ;;
  esac
  tmpdir=""
}

# Same missing-context dispatch used for an open PR head.
poll_one() {
  local sha="$1"
  local states body_ref joined miss app i scope ctx s
  local flutter_apps i18n_apps visual_apps web_scopes utools_scopes
  flutter_apps=(mail-box shared_package footprint eye-care admin-app water-tracker)
  i18n_apps=(daymica mail-box password-vault yaoxiaobai eye-care footprint water-tracker admin-app shared_package)
  visual_apps=(mail-box password-vault eye-care footprint yaoxiaobai daymica water-tracker)
  web_scopes=(tokens web-shared website)
  utools_scopes=(export-diff easy-script bookmark-collector blog-sync daymica-capture)
  local -A utools_ctx=(
    [export-diff]="export-diff"
    [easy-script]="gate (easy-script)"
    [bookmark-collector]="gate (bookmark-collector)"
    [blog-sync]="gate (blog-sync)"
    [daymica-capture]="gate (daymica-capture)"
  )

  states="$tmpdir/$sha.tsv"
  latest_states "$sha" "$states"
  body_ref=$(printf '{"ref":"%s","inputs":{"ref":"%s","sha":"%s"' "$DISPATCH_REF" "$sha" "$sha")

  if want quality; then
    local -a scopes=()
    missing "$states" "quality/backend" && scopes+=(backend)
    missing "$states" "quality/website" && scopes+=(website)
    missing "$states" "quality/flutter-analyze" && scopes+=(flutter)
    if [ "${#scopes[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${scopes[*]}")
      missing "$states" "quality/backend" && post_pending "$sha" "quality/backend"
      missing "$states" "quality/website" && post_pending "$sha" "quality/website"
      missing "$states" "quality/flutter-analyze" && post_pending "$sha" "quality/flutter-analyze"
      dispatch quality-analyze.yml "${body_ref},\"scopes\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        local -a qctx=()
        for s in "${scopes[@]}"; do
          case "$s" in
            backend) qctx+=("quality/backend") ;;
            website) qctx+=("quality/website") ;;
            flutter) qctx+=("quality/flutter-analyze") ;;
          esac
        done
        mark_dispatch_failed "$sha" "${qctx[@]}"
      fi
    fi
  fi

  if want flutter; then
    local -a need=()
    for app in "${flutter_apps[@]}"; do
      ctx="flutter-test (${app})"
      if missing "$states" "$ctx"; then
        post_pending "$sha" "$ctx"
        need+=("$app")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch flutter-test.yml "${body_ref},\"only\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        local -a fctx=()
        for app in "${need[@]}"; do
          fctx+=("flutter-test (${app})")
        done
        mark_dispatch_failed "$sha" "${fctx[@]}"
      fi
    fi
  fi

  if want daymica; then
    need=()
    for i in 0 1 2 3 4 5 6 7; do
      ctx="flutter-test (daymica/${i})"
      if missing "$states" "$ctx"; then
        post_pending "$sha" "$ctx"
        need+=("$i")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch daymica-test.yml "${body_ref},\"shards\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        local -a dctx=()
        for i in "${need[@]}"; do
          dctx+=("flutter-test (daymica/${i})")
        done
        mark_dispatch_failed "$sha" "${dctx[@]}"
      fi
    fi
  fi

  if want ci-scripts; then
    if missing "$states" "ci-scripts"; then
      post_pending "$sha" "ci-scripts"
      dispatch ci-scripts.yml "${body_ref}}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        mark_dispatch_failed "$sha" "ci-scripts"
      fi
    fi
  fi

  if want i18n; then
    need=()
    for app in "${i18n_apps[@]}"; do
      ctx="i18n-gate (${app})"
      if missing "$states" "$ctx"; then
        post_pending "$sha" "$ctx"
        need+=("$app")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch i18n-gate.yml "${body_ref},\"apps\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        local -a ictx=()
        for app in "${need[@]}"; do
          ictx+=("i18n-gate (${app})")
        done
        mark_dispatch_failed "$sha" "${ictx[@]}"
      fi
    fi
  fi

  if want visual; then
    need=()
    for app in "${visual_apps[@]}"; do
      ctx="visual-lint (${app})"
      if missing "$states" "$ctx"; then
        post_pending "$sha" "$ctx"
        need+=("$app")
      fi
    done
    if missing "$states" "golden-tests (shared_package)"; then
      post_pending "$sha" "golden-tests (shared_package)"
      need+=(golden)
    fi
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch visual-lint.yml "${body_ref},\"only\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        local -a vctx=()
        for app in "${need[@]}"; do
          if [ "$app" = golden ]; then
            vctx+=("golden-tests (shared_package)")
          else
            vctx+=("visual-lint (${app})")
          fi
        done
        mark_dispatch_failed "$sha" "${vctx[@]}"
      fi
    fi
  fi

  if want domain; then
    if missing "$states" "assert domain registry"; then
      post_pending "$sha" "assert domain registry"
      dispatch domain-gate.yml "${body_ref}}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        mark_dispatch_failed "$sha" "assert domain registry"
      fi
    fi
  fi

  if want web; then
    need=()
    for scope in "${web_scopes[@]}"; do
      if missing "$states" "$scope"; then
        post_pending "$sha" "$scope"
        need+=("$scope")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch web-visual.yml "${body_ref},\"scopes\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        mark_dispatch_failed "$sha" "${need[@]}"
      fi
    fi
  fi

  if want utools; then
    need=()
    for scope in "${utools_scopes[@]}"; do
      ctx="${utools_ctx[$scope]}"
      if missing "$states" "$ctx"; then
        post_pending "$sha" "$ctx"
        need+=("$scope")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch utools-visual.yml "${body_ref},\"scopes\":\"${joined}\"}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        local -a uctx=()
        for scope in "${need[@]}"; do
          uctx+=("${utools_ctx[$scope]}")
        done
        mark_dispatch_failed "$sha" "${uctx[@]}"
      fi
    fi
  fi

  if want gitleaks; then
    if missing "$states" "gitleaks"; then
      post_pending "$sha" "gitleaks"
      dispatch gitleaks.yml "${body_ref}}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        mark_dispatch_failed "$sha" "gitleaks"
      fi
    fi
  fi

  if want admin-web; then
    if missing "$states" "validate-admin-web"; then
      post_pending "$sha" "validate-admin-web"
      dispatch admin-web-gate.yml "${body_ref}}}"
      if [ "$DISPATCH_OK" -ne 0 ]; then
        mark_dispatch_failed "$sha" "validate-admin-web"
      fi
    fi
  fi

  if want scripts; then
    local tree="$tmpdir/${sha}.tree" ctxfile="$tmpdir/${sha}.ctx"
    if GH_TOKEN="$GH_TOKEN" gh api "repos/${PRIVATE_REPO}/git/trees/${sha}?recursive=1" >"$tree" \
      && python3 .github/scripts/scripts_gate_run.py --contexts "$tree" "$ctxfile" >/dev/null; then
      miss=0
      while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        if missing "$states" "$ctx"; then
          post_pending "$sha" "$ctx"
          miss=1
        fi
      done <"$ctxfile"
      if [ "$miss" -eq 1 ]; then
        dispatch scripts-gate.yml "${body_ref},\"force\":\"false\"}}"
        if [ "$DISPATCH_OK" -ne 0 ]; then
          local -a sctx=()
          while IFS= read -r ctx; do
            [ -n "$ctx" ] || continue
            if missing "$states" "$ctx"; then
              sctx+=("$ctx")
            fi
          done <"$ctxfile"
          if [ "${#sctx[@]}" -gt 0 ]; then
            mark_dispatch_failed "$sha" "${sctx[@]}"
          fi
        fi
      fi
    else
      echo "FAIL scripts-list"
    fi
  fi
}

run_poll() {
  trap cleanup_poll EXIT
  PB_REPO="${GITHUB_REPOSITORY:?}"
  : "${GH_TOKEN:?}"
  : "${DISPATCH_TOKEN:?}"
  : "${DISPATCH_REF:?}"
  : "${RUN_URL:?}"

  if ! printf '%s' "$DISPATCH_REF" | grep -Eq '^[A-Za-z0-9._/-]{1,200}$'; then
    echo "FAIL poll ref"
    exit 1
  fi

  only="${ONLY:-}"
  case "$only" in
    ""|quality|flutter|daymica|ci-scripts|i18n|visual|domain|scripts|web|utools|gitleaks|admin-web) ;;
    *) echo "FAIL poll only"; exit 1 ;;
  esac

  local main_sha s
  main_sha=$(GH_TOKEN="$GH_TOKEN" gh api "repos/${PRIVATE_REPO}/commits/main" --jq .sha)
  main_sha=$(printf '%s' "$main_sha" | tr 'A-F' 'a-f' | tr -d '[:space:]')
  if ! printf '%s' "$main_sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "FAIL poll head"
    exit 1
  fi

  local -a pr_shas=()
  mapfile -t pr_shas < <(GH_TOKEN="$GH_TOKEN" gh api --paginate \
    "repos/${PRIVATE_REPO}/pulls?state=open&per_page=100" --jq '.[].head.sha')

  local -A seen=()
  local -a prs=()
  if [ "${#pr_shas[@]}" -gt 0 ]; then
    for s in "${pr_shas[@]}"; do
      s=$(printf '%s' "$s" | tr 'A-F' 'a-f' | tr -d '[:space:]')
      if ! printf '%s' "$s" | grep -Eq '^[0-9a-f]{40}$'; then
        continue
      fi
      # The default-branch head is decided once, even if a PR lists it.
      if [ "$s" = "$main_sha" ]; then
        continue
      fi
      if [ -z "${seen[$s]:-}" ]; then
        seen[$s]=1
        prs+=("$s")
      fi
    done
  fi

  cleanup_poll
  tmpdir=$(mktemp -d)
  local head_states="$tmpdir/head.tsv" skip=0 total
  latest_states "$main_sha" "$head_states"
  if has_builder_status "$head_states"; then
    skip=1
  fi
  total=$(( ${#prs[@]} + 1 ))
  echo "PASS poll shas=${total}"
  echo "PASS poll skip=${skip}"

  if [ "$skip" -eq 0 ]; then
    poll_one "$main_sha"
  fi
  if [ "${#prs[@]}" -gt 0 ]; then
    for s in "${prs[@]}"; do
      poll_one "$s"
    done
  fi
  cleanup_poll
}

selftest() {
  local root script_dir wf
  script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
  root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
  cd "$root"
  wf="$script_dir/../workflows/poll-private-gates.yml"

  if [ ! -f .github/scripts/scripts_gate_run.py ]; then
    echo "FAIL selftest-root"
    exit 1
  fi
  if ! grep -Fq "cron: '3,13,23,33,43,53 * * * *'" "$wf"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  if grep -Fq "cron: '*/5 * * * *'" "$wf"; then
    echo "FAIL selftest-cron"
    exit 1
  fi
  if awk '/^selftest\(\)/ { exit } { print }' "$script_dir/poll-gates.sh" \
    | grep -Eq 'build-private-android|build-private-windows|trigger-build'; then
    echo "FAIL selftest-boundary"
    exit 1
  fi
  if grep -Eq 'build-private-android|build-private-windows|trigger-build' "$wf"; then
    echo "FAIL selftest-boundary"
    exit 1
  fi
  if ! grep -Fq 'quality-analyze.yml' "$script_dir/purge-gate-logs.sh" \
    || ! grep -Fq 'flutter-test.yml' "$script_dir/purge-gate-logs.sh" \
    || ! grep -Fq 'scripts-gate.yml' "$script_dir/purge-gate-logs.sh" \
    || ! grep -Fq 'utools-visual.yml' "$script_dir/purge-gate-logs.sh" \
    || ! grep -Fq 'gitleaks.yml' "$script_dir/purge-gate-logs.sh" \
    || ! grep -Fq 'admin-web-gate.yml' "$script_dir/purge-gate-logs.sh"; then
    echo "FAIL selftest-purge"
    exit 1
  fi

  expect_yes() {
    if ! is_builder_context "$2"; then
      echo "FAIL selftest-ctx-$1"
      exit 1
    fi
  }
  expect_no() {
    if is_builder_context "$2"; then
      echo "FAIL selftest-ctx-$1"
      exit 1
    fi
  }
  expect_yes qb "quality/backend"
  expect_yes qw "quality/website"
  expect_yes qf "quality/flutter-analyze"
  expect_yes ci "ci-scripts"
  expect_yes ft "flutter-test (shared_package)"
  expect_yes fd "flutter-test (daymica/0)"
  expect_yes i18n "i18n-gate (water-tracker)"
  expect_yes vis "visual-lint (mail-box)"
  expect_yes gold "golden-tests (shared_package)"
  expect_yes gate "gate (easy-script)"
  expect_yes dom "assert domain registry"
  expect_yes lay "layout + domain gates"
  expect_yes tok "tokens"
  expect_yes web "website"
  expect_yes exp "export-diff"
  expect_yes scr "scripts/layout.tests.ps1"
  expect_yes nest "scripts/nested/name.tests.ps1"
  expect_yes gl "gitleaks"
  expect_yes aw "validate-admin-web"
  expect_no gl2 "Gitleaks"
  expect_no gl3 "gitleaks / scan"
  expect_no bc "build-check"
  expect_no pd "push-dockerhub"
  expect_no cov "coverage"
  expect_no bad "scripts/not-a-test.ps1"

  export GH_TOKEN='ghp_selftestsecretvalue'
  export DISPATCH_TOKEN="$GH_TOKEN"
  export GITHUB_REPOSITORY='example/public-builder'
  export DISPATCH_REF='selftest'
  export RUN_URL='run-local'
  export ONLY=''
  local HEAD PR
  HEAD='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  PR='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

  prepare() {
    TEST_DIR=$(mktemp -d)
    export FAKE_LOG="$TEST_DIR/log"
    export FAKE_STATUSES="$TEST_DIR/statuses"
    : >"$FAKE_LOG"
    : >"$FAKE_STATUSES"
    cat >"$TEST_DIR/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
log="${FAKE_LOG:?}"
method=GET
url=""
context=""
state=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--method" ]; then
    method=$a
  elif [ "$prev" = "-f" ]; then
    case "$a" in
      context=*) context=${a#context=} ;;
      state=*) state=${a#state=} ;;
    esac
  elif [[ "$a" == repos/* ]]; then
    url=$a
  fi
  prev=$a
done
if [ "$method" = POST ] && [[ "$url" == *"/dispatches" ]]; then
  body=$(cat)
  wf=$(printf '%s' "$url" | sed -n 's|.*/workflows/\([^/]*\)/dispatches|\1|p')
  printf 'dispatch\t%s\t%s\n' "$wf" "$body" >>"$log"
  exit 0
fi
if [ "$method" = POST ] && [[ "$url" == *"/statuses/"* ]]; then
  sha=${url##*/}
  printf 'status\t%s\t%s\t%s\n' "$sha" "$context" "$state" >>"$log"
  exit 0
fi
if [[ "$url" == *"/commits/"*"/statuses?"* ]]; then
  sha=$(printf '%s' "$url" | sed -n 's|.*/commits/\([0-9a-fA-F]\{40\}\)/statuses.*|\1|p')
  sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
  if [ -f "${FAKE_STATUSES:?}" ]; then
    awk -F '\t' -v s="$sha" '$1==s { print $2 "\t" $3 }' "$FAKE_STATUSES"
  fi
  exit 0
fi
if [[ "$url" == *"/commits/main" ]]; then
  printf '%s' "${FAKE_MAIN_SHA-}"
  exit 0
fi
if [[ "$url" == *"/pulls?"* ]]; then
  if [ -n "${FAKE_PR_SHAS:-}" ]; then
    printf '%s\n' "$FAKE_PR_SHAS"
  fi
  exit 0
fi
if [[ "$url" == *"/git/trees/"* ]]; then
  printf '%s' '{"truncated":false,"tree":[{"path":"scripts/lib/assert-scripts-layout.ps1","type":"blob"},{"path":"scripts/lib/assert-domain-registry.ps1","type":"blob"},{"path":"scripts/layout.tests.ps1","type":"blob"}]}'
  exit 0
fi
printf 'unexpected\n' >>"$log"
exit 1
EOF
    chmod +x "$TEST_DIR/gh"
  }

  execute() {
    TEST_OUT="$TEST_DIR/out"
    TEST_ERR="$TEST_DIR/err"
    set +e
    (
      hash -r
      export PATH="$TEST_DIR:$PATH"
      run_poll
    ) >"$TEST_OUT" 2>"$TEST_ERR"
    TEST_RC=$?
    set -e
  }

  check_quiet() {
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
      if ! printf '%s' "$line" | grep -Eq '^(PASS|FAIL) [A-Za-z0-9._+=,()-]+( [A-Za-z0-9._+=,()-]+)?$'; then
        echo "FAIL selftest-${id}-log"
        exit 1
      fi
    done <"$TEST_OUT"
    files=("$TEST_OUT" "$TEST_ERR")
    if grep -F -q "$GH_TOKEN" "${files[@]}" \
      || grep -E -q 'https?://|refs/|scripts/|\.ps1|zysicyj' "${files[@]}" \
      || grep -F -q "$HEAD" "${files[@]}"; then
      echo "FAIL selftest-${id}-leak"
      exit 1
    fi
    if [ -n "${PR_USED:-}" ] && grep -F -q "$PR" "${files[@]}"; then
      echo "FAIL selftest-${id}-leak"
      exit 1
    fi
  }

  dispatch_count() {
    local wf="$1" sha="$2"
    awk -F '\t' -v w="$wf" -v s="$sha" \
      '$1=="dispatch" && $2==w && index($3,s) { n++ } END { print n+0 }' "$FAKE_LOG"
  }

  status_count() {
    local sha="$1"
    awk -F '\t' -v s="$sha" '$1=="status" && $2==s { n++ } END { print n+0 }' "$FAKE_LOG"
  }

  gates='quality-analyze.yml flutter-test.yml daymica-test.yml ci-scripts.yml i18n-gate.yml visual-lint.yml domain-gate.yml web-visual.yml utools-visual.yml gitleaks.yml admin-web-gate.yml scripts-gate.yml'

  # Missing builder status: run the full gate set once.
  prepare
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet missing-run
  if [ "$TEST_RC" -ne 0 ] \
    || ! grep -Fxq 'PASS poll shas=1' "$TEST_OUT" \
    || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT"; then
    echo "FAIL selftest-missing-run"
    exit 1
  fi
  local g got
  for g in $gates; do
    got=$(dispatch_count "$g" "$HEAD")
    if [ "$got" != 1 ]; then
      echo "FAIL selftest-missing-run"
      exit 1
    fi
  done
  if [ "$(status_count "$HEAD")" -eq 0 ]; then
    echo "FAIL selftest-missing-run"
    exit 1
  fi
  if awk -F '\t' '$1=="dispatch" && $2 !~ /^(quality-analyze|flutter-test|daymica-test|ci-scripts|i18n-gate|visual-lint|domain-gate|web-visual|utools-visual|gitleaks|admin-web-gate|scripts-gate)\.yml$/ { bad=1 } END { exit bad+0 }' "$FAKE_LOG"; then
    :
  else
    echo "FAIL selftest-missing-run"
    exit 1
  fi
  local replay="$TEST_DIR/replay.tsv"
  awk -F '\t' '$1=="status" { print $2 "\t" $3 "\t" $4 }' "$FAKE_LOG" >"$replay"

  # Statuses this run just posted, including pending, skip the next pass.
  prepare
  cp "$replay" "$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet present-skip
  if [ "$TEST_RC" -ne 0 ] \
    || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT" \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 0 ] \
    || [ "$(status_count "$HEAD")" != 0 ]; then
    echo "FAIL selftest-present-skip"
    exit 1
  fi

  # A single pending quality status is enough to skip the whole head.
  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'quality/backend' 'pending' >"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet pending-skip
  if [ "$TEST_RC" -ne 0 ] \
    || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT" \
    || [ "$(awk -F '\t' '$1=="dispatch" { n++ } END { print n+0 }' "$FAKE_LOG")" != 0 ]; then
    echo "FAIL selftest-pending-skip"
    exit 1
  fi

  # success and error are present too.
  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'flutter-test (shared_package)' 'success' >"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet success-skip
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT" \
    || [ "$(awk -F '\t' '$1=="dispatch" { n++ } END { print n+0 }' "$FAKE_LOG")" != 0 ]; then
    echo "FAIL selftest-success-skip"
    exit 1
  fi

  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'error' >"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet error-skip
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT"; then
    echo "FAIL selftest-error-skip"
    exit 1
  fi

  # The gitleaks commit status counts, so it skips the whole head.
  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'gitleaks' 'success' >"$FAKE_STATUSES"
  printf '%s\t%s\t%s\n' "$HEAD" 'Gitleaks' 'pending' >>"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet gitleaks-skip
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT" \
    || [ "$(awk -F '\t' '$1=="dispatch" { n++ } END { print n+0 }' "$FAKE_LOG")" != 0 ]; then
    echo "FAIL selftest-gitleaks-skip"
    exit 1
  fi

  # Check-run style names are not the commit status and do not skip.
  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'gitleaks / scan' 'success' >"$FAKE_STATUSES"
  printf '%s\t%s\t%s\n' "$HEAD" 'Gitleaks' 'pending' >>"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet gitleaks-checkrun
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count gitleaks.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 1 ]; then
    echo "FAIL selftest-gitleaks-checkrun"
    exit 1
  fi

  # Release contexts do not count.
  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'build-check' 'success' >"$FAKE_STATUSES"
  printf '%s\t%s\t%s\n' "$HEAD" 'push-dockerhub' 'success' >>"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet release-run
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count flutter-test.yml "$HEAD")" != 1 ]; then
    echo "FAIL selftest-release-run"
    exit 1
  fi

  # Open PR heads still fill missing contexts when the default head is skipped.
  prepare
  printf '%s\t%s\t%s\n' "$HEAD" 'quality/backend' 'success' >"$FAKE_STATUSES"
  printf '%s\t%s\t%s\n' "$PR" 'quality/backend' 'pending' >>"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS="$PR" ONLY='' PR_USED=1
  execute
  check_quiet pr-still
  pr_quality=$(awk -F '\t' -v s="$PR" \
    '$1=="dispatch" && $2=="quality-analyze.yml" && index($3,s) { print $3 }' "$FAKE_LOG")
  if [ "$TEST_RC" -ne 0 ] \
    || ! grep -Fxq 'PASS poll shas=2' "$TEST_OUT" \
    || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT" \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 0 ] \
    || [ "$(dispatch_count flutter-test.yml "$HEAD")" != 0 ] \
    || [ "$(dispatch_count quality-analyze.yml "$PR")" != 1 ] \
    || [ "$(dispatch_count flutter-test.yml "$PR")" != 1 ] \
    || printf '%s' "$pr_quality" | grep -q 'backend'; then
    echo "FAIL selftest-pr-still"
    exit 1
  fi

  # The same SHA listed as a PR head is not dispatched twice.
  prepare
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS="$HEAD" ONLY='' PR_USED=''
  execute
  check_quiet once
  if [ "$TEST_RC" -ne 0 ] \
    || ! grep -Fxq 'PASS poll shas=1' "$TEST_OUT" \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count scripts-gate.yml "$HEAD")" != 1 ]; then
    echo "FAIL selftest-once"
    exit 1
  fi

  # Manual only= still limits the one pass. It does not name a branch.
  prepare
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='quality' PR_USED=''
  execute
  check_quiet only
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count flutter-test.yml "$HEAD")" != 0 ] \
    || [ "$(dispatch_count gitleaks.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-only"
    exit 1
  fi

  prepare
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='gitleaks' PR_USED=''
  execute
  check_quiet only-gitleaks
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count gitleaks.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count admin-web-gate.yml "$HEAD")" != 0 ] \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-only-gitleaks"
    exit 1
  fi

  prepare
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='admin-web' PR_USED=''
  execute
  check_quiet only-admin
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count admin-web-gate.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count gitleaks.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-only-admin"
    exit 1
  fi

  prepare
  export FAKE_MAIN_SHA='not-a-sha' FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet badhead
  if [ "$TEST_RC" -eq 0 ] || ! grep -Fxq 'FAIL poll head' "$TEST_OUT"; then
    echo "FAIL selftest-badhead"
    exit 1
  fi

  echo "PASS selftest"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_poll
