#!/usr/bin/env bash
# List open PR head SHAs plus main, and dispatch a public-builder gate when
# its commit status is missing. Does not print branch names, titles, or paths.
set -euo pipefail

if [ "${1:-}" = "--selftest" ]; then
  echo "poll-gates selftest ok"
  exit 0
fi

PRIVATE_REPO="zysicyj-xxc/zysicyj"
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
  ""|quality|flutter|daymica|ci-scripts|i18n|visual|domain|scripts|web|utools) ;;
  *) echo "FAIL poll only"; exit 1 ;;
esac
want() {
  [ -z "$only" ] || [ "$only" = "$1" ]
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

main_sha=$(GH_TOKEN="$GH_TOKEN" gh api "repos/${PRIVATE_REPO}/commits/main" --jq .sha)
main_sha=$(printf '%s' "$main_sha" | tr 'A-F' 'a-f' | tr -d '[:space:]')
if ! printf '%s' "$main_sha" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "FAIL poll main"
  exit 1
fi

mapfile -t pr_shas < <(GH_TOKEN="$GH_TOKEN" gh api --paginate \
  "repos/${PRIVATE_REPO}/pulls?state=open&per_page=100" --jq '.[].head.sha')

declare -A seen=()
shas=()
for s in "$main_sha" "${pr_shas[@]}"; do
  s=$(printf '%s' "$s" | tr 'A-F' 'a-f' | tr -d '[:space:]')
  if ! printf '%s' "$s" | grep -Eq '^[0-9a-f]{40}$'; then
    continue
  fi
  if [ -z "${seen[$s]:-}" ]; then
    seen[$s]=1
    shas+=("$s")
  fi
done
echo "PASS poll shas=${#shas[@]}"

flutter_apps=(mail-box shared_package footprint eye-care admin-app water-tracker)
i18n_apps=(daymica mail-box password-vault yaoxiaobai eye-care footprint water-tracker admin-app shared_package)
visual_apps=(mail-box password-vault eye-care footprint yaoxiaobai daymica water-tracker)
web_scopes=(tokens web-shared website)
utools_scopes=(export-diff easy-script bookmark-collector blog-sync daymica-capture)
declare -A utools_ctx=(
  [export-diff]="export-diff"
  [easy-script]="gate (easy-script)"
  [bookmark-collector]="gate (bookmark-collector)"
  [blog-sync]="gate (blog-sync)"
  [daymica-capture]="gate (daymica-capture)"
)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

for sha in "${shas[@]}"; do
  states="$tmpdir/$sha.tsv"
  latest_states "$sha" "$states"
  body_ref=$(printf '{"ref":"%s","inputs":{"ref":"%s","sha":"%s"' "$DISPATCH_REF" "$sha" "$sha")

  if want quality; then
    scopes=()
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
        qctx=()
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
    need=()
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
        fctx=()
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
        dctx=()
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
        ictx=()
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
        vctx=()
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
        uctx=()
        for scope in "${need[@]}"; do
          uctx+=("${utools_ctx[$scope]}")
        done
        mark_dispatch_failed "$sha" "${uctx[@]}"
      fi
    fi
  fi

  if want scripts; then
    tree="$tmpdir/tree.json"
    ctxfile="$tmpdir/contexts.txt"
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
          sctx=()
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
done
