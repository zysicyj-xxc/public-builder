#!/usr/bin/env bash
# List open PR head SHAs. Also consider the private repo default-branch
# head once: if that commit has no public-builder commit status, dispatch
# the same gates as a PR head. A fresh pending counts as present. Release
# contexts do not. The gitleaks commit status does. A check-run name
# such as "gitleaks / scan" is not a commit status. Does not print
# branch names, titles, or paths.
# error "dispatch failed", "rate-limited", and "report rate-limited" are
# missing and can be dispatched again. pending "queued", "running", or
# "rate-limited" older than 90 minutes is missing too. A 403 or 429 on
# dispatch writes nothing and stops the rest of the round.
set -euo pipefail

PRIVATE_REPO="zysicyj-xxc/zysicyj"
PB_REPO=""
REDISPATCH_SECS=5400
RATE_FLOOR=200

only=""
tmpdir=""
STOP_POLL=0
DISPATCH_OK=0
DISPATCH_RATE=0
FORCE_ERRORS=0
RATE_REMAINING=""
declare -gA PR_NUMBER=()

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

is_redispatchable() {
  local state="$1" desc="$2" updated="$3" now stamp
  case "$state" in
    error)
      case "$desc" in
        "dispatch failed"|rate-limited|"report rate-limited") return 0 ;;
      esac
      ;;
    pending)
      case "$desc" in
        queued|running|rate-limited) ;;
        *) return 1 ;;
      esac
      if ! printf '%s' "$updated" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
        return 1
      fi
      now=$(date -u +%s)
      stamp=$(date -u -d "$updated" +%s 2>/dev/null) || return 1
      if [ $((now - stamp)) -gt "$REDISPATCH_SECS" ]; then
        return 0
      fi
      ;;
  esac
  return 1
}

has_builder_status() {
  local file="$1" ctx state desc updated
  while IFS=$'\t' read -r ctx state desc updated || [ -n "${ctx:-}" ]; do
    [ -n "$ctx" ] || continue
    if is_builder_context "$ctx" && ! is_redispatchable "$state" "$desc" "$updated"; then
      return 0
    fi
  done <"$file"
  return 1
}

has_redispatch_gap() {
  local file="$1" ctx state desc updated
  while IFS=$'\t' read -r ctx state desc updated || [ -n "${ctx:-}" ]; do
    [ -n "$ctx" ] || continue
    if is_builder_context "$ctx" && is_redispatchable "$state" "$desc" "$updated"; then
      return 0
    fi
  done <"$file"
  return 1
}

http_code_of() {
  local file="$1" code
  code=$(awk '
    BEGIN { c = 0 }
    { sub(/\r/, "") }
    /^HTTP\// { c = $2 }
    END { if (c ~ /^[0-9]+$/) print c; else print 0 }
  ' "$file")
  if [ "$code" != "0" ]; then
    printf '%s' "$code"
    return 0
  fi
  code=$(grep -Eo '\(HTTP [0-9]{3}\)' "$file" 2>/dev/null | head -n 1 | grep -Eo '[0-9]{3}' || true)
  printf '%s' "${code:-0}"
}

header_remaining() {
  awk '
    BEGIN { IGNORECASE = 1 }
    {
      sub(/\r/, "")
      if (tolower($0) ~ /^x-ratelimit-remaining:/) {
        sub(/^[^:]+:[[:space:]]*/, "")
        print
        exit
      }
    }
  ' "$1"
}

post_status() {
  local sha="$1" state="$2" ctx="$3" desc="$4"
  GH_TOKEN="$GH_TOKEN" gh api --method POST "repos/${PRIVATE_REPO}/statuses/${sha}" \
    -f state="$state" \
    -f target_url="$RUN_URL" \
    -f description="$desc" \
    -f context="$ctx" >/dev/null
}

post_pending() {
  post_status "$1" pending "$2" queued
}

dispatch() {
  local wf="$1" body="$2" raw err rc code remain
  DISPATCH_OK=0
  DISPATCH_RATE=0
  raw=$(mktemp)
  err=$(mktemp)
  if GH_TOKEN="$DISPATCH_TOKEN" gh api -i --method POST \
    "repos/${PB_REPO}/actions/workflows/${wf}/dispatches" \
    --input - <<<"$body" >"$raw" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  code=$(http_code_of "$raw")
  if [ "$code" = "0" ]; then
    code=$(http_code_of "$err")
  fi
  remain=$(header_remaining "$raw" || true)
  rm -f "$raw" "$err"
  if printf '%s' "$remain" | grep -Eq '^[0-9]+$'; then
    RATE_REMAINING=$remain
  fi
  if [ "$rc" -eq 0 ] && { [ "$code" = "0" ] || { [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; }; }; then
    echo "PASS dispatch ${wf}"
    return 0
  fi
  DISPATCH_OK=1
  if [ "$code" = "403" ] || [ "$code" = "429" ]; then
    DISPATCH_RATE=1
    echo "FAIL poll rate-limited"
    return 0
  fi
  echo "FAIL dispatch ${wf}"
}

budget_low() {
  if [ -z "${RATE_REMAINING:-}" ]; then
    return 1
  fi
  [ "$RATE_REMAINING" -lt "$RATE_FLOOR" ]
}

dispatch_contexts() {
  local sha="$1" wf="$2" body="$3" ctx
  shift 3
  if [ "$STOP_POLL" -ne 0 ]; then
    return 0
  fi
  if budget_low; then
    STOP_POLL=1
    echo "FAIL poll rate-limited"
    return 0
  fi
  dispatch "$wf" "$body"
  if [ "$DISPATCH_RATE" -ne 0 ]; then
    STOP_POLL=1
    return 0
  fi
  if [ "$DISPATCH_OK" -ne 0 ]; then
    if [ "$#" -gt 0 ]; then
      mark_dispatch_failed "$sha" "$@"
    fi
    return 0
  fi
  for ctx in "$@"; do
    post_pending "$sha" "$ctx"
  done
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
    --jq '.[] | [.context, .state, (.description // ""), (.updated_at // .created_at // "")] | @tsv' \
    >"$out.raw" || true
  awk -F '\t' 'NF>=2 && !seen[$1]++ { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$out.raw" >"$out"
  rm -f "$out.raw"
}

state_of() {
  local file="$1" ctx="$2"
  awk -F '\t' -v c="$ctx" '$1==c { print $2; exit }' "$file"
}

missing() {
  local file="$1" ctx="$2" st desc updated
  IFS=$'\t' read -r st desc updated < <(awk -F '\t' -v c="$ctx" '
    $1 == c { print $2 "\t" $3 "\t" $4; exit }
  ' "$file")
  if [ -z "${st:-}" ]; then
    return 0
  fi
  if [ "${FORCE_ERRORS:-0}" -eq 1 ] && [ "$st" = "error" ]; then
    return 0
  fi
  if is_redispatchable "$st" "$desc" "$updated"; then
    return 0
  fi
  return 1
}

admin_relevant() {
  case "$1" in
    apps/admin-web/*|apps/web_shared/*|apps/shared_package/generated/*|.github/workflows/admin-web-gate.yml)
      return 0
      ;;
  esac
  return 1
}

admin_changed() {
  local sha="$1" path files count n hit
  files=$(mktemp)
  hit=0
  if [ -n "${PR_NUMBER[$sha]:-}" ]; then
    n="${PR_NUMBER[$sha]}"
    if ! GH_TOKEN="$GH_TOKEN" gh api --paginate \
      "repos/${PRIVATE_REPO}/pulls/${n}/files?per_page=100" \
      --jq '.[].filename' >"$files" 2>/dev/null; then
      rm -f "$files"
      return 0
    fi
  else
    if ! GH_TOKEN="$GH_TOKEN" gh api "repos/${PRIVATE_REPO}/commits/${sha}" \
      --jq '.files[]?.filename' >"$files" 2>/dev/null; then
      rm -f "$files"
      return 0
    fi
    count=$(grep -c . "$files" || true)
    if [ "${count:-0}" -ge 300 ]; then
      rm -f "$files"
      return 0
    fi
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if admin_relevant "$path"; then
      hit=1
      break
    fi
  done <"$files"
  rm -f "$files"
  [ "$hit" -eq 1 ]
}

load_tree() {
  local sha="$1" dest="$2" cached
  cached="$tmpdir/tree-${sha}"
  if [ -f "$cached" ]; then
    cp "$cached" "$dest"
    return 0
  fi
  if GH_TOKEN="$GH_TOKEN" gh api "repos/${PRIVATE_REPO}/git/trees/${sha}?recursive=1" >"$cached"; then
    cp "$cached" "$dest"
    return 0
  fi
  rm -f "$cached"
  return 1
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
  local states body_ref joined app i scope ctx s
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

  if [ "$STOP_POLL" -eq 0 ] && want quality; then
    local -a scopes=() qctx=()
    missing "$states" "quality/backend" && scopes+=(backend) && qctx+=("quality/backend")
    missing "$states" "quality/website" && scopes+=(website) && qctx+=("quality/website")
    missing "$states" "quality/flutter-analyze" && scopes+=(flutter) && qctx+=("quality/flutter-analyze")
    if [ "${#scopes[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${scopes[*]}")
      dispatch_contexts "$sha" quality-analyze.yml "${body_ref},\"scopes\":\"${joined}\"}}" "${qctx[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want flutter; then
    local -a need=() fctx=()
    for app in "${flutter_apps[@]}"; do
      ctx="flutter-test (${app})"
      if missing "$states" "$ctx"; then
        need+=("$app")
        fctx+=("$ctx")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch_contexts "$sha" flutter-test.yml "${body_ref},\"only\":\"${joined}\"}}" "${fctx[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want daymica; then
    need=()
    local -a dctx=()
    for i in 0 1 2 3 4 5 6 7; do
      ctx="flutter-test (daymica/${i})"
      if missing "$states" "$ctx"; then
        need+=("$i")
        dctx+=("$ctx")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch_contexts "$sha" daymica-test.yml "${body_ref},\"shards\":\"${joined}\"}}" "${dctx[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want ci-scripts; then
    if missing "$states" "ci-scripts"; then
      dispatch_contexts "$sha" ci-scripts.yml "${body_ref}}}" "ci-scripts"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want i18n; then
    need=()
    local -a ictx=()
    for app in "${i18n_apps[@]}"; do
      ctx="i18n-gate (${app})"
      if missing "$states" "$ctx"; then
        need+=("$app")
        ictx+=("$ctx")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch_contexts "$sha" i18n-gate.yml "${body_ref},\"apps\":\"${joined}\"}}" "${ictx[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want visual; then
    need=()
    local -a vctx=()
    for app in "${visual_apps[@]}"; do
      ctx="visual-lint (${app})"
      if missing "$states" "$ctx"; then
        need+=("$app")
        vctx+=("$ctx")
      fi
    done
    if missing "$states" "golden-tests (shared_package)"; then
      need+=(golden)
      vctx+=("golden-tests (shared_package)")
    fi
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch_contexts "$sha" visual-lint.yml "${body_ref},\"only\":\"${joined}\"}}" "${vctx[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want domain; then
    if missing "$states" "assert domain registry"; then
      dispatch_contexts "$sha" domain-gate.yml "${body_ref}}}" "assert domain registry"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want web; then
    need=()
    for scope in "${web_scopes[@]}"; do
      if missing "$states" "$scope"; then
        need+=("$scope")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch_contexts "$sha" web-visual.yml "${body_ref},\"scopes\":\"${joined}\"}}" "${need[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want utools; then
    need=()
    local -a uctx=()
    for scope in "${utools_scopes[@]}"; do
      ctx="${utools_ctx[$scope]}"
      if missing "$states" "$ctx"; then
        need+=("$scope")
        uctx+=("$ctx")
      fi
    done
    if [ "${#need[@]}" -gt 0 ]; then
      joined=$(IFS=,; printf '%s' "${need[*]}")
      dispatch_contexts "$sha" utools-visual.yml "${body_ref},\"scopes\":\"${joined}\"}}" "${uctx[@]}"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want gitleaks; then
    if missing "$states" "gitleaks"; then
      dispatch_contexts "$sha" gitleaks.yml "${body_ref}}}" "gitleaks"
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want admin-web; then
    if missing "$states" "validate-admin-web"; then
      if admin_changed "$sha"; then
        dispatch_contexts "$sha" admin-web-gate.yml "${body_ref}}}" "validate-admin-web"
      else
        post_status "$sha" success "validate-admin-web" "skipped: no admin-web changes"
      fi
    fi
  fi

  if [ "$STOP_POLL" -eq 0 ] && want scripts; then
    local tree="$tmpdir/${sha}.tree" ctxfile="$tmpdir/${sha}.ctx"
    if load_tree "$sha" "$tree" \
      && python3 .github/scripts/scripts_gate_run.py --contexts "$tree" "$ctxfile" >/dev/null; then
      local -a sctx=()
      while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        if missing "$states" "$ctx"; then
          sctx+=("$ctx")
        fi
      done <"$ctxfile"
      if [ "${#sctx[@]}" -gt 0 ]; then
        dispatch_contexts "$sha" scripts-gate.yml "${body_ref},\"force\":\"false\"}}" "${sctx[@]}"
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

  local -a pr_rows=()
  mapfile -t pr_rows < <(GH_TOKEN="$GH_TOKEN" gh api --paginate \
    "repos/${PRIVATE_REPO}/pulls?state=open&per_page=100" \
    --jq '.[] | [.number, .head.sha] | @tsv')

  PR_NUMBER=()
  local -A seen=()
  local -a prs=()
  local row n want_sha found
  local -a only_prs=()
  if [ "${#pr_rows[@]}" -gt 0 ]; then
    for row in "${pr_rows[@]}"; do
      [ -n "$row" ] || continue
      n=""
      s=""
      if [[ "$row" == *$'\t'* ]]; then
        n=${row%%$'\t'*}
        s=${row#*$'\t'}
      else
        s=$row
      fi
      s=$(printf '%s' "$s" | tr 'A-F' 'a-f' | tr -d '[:space:]')
      if ! printf '%s' "$s" | grep -Eq '^[0-9a-f]{40}$'; then
        continue
      fi
      if printf '%s' "$n" | grep -Eq '^[0-9]+$'; then
        PR_NUMBER[$s]=$n
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

  want_sha=$(printf '%s' "${SHA_INPUT:-}" | tr 'A-F' 'a-f' | tr -d '[:space:]')
  if [ -n "$want_sha" ] && ! printf '%s' "$want_sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "FAIL poll sha"
    exit 1
  fi
  case "${FORCE:-false}" in
    true|True|TRUE) FORCE_ERRORS=1 ;;
    false|False|FALSE|"") FORCE_ERRORS=0 ;;
    *) echo "FAIL poll force"; exit 1 ;;
  esac
  if [ "$FORCE_ERRORS" -eq 1 ] && [ -z "$want_sha" ]; then
    echo "FAIL poll force"
    exit 1
  fi
  if [ -n "$want_sha" ]; then
    if [ "$want_sha" = "$main_sha" ]; then
      prs=()
    else
      found=0
      only_prs=()
      for s in "${prs[@]+"${prs[@]}"}"; do
        if [ "$s" = "$want_sha" ]; then
          only_prs+=("$s")
          found=1
        fi
      done
      if [ "$found" -ne 1 ]; then
        echo "FAIL poll sha"
        exit 1
      fi
      prs=("${only_prs[@]}")
    fi
  fi

  cleanup_poll
  tmpdir=$(mktemp -d)
  STOP_POLL=0
  RATE_REMAINING=""
  local head_states="$tmpdir/head.tsv" skip=0 total active rem need
  latest_states "$main_sha" "$head_states"
  if [ -n "$want_sha" ] && [ "$want_sha" != "$main_sha" ]; then
    skip=1
  elif [ "$FORCE_ERRORS" -ne 1 ] && has_builder_status "$head_states" \
    && ! has_redispatch_gap "$head_states"; then
    skip=1
  fi
  if [ -n "$want_sha" ]; then
    total=1
  else
    total=$(( ${#prs[@]} + 1 ))
  fi
  echo "PASS poll shas=${total}"
  echo "PASS poll skip=${skip}"

  active=${#prs[@]}
  if [ "$skip" -eq 0 ]; then
    active=$((active + 1))
  fi
  if [ "$active" -gt 0 ]; then
    rem=$(GH_TOKEN="$DISPATCH_TOKEN" gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || true)
    if printf '%s' "$rem" | grep -Eq '^[0-9]+$'; then
      RATE_REMAINING=$rem
      need=$((12 * active + 200))
      if [ "$RATE_REMAINING" -lt "$need" ]; then
        echo "FAIL poll rate-limited"
        cleanup_poll
        exit 0
      fi
    fi
  fi

  if [ "$skip" -eq 0 ]; then
    poll_one "$main_sha"
  fi
  if [ "$STOP_POLL" -eq 0 ] && [ "${#prs[@]}" -gt 0 ]; then
    for s in "${prs[@]}"; do
      if [ "$STOP_POLL" -ne 0 ]; then
        break
      fi
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
  if ! grep -Fq 'Must be an open PR head or main' "$wf" \
    || ! grep -Fq 'redispatch missing and error contexts' "$wf"; then
    echo "FAIL selftest-input"
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
  export SHA_INPUT=''
  export FORCE=false
  local HEAD PR
  HEAD='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  PR='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

  prepare() {
    TEST_DIR=$(mktemp -d)
    export FAKE_LOG="$TEST_DIR/log"
    export FAKE_STATUSES="$TEST_DIR/statuses"
    export SHA_INPUT=''
    export FORCE=false
    export FAKE_DISPATCH_HTTP=200
    export FAKE_RATE_REMAINING=5000
    unset FAKE_RATE_HEADER || true
    unset FAKE_COMMIT_FILE || true
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
desc=""
verbose=0
prev=""
for a in "$@"; do
  if [ "$a" = "-i" ]; then
    verbose=1
  elif [ "$prev" = "--method" ]; then
    method=$a
  elif [ "$prev" = "-f" ]; then
    case "$a" in
      context=*) context=${a#context=} ;;
      state=*) state=${a#state=} ;;
      description=*) desc=${a#description=} ;;
    esac
  elif [ "$a" = "rate_limit" ]; then
    url=$a
  elif [[ "$a" == repos/* ]]; then
    url=$a
  fi
  prev=$a
done
if [ "$url" = "rate_limit" ]; then
  printf '%s\n' "${FAKE_RATE_REMAINING:-5000}"
  exit 0
fi
if [ "$method" = POST ] && [[ "$url" == *"/dispatches" ]]; then
  body=$(cat)
  wf=$(printf '%s' "$url" | sed -n 's|.*/workflows/\([^/]*\)/dispatches|\1|p')
  printf 'dispatch\t%s\t%s\n' "$wf" "$body" >>"$log"
  code="${FAKE_DISPATCH_HTTP:-200}"
  if [ "$code" != "200" ]; then
    echo "gh: request failed (HTTP ${code})" >&2
    exit 1
  fi
  if [ "$verbose" = 1 ] && [ -n "${FAKE_RATE_HEADER:-}" ]; then
    printf 'HTTP/2.0 204 No Content\nX-RateLimit-Remaining: %s\n\n' "$FAKE_RATE_HEADER"
  fi
  exit 0
fi
if [ "$method" = POST ] && [[ "$url" == *"/statuses/"* ]]; then
  sha=${url##*/}
  printf 'status\t%s\t%s\t%s\t%s\n' "$sha" "$context" "$state" "$desc" >>"$log"
  exit 0
fi
if [[ "$url" == *"/commits/"*"/statuses?"* ]]; then
  sha=$(printf '%s' "$url" | sed -n 's|.*/commits/\([0-9a-fA-F]\{40\}\)/statuses.*|\1|p')
  sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
  if [ -f "${FAKE_STATUSES:?}" ]; then
    awk -F '\t' -v s="$sha" '$1==s { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$FAKE_STATUSES"
  fi
  exit 0
fi
if [[ "$url" == *"/commits/main" ]]; then
  printf '%s' "${FAKE_MAIN_SHA-}"
  exit 0
fi
if [[ "$url" == *"/commits/"* ]]; then
  if [ -n "${FAKE_COMMIT_FILE:-}" ]; then
    cat "$FAKE_COMMIT_FILE"
  else
    printf '%s\n' 'apps/admin-web/src/App.tsx'
  fi
  exit 0
fi
if [[ "$url" == *"/pulls/"*"/files"* ]]; then
  if [ -n "${FAKE_COMMIT_FILE:-}" ]; then
    cat "$FAKE_COMMIT_FILE"
  else
    printf '%s\n' 'apps/admin-web/src/App.tsx'
  fi
  exit 0
fi
if [[ "$url" == *"/pulls?"* ]]; then
  if [ -n "${FAKE_PR_SHAS:-}" ]; then
    printf '%s\n' "$FAKE_PR_SHAS"
  fi
  exit 0
fi
if [[ "$url" == *"/git/trees/"* ]]; then
  printf 'tree\t%s\n' "$url" >>"$log"
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
      # shellcheck disable=SC2030
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
  awk -F '\t' '$1=="status" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" }' "$FAKE_LOG" >"$replay"

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
  printf '%s\t%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'error' 'failure' >"$FAKE_STATUSES"
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

  if admin_relevant 'apps/admin-web/src/App.tsx' \
    && admin_relevant 'apps/web_shared/src/a.ts' \
    && admin_relevant 'apps/shared_package/generated/a.dart' \
    && admin_relevant '.github/workflows/admin-web-gate.yml' \
    && ! admin_relevant 'apps/daymica/lib/main.dart' \
    && ! admin_relevant 'README.md'; then
    :
  else
    echo "FAIL selftest-admin-path"
    exit 1
  fi

  # error "dispatch failed" is missing and is dispatched again.
  prepare
  printf '%s\t%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'error' 'dispatch failed' >"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='ci-scripts' PR_USED=''
  execute
  check_quiet error-redispatch
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 1 ] \
    || [ "$(awk -F '\t' '$1=="status" && $4=="error" { n++ } END { print n+0 }' "$FAKE_LOG")" != 0 ]; then
    echo "FAIL selftest-error-redispatch"
    exit 1
  fi

  prepare
  printf '%s\t%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'error' 'report rate-limited' >"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='ci-scripts' PR_USED=''
  execute
  check_quiet report-redispatch
  if [ "$TEST_RC" -ne 0 ] || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 1 ]; then
    echo "FAIL selftest-report-redispatch"
    exit 1
  fi

  # A pending marker older than 90 minutes is dispatched again.
  prepare
  old=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\t%s\t%s\n' "$HEAD" 'quality/backend' 'success' 'success' "$old" >"$FAKE_STATUSES"
  printf '%s\t%s\t%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'pending' 'queued' "$old" >>"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='ci-scripts' PR_USED=''
  execute
  check_quiet pending-expired
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=0' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-pending-expired"
    exit 1
  fi

  prepare
  fresh=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'pending' 'running' "$fresh" >"$FAKE_STATUSES"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='ci-scripts' PR_USED=''
  execute
  check_quiet pending-fresh
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll skip=1' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-pending-fresh"
    exit 1
  fi

  # 403 writes no error status and does not dispatch the next head.
  prepare
  export FAKE_DISPATCH_HTTP=403
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS="$PR" ONLY='ci-scripts' PR_USED=1
  execute
  check_quiet dispatch-rate
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'FAIL poll rate-limited' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count ci-scripts.yml "$PR")" != 0 ] \
    || [ "$(status_count "$HEAD")" != 0 ] \
    || [ "$(status_count "$PR")" != 0 ]; then
    echo "FAIL selftest-dispatch-rate"
    exit 1
  fi

  # Other dispatch failures still record error and the round continues.
  prepare
  export FAKE_DISPATCH_HTTP=500
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS="$PR" ONLY='ci-scripts' PR_USED=1
  execute
  check_quiet dispatch-error
  if [ "$TEST_RC" -ne 0 ] || grep -Fxq 'FAIL poll rate-limited' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count ci-scripts.yml "$PR")" != 1 ] \
    || [ "$(awk -F '\t' -v s="$HEAD" '$1=="status" && $2==s && $3=="ci-scripts" && $4=="error" && $5=="dispatch failed" { n++ } END { print n+0 }' "$FAKE_LOG")" != 1 ]; then
    echo "FAIL selftest-dispatch-error"
    exit 1
  fi

  prepare
  export FAKE_RATE_REMAINING=10
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet poll-budget
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'FAIL poll rate-limited' "$TEST_OUT" \
    || [ "$(awk -F '\t' '$1=="dispatch" { n++ } END { print n+0 }' "$FAKE_LOG")" != 0 ]; then
    echo "FAIL selftest-poll-budget"
    exit 1
  fi

  prepare
  export FAKE_RATE_HEADER=10
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet poll-header
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'FAIL poll rate-limited' "$TEST_OUT" \
    || [ "$(awk -F '\t' '$1=="dispatch" { n++ } END { print n+0 }' "$FAKE_LOG")" != 1 ] \
    || [ "$(dispatch_count quality-analyze.yml "$HEAD")" != 1 ] \
    || [ "$(dispatch_count flutter-test.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-poll-header"
    exit 1
  fi

  prepare
  printf '%s\n' 'README.md' >"$TEST_DIR/files"
  export FAKE_COMMIT_FILE="$TEST_DIR/files"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='admin-web' PR_USED=''
  execute
  check_quiet admin-skip
  if [ "$TEST_RC" -ne 0 ] || [ "$(dispatch_count admin-web-gate.yml "$HEAD")" != 0 ] \
    || [ "$(awk -F '\t' -v s="$HEAD" '$1=="status" && $2==s && $3=="validate-admin-web" && $4=="success" && $5=="skipped: no admin-web changes" { n++ } END { print n+0 }' "$FAKE_LOG")" != 1 ]; then
    echo "FAIL selftest-admin-skip"
    exit 1
  fi

  prepare
  export SHA_INPUT='cccccccccccccccccccccccccccccccccccccccc' FORCE=false
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet bad-sha
  if [ "$TEST_RC" -eq 0 ] || ! grep -Fxq 'FAIL poll sha' "$TEST_OUT"; then
    echo "FAIL selftest-bad-sha"
    exit 1
  fi

  prepare
  export FORCE=true SHA_INPUT=''
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  execute
  check_quiet force-need-sha
  if [ "$TEST_RC" -eq 0 ] || ! grep -Fxq 'FAIL poll force' "$TEST_OUT"; then
    echo "FAIL selftest-force-need-sha"
    exit 1
  fi

  prepare
  printf '%s\t%s\t%s\t%s\n' "$HEAD" 'ci-scripts' 'error' 'tests failed' >"$FAKE_STATUSES"
  export SHA_INPUT="$HEAD" FORCE=true
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='ci-scripts' PR_USED=''
  execute
  check_quiet force-error
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll shas=1' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 1 ]; then
    echo "FAIL selftest-force-error"
    exit 1
  fi

  prepare
  export SHA_INPUT="$PR"
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS="$PR" ONLY='ci-scripts' PR_USED=1
  execute
  check_quiet sha-pr
  if [ "$TEST_RC" -ne 0 ] || ! grep -Fxq 'PASS poll shas=1' "$TEST_OUT" \
    || [ "$(dispatch_count ci-scripts.yml "$PR")" != 1 ] \
    || [ "$(dispatch_count ci-scripts.yml "$HEAD")" != 0 ]; then
    echo "FAIL selftest-sha-pr"
    exit 1
  fi

  prepare
  export FAKE_MAIN_SHA="$HEAD" FAKE_PR_SHAS='' ONLY='' PR_USED=''
  # shellcheck disable=SC2031
  old_path=$PATH
  # shellcheck disable=SC2031
  PATH="$TEST_DIR:$PATH"
  tmpdir=$(mktemp -d)
  load_tree "$HEAD" "$tmpdir/a"
  load_tree "$HEAD" "$tmpdir/b"
  rm -rf "$tmpdir"
  tmpdir=""
  PATH=$old_path
  if [ "$(awk -F '\t' '$1=="tree" { n++ } END { print n+0 }' "$FAKE_LOG")" != 1 ]; then
    echo "FAIL selftest-tree-cache"
    exit 1
  fi

  echo "PASS selftest"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_poll
