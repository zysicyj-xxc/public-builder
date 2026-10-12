#!/usr/bin/env python3
"""Allowlist optional CNB dispatch fields. Untrusted input comes from the environment.

RAW_PR: empty or a decimal pull number.
RAW_CNB_BUILD: empty or a CNB build id (cnb-...).
Writes pr and cnb_build to GITHUB_OUTPUT when that file is set.
"""

import os
import re
import sys

PR_RE = re.compile(r"^[0-9]{1,10}$")
BUILD_RE = re.compile(r"^cnb-[A-Za-z0-9-]{1,80}$")


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def clean(raw, label, pattern, limit):
    if raw is None:
        return ""
    if len(raw) > limit or raw != "".join(ch for ch in raw if ch >= " " and ch != "\x7f"):
        fail(f"{label} failed allowlist")
    raw = raw.strip()
    if not raw:
        return ""
    if not pattern.fullmatch(raw):
        fail(f"{label} failed allowlist")
    return raw


def parse(pr_raw, build_raw):
    return clean(pr_raw, "pr", PR_RE, 16), clean(build_raw, "cnb_build", BUILD_RE, 96)


def write_output(pr, build):
    path = os.environ.get("GITHUB_OUTPUT", "")
    if not path:
        print(f"pr={pr}")
        print(f"cnb_build={build}")
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"pr={pr}\n")
        fh.write(f"cnb_build={build}\n")


def selftest():
    assert parse("", "") == ("", "")
    assert parse(" 123 ", "") == ("123", "")
    assert parse("", "cnb-sle-1k4f9usjt") == ("", "cnb-sle-1k4f9usjt")
    for bad_pr in ("12a", "0x1", "-1", "1\n2", "12345678901"):
        try:
            parse(bad_pr, "")
        except SystemExit:
            continue
        fail(f"pr should fail: {bad_pr!r}")
    for bad_build in ("main", "cnb-", "CNB-1", "cnb-sle 1", "cnb-" + "a" * 81):
        try:
            parse("", bad_build)
        except SystemExit:
            continue
        fail(f"cnb_build should fail: {bad_build!r}")
    print("cnb_payload selftest ok")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return
    if argv[1:]:
        fail("usage: cnb_payload.py [--selftest]")
    pr, build = parse(os.environ.get("RAW_PR", ""), os.environ.get("RAW_CNB_BUILD", ""))
    write_output(pr, build)
    print("cnb payload ok")


if __name__ == "__main__":
    main(sys.argv)
