#!/usr/bin/env python3
"""Build a private staging bundle and POST it to daymica-staging-deployer.

The public entry is POST https://test-daymica.zysicyj.top/__staging-deploy.
Authorization is Bearer STAGING_WEBHOOK_DEPLOY_KEY. There is no HMAC.
The bearer value and STAGING_ORIGIN_IP are sent with curl --config on stdin
so they are not curl argv. Public stdout is PASS/FAIL only.

This runs scripts/ci/staging-deploy.sh build. It does not run that script's
deploy subcommand, and it does not send an nginx multipart field.
"""

import io
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

URL = "https://test-daymica.zysicyj.top/__staging-deploy"
HOST = "test-daymica.zysicyj.top"
KEY_NAME = "STAGING_WEBHOOK_DEPLOY_KEY"
IP_NAME = "STAGING_ORIGIN_IP"
DEPLOY_REL = Path("scripts/ci/staging-deploy.sh")
MAX_GZIP = 200 * 1024 * 1024
MAX_RAW = 400 * 1024 * 1024
CURL_MAX_TIME = 150
CONNECT_TIMEOUT = 15
RETRY_SLEEPS = (5, 10, 20, 30, 30)
MAX_SCRIPT = 200_000
DETAIL_CAP = 200_000
ROOT = Path(__file__).resolve().parents[2]

FILE_NAMES = {"daymica-server", "seed-e2e-account", "prod-sql-gate"}
REQUIRED = ("daymica-server", "web/index.html")

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
SET_FLAGS = re.compile(r"(?m)^\s*set\s+-([A-Za-z]+)\b")
SET_XTRACE = re.compile(r"(?m)^\s*set\s+-o\s+xtrace\b")
SHEBANG_X = re.compile(r"^#![^\n]*\s-[A-Za-z]*x")
BASH_X = re.compile(r"(?m)\bbash\s+-[A-Za-z]*x\b")
VERBOSE_CURL = re.compile(r"(?m)curl[^\n]*(?:--trace\b|--verbose\b|(?:^|\s)-v\b)")
SECRET_VALUE = re.compile(
    r"(?i)(echo|printf|print|console\.log|Write-Host|Write-Output)\b[^\n]*"
    r"\$\{?(?:STAGING_WEBHOOK_DEPLOY_KEY|STAGING_ORIGIN_IP|"
    r"PRIVATE_REPO_ACCESS_TOKEN|GITHUB_TOKEN|GATE_LOG_KEY)\b"
)
ORIGIN_PRINT = re.compile(
    r"(?im)\b(?:echo|printf)\b[^\n]*\$\{?STAGING_ORIGIN_IP\b"
)
LOADER = "load-daymica-secrets"
SOURCE_DUMP = re.compile(
    r"(?i)\b(git\s+show|git\s+diff|git\s+cat-file|git\s+clone|"
    r"base64\s+[^\n]*secret|cat\s+[^\n]*\.(?:go|dart|yml|yaml|env|pem|key))\b"
)
SOURCE_LINE = re.compile(
    r"""(?m)^(?:source|\.)\s+['"]?([A-Za-z0-9._/-]+\.sh)['"]?\s*(?:#.*)?$"""
)
ANY_SOURCE = re.compile(r"(?m)^(?:source|\.)\s+\S+")
SHELL_NAME = re.compile(r"^scripts/ci/[A-Za-z0-9._-]+\.sh$")
# `flutter pub get` prints "+ pkg ver". Only lines tagged by child_env PS4 are xtrace.
XTRACE_OUT = re.compile(r"^\s*\+*__PB_XTRACE__ ")
TOKEN_LEAK = re.compile(r"\b(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]+")
SET_X_CMD = re.compile(r"(?m)^\s*set\s+-[A-Za-z]*x\b|^\s*set\s+-o\s+xtrace\b")

ALLOW_ENV = (
    "PATH",
    "HOME",
    "USER",
    "LANG",
    "LC_ALL",
    "TMPDIR",
    "RUNNER_TEMP",
    "RUNNER_TOOL_CACHE",
    "CI",
    "DEBIAN_FRONTEND",
    "FLUTTER_ROOT",
    "PUB_CACHE",
    "GOROOT",
    "GOPATH",
    "GOTOOLCHAIN",
    "GOPROXY",
    "JAVA_HOME",
    "ANDROID_HOME",
    "ANDROID_SDK_ROOT",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "CURL_CA_BUNDLE",
)


def fail(code):
    note_detail(f"FAIL_CODE: {code}", [])
    if not re.fullmatch(r"[a-z0-9-]{1,40}", code):
        code = "internal"
    print(f"FAIL {code}", file=sys.stderr)
    raise SystemExit(1)


def fail_http(code):
    if not re.fullmatch(r"[0-9]{3}", code or ""):
        code = "000"
    print(f"FAIL deploy http={code}", file=sys.stderr)
    raise SystemExit(1)


def ok(msg):
    if not re.fullmatch(r"[A-Za-z0-9 .=_-]{1,80}", msg):
        msg = "ok"
    print(f"PASS {msg}")


def mask(value):
    if os.environ.get("STAGING_CURL_SELFTEST") == "1":
        return
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    if not value or any(c in value for c in "\r\n"):
        return
    safe = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::add-mask::{safe}", flush=True)


def valid_key(key):
    if not isinstance(key, str) or len(key) < 16 or len(key) > 512:
        return False
    if any(c in key for c in "\r\n\"\\ \t"):
        return False
    return key.isascii()


def valid_ip(ip):
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    for part in parts:
        if not part.isdigit() or (len(part) > 1 and part.startswith("0")):
            return False
        if int(part) > 255:
            return False
    return True


def redact(text, secrets):
    kept = []
    xtrace = 0
    for line in text.splitlines():
        if XTRACE_OUT.match(line):
            xtrace += 1
            continue
        if TOKEN_LEAK.search(line) or "authorization" in line.lower() or "bearer" in line.lower():
            kept.append("[redacted]")
            continue
        for secret in secrets:
            if secret and len(secret) >= 8 and secret in line:
                line = line.replace(secret, "***")
        line = IPV4.sub("[ip]", line)
        if len(line) > 500:
            line = "[redacted-long-line]"
        kept.append(line)
    out = "\n".join(kept)
    if len(out) > DETAIL_CAP:
        out = out[:DETAIL_CAP] + "\n[truncated]"
    return out, xtrace


def note_detail(text, secrets):
    path = os.environ.get("DETAIL_LOG", "")
    if not path or not text:
        return
    cleaned, _ = redact(text, secrets)
    if not cleaned:
        return
    dest = Path(path)
    with dest.open("a", encoding="utf-8") as fh:
        fh.write(cleaned)
        if not cleaned.endswith("\n"):
            fh.write("\n")
    os.chmod(dest, 0o600)


def clear_detail():
    path = os.environ.get("DETAIL_LOG", "")
    if path:
        Path(path).unlink(missing_ok=True)


def norm_name(name):
    name = name.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    parts = []
    for part in name.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            return None
        parts.append(part)
    if not parts:
        return None
    return "/".join(parts)


def allowed_name(name):
    if name in FILE_NAMES or name == "web":
        return True
    return name.startswith("web/") and ".." not in name.split("/")


def assess_members(items, compressed):
    """items are (name, kind, size) with kind in file, dir, link."""
    if compressed <= 0 or compressed > MAX_GZIP:
        return "archive-size"
    files = {}
    raw = 0
    for name, kind, size in items:
        normal = norm_name(name)
        if not normal or not allowed_name(normal):
            return "archive-member"
        if kind == "link":
            return "archive-link"
        if kind == "dir":
            if normal in FILE_NAMES:
                return "archive-member"
            continue
        if kind != "file":
            return "archive-member"
        if normal in files or size < 0:
            return "archive-member"
        if normal in REQUIRED and size <= 0:
            return "archive-member"
        raw += size
        if raw > MAX_RAW or size > MAX_RAW:
            return "archive-size"
        files[normal] = size
    for required in REQUIRED:
        if required not in files:
            return "archive-member"
    return ""


def assess_tar(path, max_gzip=MAX_GZIP):
    if path.is_symlink() or not path.is_file():
        fail("archive-link")
    compressed = path.stat().st_size
    if compressed <= 0 or compressed > max_gzip:
        fail("archive-size")
    items = []
    raw = 0
    try:
        with tarfile.open(path, "r:gz") as handle:
            for member in handle:
                if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                    fail("archive-link")
                if member.isdir():
                    kind = "dir"
                    size = 0
                elif member.isreg():
                    kind = "file"
                    size = int(member.size)
                else:
                    fail("archive-link")
                raw += size
                if raw > MAX_RAW:
                    fail("archive-size")
                items.append((member.name, kind, size))
    except (tarfile.TarError, OSError, EOFError):
        fail("archive-member")
    reason = assess_members(items, compressed)
    if reason:
        fail(reason)


def assess_tree(root: Path):
    if root.is_symlink() or not root.is_dir():
        fail("archive-member")
    items = []
    seen_inodes = set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        kept = []
        for name in dirnames:
            path = Path(dirpath) / name
            if path.is_symlink():
                fail("archive-link")
            kept.append(name)
            rel = path.relative_to(root).as_posix()
            items.append((rel, "dir", 0))
        dirnames[:] = kept
        for name in filenames:
            path = Path(dirpath) / name
            if path.is_symlink():
                fail("archive-link")
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode):
                fail("archive-link")
            if info.st_nlink > 1 or info.st_ino in seen_inodes:
                fail("archive-link")
            seen_inodes.add(info.st_ino)
            rel = path.relative_to(root).as_posix()
            items.append((rel, "file", info.st_size))
    reason = assess_members(items, 1)
    if reason and reason != "archive-size":
        fail(reason)
    raw = sum(size for _, kind, size in items if kind == "file")
    if raw <= 0 or raw > MAX_RAW:
        fail("archive-size")


def pack_tree(root: Path, dest: Path):
    assess_tree(root)
    if dest.exists():
        fail("archive-member")
    with tarfile.open(dest, "w:gz") as handle:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            dirnames[:] = [d for d in dirnames if not (Path(dirpath) / d).is_symlink()]
            for name in filenames:
                path = Path(dirpath) / name
                if path.is_symlink():
                    fail("archive-link")
                rel = path.relative_to(root).as_posix()
                handle.add(path, arcname=rel, recursive=False)
    assess_tar(dest)


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


def guard_file(root: Path, rel: Path, seen):
    key = str(rel).replace("\\", "/")
    if key in seen:
        return
    if len(seen) > 20 or key in {".ci/cnb-staging-deploy.sh", ".ci/cnb-staging-web-e2e.sh"}:
        fail("rejected-path")
    if ".." in key.split("/") or not SHELL_NAME.fullmatch(key):
        fail("rejected-path")
    seen.add(key)
    path = (root / key).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        fail("rejected-path")
    if not path.is_file() or path.is_symlink():
        fail("missing-script")
    data = path.read_bytes()
    if len(data) > MAX_SCRIPT:
        fail("rejected-size")
    text = data.decode("utf-8", errors="replace")
    reason = guard_text(text)
    if reason:
        fail(reason)
    for match in SOURCE_LINE.finditer(text):
        guard_file(root, Path(match.group(1)), seen)


def expect_sha():
    sha = os.environ.get("EXPECT_SHA", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        fail("sha")
    return sha


def check_head(sha):
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip().lower()
    except (subprocess.CalledProcessError, FileNotFoundError):
        fail("sha")
    if head != sha:
        fail("sha-mismatch")


def branch_name():
    if os.environ.get("STAGING_SHA_INPUT", "").strip():
        return ""
    ref = os.environ.get("STAGING_GIT_REF", "").strip()
    if not ref.startswith("refs/heads/"):
        return ""
    name = ref[len("refs/heads/") :]
    if ".." in name.split("/") or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", name):
        return ""
    return name


def child_env(sha):
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    server = os.environ.get("GITHUB_SERVER_URL", "").rstrip("/")
    if repo != "zysicyj-xxc/public-builder" or server != "https://github.com":
        fail("repository")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[0-9]+", run_id):
        fail("run-id")
    env = {}
    for name in ALLOW_ENV:
        value = os.environ.get(name)
        if value:
            env[name] = value
    env["CI"] = "true"
    env["CI_PROVIDER"] = "github"
    env["DEBIAN_FRONTEND"] = "noninteractive"
    env["GITHUB_SHA"] = sha
    env["CNB_COMMIT"] = sha
    env["CNB_BUILD_ID"] = run_id
    env["GITHUB_RUN_ID"] = run_id
    env["WORKFLOW_RUN_ID"] = run_id
    run_url = f"{server}/{repo}/actions/runs/{run_id}"
    env["BUILD_URL"] = run_url
    env["PUBLIC_BUILDER_RUN_URL"] = run_url
    branch = branch_name()
    if branch:
        env["CNB_BRANCH"] = branch
    for banned in (KEY_NAME, IP_NAME, "GITHUB_TOKEN", "PRIVATE_REPO_ACCESS_TOKEN", "GATE_LOG_KEY"):
        env.pop(banned, None)
    env["PS4"] = "+__PB_XTRACE__ "
    return env


def run_build(root: Path, sha, secrets):
    guard_file(root, DEPLOY_REL, set())
    script = (root / DEPLOY_REL).resolve()
    env = child_env(sha)
    proc = subprocess.run(
        ["bash", str(script), "build"],
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    cleaned, xtrace = redact(proc.stdout or "", secrets)
    note_detail(cleaned, [])
    if xtrace:
        fail("xtrace")
    if proc.returncode != 0:
        fail("staging-build")


def find_tar(root: Path, sha):
    name = f"staging-{sha}.tar.gz"
    found = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [
            item
            for item in dirnames
            if item != ".git" and not (Path(dirpath) / item).is_symlink()
        ]
        if name not in filenames:
            continue
        path = Path(dirpath) / name
        if path.is_symlink():
            fail("archive-link")
        found.append(path)
    if not found:
        return None
    if len(found) != 1:
        fail("archive-ambiguous")
    return found[0]


def curl_bin():
    if os.environ.get("STAGING_CURL_SELFTEST") == "1":
        binary = os.environ.get("STAGING_CURL", "")
        if binary:
            return binary
    return "curl"


def config_text(key, ip):
    return (
        f'header = "Authorization: Bearer {key}"\n'
        f'resolve = "{HOST}:443:{ip}"\n'
    )


def curl_env():
    env = {}
    for name in ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE"):
        value = os.environ.get(name)
        if value:
            env[name] = value
    if os.environ.get("STAGING_CURL_SELFTEST") == "1":
        for name in ("CURL_QUEUE", "CURL_RECORD", "CURL_COMMIT", "STAGING_CURL_SELFTEST"):
            value = os.environ.get(name)
            if value:
                env[name] = value
    return env


def accept_200(body, sha):
    text = body.decode("utf-8", errors="replace").strip()
    if not text:
        return True
    if not text.startswith("{"):
        return True
    import json

    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return False
    if not isinstance(data, dict):
        return False
    if data.get("success") is False:
        return False
    commit = data.get("commit")
    if commit is None:
        return True
    return commit == sha


def post_once(archive: Path, sha, key, ip):
    if not valid_key(key) or not valid_ip(ip):
        fail("deploy-secret")
    if sha not in archive.name or not archive.is_file() or archive.is_symlink():
        fail("archive-missing")
    arc = str(archive)
    if any(c in arc for c in "\r\n;\"`"):
        fail("archive-member")
    body = tempfile.NamedTemporaryFile(prefix="staging-body-", delete=False)
    body.close()
    os.chmod(body.name, 0o600)
    cmd = [
        curl_bin(),
        "--config",
        "-",
        "--silent",
        "--show-error",
        "--proto",
        "=https",
        "--max-redirs",
        "0",
        "--connect-timeout",
        str(CONNECT_TIMEOUT),
        "--max-time",
        str(CURL_MAX_TIME),
        "--request",
        "POST",
        "--form-string",
        f"sha={sha}",
        "--form",
        f"archive=@{arc};filename=staging-{sha}.tar.gz;type=application/gzip",
        "--output",
        body.name,
        "--write-out",
        "%{http_code}",
        "--url",
        URL,
    ]
    joined = "\n".join(cmd)
    if key in joined or ip in joined or "-H" in cmd or "--header" in cmd:
        Path(body.name).unlink(missing_ok=True)
        fail("deploy-argv")
    try:
        proc = subprocess.run(
            cmd,
            input=config_text(key, ip).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=curl_env(),
            check=False,
        )
        note_detail(proc.stderr.decode("utf-8", errors="replace"), [key, ip])
        raw = proc.stdout.decode("utf-8", errors="replace").strip()
        code = raw if re.fullmatch(r"[0-9]{3}", raw) else "000"
        payload = b""
        path = Path(body.name)
        if path.is_file() and path.stat().st_size <= 65536:
            payload = path.read_bytes()
        note_detail(f"HTTP_RESULT code={code} body={payload.decode('utf-8', errors='replace')[:500]}", [key, ip])
        return code, payload
    finally:
        Path(body.name).unlink(missing_ok=True)


def pause(seconds):
    if os.environ.get("STAGING_NO_SLEEP") == "1":
        return
    time.sleep(seconds)


def post_archive(archive: Path, sha, key, ip):
    for attempt, delay in enumerate(RETRY_SLEEPS):
        code, body = post_once(archive, sha, key, ip)
        if code == "200":
            if not accept_200(body, sha):
                fail("version")
            return
        if code != "409":
            fail_http(code)
        pause(delay)
        del attempt
    code, body = post_once(archive, sha, key, ip)
    if code == "200":
        if not accept_200(body, sha):
            fail("version")
        return
    fail_http(code)


def delete_archives(root: Path, sha):
    name = f"staging-{sha}.tar.gz"
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [
            item
            for item in dirnames
            if item != ".git" and not (Path(dirpath) / item).is_symlink()
        ]
        if name not in filenames:
            continue
        path = Path(dirpath) / name
        if path.is_file() and not path.is_symlink():
            path.unlink()


def locate_archive(root: Path, sha):
    found = find_tar(root, sha)
    owned = None
    if found is not None:
        assess_tar(found)
        return found, owned
    dist = root / "staging-dist"
    if not dist.is_dir() or dist.is_symlink():
        fail("archive-missing")
    owned = Path(tempfile.mkdtemp(prefix="staging-pack-")) / f"staging-{sha}.tar.gz"
    pack_tree(dist, owned)
    return owned, owned.parent


def deploy():
    key = os.environ.pop(KEY_NAME, "")
    ip = os.environ.pop(IP_NAME, "")
    mask(key)
    mask(ip)
    secrets = [item for item in (key, ip) if len(item) >= 8]
    if not valid_key(key) or not valid_ip(ip):
        fail("deploy-secret")
    sha = expect_sha()
    root = Path(".").resolve()
    check_head(sha)
    archive = None
    owned_dir = None
    try:
        run_build(root, sha, secrets)
        ok("staging-build")
        archive, owned_dir = locate_archive(root, sha)
        if os.environ.get("STAGING_CURL_SELFTEST") == "1":
            os.environ["CURL_COMMIT"] = sha
        post_archive(archive, sha, key, ip)
        ok("deploy http=200")
        clear_detail()
    finally:
        delete_archives(root, sha)
        if archive is not None and archive.is_file() and not archive.is_symlink():
            archive.unlink()
        if owned_dir is not None:
            for child in owned_dir.glob("staging-*.tar.gz"):
                if child.is_file() and not child.is_symlink():
                    child.unlink()
            try:
                owned_dir.rmdir()
            except OSError:
                pass


def contract():
    key = os.environ.get(KEY_NAME, "")
    ip = os.environ.get(IP_NAME, "")
    mask(key)
    mask(ip)
    if not valid_key(key) or not valid_ip(ip):
        fail("deploy-secret")
    ok("contract")


def scan_sources():
    workflow = (ROOT / ".github/workflows/staging-webhook-deploy.yml").read_text(encoding="utf-8")
    script = Path(__file__).read_text(encoding="utf-8")
    doc = (ROOT / ".github/staging-webhook-deploy.md").read_text(encoding="utf-8")
    purge = (ROOT / ".github/scripts/purge-gate-logs.sh").read_text(encoding="utf-8")
    poll = (ROOT / ".github/scripts/poll-gates.sh").read_text(encoding="utf-8")
    if URL not in script or URL not in doc:
        fail("selftest-url")
    if IPV4.search(script) or IPV4.search(workflow) or IPV4.search(doc):
        fail("selftest-ip-literal")
    if SET_X_CMD.search(workflow):
        fail("selftest-xtrace")
    if "set +x" not in workflow:
        fail("selftest-xtrace")
    for name in (KEY_NAME, IP_NAME, "PRIVATE_REPO_ACCESS_TOKEN"):
        if f"secrets.{name}" not in workflow:
            fail("selftest-secret-name")
    if "STAGING_CURL_SELFTEST" in workflow or "\ncurl " in workflow or "--header" in workflow:
        fail("selftest-workflow")
    allowed = {
        "PRIVATE_REPO_ACCESS_TOKEN",
        KEY_NAME,
        IP_NAME,
        "GATE_LOG_KEY",
    }
    for match in re.finditer(r"secrets\.([A-Z0-9_]+)", workflow):
        if match.group(1) not in allowed:
            fail("selftest-secret-name")
    prod = KEY_NAME[len("STAGING_") :]
    if prod in workflow.replace(KEY_NAME, ""):
        fail("selftest-prod-secret")
    if "staging-webhook-deploy.yml" not in purge:
        fail("selftest-purge")
    if "staging-webhook-deploy.yml" in poll:
        fail("selftest-poll")


def selftest():
    scan_sources()
    assert guard_text("set -euo pipefail\nprintf 'build'\n") == ""
    assert guard_text("set -x\n") == "rejected-xtrace"
    assert guard_text("set -eux\n") == "rejected-xtrace"
    assert guard_text('echo "$STAGING_WEBHOOK_DEPLOY_KEY"\n') == "rejected-secret-print"
    assert guard_text('printf "%s" "$STAGING_ORIGIN_IP"\n') == "rejected-secret-print"
    assert guard_text("echo STAGING_ORIGIN_IP is unset\n") == ""
    ip_literal = ".".join(["10", "1", "2", "3"])
    assert guard_text(f"host={ip_literal}\n") == "rejected-ipv4"
    assert guard_text("curl -v https://example.com\n") == "rejected-verbose-curl"
    assert guard_text("git clone https://example.com/secrets.git\n") == "rejected-source-dump"
    sample_ip = ".".join(["203", "0", "113", "10"])
    cleaned, xtrace = redact(
        "\n".join(
            [
                "+__PB_XTRACE__ curl secret",
                "+ async 2.11.0",
                "Authorization: Bearer deploy-key-value-0123",
                f"dial {sample_ip}",
                "ok",
            ]
        )
        + "\n",
        ["deploy-key-value-0123"],
    )
    assert xtrace == 1
    assert "+__PB_XTRACE__" not in cleaned
    assert "+ async 2.11.0" in cleaned
    assert "deploy-key-value-0123" not in cleaned
    assert sample_ip not in cleaned
    assert "ok" in cleaned
    assert valid_key("short") is False
    assert valid_key("deploy-key-value-0123") is True
    assert valid_key("deploy-key-value-0123\n") is False
    assert valid_ip(sample_ip) is True
    assert valid_ip("10.1.2") is False
    assert valid_ip(".".join(["10", "1", "2", "300"])) is False
    assert assess_members(
        [
            ("daymica-server", "file", 4),
            ("web", "dir", 0),
            ("web/index.html", "file", 4),
            ("seed-e2e-account", "file", 2),
            ("prod-sql-gate", "file", 2),
        ],
        100,
    ) == ""
    assert assess_members([("daymica-server", "file", 4), ("web/index.html", "file", 1)], 10) == ""
    assert assess_members([("web/index.html", "file", 1)], 10) == "archive-member"
    assert assess_members(
        [("daymica-server", "file", 4), ("web/index.html", "file", 1), ("nginx.conf", "file", 1)],
        10,
    ) == "archive-member"
    assert assess_members(
        [("daymica-server", "file", 4), ("../web/index.html", "file", 1)],
        10,
    ) == "archive-member"
    assert assess_members(
        [("daymica-server", "link", 0), ("web/index.html", "file", 1)],
        10,
    ) == "archive-link"
    assert assess_members(
        [("daymica-server", "file", 4), ("web/index.html", "file", MAX_RAW)],
        10,
    ) == "archive-size"
    assert assess_members(
        [("daymica-server", "file", 4), ("web/index.html", "file", 1)],
        MAX_GZIP + 1,
    ) == "archive-size"
    assert accept_200(b"", "a" * 40) is True
    sha = "0123456789abcdef0123456789abcdef01234567"
    assert accept_200(
        ('{"success":true,"message":"installed","commit":"%s"}' % sha).encode(),
        sha,
    )
    assert accept_200(b'{"success":true,"commit":"ffffffffffffffffffffffffffffffffffffffff"}', sha) is False
    assert accept_200(b'{"success":false,"commit":"%s"}' % sha.encode(), sha) is False

    cfg = config_text("deploy-key-value-0123", sample_ip)
    assert "Authorization: Bearer deploy-key-value-0123" in cfg
    assert f"resolve = \"{HOST}:443:{sample_ip}\"" in cfg
    argv = ["curl", "--config", "-", "--form-string", f"sha={sha}", "--url", URL]
    assert "deploy-key-value-0123" not in "\n".join(argv)
    assert sample_ip not in "\n".join(argv)

    syntax_ip = ".".join(["127", "0", "0", "1"])
    syntax_key = "test-deploy-key-0123456789"
    syntax_host = "deploy-selftest.invalid"
    syntax = (
        f'header = "Authorization: Bearer {syntax_key}"\n'
        f'resolve = "{syntax_host}:443:{syntax_ip}"\n'
    )
    proc = subprocess.run(
        [
            "curl",
            "--config",
            "-",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--max-redirs",
            "0",
            "--connect-timeout",
            "2",
            "--max-time",
            "3",
            "--output",
            os.devnull,
            "--write-out",
            "%{http_code}",
            "--url",
            f"https://{syntax_host}/__staging-deploy",
        ],
        input=syntax.encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    err = proc.stderr.decode("utf-8", errors="replace").lower()
    if proc.returncode == 2 or "unknown option" in err or "error parsing" in err:
        fail("curl-config")
    if syntax_key.encode() in proc.stderr or syntax_key.encode() in proc.stdout:
        fail("curl-config-leak")
    if syntax_ip.encode() in proc.stderr or syntax_ip.encode() in proc.stdout:
        fail("curl-config-leak")

    saved = {name: os.environ.get(name) for name in (
        "GITHUB_RUN_ID",
        "GITHUB_SERVER_URL",
        "GITHUB_REPOSITORY",
        "STAGING_GIT_REF",
        "STAGING_SHA_INPUT",
        KEY_NAME,
        IP_NAME,
        "GITHUB_TOKEN",
    )}
    os.environ["GITHUB_RUN_ID"] = "42"
    os.environ["GITHUB_SERVER_URL"] = "https://github.com"
    os.environ["GITHUB_REPOSITORY"] = "zysicyj-xxc/public-builder"
    os.environ["STAGING_GIT_REF"] = "refs/heads/main"
    os.environ["STAGING_SHA_INPUT"] = ""
    os.environ[KEY_NAME] = "deploy-key-value-0123"
    os.environ[IP_NAME] = sample_ip
    os.environ["GITHUB_TOKEN"] = "selftest-token-value"
    try:
        env = child_env(sha)
    finally:
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    assert KEY_NAME not in env
    assert IP_NAME not in env
    assert "GITHUB_TOKEN" not in env
    assert "deploy-key-value-0123" not in env.values()
    assert sample_ip not in env.values()
    assert env["CNB_BRANCH"] == "main"
    assert env["CNB_COMMIT"] == sha
    assert env["PS4"] == "+__PB_XTRACE__ "
    os.environ["STAGING_SHA_INPUT"] = sha
    os.environ["STAGING_GIT_REF"] = "refs/heads/main"
    os.environ["GITHUB_RUN_ID"] = "42"
    os.environ["GITHUB_SERVER_URL"] = "https://github.com"
    os.environ["GITHUB_REPOSITORY"] = "zysicyj-xxc/public-builder"
    overridden = child_env(sha)
    assert "CNB_BRANCH" not in overridden
    os.environ.pop("STAGING_SHA_INPUT", None)

    tmp = Path(tempfile.mkdtemp(prefix="staging-selftest-"))
    try:
        _tar_cases(tmp)
        _tree_cases(tmp)
        _post_cases(tmp, sha, sample_ip)
        _deploy_case(tmp, sample_ip)
        xtrace_dir = tmp / "xtrace-run"
        xtrace_dir.mkdir()
        _deploy_case(
            xtrace_dir,
            sample_ip,
            xtrace_hook="trace_opt=-x\nbash \"$trace_opt\" -c true\n",
        )
    finally:
        import shutil

        shutil.rmtree(tmp, ignore_errors=True)
    ok("selftest")


def _tar_add(path, members):
    with tarfile.open(path, "w:gz") as handle:
        for name, kind, content in members:
            info = tarfile.TarInfo(name)
            if kind == "file":
                data = content.encode()
                info.size = len(data)
                info.type = tarfile.REGTYPE
                handle.addfile(info, io.BytesIO(data))
            elif kind == "dir":
                info.type = tarfile.DIRTYPE
                handle.addfile(info)
            elif kind == "sym":
                info.type = tarfile.SYMTYPE
                info.linkname = content
                handle.addfile(info)
            elif kind == "lnk":
                info.type = tarfile.LNKTYPE
                info.linkname = content
                handle.addfile(info)


def _expect_fail(want, fn):
    text = _capture_fail(fn)
    if text.strip() != f"FAIL {want}":
        fail("selftest-mismatch")


def _tar_cases(tmp: Path):
    good = tmp / "good.tar.gz"
    _tar_add(
        good,
        [
            ("daymica-server", "file", "bin"),
            ("web", "dir", ""),
            ("web/index.html", "file", "page"),
            ("seed-e2e-account", "file", "seed"),
        ],
    )
    assess_tar(good)
    bad_link = tmp / "link.tar.gz"
    _tar_add(
        bad_link,
        [
            ("daymica-server", "file", "bin"),
            ("web/index.html", "sym", "daymica-server"),
        ],
    )
    _expect_fail("archive-link", lambda: assess_tar(bad_link))
    hard = tmp / "hard.tar.gz"
    _tar_add(
        hard,
        [
            ("daymica-server", "file", "bin"),
            ("web/index.html", "lnk", "daymica-server"),
        ],
    )
    _expect_fail("archive-link", lambda: assess_tar(hard))
    slip = tmp / "slip.tar.gz"
    _tar_add(
        slip,
        [
            ("daymica-server", "file", "bin"),
            ("web/../../etc/passwd", "file", "x"),
        ],
    )
    _expect_fail("archive-member", lambda: assess_tar(slip))
    extra = tmp / "extra.tar.gz"
    _tar_add(
        extra,
        [
            ("daymica-server", "file", "bin"),
            ("web/index.html", "file", "page"),
            ("nginx.conf", "file", "server{}"),
        ],
    )
    _expect_fail("archive-member", lambda: assess_tar(extra))


def _tree_cases(tmp: Path):
    dist = tmp / "dist"
    web = dist / "web"
    web.mkdir(parents=True)
    (dist / "daymica-server").write_text("bin", encoding="utf-8")
    (web / "index.html").write_text("page", encoding="utf-8")
    dest = tmp / "packed.tar.gz"
    pack_tree(dist, dest)
    assess_tar(dest)
    linked = tmp / "linked"
    (linked / "web").mkdir(parents=True)
    server = linked / "daymica-server"
    server.write_text("bin", encoding="utf-8")
    (linked / "web" / "index.html").write_text("page", encoding="utf-8")
    (linked / "web" / "alias").symlink_to("index.html")
    _expect_fail("archive-link", lambda: pack_tree(linked, tmp / "nope.tar.gz"))
    assert not (tmp / "nope.tar.gz").exists()
    hard = tmp / "hardtree"
    (hard / "web").mkdir(parents=True)
    src = hard / "daymica-server"
    src.write_text("bin", encoding="utf-8")
    (hard / "web" / "index.html").write_text("page", encoding="utf-8")
    os.link(src, hard / "seed-e2e-account")
    _expect_fail("archive-link", lambda: assess_tree(hard))


def _write_fake_curl(tmp: Path):
    path = tmp / "curl"
    path.write_text(
        """#!/usr/bin/env python3
import os, pathlib, sys
record = pathlib.Path(os.environ["CURL_RECORD"])
queue = pathlib.Path(os.environ["CURL_QUEUE"])
stdin = sys.stdin.read()
with record.open("a", encoding="utf-8") as fh:
    fh.write("---\\n")
    fh.write("\\n".join(sys.argv[1:]))
    fh.write("\\nSTDIN\\n")
    fh.write(stdin)
    fh.write("\\n")
lines = queue.read_text(encoding="utf-8").splitlines()
code = lines[0] if lines else "200"
queue.write_text("\\n".join(lines[1:]) + ("\\n" if lines[1:] else ""), encoding="utf-8")
if "--output" in sys.argv:
    out = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
    commit = os.environ.get("CURL_COMMIT", "")
    out.write_text('{"success":true,"message":"installed","commit":"%s"}' % commit, encoding="utf-8")
sys.stdout.write(code)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)
    return path


def _post_setup(tmp: Path, codes, sha):
    tmp.mkdir(parents=True, exist_ok=True)
    queue = tmp / "queue"
    record = tmp / "record"
    queue.write_text("\n".join(codes) + "\n", encoding="utf-8")
    record.write_text("", encoding="utf-8")
    os.environ["STAGING_CURL_SELFTEST"] = "1"
    os.environ["STAGING_CURL"] = str(_write_fake_curl(tmp))
    os.environ["CURL_QUEUE"] = str(queue)
    os.environ["CURL_RECORD"] = str(record)
    os.environ["CURL_COMMIT"] = sha
    os.environ["STAGING_NO_SLEEP"] = "1"
    return record


def _records(record: Path):
    text = record.read_text(encoding="utf-8")
    return [part for part in text.split("---\n") if part.strip()]


def _assert_request(record: Path, key, ip, sha):
    calls = _records(record)
    if not calls:
        fail("selftest-curl")
    for call in calls:
        argv, _, stdin = call.partition("\nSTDIN\n")
        if key in argv or ip in argv:
            fail("selftest-argv")
        if "-H\n" in argv or "\n--header\n" in f"\n{argv}\n":
            fail("selftest-header-arg")
        if key not in stdin or ip not in stdin:
            fail("selftest-config")
        if URL not in argv:
            fail("selftest-url")
        if "nginx" in argv or "nginx" in stdin:
            fail("selftest-nginx")
        sha_at = argv.find(f"sha={sha}")
        arc_at = argv.find("archive=@")
        if sha_at < 0 or arc_at < 0 or sha_at > arc_at:
            fail("selftest-order")
        args = [line for line in argv.split("\n") if line != ""]
        if "--config" not in args or args[args.index("--config") + 1] != "-":
            fail("selftest-config")
    return calls


def _capture_fail(fn):
    err = io.StringIO()
    out = io.StringIO()
    old_err, old_out = sys.stderr, sys.stdout
    sys.stderr, sys.stdout = err, out
    try:
        try:
            fn()
        except SystemExit:
            pass
        else:
            sys.stderr, sys.stdout = old_err, old_out
            fail("selftest-expected-fail")
    finally:
        sys.stderr, sys.stdout = old_err, old_out
    return out.getvalue() + err.getvalue()


def _post_cases(tmp: Path, sha, ip):
    key = "deploy-key-value-0123"
    archive = tmp / f"staging-{sha}.tar.gz"
    _tar_add(
        archive,
        [
            ("daymica-server", "file", "bin"),
            ("web", "dir", ""),
            ("web/index.html", "file", "page"),
        ],
    )
    record = _post_setup(tmp, ["200"], sha)
    post_archive(archive, sha, key, ip)
    calls = _assert_request(record, key, ip, sha)
    if len(calls) != 1:
        fail("selftest-200")

    for code in ("400", "401", "413", "500", "502", "504", "000"):
        record = _post_setup(tmp / code, [code], sha)
        text = _capture_fail(lambda: post_archive(archive, sha, key, ip))
        if text.strip() != f"FAIL deploy http={code}":
            fail("selftest-status")
        if key in text or ip in text:
            fail("selftest-leak")
        if len(_records(record)) != 1:
            fail("selftest-noretry")

    record = _post_setup(tmp / "retry", ["409", "409", "200"], sha)
    post_archive(archive, sha, key, ip)
    if len(_assert_request(record, key, ip, sha)) != 3:
        fail("selftest-409")

    record = _post_setup(tmp / "stop", ["409", "504"], sha)
    text = _capture_fail(lambda: post_archive(archive, sha, key, ip))
    if text.strip() != "FAIL deploy http=504":
        fail("selftest-504")
    if len(_records(record)) != 2:
        fail("selftest-504")

    record = _post_setup(tmp / "exhaust", ["409"] * 6, sha)
    text = _capture_fail(lambda: post_archive(archive, sha, key, ip))
    if text.strip() != "FAIL deploy http=409":
        fail("selftest-exhaust")
    if len(_records(record)) != 6:
        fail("selftest-exhaust")

    os.environ["CURL_COMMIT"] = "ffffffffffffffffffffffffffffffffffffffff"
    record = _post_setup(tmp / "badcommit", ["200"], sha)
    os.environ["CURL_COMMIT"] = "ffffffffffffffffffffffffffffffffffffffff"
    text = _capture_fail(lambda: post_archive(archive, sha, key, ip))
    if text.strip() != "FAIL version":
        fail("selftest-version")
    if key in text or ip in text:
        fail("selftest-leak")


def _deploy_case(tmp: Path, ip, xtrace_hook=""):
    repo = tmp / "repo"
    repo.mkdir()
    script_dir = repo / "scripts" / "ci"
    script_dir.mkdir(parents=True)
    (script_dir / "staging-deploy.sh").write_text(
        """#!/bin/bash
set -euo pipefail
if [ "${1:-}" != "build" ]; then
  exit 9
fi
printf '+ async 2.11.0\\n'
"""
        + xtrace_hook
        + """mkdir -p web
printf 'bin' > daymica-server
printf 'page' > web/index.html
tar -czf "staging-${GITHUB_SHA}.tar.gz" daymica-server web
""",
        encoding="utf-8",
    )
    subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "selftest@example.com"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "selftest"], check=True)
    subprocess.run(["git", "-C", str(repo), "add", "scripts/ci/staging-deploy.sh"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "selftest"], check=True)
    sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    detail = tmp / "detail.log"
    key = "deploy-key-value-0123"
    saved = os.getcwd()
    previous = {
        name: os.environ.get(name)
        for name in (
            "EXPECT_SHA",
            "STAGING_GIT_REF",
            "STAGING_SHA_INPUT",
            "DETAIL_LOG",
            "GITHUB_RUN_ID",
            "GITHUB_SERVER_URL",
            "GITHUB_REPOSITORY",
            KEY_NAME,
            IP_NAME,
            "STAGING_CURL_SELFTEST",
            "GITHUB_ACTIONS",
        )
    }
    os.chdir(repo)
    os.environ["EXPECT_SHA"] = sha
    os.environ["STAGING_GIT_REF"] = "refs/heads/main"
    os.environ["STAGING_SHA_INPUT"] = ""
    os.environ["DETAIL_LOG"] = str(detail)
    os.environ["GITHUB_RUN_ID"] = "42"
    os.environ["GITHUB_SERVER_URL"] = "https://github.com"
    os.environ["GITHUB_REPOSITORY"] = "zysicyj-xxc/public-builder"
    os.environ[KEY_NAME] = key
    os.environ[IP_NAME] = ip
    os.environ["STAGING_CURL_SELFTEST"] = "1"
    os.environ.pop("GITHUB_ACTIONS", None)
    out = io.StringIO()
    err = io.StringIO()
    record = _post_setup(tmp / "deploy", ["200"], sha)
    try:
        old_out, old_err = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = out, err
        try:
            deploy()
        except SystemExit:
            if not xtrace_hook:
                raise
        finally:
            sys.stdout, sys.stderr = old_out, old_err
    finally:
        os.chdir(saved)
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    text = out.getvalue() + err.getvalue()
    if xtrace_hook:
        if text.strip() != "FAIL xtrace":
            fail("selftest-xtrace")
        if key in text or ip in text or URL in text:
            fail("selftest-leak")
        if _records(record):
            fail("selftest-xtrace")
        if not detail.exists():
            fail("selftest-xtrace")
        body = detail.read_text(encoding="utf-8", errors="replace")
        if key in body or ip in body:
            fail("selftest-leak")
        if "+__PB_XTRACE__" in body or "+ async 2.11.0" not in body:
            fail("selftest-xtrace")
        return
    if "PASS staging-build" not in text or "PASS deploy http=200" not in text:
        fail("selftest-deploy")
    if key in text or ip in text or URL in text:
        fail("selftest-leak")
    calls = _assert_request(record, key, ip, sha)
    if len(calls) != 1:
        fail("selftest-deploy")
    if detail.exists():
        body = detail.read_text(encoding="utf-8", errors="replace")
        if key in body or ip in body:
            fail("selftest-leak")
    if list(repo.glob("staging-*.tar.gz")):
        fail("selftest-leftover")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return 0
    if argv[1:] == ["contract"]:
        try:
            contract()
        except SystemExit:
            raise
        except Exception:
            print("FAIL deploy-error", file=sys.stderr)
            return 1
        return 0
    if argv[1:] == ["deploy"]:
        try:
            deploy()
        except SystemExit:
            raise
        except Exception:
            print("FAIL deploy-error", file=sys.stderr)
            return 1
        return 0
    fail("usage")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
