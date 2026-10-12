#!/usr/bin/env python3
"""Run the private staging core entries, then keep public logs safe.

Does not execute .ci/cnb-staging-deploy.sh or .ci/cnb-staging-web-e2e.sh.
Those wrappers load secrets from another repo and mention the origin address.
Deploy is:

  bash scripts/ci/staging-deploy.sh build
  bash scripts/ci/staging-deploy.sh deploy

E2E is:

  node tools/staging-web-e2e/run.js

The script body is never printed. xtrace, secret expansions, IPv4 literals,
and source dumps are refused before execution. The origin variable name may
appear in the deploy script; echo and printf of that variable are refused,
and the child environment never sets it. Child output is redacted.
E2E logs are failed case names only.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

DEPLOY_REL = Path("scripts/ci/staging-deploy.sh")
E2E_REL = Path("tools/staging-web-e2e/run.js")
WRAPPERS = {
    ".ci/cnb-staging-deploy.sh",
    ".ci/cnb-staging-web-e2e.sh",
}
SHELL_NAME = re.compile(r"^scripts/ci/[A-Za-z0-9._-]+\.sh$")
JS_NAME = re.compile(
    r"^tools/staging-web-e2e/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.js$"
)
MAX_SCRIPT = 200_000
WEB = "https://test-daymica.zysicyj.top"
API = "https://test-api-daymica.zysicyj.top"
DEPLOY_URL = WEB + "/__staging-deploy"

SET_FLAGS = re.compile(r"(?m)^\s*set\s+-([A-Za-z]+)\b")
SET_XTRACE = re.compile(r"(?m)^\s*set\s+-o\s+xtrace\b")
SHEBANG_X = re.compile(r"^#![^\n]*\s-[A-Za-z]*x")
BASH_X = re.compile(r"(?m)\bbash\s+-[A-Za-z]*x\b")
VERBOSE_CURL = re.compile(r"(?m)curl[^\n]*(?:--trace\b|--verbose\b|(?:^|\s)-v\b)")
SECRET_VALUE = re.compile(
    r"(?i)(echo|printf|print|console\.log|Write-Host|Write-Output)\b[^\n]*"
    r"\$\{?(?:STAGING_WEBHOOK_DEPLOY_KEY|STAGING_E2E_PASSWORD|STAGING_E2E_EMAIL|"
    r"CNB_STATUS_TOKEN|PRIVATE_REPO_ACCESS_TOKEN|GITHUB_TOKEN|CNB_TOKEN)\b"
)
ORIGIN_NAME = "STAGING_" + "ORIGIN_" + "IP"
ORIGIN_PRINT = re.compile(
    r"(?im)\b(?:echo|printf)\b[^\n]*\$\{?" + re.escape(ORIGIN_NAME) + r"\b"
)
LOADER = "load-daymica-secrets"
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
SOURCE_DUMP = re.compile(
    r"(?i)\b(git\s+show|git\s+diff|git\s+cat-file|git\s+clone|"
    r"base64\s+[^\n]*secret|cat\s+[^\n]*\.(?:go|dart|yml|yaml|env|pem|key))\b"
)
SOURCE_LINE = re.compile(
    r"""(?m)^(?:source|\.)\s+['"]?([A-Za-z0-9._/-]+\.sh)['"]?\s*(?:#.*)?$"""
)
ANY_SOURCE = re.compile(r"(?m)^(?:source|\.)\s+\S+")
JS_IMPORT = re.compile(
    r"""(?m)(?:require\(\s*|from\s+|import\s+)['"](\./[A-Za-z0-9._/-]+\.js)['"]"""
)
JS_BIN = re.compile(r"""(?m)['"](bin/[A-Za-z0-9._/-]+\.js)['"]""")
TOKEN_LEAK = re.compile(r"\b(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]+")
XTRACE_OUT = re.compile(r"^\s*\+")
CASE_LINE = re.compile(r"(?m)^\s*(?:\d+\)|✘\s+\d+)\s+(.+?)\s*$")
CASE_NAME = re.compile(r"^[\w .:/()+\-]{1,120}$")


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def guard_text(text):
    if "\x00" in text:
        return "rejected-binary"
    if SHEBANG_X.search(text) or SET_XTRACE.search(text) or BASH_X.search(text):
        return "rejected-xtrace"
    if any("x" in match.group(1) for match in SET_FLAGS.finditer(text)):
        return "rejected-xtrace"
    if VERBOSE_CURL.search(text):
        return "rejected-verbose-curl"
    if SECRET_VALUE.search(text) or ORIGIN_PRINT.search(text):
        return "rejected-secret-print"
    if "CNB_TOKEN" in text or LOADER in text:
        return "rejected-secret-loader"
    if IPV4.search(text):
        return "rejected-ipv4"
    if SOURCE_DUMP.search(text):
        return "rejected-source-dump"
    for match in ANY_SOURCE.finditer(text):
        line = match.group(0).strip()
        parsed = SOURCE_LINE.fullmatch(line)
        if not parsed or ".." in parsed.group(1).split("/"):
            return "rejected-source-path"
        if not SHELL_NAME.fullmatch(parsed.group(1)):
            return "rejected-source-path"
    return ""


def resolve_script(root: Path, rel: Path):
    raw = str(rel).replace("\\", "/")
    if raw in WRAPPERS or not (SHELL_NAME.fullmatch(raw) or JS_NAME.fullmatch(raw)):
        fail("rejected-path")
    path = (root / rel).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        fail("rejected-path")
    if not path.is_file() or path.is_symlink():
        fail("missing staging script")
    return path


def guard_file(root: Path, rel: Path, seen):
    key = str(rel).replace("\\", "/")
    if key in seen:
        return
    if len(seen) > 20:
        fail("rejected-source-path")
    if key in WRAPPERS or ".." in key.split("/"):
        fail("rejected-path")
    if not (SHELL_NAME.fullmatch(key) or JS_NAME.fullmatch(key)):
        fail("rejected-path")
    seen.add(key)
    path = (root / key).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        fail("rejected-path")
    if not path.is_file() or path.is_symlink():
        fail("missing staging script")
    data = path.read_bytes()
    if len(data) > MAX_SCRIPT:
        fail("rejected-size")
    text = data.decode("utf-8", errors="replace")
    reason = guard_text(text)
    if reason:
        fail(reason)
    if key.endswith(".sh"):
        for match in SOURCE_LINE.finditer(text):
            nested = match.group(1)
            guard_file(root, Path(nested), seen)
        return
    base = path.parent
    rel_imports = [match.group(1) for match in JS_IMPORT.finditer(text)]
    rel_imports.extend(match.group(1) for match in JS_BIN.finditer(text))
    for rel_import in rel_imports:
        nested = (base / rel_import).resolve()
        try:
            rel_nested = nested.relative_to(root.resolve())
        except ValueError:
            fail("rejected-path")
        guard_file(root, rel_nested, seen)


def secret_values():
    names = (
        "STAGING_WEBHOOK_DEPLOY_KEY",
        "STAGING_E2E_EMAIL",
        "STAGING_E2E_PASSWORD",
        "CNB_STATUS_TOKEN",
        "PRIVATE_REPO_ACCESS_TOKEN",
        "GITHUB_TOKEN",
        "ACTIONS_RUNTIME_TOKEN",
        "CNB_TOKEN",
    )
    values = []
    for name in names:
        value = os.environ.get(name, "")
        if len(value) >= 6:
            values.append(value)
    return values


def redact_line(line, secrets):
    if XTRACE_OUT.match(line):
        return None, "xtrace"
    if TOKEN_LEAK.search(line):
        return "[redacted]", ""
    for secret in secrets:
        if secret and secret in line:
            line = line.replace(secret, "***")
    if IPV4.search(line):
        line = IPV4.sub("[ip]", line)
    if len(line) > 500:
        return "[redacted-long-line]", ""
    return line, ""


def redact_stream(text, secrets):
    kept = []
    xtrace = 0
    for line in text.splitlines():
        cleaned, flag = redact_line(line, secrets)
        if flag == "xtrace":
            xtrace += 1
            continue
        if cleaned is not None:
            kept.append(cleaned)
    return "\n".join(kept), xtrace


def case_names(text):
    found = []
    seen = set()
    for match in CASE_LINE.finditer(text):
        raw = match.group(1).strip()
        if "@" in raw or "http" in raw.lower() or "***" in raw or "[ip]" in raw:
            continue
        if "›" in raw:
            raw = raw.rsplit("›", 1)[-1].strip()
        raw = re.sub(r"\s*\([0-9.]+s\)\s*$", "", raw).strip()
        if (
            not raw
            or "@" in raw
            or "http" in raw.lower()
            or "***" in raw
            or "[ip]" in raw
            or not CASE_NAME.fullmatch(raw)
        ):
            continue
        if raw in seen:
            continue
        seen.add(raw)
        found.append(raw)
        if len(found) >= 30:
            break
    return found


def child_env(mode, expect_sha):
    if mode == "deploy":
        key = os.environ.get("STAGING_WEBHOOK_DEPLOY_KEY", "")
        if not key.strip():
            fail("STAGING_WEBHOOK_DEPLOY_KEY is empty")
    elif mode == "e2e":
        if not os.environ.get("STAGING_E2E_EMAIL", "").strip():
            fail("STAGING_E2E_EMAIL is empty")
        if not os.environ.get("STAGING_E2E_PASSWORD", "").strip():
            fail("STAGING_E2E_PASSWORD is empty")
    else:
        fail("mode failed allowlist")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[0-9]+", run_id or ""):
        fail("run id failed allowlist")
    if not re.fullmatch(r"[0-9a-f]{40}", expect_sha):
        fail("sha failed allowlist")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    repo = os.environ.get("GITHUB_REPOSITORY", "zysicyj-xxc/public-builder")
    if repo != "zysicyj-xxc/public-builder" or server != "https://github.com":
        fail("repository failed allowlist")
    run_url = f"{server}/{repo}/actions/runs/{run_id}"
    names = [
        "PATH",
        "HOME",
        "USER",
        "LANG",
        "LC_ALL",
        "TMPDIR",
        "RUNNER_TEMP",
        "RUNNER_TOOL_CACHE",
        "CI",
        "FLUTTER_ROOT",
        "PUB_CACHE",
        "GOROOT",
        "GOPATH",
        "JAVA_HOME",
        "ANDROID_HOME",
        "ANDROID_SDK_ROOT",
    ]
    env = {}
    for name in names:
        value = os.environ.get(name)
        if value:
            env[name] = value
    env["CI"] = "true"
    env["CI_PROVIDER"] = "github"
    env["DEBIAN_FRONTEND"] = "noninteractive"
    env["WEB"] = WEB
    env["API"] = API
    env["STAGING_WEB_URL"] = WEB
    env["STAGING_API_URL"] = API
    env["STAGING_DEPLOY_URL"] = DEPLOY_URL
    env["WORKFLOW_RUN_ID"] = run_id
    env["GITHUB_RUN_ID"] = run_id
    env["GITHUB_SHA"] = expect_sha
    env["PUBLIC_BUILDER_RUN_URL"] = run_url
    env["BUILD_URL"] = run_url
    env["CNB_BRANCH"] = "main"
    env["CNB_COMMIT"] = expect_sha
    env["CNB_BUILD_ID"] = run_id
    if mode == "deploy":
        env["STAGING_WEBHOOK_DEPLOY_KEY"] = os.environ["STAGING_WEBHOOK_DEPLOY_KEY"]
    else:
        env["GITHUB_EVENT_NAME"] = "repository_dispatch"
        env["STAGING_E2E_EMAIL"] = os.environ["STAGING_E2E_EMAIL"]
        env["STAGING_E2E_PASSWORD"] = os.environ["STAGING_E2E_PASSWORD"]
    if ORIGIN_NAME in env:
        fail("origin address was set")
    return env


def run_checked(cmd, cwd, env, secrets, mode):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    cleaned, xtrace = redact_stream(proc.stdout or "", secrets)
    if xtrace:
        fail("xtrace output rejected")
    label = cmd[-1]
    if mode == "e2e":
        names = case_names(cleaned)
        if proc.returncode != 0:
            if names:
                for name in names:
                    print(f"e2e failed: {name}")
            else:
                print("e2e failed: unnamed")
            fail(f"staging script exit {proc.returncode}")
        print("staging e2e ok")
        return
    if cleaned:
        print(cleaned)
    if proc.returncode != 0:
        fail(f"staging script exit {proc.returncode}")
    print(f"staging {label} ok")


def run_mode(mode):
    expect = os.environ.get("EXPECT_SHA", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", expect):
        fail("sha failed allowlist")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip().lower()
    if head != expect:
        fail("checked out commit does not match payload sha")
    root = Path(".").resolve()
    if mode == "deploy":
        rel = DEPLOY_REL
        steps = ("build", "deploy")
    elif mode == "e2e":
        rel = E2E_REL
        steps = ("",)
    else:
        fail("mode failed allowlist")
    guard_file(root, rel, set())
    print("staging script guard ok")
    script = resolve_script(root, rel)
    env = child_env(mode, expect)
    secrets = secret_values()
    for name in (
        "GITHUB_TOKEN",
        "PRIVATE_REPO_ACCESS_TOKEN",
        "CNB_STATUS_TOKEN",
        "ACTIONS_RUNTIME_TOKEN",
        "CNB_TOKEN",
        "STAGING_WEBHOOK_DEPLOY_KEY",
        "STAGING_E2E_EMAIL",
        "STAGING_E2E_PASSWORD",
    ):
        os.environ.pop(name, None)
    if mode == "deploy":
        commands = [(["bash", str(script), step], root) for step in steps]
    else:
        commands = [(["node", "run.js"], root / "tools" / "staging-web-e2e")]
    for cmd, cwd in commands:
        run_checked(cmd, cwd, env, secrets, mode)


def selftest():
    assert guard_text("set -euo pipefail\ncurl -fsS \"$STAGING_DEPLOY_URL\"\n") == ""
    assert guard_text("echo STAGING_WEBHOOK_DEPLOY_KEY is unset\n") == ""
    assert guard_text("set -x\n") == "rejected-xtrace"
    assert guard_text("set -eux\n") == "rejected-xtrace"
    assert guard_text("#!/bin/bash -x\n") == "rejected-xtrace"
    assert guard_text("source ../secret.sh\n") == "rejected-source-path"
    assert guard_text("source .ci/helper.sh\n") == "rejected-source-path"
    assert guard_text('echo "$STAGING_WEBHOOK_DEPLOY_KEY"\n') == "rejected-secret-print"
    assert guard_text("curl -v https://example.com\n") == "rejected-verbose-curl"
    assert guard_text("host=10.1.2.3\n") == "rejected-ipv4"
    assert guard_text("host=8.8.8.8\n") == "rejected-ipv4"
    assert guard_text(f"if [ -n \"${{{ORIGIN_NAME}:-}}\" ]; then echo warn; fi\n") == ""
    assert guard_text(f'echo "${ORIGIN_NAME}"\n') == "rejected-secret-print"
    assert guard_text(f'printf "%s" "${{{ORIGIN_NAME}}}"\n') == "rejected-secret-print"
    assert guard_text(f"echo {ORIGIN_NAME} is unset\n") == ""
    assert guard_text("git clone https://example.com/secrets.git\n") == "rejected-source-dump"
    assert guard_text("git diff HEAD\n") == "rejected-source-dump"
    cleaned, xtrace = redact_stream("+ curl secret\nok line\n", ["secret"])
    assert xtrace == 1
    assert "ok line" in cleaned
    assert "secret" not in cleaned
    masked, _ = redact_stream("dial 8.8.8.8 and 10.1.2.3\n", [])
    assert "8.8.8.8" not in masked
    assert "10.1.2.3" not in masked
    assert masked.count("[ip]") == 2
    sample = "\n".join(
        [
            "  1) [chromium] › tests/login.spec.ts:10:3 › opens the timeline",
            "  ✘  2 tests/login.spec.ts:20:3 › saves a note (1.2s)",
            "  3) user@example.com › hidden",
        ]
    )
    assert case_names(sample) == ["opens the timeline", "saves a note"]
    sha = "0123456789abcdef0123456789abcdef01234567"
    keys = (
        "GITHUB_RUN_ID",
        "GITHUB_SERVER_URL",
        "GITHUB_REPOSITORY",
        "STAGING_E2E_EMAIL",
        "STAGING_E2E_PASSWORD",
        "STAGING_WEBHOOK_DEPLOY_KEY",
        ORIGIN_NAME,
    )
    saved = {key: os.environ.get(key) for key in keys}
    os.environ["GITHUB_RUN_ID"] = "42"
    os.environ["GITHUB_SERVER_URL"] = "https://github.com"
    os.environ["GITHUB_REPOSITORY"] = "zysicyj-xxc/public-builder"
    os.environ["STAGING_E2E_EMAIL"] = "e2e@example.com"
    os.environ["STAGING_E2E_PASSWORD"] = "e2e-password"
    os.environ["STAGING_WEBHOOK_DEPLOY_KEY"] = "deploy-key-value"
    os.environ[ORIGIN_NAME] = "203.0.113.10"
    try:
        e2e_env = child_env("e2e", sha)
        deploy_env = child_env("deploy", sha)
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    assert ORIGIN_NAME not in e2e_env
    assert ORIGIN_NAME not in deploy_env
    assert "203.0.113.10" not in e2e_env.values()
    assert "203.0.113.10" not in deploy_env.values()
    assert e2e_env["CI_PROVIDER"] == "github"
    assert e2e_env["GITHUB_EVENT_NAME"] == "repository_dispatch"
    assert deploy_env["CI_PROVIDER"] == "github"
    assert "GITHUB_EVENT_NAME" not in deploy_env
    import tempfile

    tmp = Path(tempfile.mkdtemp())
    ci = tmp / "scripts" / "ci"
    ci.mkdir(parents=True)
    (ci / "staging-deploy.sh").write_text(
        f'if [ -z "${{{ORIGIN_NAME}:-}}" ]; then echo domain; fi\n',
        encoding="utf-8",
    )
    (ci / "bad.sh").write_text("set -x\n", encoding="utf-8")
    wrap = tmp / ".ci"
    wrap.mkdir()
    (wrap / "cnb-staging-deploy.sh").write_text("echo wrapper\n", encoding="utf-8")
    os.chdir(tmp)
    guard_file(tmp, DEPLOY_REL, set())
    try:
        guard_file(tmp, Path("scripts/ci/bad.sh"), set())
    except SystemExit:
        pass
    else:
        fail("bad script should fail")
    try:
        resolve_script(tmp, Path(".ci/cnb-staging-deploy.sh"))
    except SystemExit:
        pass
    else:
        fail("wrapper should fail")
    print("staging_private_run selftest ok")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return
    if len(argv) == 2 and argv[1] in ("deploy", "e2e"):
        run_mode(argv[1])
        return
    fail("usage: staging_private_run.py deploy|e2e|--selftest")


if __name__ == "__main__":
    main(sys.argv)
