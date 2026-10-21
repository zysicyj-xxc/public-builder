#!/usr/bin/env bash
# Install deps and run one uTools plugin's test script.
# The private utools-test workflow runs `pnpm test`. Hosted runners were
# exiting before that: package.json exists, but neither utools/<plugin> nor
# utools/ has pnpm-lock.yaml (run 39034368984).
# Search order: plugin pnpm-lock, utools pnpm-lock, plugin package-lock,
# repo pnpm-lock. With no lockfile, install that plugin from package.json
# and still run the test. Summary lines stay free of paths.
# Before install, private CNB npm tarball URLs in the working-copy lockfiles
# are rewritten to https://registry.npmjs.org/. The rewrite is not committed
# and raw URLs are not logged.
# A package.json with no scripts.test prints SKIP and exits 0. A test script
# that fails is still FAIL, including when the log mentions Missing script.
set -euo pipefail

classify() {
  local log="$1"
  if grep -Eq 'Cannot find module|ERR_MODULE_NOT_FOUND|MODULE_NOT_FOUND' "$log"; then
    echo missing-module
  elif grep -Eq 'utools is not defined' "$log"; then
    echo no-utools
  elif grep -Eq 'cannot open display|Missing X server' "$log"; then
    echo no-display
  elif grep -Eq 'npm error code E40[13]|ERR_PNPM_FETCH_40[13]' "$log"; then
    echo registry-auth
  elif grep -Eq 'ECONNREFUSED|ENOTFOUND|getaddrinfo' "$log"; then
    echo external
  elif grep -Eq 'coverage threshold|below threshold' "$log"; then
    echo coverage
  elif grep -Eq 'Missing script' "$log"; then
    echo no-test-script
  elif grep -Eq 'ERR_PNPM_|npm ERR!|npm error' "$log"; then
    echo install
  else
    echo failed
  fi
}

capture() {
  local log rc reason
  log=$(mktemp)
  set +e
  bash -c "$1" >"$log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    reason=$(classify "$log")
    echo "FAIL test ${reason}"
    rm -f "$log"
    exit "$rc"
  fi
  rm -f "$log"
  echo "PASS test"
}

bit() {
  if [ -f "$1" ]; then
    echo 1
  else
    echo 0
  fi
}

# Exit 0 when scripts.test is a non-empty string, 1 when it is absent, 2 when
# package.json cannot be parsed. Prints nothing.
has_test_script() {
  node -e 'const fs=require("fs"); let pkg; try { pkg=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch (e) { process.exit(2); } const scripts=pkg&&pkg.scripts; const test=scripts&&Object.prototype.hasOwnProperty.call(scripts,"test")?scripts.test:undefined; if (typeof test==="string" && test.length>0) process.exit(0); process.exit(1);' "$1" 2>/dev/null
}

# Working copy only. Do not commit rewritten lockfiles. Prints the count.
rewrite_registries() {
  local plugin_dir="$1"
  local total
  total=$(node -e 'const fs=require("fs"); const re=/https:\/\/npm\.cnb\.cool\/[^/]+\/[^/]+\/-\/packages\//g; let n=0; for (const file of process.argv.slice(1)) { if (!fs.existsSync(file)) continue; const text=fs.readFileSync(file,"utf8"); const found=text.match(re); if (!found) continue; n+=found.length; fs.writeFileSync(file, text.replace(re, "https://registry.npmjs.org/")); } process.stdout.write(String(n));' \
    "${plugin_dir}/package-lock.json" \
    "${plugin_dir}/pnpm-lock.yaml" \
    "utools/package-lock.json" \
    "utools/pnpm-lock.yaml" \
    "package-lock.json" \
    "pnpm-lock.yaml")
  if ! printf '%s' "$total" | grep -Eq '^[0-9]+$'; then
    echo "FAIL package"
    exit 1
  fi
  echo "PASS registry rewrite n=${total}"
}

run_plugin() {
  local plugin dir qdir script_rc
  plugin="${1:?plugin required}"
  case "$plugin" in
    easy-script|bookmark-collector|blog-sync|daymica-capture) ;;
    *)
      echo "FAIL plugin"
      exit 1
      ;;
  esac
  dir="utools/${plugin}"
  if [ ! -f "${dir}/package.json" ]; then
    echo "FAIL package"
    exit 1
  fi
  script_rc=0
  has_test_script "${dir}/package.json" || script_rc=$?
  case "$script_rc" in
    0) ;;
    1)
      echo "SKIP test no-script"
      exit 0
      ;;
    *)
      echo "FAIL package"
      exit 1
      ;;
  esac
  corepack enable
  echo "PASS locks p=$(bit "${dir}/pnpm-lock.yaml") u=$(bit utools/pnpm-lock.yaml) r=$(bit pnpm-lock.yaml) n=$(bit "${dir}/package-lock.json") y=$(bit "${dir}/yarn.lock") w=$(bit pnpm-workspace.yaml) uw=$(bit utools/pnpm-workspace.yaml)"
  rewrite_registries "$dir"
  qdir=$(printf '%q' "$dir")
  if [ -f "${dir}/pnpm-lock.yaml" ]; then
    echo "PASS install plugin-lock"
    capture "cd ${qdir} && pnpm install --frozen-lockfile && pnpm test"
  elif [ -f utools/pnpm-lock.yaml ]; then
    echo "PASS install utools-lock"
    capture "pnpm install --frozen-lockfile --dir utools && pnpm --dir ${qdir} test"
  elif [ -f "${dir}/package-lock.json" ]; then
    echo "PASS install npm-lock"
    capture "npm ci --prefix ${qdir} && npm test --prefix ${qdir}"
  elif [ -f "${dir}/yarn.lock" ]; then
    echo "FAIL install yarn"
    exit 1
  elif [ -f pnpm-lock.yaml ]; then
    echo "PASS install root-lock"
    if [ -f pnpm-workspace.yaml ]; then
      capture "pnpm install --frozen-lockfile --filter ./${dir}... && pnpm --dir ${qdir} test"
    else
      capture "pnpm install --frozen-lockfile && pnpm --dir ${qdir} test"
    fi
  elif [ -f utools/pnpm-workspace.yaml ]; then
    echo "PASS install utools-workspace"
    capture "pnpm install --dir utools --filter ./${dir}... && pnpm --dir ${qdir} test"
  elif [ -f pnpm-workspace.yaml ]; then
    echo "PASS install root-workspace"
    capture "pnpm install --filter ./${dir}... && pnpm --dir ${qdir} test"
  else
    echo "PASS install unlocked"
    capture "cd ${qdir} && pnpm install --ignore-workspace && pnpm test"
  fi
}

selftest() {
  local root fake bin log
  root=$(mktemp -d)
  fake=$(mktemp -d)
  trap 'rm -rf "'"$root"'" "'"$fake"'"' EXIT
  cat >"$fake/corepack" <<'EOF'
#!/bin/sh
echo "corepack $*" >> "${GATE_FAKE_LOG:?}"
exit 0
EOF
  cat >"$fake/pnpm" <<'EOF'
#!/bin/sh
echo "pnpm $* cwd=$(pwd)" >> "${GATE_FAKE_LOG:?}"
rc="${GATE_FAKE_PNPM_RC:-0}"
msg="${GATE_FAKE_PNPM_MSG:-}"
if [ -n "${GATE_FAKE_DIR:-}" ] && [ -f "${GATE_FAKE_DIR}/rc" ]; then
  rc=$(cat "${GATE_FAKE_DIR}/rc")
fi
if [ -n "${GATE_FAKE_DIR:-}" ] && [ -f "${GATE_FAKE_DIR}/msg" ]; then
  msg=$(cat "${GATE_FAKE_DIR}/msg")
fi
if [ "$rc" != 0 ]; then
  if [ -n "$msg" ]; then
    printf '%s\n' "$msg" >&2
  else
    echo "Cannot find module 'vitest'" >&2
  fi
  exit "$rc"
fi
exit 0
EOF
  cat >"$fake/npm" <<'EOF'
#!/bin/sh
echo "npm $* cwd=$(pwd)" >> "${GATE_FAKE_LOG:?}"
exit 0
EOF
  chmod +x "$fake/corepack" "$fake/pnpm" "$fake/npm"

  run_case() {
    local name="$1" plugin="$2" expect_rc="$3"
    shift 3
    log="$root/${name}.log"
    : >"$log"
    set +e
    (
      cd "$root/$name"
      export PATH="$fake:$PATH"
      export GATE_FAKE_LOG="$log"
      export PLUGIN="$plugin"
      bash "$self" >"$root/${name}.out" 2>&1
    )
    local rc=$?
    set -e
    if [ "$rc" -ne "$expect_rc" ]; then
      echo "selftest ${name} rc=${rc}" >&2
      cat "$root/${name}.out" >&2
      exit 1
    fi
    while [ "$#" -gt 0 ]; do
      if ! cat "$root/${name}.out" "$log" | grep -F -q -- "$1"; then
        echo "selftest ${name} missing $1" >&2
        cat "$root/${name}.out" "$log" >&2
        exit 1
      fi
      shift
    done
  }

  case "$0" in
    /*) self=$0 ;;
    *) self="$(pwd)/$0" ;;
  esac
  export GATE_FAKE_DIR="$fake"
  mkdir -p "$root/plugin-lock/utools/easy-script"
  printf '%s\n' '{"name":"easy-script","scripts":{"test":"node -e process.exit(0)"}}' >"$root/plugin-lock/utools/easy-script/package.json"
  : >"$root/plugin-lock/utools/easy-script/pnpm-lock.yaml"
  run_case plugin-lock easy-script 0 "PASS registry rewrite n=0" "PASS install plugin-lock" "PASS test" "pnpm install --frozen-lockfile cwd=${root}/plugin-lock/utools/easy-script" "corepack enable"

  mkdir -p "$root/utools-lock/utools/bookmark-collector"
  printf '%s\n' '{"name":"bookmark-collector","scripts":{"test":"node -e process.exit(0)"}}' >"$root/utools-lock/utools/bookmark-collector/package.json"
  : >"$root/utools-lock/utools/pnpm-lock.yaml"
  run_case utools-lock bookmark-collector 0 "PASS install utools-lock" "pnpm install --frozen-lockfile --dir utools cwd=${root}/utools-lock" "pnpm --dir utools/bookmark-collector test cwd=${root}/utools-lock"

  mkdir -p "$root/npm-lock/utools/blog-sync"
  printf '%s\n' '{"name":"blog-sync","scripts":{"test":"node -e process.exit(0)"}}' >"$root/npm-lock/utools/blog-sync/package.json"
  : >"$root/npm-lock/utools/blog-sync/package-lock.json"
  run_case npm-lock blog-sync 0 "PASS registry rewrite n=0" "PASS install npm-lock" "npm ci --prefix utools/blog-sync" "npm test --prefix utools/blog-sync"
  if grep -q 'pnpm install' "$root/npm-lock.log"; then
    echo "selftest npm-lock used pnpm install" >&2
    exit 1
  fi

  mkdir -p "$root/root-lock/utools/daymica-capture"
  printf '%s\n' '{"name":"daymica-capture","scripts":{"test":"node -e process.exit(0)"}}' >"$root/root-lock/utools/daymica-capture/package.json"
  printf '%s\n' 'packages:' '  - utools/*' >"$root/root-lock/pnpm-workspace.yaml"
  : >"$root/root-lock/pnpm-lock.yaml"
  run_case root-lock daymica-capture 0 "PASS install root-lock" "pnpm install --frozen-lockfile --filter ./utools/daymica-capture..."

  mkdir -p "$root/unlocked/utools/easy-script"
  printf '%s\n' '{"name":"easy-script","scripts":{"test":"node -e process.exit(0)"}}' >"$root/unlocked/utools/easy-script/package.json"
  run_case unlocked easy-script 0 "PASS locks p=0 u=0 r=0 n=0 y=0 w=0 uw=0" "PASS install unlocked" "pnpm install --ignore-workspace cwd=${root}/unlocked/utools/easy-script"

  mkdir -p "$root/yarn-only/utools/easy-script"
  printf '%s\n' '{"name":"easy-script","scripts":{"test":"node -e process.exit(0)"}}' >"$root/yarn-only/utools/easy-script/package.json"
  : >"$root/yarn-only/utools/easy-script/yarn.lock"
  run_case yarn-only easy-script 1 "FAIL install yarn"

  mkdir -p "$root/missing/utools"
  run_case missing easy-script 1 "FAIL package"

  mkdir -p "$root/bad/utools/other"
  printf '%s\n' '{"name":"other"}' >"$root/bad/utools/other/package.json"
  run_case bad other 1 "FAIL plugin"

  mkdir -p "$root/broken/utools/easy-script"
  printf '%s\n' '{"name":"easy-script","scripts":{"test":"node -e process.exit(1)"}}' >"$root/broken/utools/easy-script/package.json"
  log="$root/broken.log"
  : >"$log"
  set +e
  (
    cd "$root/broken"
    export PATH="$fake:$PATH"
    export GATE_FAKE_LOG="$log"
    export GATE_FAKE_PNPM_RC=7
    export PLUGIN=easy-script
    bash "$self" >"$root/broken.out" 2>&1
  )
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "selftest broken expected failure" >&2
    exit 1
  fi
  if ! grep -q 'FAIL test missing-module' "$root/broken.out"; then
    echo "selftest broken summary mismatch" >&2
    cat "$root/broken.out" >&2
    exit 1
  fi
  if grep -q 'SKIP test' "$root/broken.out"; then
    echo "selftest broken became skip" >&2
    exit 1
  fi

  plant_cnb() {
    local file="$1"
    shift
    local name
    mkdir -p "$(dirname "$file")"
    : >"$file"
    for name in "$@"; do
      printf 'https://npm.cnb.cool/org/repo/-/packages/%s/-/%s-1.0.0.tgz\n' "$name" "$name" >>"$file"
    done
  }
  assert_rewritten() {
    local file="$1"
    shift
    local name
    if grep -q 'npm.cnb.cool' "$file"; then
      echo "selftest cnb host remains" >&2
      exit 1
    fi
    for name in "$@"; do
      if ! grep -q "https://registry.npmjs.org/${name}/-/${name}-1.0.0.tgz" "$file"; then
        echo "selftest public tarball missing" >&2
        exit 1
      fi
    done
  }

  mkdir -p "$root/cnb-rewrite/utools/easy-script"
  printf '%s\n' '{"name":"easy-script","scripts":{"test":"node -e process.exit(0)"}}' >"$root/cnb-rewrite/utools/easy-script/package.json"
  plant_cnb "$root/cnb-rewrite/utools/easy-script/package-lock.json" alpha beta
  printf 'https://registry.npmjs.org/keeper/-/keeper-1.0.0.tgz\n' >>"$root/cnb-rewrite/utools/easy-script/package-lock.json"
  plant_cnb "$root/cnb-rewrite/utools/easy-script/pnpm-lock.yaml" gamma
  plant_cnb "$root/cnb-rewrite/utools/package-lock.json" delta
  plant_cnb "$root/cnb-rewrite/utools/pnpm-lock.yaml" epsilon
  plant_cnb "$root/cnb-rewrite/package-lock.json" zeta
  plant_cnb "$root/cnb-rewrite/pnpm-lock.yaml" eta
  run_case cnb-rewrite easy-script 0 "PASS registry rewrite n=7" "PASS install plugin-lock" "PASS test"
  assert_rewritten "$root/cnb-rewrite/utools/easy-script/package-lock.json" alpha beta
  if ! grep -q 'https://registry.npmjs.org/keeper/-/keeper-1.0.0.tgz' "$root/cnb-rewrite/utools/easy-script/package-lock.json"; then
    echo "selftest keeper tarball missing" >&2
    exit 1
  fi
  assert_rewritten "$root/cnb-rewrite/utools/easy-script/pnpm-lock.yaml" gamma
  assert_rewritten "$root/cnb-rewrite/utools/package-lock.json" delta
  assert_rewritten "$root/cnb-rewrite/utools/pnpm-lock.yaml" epsilon
  assert_rewritten "$root/cnb-rewrite/package-lock.json" zeta
  assert_rewritten "$root/cnb-rewrite/pnpm-lock.yaml" eta
  if grep -q 'npm.cnb.cool' "$root/cnb-rewrite.out" "$root/cnb-rewrite.log"; then
    echo "selftest cnb host in output" >&2
    exit 1
  fi

  mkdir -p "$root/no-script/utools/daymica-capture"
  printf '%s\n' '{"name":"daymica-capture","scripts":{"build":"node -e process.exit(0)"}}' >"$root/no-script/utools/daymica-capture/package.json"
  plant_cnb "$root/no-script/utools/daymica-capture/package-lock.json" untouched
  run_case no-script daymica-capture 0 "SKIP test no-script"
  if grep -q 'PASS test' "$root/no-script.out"; then
    echo "selftest no-script counted as pass" >&2
    exit 1
  fi
  if [ -s "$root/no-script.log" ]; then
    echo "selftest no-script invoked tools" >&2
    exit 1
  fi
  if grep -q 'npm.cnb.cool' "$root/no-script.out"; then
    echo "selftest no-script leaked registry host" >&2
    exit 1
  fi
  if ! grep -q 'npm.cnb.cool' "$root/no-script/utools/daymica-capture/package-lock.json"; then
    echo "selftest no-script rewrote lockfile" >&2
    exit 1
  fi

  fail_with() {
    local name="$1" msg="$2" expect="$3"
    mkdir -p "$root/${name}/utools/easy-script"
    printf '%s\n' '{"name":"easy-script","scripts":{"test":"vitest run"}}' >"$root/${name}/utools/easy-script/package.json"
    printf '%s\n' 1 >"$fake/rc"
    printf '%s\n' "$msg" >"$fake/msg"
    run_case "$name" easy-script 1 "$expect" "PASS registry rewrite n=0"
    rm -f "$fake/rc" "$fake/msg"
    if grep -q 'SKIP test' "$root/${name}.out"; then
      echo "selftest ${name} became skip" >&2
      exit 1
    fi
  }
  fail_with script-fail 'Error: assertion failed' "FAIL test failed"
  fail_with missing-script 'npm error Missing script: "test"' "FAIL test no-test-script"
  fail_with registry-auth 'npm error code E401' "FAIL test registry-auth"
  fail_with registry-auth-pnpm 'ERR_PNPM_FETCH_403' "FAIL test registry-auth"
  fail_with npm-error 'npm error code E404' "FAIL test install"

  echo "utools gate selftest ok"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_plugin "${PLUGIN:?PLUGIN empty}"
