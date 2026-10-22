#!/usr/bin/env bash
# validate-admin-web: Node 22, pnpm from packageManager (else pnpm 9.12.3).
# corepack shims go under $HOME, not /usr/local/bin.
# Commands: pnpm install --frozen-lockfile, typecheck, test, build.
# Summary lines are PASS/FAIL names. Command output stays on stdout for quiet.sh.
set -euo pipefail

run_step() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "PASS ${name}"
    return 0
  fi
  echo "FAIL ${name}"
  return "$rc"
}

run_gate() {
  local major pm
  if [ ! -f apps/admin-web/package.json ]; then
    echo "FAIL admin-web missing=1"
    return 1
  fi
  major=$(node -v | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')
  if [ "$major" != "22" ]; then
    echo "FAIL node"
    return 1
  fi
  echo "PASS node major=22"

  pm=$(python3 -c 'import json,re,sys
p=json.load(open("apps/admin-web/package.json", encoding="utf-8"))
pm=p.get("packageManager") or ""
if not isinstance(pm, str):
    pm=""
if pm and not re.fullmatch(r"[A-Za-z0-9@._+-]+", pm):
    sys.exit(2)
print(pm)') || {
    echo "FAIL package"
    return 1
  }
  if [ -z "$pm" ]; then
    pm='pnpm@9.12.3'
  fi

  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/pnpm"
  export PNPM_HOME="$HOME/.local/share/pnpm"
  export PATH="$HOME/.local/bin:$PNPM_HOME:$PATH"
  if ! corepack enable --install-directory "$HOME/.local/bin" \
    || ! corepack prepare "$pm" --activate; then
    echo "FAIL pnpm"
    return 1
  fi
  echo "PASS pnpm"

  cd apps/admin-web
  run_step install pnpm install --frozen-lockfile
  run_step typecheck pnpm typecheck
  run_step test pnpm test
  run_step build pnpm build
}

selftest() {
  local root work dir out rc
  root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
  work=$(mktemp -d)
  dir=$(mktemp -d)
  mkdir -p "$work/apps/admin-web" "$dir/home/.local/bin"
  cat >"$work/apps/admin-web/package.json" <<'EOF'
{"packageManager":"pnpm@9.12.3","scripts":{"typecheck":"tsc","test":"vitest","build":"vite build"}}
EOF

  cat >"$dir/node" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-v" ]; then
  printf '%s\n' "v22.16.0"
  exit 0
fi
exit 0
EOF
  cat >"$dir/corepack" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_COREPACK_LOG:?}"
if printf '%s\n' "$*" | grep -q '/usr/local/bin'; then
  exit 1
fi
exit 0
EOF
  cat >"$dir/pnpm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_PNPM_LOG:?}"
if [ "${1:-}" = "${FAKE_PNPM_FAIL:-}" ]; then
  echo "secret at apps/admin-web/src/a.ts:3"
  exit 1
fi
exit 0
EOF
  chmod +x "$dir/node" "$dir/corepack" "$dir/pnpm"
  export FAKE_COREPACK_LOG="$dir/corepack.log"
  export FAKE_PNPM_LOG="$dir/pnpm.log"
  : >"$FAKE_COREPACK_LOG"
  : >"$FAKE_PNPM_LOG"

  run_quiet() {
    set +e
    out=$(
      cd "$work"
      HOME="$dir/home" PATH="$dir:$PATH" \
        RUNNER_TEMP="$dir" \
        GATE_LOG_KEY='selftest-key' \
        QUIET_LABEL=admin-web \
        QUIET_KIND=generic \
        QUIET_CMD="$1" \
        bash "$root/.github/scripts/quiet.sh"
    )
    rc=$?
    set -e
  }

  run_quiet "bash '$root/.github/scripts/admin-web-gate.sh'"
  if [ "$rc" -ne 0 ] \
    || ! printf '%s\n' "$out" | grep -qx 'PASS node major=22' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS install' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS typecheck' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS test' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS build'; then
    echo "FAIL selftest-run"
    exit 1
  fi
  if ! grep -qx 'enable --install-directory '"$dir/home/.local/bin" "$FAKE_COREPACK_LOG" \
    || ! grep -qx 'prepare pnpm@9.12.3 --activate' "$FAKE_COREPACK_LOG" \
    || ! grep -qx 'install --frozen-lockfile' "$FAKE_PNPM_LOG" \
    || ! grep -qx 'typecheck' "$FAKE_PNPM_LOG" \
    || ! grep -qx 'test' "$FAKE_PNPM_LOG" \
    || ! grep -qx 'build' "$FAKE_PNPM_LOG"; then
    echo "FAIL selftest-cmds"
    exit 1
  fi
  if printf '%s\n' "$out" | grep -F -q '/usr/local/bin'; then
    echo "FAIL selftest-home"
    exit 1
  fi

  : >"$FAKE_PNPM_LOG"
  export FAKE_PNPM_FAIL=test
  run_quiet "bash '$root/.github/scripts/admin-web-gate.sh'"
  if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -qx 'FAIL test' \
    || printf '%s\n' "$out" | grep -F -q -e 'a.ts' -e 'secret'; then
    echo "FAIL selftest-fail"
    exit 1
  fi
  if ! find "$dir/gate-encrypted" -type f -name '*.bin' | grep -q .; then
    echo "FAIL selftest-encrypted"
    exit 1
  fi

  rm -rf "$work/apps"
  export FAKE_PNPM_FAIL=''
  run_quiet "bash '$root/.github/scripts/admin-web-gate.sh'"
  if [ "$rc" -eq 0 ] || [ "$out" != "FAIL admin-web missing=1" ]; then
    echo "FAIL selftest-missing"
    exit 1
  fi

  rm -rf "$work" "$dir"
  echo "PASS selftest"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

run_gate
