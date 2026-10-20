#!/usr/bin/env bash
# Install deps and run one uTools plugin's test script.
# The private utools-test workflow runs `pnpm test`. Hosted runners were
# exiting before that: package.json exists, but neither utools/<plugin> nor
# utools/ has pnpm-lock.yaml (run 39034368984).
# Search order: plugin pnpm-lock, utools pnpm-lock, plugin package-lock,
# repo pnpm-lock. With no lockfile, install that plugin from package.json
# and still run the test. Summary lines stay free of paths.
set -euo pipefail

classify() {
  local log="$1"
  if grep -Eq 'Cannot find module|ERR_MODULE_NOT_FOUND|MODULE_NOT_FOUND' "$log"; then
    echo missing-module
  elif grep -Eq 'utools is not defined' "$log"; then
    echo no-utools
  elif grep -Eq 'cannot open display|Missing X server' "$log"; then
    echo no-display
  elif grep -Eq 'ECONNREFUSED|ENOTFOUND|getaddrinfo' "$log"; then
    echo external
  elif grep -Eq 'coverage threshold|below threshold' "$log"; then
    echo coverage
  elif grep -Eq 'ERR_PNPM_|npm ERR!' "$log"; then
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

run_plugin() {
  local plugin dir qdir
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
  corepack enable
  echo "PASS locks p=$(bit "${dir}/pnpm-lock.yaml") u=$(bit utools/pnpm-lock.yaml) r=$(bit pnpm-lock.yaml) n=$(bit "${dir}/package-lock.json") y=$(bit "${dir}/yarn.lock") w=$(bit pnpm-workspace.yaml) uw=$(bit utools/pnpm-workspace.yaml)"
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
if [ "${GATE_FAKE_PNPM_RC:-0}" != 0 ]; then
  echo "Cannot find module 'vitest'" >&2
  exit "$GATE_FAKE_PNPM_RC"
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

  self=$0
  mkdir -p "$root/plugin-lock/utools/easy-script"
  printf '%s\n' '{"name":"easy-script","scripts":{"test":"node -e process.exit(0)"}}' >"$root/plugin-lock/utools/easy-script/package.json"
  : >"$root/plugin-lock/utools/easy-script/pnpm-lock.yaml"
  run_case plugin-lock easy-script 0 "PASS install plugin-lock" "PASS test" "pnpm install --frozen-lockfile cwd=${root}/plugin-lock/utools/easy-script" "corepack enable"

  mkdir -p "$root/utools-lock/utools/bookmark-collector"
  printf '%s\n' '{"name":"bookmark-collector","scripts":{"test":"node -e process.exit(0)"}}' >"$root/utools-lock/utools/bookmark-collector/package.json"
  : >"$root/utools-lock/utools/pnpm-lock.yaml"
  run_case utools-lock bookmark-collector 0 "PASS install utools-lock" "pnpm install --frozen-lockfile --dir utools cwd=${root}/utools-lock" "pnpm --dir utools/bookmark-collector test cwd=${root}/utools-lock"

  mkdir -p "$root/npm-lock/utools/blog-sync"
  printf '%s\n' '{"name":"blog-sync","scripts":{"test":"node -e process.exit(0)"}}' >"$root/npm-lock/utools/blog-sync/package.json"
  : >"$root/npm-lock/utools/blog-sync/package-lock.json"
  run_case npm-lock blog-sync 0 "PASS install npm-lock" "npm ci --prefix utools/blog-sync" "npm test --prefix utools/blog-sync"
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
  printf '%s\n' '{"name":"easy-script"}' >"$root/yarn-only/utools/easy-script/package.json"
  : >"$root/yarn-only/utools/easy-script/yarn.lock"
  run_case yarn-only easy-script 1 "FAIL install yarn"

  mkdir -p "$root/missing/utools"
  run_case missing easy-script 1 "FAIL package"

  mkdir -p "$root/bad/utools/other"
  printf '%s\n' '{"name":"other"}' >"$root/bad/utools/other/package.json"
  run_case bad other 1 "FAIL plugin"

  mkdir -p "$root/broken/utools/easy-script"
  printf '%s\n' '{"name":"easy-script"}' >"$root/broken/utools/easy-script/package.json"
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
  echo "utools gate selftest ok"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_plugin "${PLUGIN:?PLUGIN empty}"
