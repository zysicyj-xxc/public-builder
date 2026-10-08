#!/usr/bin/env python3
"""Count production API hostnames in a staging package.

APK/zip: every member. Directory: exe, dll, and so only (data/app.so, the
app exe). test-api-* is not a hit. Stdout is hostname and count.
"""
import os
import sys
import zipfile
import re

PAT = re.compile(rb"(?<!test-)api-[a-z0-9-]+\.zysicyj\.top")
BIN_SUFFIX = (".exe", ".dll", ".so")


def tally(blob, counts):
    folded = bytes(b | 0x20 if 65 <= b <= 90 else b for b in blob)
    for match in PAT.finditer(folded):
        host = match.group(0).decode("ascii")
        counts[host] = counts.get(host, 0) + 1


def scan_zip(path, counts):
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        print("not a zip", file=sys.stderr)
        sys.exit(1)
    with zf:
        for info in zf.infolist():
            tally(info.filename.encode("utf-8", "surrogateescape"), counts)
            if info.is_dir():
                continue
            tally(zf.read(info), counts)


def scan_dir(path, counts):
    found = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            if not name.lower().endswith(BIN_SUFFIX):
                continue
            found += 1
            with open(os.path.join(root, name), "rb") as fh:
                tally(fh.read(), counts)
    if found == 0:
        print("no binaries", file=sys.stderr)
        sys.exit(1)


def scan_path(path, counts):
    if os.path.isdir(path):
        scan_dir(path, counts)
    elif os.path.isfile(path) and zipfile.is_zipfile(path):
        scan_zip(path, counts)
    else:
        print("scan target missing", file=sys.stderr)
        sys.exit(1)


def report(counts):
    counts.setdefault("api-daymica.zysicyj.top", 0)
    for host in sorted(counts):
        print(f"{host} {counts[host]}")
    return 1 if any(counts.values()) else 0


def main(argv):
    if len(argv) != 2:
        print("paths file required", file=sys.stderr)
        return 1
    raw = open(argv[1], encoding="utf-8-sig").read()
    paths = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    if not paths:
        print("scan path missing", file=sys.stderr)
        return 1
    counts = {}
    for path in paths:
        scan_path(path, counts)
    return report(counts)


def _selftest():
    import io
    import tempfile

    def zip_bytes(parts):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            for name, data in parts:
                zf.writestr(name, data)
        return buf.getvalue()

    def run(paths_to_make):
        with tempfile.TemporaryDirectory() as tmp:
            lines = []
            for kind, payload in paths_to_make:
                if kind == "zip":
                    dest = os.path.join(tmp, "pkg.zip")
                    open(dest, "wb").write(payload)
                    lines.append(dest)
                elif kind == "dir":
                    dest = os.path.join(tmp, "Release")
                    os.makedirs(dest, exist_ok=True)
                    for name, data in payload:
                        full = os.path.join(dest, name)
                        os.makedirs(os.path.dirname(full), exist_ok=True)
                        open(full, "wb").write(data)
                    lines.append(dest)
            listing = os.path.join(tmp, "paths.txt")
            open(listing, "w", encoding="utf-8").write("\n".join(lines) + "\n")
            saved = sys.stdout
            sys.stdout = io.StringIO()
            try:
                code = main([None, listing])
                text = sys.stdout.getvalue()
            finally:
                sys.stdout = saved
            return code, text

    prod = b"https://api-daymica.zysicyj.top/v1"
    test = b"https://test-api-daymica.zysicyj.top/v1"
    other = b"https://daymica.zysicyj.top/ https://api.zysicyj.top/ https://rustfs.zysicyj.top/"
    cases = [
        ("test zip", [("zip", zip_bytes([("lib/app.so", test)]))], 0, "api-daymica.zysicyj.top 0\n"),
        ("prod zip", [("zip", zip_bytes([("lib/app.so", prod)]))], 1, "api-daymica.zysicyj.top 1\n"),
        ("both", [("zip", zip_bytes([("a", test), ("b", prod)]))], 1, "api-daymica.zysicyj.top 1\n"),
        ("case", [("zip", zip_bytes([("a", b"API-DAYMICA.ZYSICYJ.TOP")]))], 1, "api-daymica.zysicyj.top 1\n"),
        ("dir so", [("dir", [("data/app.so", prod), ("readme.md", prod)])], 1, "api-daymica.zysicyj.top 1\n"),
        ("dir exe test", [("dir", [("daymica_staging.exe", test)])], 0, "api-daymica.zysicyj.top 0\n"),
        ("not website", [("dir", [("app.exe", other)])], 0, "api-daymica.zysicyj.top 0\n"),
    ]
    for name, spec, want_code, want_out in cases:
        code, out = run(spec)
        if code != want_code or out != want_out:
            print(f"FAIL {name} code={code} out={out!r}", file=sys.stderr)
            sys.exit(1)
    with tempfile.TemporaryDirectory() as tmp:
        empty = os.path.join(tmp, "Release")
        os.makedirs(empty)
        open(os.path.join(empty, "note.md"), "wb").write(prod)
        listing = os.path.join(tmp, "paths.txt")
        open(listing, "w", encoding="utf-8").write(empty + "\n")
        try:
            main([None, listing])
        except SystemExit as exc:
            if exc.code != 1:
                print("FAIL empty dir", file=sys.stderr)
                sys.exit(1)
        else:
            print("FAIL empty dir did not exit", file=sys.stderr)
            sys.exit(1)
    print("count-prod-api-hosts selftest ok")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        _selftest()
    else:
        sys.exit(main(sys.argv))
