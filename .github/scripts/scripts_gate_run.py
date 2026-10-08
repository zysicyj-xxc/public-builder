#!/usr/bin/env python3
"""Plan and run the scripts gate. Prints paths, exit codes, and skip reasons only."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LAYOUT_CONTEXT = "layout + domain gates"
TEST_PATH = re.compile(r"^scripts/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.tests\.ps1$")
LAYOUT_PATH = re.compile(r"^scripts/(?:[A-Za-z0-9._-]+/)*assert-scripts-layout\.ps1$")
DOMAIN_PATH = re.compile(r"^scripts/(?:[A-Za-z0-9._-]+/)*assert-domain-registry\.ps1$")
CONTEXT_OK = re.compile(r"^[A-Za-z0-9 ._+/()-]{1,200}$")
DESC_OK = re.compile(r"^[a-z0-9-]{1,40}$")

DESKTOP = re.compile(
    r"(?i)(UIAutomation|System\.Windows\.Forms|System\.Windows\.Automation|"
    r"SendKeys|user32\.dll|WScript\.Shell|ShowWindow|WinAppDriver|"
    r"New-Object\s+-ComObject\s+WScript|flutter\s+run|\badb(\.exe)?\b)"
)
EXTERNAL = re.compile(
    r"(?i)(Invoke-WebRequest|Invoke-RestMethod|\bcurl(\.exe)?\b|\bmysql\b|"
    r"MySqlConnection|SqlConnection|Test-NetConnection|docker-compose|"
    r"System\.Net\.Http\.HttpClient|System\.Net\.Sockets\.TcpClient|"
    r"Invoke-Sqlcmd|New-PSSession)"
)
SENSITIVE = re.compile(
    r"(?i)(?:password|passwd|pwd|secret|api[_-]?key|connectionstring|data source)"
    r"\s*[:=]\s*['\"][^'\"]{3,}['\"]"
    r"|(?:mysql|postgres(?:ql)?|mongodb|redis)://\S+"
    r"|\b(?:user\s+id|uid|pwd)\s*=\s*\S+"
)
PRINT_CALL = re.compile(r"(?i)(Write-Host|Write-Output|Out-Host|Console\.Write)")
ENV_SECRET = re.compile(
    r"(?i)(\$env:(DSN|PASSWORD|SECRET|TOKEN|CONNECTION|MYSQL)|"
    r"Get-Content[^\n]{0,80}(\.env|appsettings|credentials))"
)
SOURCE_RE = re.compile(
    r"""(?im)^\s*\.\s+(?:['"])?((?:\.|\.\.|scripts)[/\\][^'"\s;]+)"""
)
PESTER_RE = re.compile(r"(?m)^\s*(Describe|Context|It|BeforeAll|BeforeEach)\s+")
PRIVATE_IP = re.compile(
    r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|"
    r"172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|"
    r"100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b"
)
USERINFO = re.compile(r"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@", re.I)
TOKEN_LEAK = re.compile(r"\b(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]+")

MAX_READ = 512_000
MAX_OUT_LINES = 150
MAX_OUT_CHARS = 20_000


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def classify_text(text):
    if "\x00" in text:
        return "skipped-external"
    if SENSITIVE.search(text) or (PRINT_CALL.search(text) and ENV_SECRET.search(text)):
        return "skipped-sensitive"
    if EXTERNAL.search(text):
        return "skipped-external"
    if DESKTOP.search(text):
        return "skipped-desktop"
    return None


def output_problem(text):
    if not text:
        return None
    if TOKEN_LEAK.search(text) or USERINFO.search(text) or PRIVATE_IP.search(text):
        return "suppressed-sensitive"
    if SENSITIVE.search(text):
        return "suppressed-sensitive"
    return None


def safe_path(root, rel):
    root_p = Path(root).resolve()
    rel_s = rel.replace("\\", "/")
    if rel_s.startswith("/") or ".." in Path(rel_s).parts:
        return None
    path = (root_p / rel_s).resolve()
    if path != root_p and root_p not in path.parents:
        return None
    return path


def read_text(root, rel):
    path = safe_path(root, rel)
    if path is None or not path.is_file():
        return None
    if path.stat().st_size > MAX_READ:
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def classify_file(root, rel, depth=0):
    text = read_text(root, rel)
    if text is None:
        return "skipped-external" if depth else None
    hit = classify_text(text)
    if hit or depth >= 2:
        return hit
    base = Path(rel.replace("\\", "/")).parent
    for raw in SOURCE_RE.findall(text):
        norm = raw.replace("\\", "/")
        if norm.startswith("scripts/"):
            child = norm
        else:
            child = str((base / norm).as_posix())
        child_hit = classify_file(root, child, depth + 1)
        if child_hit:
            return child_hit
    return None


def matching(paths, pattern):
    return sorted(p for p in paths if pattern.fullmatch(p))


def select_tests(paths):
    tests = matching(paths, TEST_PATH)
    if not tests:
        fail("no scripts/**/*.tests.ps1")
    for p in tests:
        if not CONTEXT_OK.fullmatch(p):
            fail("test path failed allowlist")
    return tests


def select_asserts(paths):
    layout = matching(paths, LAYOUT_PATH)
    domain = matching(paths, DOMAIN_PATH)
    if not layout:
        names = sorted(p for p in paths if p.startswith("scripts/") and "/assert-" in f"/{p}" and p.endswith(".ps1"))
        print("assert scripts found:")
        for name in names:
            print(name)
        fail("missing assert-scripts-layout.ps1")
    if not domain:
        names = sorted(p for p in paths if p.startswith("scripts/") and p.endswith(".ps1") and "assert-" in p)
        print("assert scripts found:")
        for name in names:
            print(name)
        fail("missing assert-domain-registry.ps1")
    return layout, domain


def tree_paths(doc):
    if doc.get("truncated"):
        fail("git tree truncated")
    paths = []
    for item in doc.get("tree") or []:
        if item.get("type") != "blob":
            continue
        path = item.get("path") or ""
        if path.startswith("scripts/") and path.endswith(".ps1"):
            paths.append(path)
    return paths


def write_tests_output(dest, tests):
    payload = json.dumps(tests, separators=(",", ":"))
    with open(dest, "a", encoding="utf-8") as fh:
        fh.write(f"tests<<EOF\n{payload}\nEOF\n")


def scrub_env():
    env = os.environ.copy()
    for key in list(env):
        upper = key.upper()
        if any(part in upper for part in ("TOKEN", "SECRET", "PASSWORD", "PASSWD", "PWD", "DSN", "CREDENTIAL")):
            env.pop(key, None)
    env["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
    env["POWERSHELL_UPDATECHECK"] = "Off"
    return env


def run_pwsh(args, cwd, env, timeout):
    proc = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        errors="replace",
        timeout=timeout,
        check=False,
    )
    return proc.returncode, proc.stdout or "", proc.stderr or ""


def emit_output(label, code, out, err):
    problem = output_problem(out) or output_problem(err)
    if problem:
        print(f"{label} exit={code} output={problem}")
        return
    text = out + (("\n" + err) if err else "")
    lines = text.splitlines()
    clipped = False
    if len(lines) > MAX_OUT_LINES:
        lines = lines[:MAX_OUT_LINES]
        clipped = True
    shown = "\n".join(lines)
    if len(shown) > MAX_OUT_CHARS:
        shown = shown[:MAX_OUT_CHARS]
        clipped = True
    if shown:
        print(shown)
    print(f"{label} exit={code}" + (" output=truncated" if clipped else ""))


PESTER_BOOT = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not (Get-Module -ListAvailable -Name Pester)) {
  Install-Module Pester -Scope CurrentUser -Force -MinimumVersion 5.5.0 -MaximumVersion 5.99.0 -ErrorAction Stop
}
Write-Output 'pester-ready'
"""

PESTER_RUN = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module Pester -MinimumVersion 5.0.0
$cfg = New-PesterConfiguration
$cfg.Run.Path = $env:SCRIPT_GATE_TEST
$cfg.Run.Exit = $true
$cfg.Output.Verbosity = 'Minimal'
Invoke-Pester -Configuration $cfg
"""


def ensure_pester(cwd):
    if shutil.which("pwsh") is None:
        fail("pwsh not on PATH")
    code, out, err = run_pwsh(
        ["pwsh", "-NoProfile", "-NonInteractive", "-Command", PESTER_BOOT],
        cwd,
        scrub_env(),
        180,
    )
    emit_output("pester", code, out, err)
    if code != 0:
        fail("could not load Pester")


def run_script(cwd, rel, pester, env):
    if pester:
        child = env.copy()
        child["SCRIPT_GATE_TEST"] = rel
        return run_pwsh(
            ["pwsh", "-NoProfile", "-NonInteractive", "-Command", PESTER_RUN],
            cwd,
            child,
            600,
        )
    return run_pwsh(
        ["pwsh", "-NoProfile", "-NonInteractive", "-File", rel],
        cwd,
        env,
        600,
    )


def record(rows, context, state, desc):
    if not CONTEXT_OK.fullmatch(context) or state not in ("success", "failure") or not DESC_OK.fullmatch(desc):
        fail("refusing to record a bad result row")
    rows.append((context, state, desc))
    print(f"RESULT {context} {state} {desc}")


def cmd_from_tree(tree_file, output_file):
    doc = json.loads(Path(tree_file).read_text(encoding="utf-8"))
    paths = tree_paths(doc)
    layout, domain = select_asserts(paths)
    tests = select_tests(paths)
    for path in layout + domain:
        print(f"assert {path}")
    for path in tests:
        print(f"test {path}")
    write_tests_output(output_file, tests)


def cmd_run():
    tests = json.loads(os.environ.get("TESTS_JSON") or "")
    if not isinstance(tests, list) or not tests:
        fail("TESTS_JSON is empty")
    for rel in tests:
        if not isinstance(rel, str) or not TEST_PATH.fullmatch(rel):
            fail("TESTS_JSON failed allowlist")
    root = Path.cwd()
    if not (root / "scripts").is_dir():
        fail("missing scripts/")
    rows = []
    disk = []
    for path in root.joinpath("scripts").rglob("*.ps1"):
        if path.is_file():
            disk.append(path.relative_to(root).as_posix())
    layout, domain = select_asserts(disk)
    env = scrub_env()
    layout_state = "success"
    # Assert scripts are the gate, not the skippable matrix. Output filtering
    # still drops secret-shaped text before it reaches the log.
    for rel in layout + domain:
        print(f"RUN {rel}")
        try:
            code, out, err = run_script(root, rel, False, env)
        except subprocess.TimeoutExpired:
            print(f"RUN {rel} timeout")
            layout_state = "failure"
            continue
        emit_output(rel, code, out, err)
        if code != 0:
            layout_state = "failure"
    record(rows, LAYOUT_CONTEXT, layout_state, "success" if layout_state == "success" else "failure")

    needs_pester = False
    planned = []
    for rel in tests:
        if not (root / rel).is_file():
            planned.append((rel, "missing"))
            continue
        text = read_text(root, rel) or ""
        hit = classify_file(root, rel)
        planned.append((rel, hit, bool(PESTER_RE.search(text))))
        if hit is None and PESTER_RE.search(text):
            needs_pester = True
    if needs_pester:
        ensure_pester(root)
    for item in planned:
        rel = item[0]
        if item[1] == "missing":
            record(rows, rel, "failure", "failure")
            continue
        hit = item[1]
        if hit:
            print(f"SKIP {rel} {hit}")
            record(rows, rel, "success", hit)
            continue
        print(f"RUN {rel}")
        try:
            code, out, err = run_script(root, rel, item[2], env)
        except subprocess.TimeoutExpired:
            print(f"RUN {rel} timeout")
            record(rows, rel, "failure", "failure")
            continue
        emit_output(rel, code, out, err)
        record(rows, rel, "success" if code == 0 else "failure", "success" if code == 0 else "failure")

    dest = os.environ.get("RESULTS_PATH")
    if not dest:
        fail("RESULTS_PATH is empty")
    lines = [f"{ctx}\t{state}\t{desc}\n" for ctx, state, desc in rows]
    Path(dest).write_text("".join(lines), encoding="utf-8")
    if any(state != "success" for _, state, _ in rows):
        raise SystemExit(1)


def selftest():
    assert classify_text("Describe 'layout' { It 'ok' { 1 | Should -Be 1 } }") is None
    assert classify_text("name = 'password-vault'") is None
    assert classify_text('password = "example-not-real"') == "skipped-sensitive"
    assert classify_text('Write-Host $env:DSN\n') == "skipped-sensitive"
    assert classify_text("Invoke-WebRequest https://example.test") == "skipped-external"
    assert classify_text("Add-Type UIAutomation") == "skipped-desktop"
    assert output_problem("listening on 10.1.2.3") == "suppressed-sensitive"
    assert output_problem("https://user:example-not-real@example.test") == "suppressed-sensitive"
    assert output_problem("ghs_" + "a" * 20) == "suppressed-sensitive"
    assert output_problem("scripts/lib/foo.ps1 ok") is None
    doc = {
        "truncated": False,
        "tree": [
            {"path": "scripts/lib/assert-scripts-layout.ps1", "type": "blob"},
            {"path": "scripts/lib/assert-domain-registry.ps1", "type": "blob"},
            {"path": "scripts/layout.tests.ps1", "type": "blob"},
            {"path": "scripts/nested/name.tests.ps1", "type": "blob"},
            {"path": "README.md", "type": "blob"},
            {"path": "apps/foo.tests.ps1", "type": "blob"},
            {"path": "scripts/lib", "type": "tree"},
        ],
    }
    paths = tree_paths(doc)
    layout, domain = select_asserts(paths)
    tests = select_tests(paths)
    assert layout == ["scripts/lib/assert-scripts-layout.ps1"]
    assert domain == ["scripts/lib/assert-domain-registry.ps1"]
    assert tests == ["scripts/layout.tests.ps1", "scripts/nested/name.tests.ps1"]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "scripts").mkdir()
        (root / "scripts" / "layout.tests.ps1").write_text(
            "Describe 'x' { It 'y' { 'password-vault' | Should -Be 'password-vault' } }\n",
            encoding="utf-8",
        )
        assert classify_file(root, "scripts/layout.tests.ps1") is None
        (root / "scripts" / "secret.tests.ps1").write_text(
            'Describe "s" { It "s" { $p = "x"; password = "example-not-real" } }\n',
            encoding="utf-8",
        )
        assert classify_file(root, "scripts/secret.tests.ps1") == "skipped-sensitive"
        (root / "scripts" / "caller.tests.ps1").write_text(
            ". ./scripts/child.ps1\nDescribe 'c' { It 'c' { 1 } }\n",
            encoding="utf-8",
        )
        (root / "scripts" / "child.ps1").write_text(
            "Invoke-RestMethod https://example.test\n",
            encoding="utf-8",
        )
        assert classify_file(root, "scripts/caller.tests.ps1") == "skipped-external"
        outside = Path(tmp) / "scripts" / "escape.tests.ps1"
        outside.write_text(". ./../../etc/passwd\n", encoding="utf-8")
        assert classify_file(root, "scripts/escape.tests.ps1") in (None, "skipped-external")
    try:
        tree_paths({"truncated": True, "tree": []})
    except SystemExit:
        pass
    else:
        raise SystemExit("truncated tree should fail")
    print("scripts-gate selftest ok")


def main():
    args = sys.argv[1:]
    if args == ["--selftest"]:
        selftest()
        return
    if len(args) == 3 and args[0] == "--from-tree":
        cmd_from_tree(args[1], args[2])
        return
    if args == ["--run"]:
        cmd_run()
        return
    fail("usage: --selftest | --from-tree TREE OUTPUT | --run")


if __name__ == "__main__":
    main()
