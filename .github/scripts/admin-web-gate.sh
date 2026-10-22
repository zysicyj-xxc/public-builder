#!/usr/bin/env bash
# validate-admin-web: Node 22, corepack prepare pnpm@9.12.3 --activate.
# corepack shims go under $HOME, not /usr/local/bin.
# Install apps/web_shared, then apps/admin-web. Both use
# pnpm install --frozen-lockfile --ignore-scripts.
# Then, in apps/admin-web: pnpm typecheck, pnpm test, pnpm build.
# Summary lines are PASS/FAIL names. Command output stays on stdout for quiet.sh.
set -euo pipefail

run_in() {
  local name="$1" dir="$2"
  shift 2
  set +e
  (cd "$dir" && "$@")
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
  local major
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

  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/pnpm"
  export PNPM_HOME="$HOME/.local/share/pnpm"
  export PATH="$HOME/.local/bin:$PNPM_HOME:$PATH"
  if ! corepack enable --install-directory "$HOME/.local/bin" \
    || ! corepack prepare pnpm@9.12.3 --activate; then
    echo "FAIL pnpm"
    return 1
  fi
  echo "PASS pnpm"

  run_in "install web-shared" apps/web_shared \
    pnpm install --frozen-lockfile --ignore-scripts || return
  run_in "install admin-web" apps/admin-web \
    pnpm install --frozen-lockfile --ignore-scripts || return
  run_in typecheck apps/admin-web pnpm typecheck || return
  run_in test apps/admin-web pnpm test || return
  run_in build apps/admin-web pnpm build
}

selftest() {
  local root work dir out rc
  root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
  work=$(mktemp -d)
  dir=$(mktemp -d)
  mkdir -p "$work/apps/admin-web" "$work/apps/web_shared" "$dir/home/.local/bin"
  cat >"$work/apps/admin-web/package.json" <<'EOF'
{"packageManager":"pnpm@10.0.0","scripts":{"typecheck":"tsc","test":"vitest","build":"vite build"}}
EOF
  printf '%s\n' '{}' >"$work/apps/web_shared/package.json"

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
printf '%s\t%s\n' "$PWD" "$*" >>"${FAKE_PNPM_LOG:?}"
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

  assert_installs() {
    python3 - "$FAKE_PNPM_LOG" <<'PY'
import sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    pwd, _, args = line.rstrip("\n").partition("\t")
    rows.append((pwd, args))
installs = [(pwd, args) for pwd, args in rows if args.startswith("install ")]
if [args for _, args in installs if args != "install --frozen-lockfile --ignore-scripts"]:
    raise SystemExit("bad install args")
if len(installs) != 2:
    raise SystemExit("install count")
if not installs[0][0].endswith("/apps/web_shared"):
    raise SystemExit("web_shared order")
if not installs[1][0].endswith("/apps/admin-web"):
    raise SystemExit("admin-web order")
rest = [(pwd, args) for pwd, args in rows if not args.startswith("install ")]
want = ["typecheck", "test", "build"]
if [args for _, args in rest] != want:
    raise SystemExit("later commands")
if any(not pwd.endswith("/apps/admin-web") for pwd, _ in rest):
    raise SystemExit("later cwd")
PY
  }

  run_quiet "bash '$root/.github/scripts/admin-web-gate.sh'"
  if [ "$rc" -ne 0 ] \
    || ! printf '%s\n' "$out" | grep -qx 'PASS node major=22' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS install web-shared' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS install admin-web' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS typecheck' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS test' \
    || ! printf '%s\n' "$out" | grep -qx 'PASS build'; then
    echo "FAIL selftest-run"
    exit 1
  fi
  if ! grep -qx 'enable --install-directory '"$dir/home/.local/bin" "$FAKE_COREPACK_LOG" \
    || ! grep -qx 'prepare pnpm@9.12.3 --activate' "$FAKE_COREPACK_LOG" \
    || grep -q 'pnpm@10.0.0' "$FAKE_COREPACK_LOG"; then
    echo "FAIL selftest-pnpm"
    exit 1
  fi
  if ! assert_installs; then
    echo "FAIL selftest-cmds"
    exit 1
  fi
  if printf '%s\n' "$out" | grep -F -q '/usr/local/bin'; then
    echo "FAIL selftest-home"
    exit 1
  fi

  : >"$FAKE_PNPM_LOG"
  rm -rf "$work/apps/web_shared"
  run_quiet "bash '$root/.github/scripts/admin-web-gate.sh'"
  if [ "$rc" -eq 0 ] || ! printf '%s\n' "$out" | grep -qx 'FAIL install web-shared' \
    || grep -q $'\tinstall ' "$FAKE_PNPM_LOG"; then
    echo "FAIL selftest-web-shared"
    exit 1
  fi

  mkdir -p "$work/apps/web_shared"
  printf '%s\n' '{}' >"$work/apps/web_shared/package.json"
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
