#!/usr/bin/env python3
"""Optional CNB writeback. No token: exit 0. Never prints the token or response bodies.

Results TSV columns: context, state, description.
Commit status POST uses the public CNB path. PR comments use the documented
comments API. Commit annotations are only a fallback when the status endpoint
is missing, so a push with no PR still leaves a mark when the token allows it.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.cnb.cool"
REPO = "zysicyj.top/zysicyj-xxc/zysicyj"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PR_RE = re.compile(r"^[0-9]{1,10}$")
BUILD_RE = re.compile(r"^cnb-[A-Za-z0-9-]{1,80}$")
CONTEXT_RE = re.compile(r"^[A-Za-z0-9 ._+/()-]{1,120}$")
STATE_RE = re.compile(r"^(success|failure|pending|error)$")
DESC_RE = re.compile(r"^[A-Za-z0-9 ._+/():-]{1,120}$")
RUN_RE = re.compile(
    r"^https://github\.com/zysicyj-xxc/public-builder/actions/runs/[0-9]+$"
)
KEY_RE = re.compile(r"[^A-Za-z0-9._-]+")


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def annotation_key(context):
    key = "pb-" + KEY_RE.sub("-", context).strip("-")
    key = key[:80]
    if not key or key == "pb-":
        fail("context failed allowlist")
    return key


def load_results(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                fail("results row failed allowlist")
            context, state, desc = parts
            if not CONTEXT_RE.fullmatch(context):
                fail("context failed allowlist")
            if not STATE_RE.fullmatch(state):
                fail("state failed allowlist")
            if not DESC_RE.fullmatch(desc):
                fail("description failed allowlist")
            rows.append((context, state, desc))
    if len(rows) > 40:
        fail("too many results")
    return rows


def comment_body(sha, pr, build, run_url, rows):
    lines = [
        "public-builder 检查结果",
        f"sha: {sha}",
        f"run: {run_url}",
    ]
    if build:
        lines.append(f"cnb_build: {build}")
    if pr:
        lines.append(f"pr: {pr}")
    for context, state, desc in rows:
        lines.append(f"{context}: {state} ({desc})")
    body = "\n".join(lines)
    if len(body) > 4000:
        fail("comment too long")
    return body


def request(method, url, payload, token):
    if not url.startswith(API + "/"):
        fail("url failed allowlist")
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read(0)
            return resp.status
    except urllib.error.HTTPError as exc:
        exc.read(0)
        return exc.code


def plan(sha, pr, build, run_url, rows):
    if not SHA_RE.fullmatch(sha):
        fail("sha failed allowlist")
    if pr and not PR_RE.fullmatch(pr):
        fail("pr failed allowlist")
    if build and not BUILD_RE.fullmatch(build):
        fail("cnb_build failed allowlist")
    if not RUN_RE.fullmatch(run_url):
        fail("run url failed allowlist")
    base = f"{API}/{REPO}"
    calls = []
    for context, state, desc in rows:
        calls.append(
            (
                "POST",
                f"{base}/-/git/commit-statuses/{sha}",
                {
                    "state": state,
                    "context": context,
                    "description": desc,
                    "target_url": run_url,
                },
            )
        )
    if pr and rows:
        calls.append(
            (
                "POST",
                f"{base}/-/pulls/{pr}/comments",
                {"body": comment_body(sha, pr, build, run_url, rows)},
            )
        )
    return calls


def fallback_annotations(sha, rows):
    base = f"{API}/{REPO}"
    value_rows = []
    for context, state, desc in rows:
        value_rows.append({"key": annotation_key(context), "value": f"{state} {desc}"[:200]})
    return (
        "PUT",
        f"{base}/-/git/commit-annotations/{sha}",
        {"annotations": value_rows},
    )


def selftest():
    sha = "0123456789abcdef0123456789abcdef01234567"
    run = "https://github.com/zysicyj-xxc/public-builder/actions/runs/123"
    rows = [("quality/backend", "success", "backend success")]
    calls = plan(sha, "15", "cnb-sle-1k4f9usjt", run, rows)
    assert calls[0][0] == "POST"
    assert calls[0][1].endswith(f"/commit-statuses/{sha}")
    assert calls[1][1].endswith("/pulls/15/comments")
    assert "0123456789abcdef0123456789abcdef01234567" in calls[1][2]["body"]
    assert "cnb-sle-1k4f9usjt" in calls[1][2]["body"]
    no_pr = plan(sha, "", "", run, rows)
    assert len(no_pr) == 1
    ann = fallback_annotations(sha, rows)
    assert ann[0] == "PUT"
    assert ann[2]["annotations"][0]["key"] == "pb-quality-backend"
    try:
        plan(sha, "15", "", "https://example.com/runs/1", rows)
    except SystemExit:
        pass
    else:
        fail("run url should fail")
    import tempfile

    path = tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8")
    path.write("flutter-test (daymica)\tfailure\tdaymica failure\n")
    path.close()
    try:
        got = load_results(path.name)
    finally:
        os.unlink(path.name)
    assert got == [("flutter-test (daymica)", "failure", "daymica failure")]
    print("cnb_report selftest ok")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return
    if len(argv) != 3 or argv[1] != "--results":
        fail("usage: cnb_report.py --results FILE")
    token = os.environ.get("CNB_STATUS_TOKEN", "")
    if token.strip() == "":
        print("CNB_STATUS_TOKEN unset; skip")
        return
    rows = load_results(argv[2])
    if not rows:
        print("no cnb results; skip")
        return
    sha = os.environ.get("CNB_SHA", "").strip().lower()
    pr = os.environ.get("CNB_PR", "").strip()
    build = os.environ.get("CNB_BUILD", "").strip()
    run_url = os.environ.get("RUN_URL", "").strip()
    calls = plan(sha, pr, build, run_url, rows)
    wrote = False
    status_missing = False
    for method, url, payload in calls:
        code = request(method, url, payload, token)
        kind = "comment" if "/comments" in url else "status"
        print(f"cnb {kind} http {code}")
        if kind == "status" and code in (404, 405):
            status_missing = True
            continue
        if code in (200, 201, 204):
            wrote = True
            continue
        fail(f"cnb {kind} http {code}")
    if status_missing:
        method, url, payload = fallback_annotations(sha, rows)
        code = request(method, url, payload, token)
        print(f"cnb annotation http {code}")
        if code in (200, 201, 204):
            wrote = True
        elif not wrote:
            fail(f"cnb annotation http {code}")
    if not wrote:
        fail("cnb writeback had no success")
    print("cnb writeback ok")


if __name__ == "__main__":
    main(sys.argv)
