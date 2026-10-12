#!/usr/bin/env python3
"""Run the private staging deploy or web E2E script, then keep public logs safe.

The script body is never printed. xtrace, secret echoes, origin IPs, and
source dumps are refused before execution. Child output is redacted.
The child environment is an explicit allowlist: no GitHub token, no CNB
token, no origin-ip variable.
"""

import os
import re
import stat
import subprocess
import sys
from pathlib import Path

DEPLOY_REL = Path(".ci/cnb-staging-deploy.sh")
E2E_REL = Path(".ci/cnb-staging-web-e2e.sh")
SOURCE_NAME = re.compile(r"^\.ci/[A-Za-z0-9._-]+\.sh$")
MAX_SCRIPT = 200_000
WEB = "https://test-daymica.zysicyj.top"
API = "https://test-api-daymica.zysicyj.top"
DEPLOY_URL = WEB + "/__staging-deploy"

SET_FLAGS = re.compile(r"(?m)^\s*set\s+-([A-Za-z]+)\b")
SET_XTRACE = re.compile(r"(?m)^\s*set\s+-o\s+xtrace\b")
SHEBANG_X = re.compile(r"^#![^\n]*\s-[A-Za-z]*x")
BASH_X = re.compile(r"(?m)\bbash\s+-[A-Za-z]*x\b")
VERBOSE_CURL = re.compile(r"(?m)curl[^\n]*(?:--trace\b|--verbose\b|(?:^|\s)-v\b)")
SECRET_PRINT = re.compile(
    r"(?i)(echo|printf|print|Write-Host|Write-Output)\b[^\n]*"
    r"(STAGING_WEBHOOK_DEPLOY_KEY|STAGING_E2E_PASSWORD|STAGING_E2E_EMAIL|"
    r"CNB_STATUS_TOKEN|PRIVATE_REPO_ACCESS_TOKEN|GITHUB_TOKEN|Authorization)"
)
ORIGIN_NAME = "STAGING_" + "ORIGIN_" + "IP"
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
SOURCE_DUMP = re.compile(
    r"(?i)\b(git\s+show|git\s+diff|git\s+cat-file|base64\s+[^\n]*secret|"
    r"cat\s+[^\n]*\.(?:go|dart|yml|yaml|env|pem|key))\b"
)
SOURCE_LINE = re.compile(
    r"""(?m)^(?:source|\.)\s+['"]?([A-Za-z0-9._/-]+\.sh)['"]?\s*(?:#.*)?$"""
)
ANY_SOURCE = re.compile(r"(?m)^(?:source|\.)\s+\S+")
PRIVATE_IP = re.compile(
    r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|"
    r"172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|"
    r"100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b"
)
TOKEN_LEAK = re.compile(r"\b(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]+")
XTRACE_OUT = re.compile(r"^\s*\+")
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp"}
SHOT_DIRS = (
    "test-results",
    "playwright-report",
    "e2e-screenshots",
    "screenshots",
    ".ci/e2e-screenshots",
    "apps/daymica/test-results",
    "apps/daymica/playwright-report",
    "apps/daymica/e2e-screenshots",
)


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
    if SECRET_PRINT.search(text):
        return "rejected-secret-print"
    if ORIGIN_NAME in text or IPV4.search(text):
        return "rejected-origin-ip"
    if SOURCE_DUMP.search(text):
        return "rejected-source-dump"
    for match in ANY_SOURCE.finditer(text):
        line = match.group(0).strip()
        parsed = SOURCE_LINE.fullmatch(line)
        if not parsed or ".." in parsed.group(1).split("/"):
            return "rejected-source-path"
    return ""


def resolve_script(root: Path, rel: Path):
    raw = str(rel).replace("\\", "/")
    if not SOURCE_NAME.fullmatch(raw):
        fail("rejected-path")
    path = (root / rel).resolve()
    ci = (root / ".ci").resolve()
    try:
        path.relative_to(ci)
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
    if ".." in key.split("/"):
        fail("rejected-path")
    seen.add(key)
    if not SOURCE_NAME.fullmatch(key) and not re.fullmatch(r"[A-Za-z0-9._/-]+\.sh", key):
        fail("rejected-path")
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
    for match in SOURCE_LINE.finditer(text):
        nested = match.group(1)
        if ".." in nested.split("/") or nested.startswith("/"):
            fail("rejected-path")
        guard_file(root, Path(nested), seen)


def secret_values():
    names = (
        "STAGING_WEBHOOK_DEPLOY_KEY",
        "STAGING_E2E_EMAIL",
        "STAGING_E2E_PASSWORD",
        "CNB_STATUS_TOKEN",
        "PRIVATE_REPO_ACCESS_TOKEN",
        "GITHUB_TOKEN",
        "ACTIONS_RUNTIME_TOKEN",
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
    if TOKEN_LEAK.search(line) or PRIVATE_IP.search(line):
        return "[redacted]", ""
    for secret in secrets:
        if secret and secret in line:
            line = line.replace(secret, "***")
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
    shot = os.environ.get("RUNNER_TEMP", "/tmp")
    env["STAGING_E2E_SCREENSHOT_DIR"] = str(Path(shot) / "e2e-screenshots")
    if mode == "deploy":
        env["STAGING_WEBHOOK_DEPLOY_KEY"] = os.environ["STAGING_WEBHOOK_DEPLOY_KEY"]
    else:
        env["STAGING_E2E_EMAIL"] = os.environ["STAGING_E2E_EMAIL"]
        env["STAGING_E2E_PASSWORD"] = os.environ["STAGING_E2E_PASSWORD"]
    return env


def run_mode(mode):
    expect = os.environ.get("EXPECT_SHA", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", expect):
        fail("sha failed allowlist")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip().lower()
    if head != expect:
        fail("checked out commit does not match payload sha")
    root = Path(".").resolve()
    rel = DEPLOY_REL if mode == "deploy" else E2E_REL
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
        "STAGING_WEBHOOK_DEPLOY_KEY",
        "STAGING_E2E_EMAIL",
        "STAGING_E2E_PASSWORD",
    ):
        os.environ.pop(name, None)
    proc = subprocess.run(
        ["bash", str(script)],
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    cleaned, xtrace = redact_stream(proc.stdout or "", secrets)
    if cleaned:
        print(cleaned)
    if xtrace:
        fail("xtrace output rejected")
    if proc.returncode != 0:
        fail(f"staging script exit {proc.returncode}")
    print(f"staging {mode} ok")


def collect(src: Path, dest: Path):
    dest.mkdir(parents=True, exist_ok=True)
    copied = 0
    roots = []
    shot = os.environ.get("STAGING_E2E_SCREENSHOT_DIR", "")
    if shot:
        roots.append(Path(shot))
    runner_shot = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "e2e-screenshots"
    roots.append(runner_shot)
    for name in SHOT_DIRS:
        roots.append(src / name)
    seen = set()
    for directory in roots:
        try:
            directory = directory.resolve()
        except OSError:
            continue
        if not directory.is_dir():
            continue
        if directory in seen:
            continue
        seen.add(directory)
        for path in directory.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            if path.suffix.lower() not in IMAGE_EXT:
                continue
            if path.stat().st_size > 8_000_000:
                continue
            if copied >= 30:
                print(f"screenshots={copied}")
                return
            target = dest / f"shot-{copied:02d}{path.suffix.lower()}"
            target.write_bytes(path.read_bytes())
            os.chmod(target, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
            copied += 1
    print(f"screenshots={copied}")


def selftest():
    assert guard_text("set -euo pipefail\ncurl -fsS \"$STAGING_DEPLOY_URL\"\n") == ""
    assert guard_text("set -x\n") == "rejected-xtrace"
    assert guard_text("set -eux\n") == "rejected-xtrace"
    assert guard_text("#!/bin/bash -x\n") == "rejected-xtrace"
    assert guard_text("source ../secret.sh\n") == "rejected-source-path"
    assert guard_text('echo "$STAGING_WEBHOOK_DEPLOY_KEY"\n') == "rejected-secret-print"
    assert guard_text("curl -v https://example.com\n") == "rejected-verbose-curl"
    assert guard_text("host=10.1.2.3\n") == "rejected-origin-ip"
    assert guard_text(f"{ORIGIN_NAME}=1\n") == "rejected-origin-ip"
    assert guard_text("git diff HEAD\n") == "rejected-source-dump"
    cleaned, xtrace = redact_stream("+ curl secret\nok line\n", ["secret"])
    assert xtrace == 1
    assert "ok line" in cleaned
    assert "secret" not in cleaned
    masked, _ = redact_stream("password=supersecretvalue\n", ["supersecretvalue"])
    assert "supersecretvalue" not in masked
    assert "***" in masked
    redacted, _ = redact_stream("dial 10.1.2.3\n", [])
    assert "10.1.2.3" not in redacted
    import tempfile

    tmp = Path(tempfile.mkdtemp())
    ci = tmp / ".ci"
    ci.mkdir()
    (ci / "cnb-staging-deploy.sh").write_text("echo deploy-ok\n", encoding="utf-8")
    (ci / "bad.sh").write_text("set -x\n", encoding="utf-8")
    os.chdir(tmp)
    guard_file(tmp, DEPLOY_REL, set())
    try:
        guard_file(tmp, Path(".ci/bad.sh"), set())
    except SystemExit:
        pass
    else:
        fail("bad script should fail")
    src = tmp / "test-results" / "case"
    src.mkdir(parents=True)
    (src / "fail.png").write_bytes(b"\x89PNG\r\n")
    (src / "trace.zip").write_bytes(b"PK")
    (src / "page.html").write_text("<html>", encoding="utf-8")
    out = tmp / "out"
    collect(tmp, out)
    names = sorted(p.name for p in out.iterdir())
    assert names == ["shot-00.png"], names
    print("staging_private_run selftest ok")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return
    if len(argv) == 4 and argv[1] == "--collect":
        collect(Path(argv[2]), Path(argv[3]))
        return
    if len(argv) == 2 and argv[1] in ("deploy", "e2e"):
        run_mode(argv[1])
        return
    fail("usage: staging_private_run.py deploy|e2e|--collect SRC DEST|--selftest")


if __name__ == "__main__":
    main(sys.argv)
