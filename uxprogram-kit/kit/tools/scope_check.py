#!/usr/bin/env python3
"""Check that a change touched only the paths it was allowed to touch.

Usage (run from the repository root):
  python .uxprogram/kit/tools/scope_check.py --base REV [--head REV]
         [--allow GLOB]... [--allow-file TASK_CARD.md] [--forbid GLOB]...
         [--max-files N] [--max-lines N] [--allow-dirty]

Glob rules: ** matches across folders, * and ? stay inside one folder.
--allow-file (repeatable, globs allowed) reads the list under "ALLOWED_PATHS:" in each task card
(one "- glob" per line, until the next blank line or KEY: line).
Always forbidden: .uxprogram/** (program files are never committed).
A dirty working tree fails unless --allow-dirty is given.
Prints SCOPE: PASS or SCOPE: FAIL. Exit 0 pass, 1 fail, 2 usage or git error.
"""
import argparse
import glob
import re
import subprocess
import sys

ALWAYS_FORBIDDEN = [".uxprogram/**"]


def glob_to_regex(glob):
    glob = glob.strip().replace("\\", "/")
    if glob.startswith("./"):
        glob = glob[2:]
    out, i = "", 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
            continue
        if glob.startswith("**", i):
            out += ".*"
            i += 2
            continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    if glob.endswith("/"):
        out += ".*"
    return re.compile("^" + out + "$")


def git(*args):
    res = subprocess.run(["git"] + list(args), capture_output=True)
    if res.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), res.stderr.decode("utf-8", "replace").strip()))
    return res.stdout.decode("utf-8", "replace")


def read_allow_file(path):
    globs, active = [], False
    for raw in open(path, encoding="utf-8").read().splitlines():
        line = raw.strip()
        if line.upper().startswith("ALLOWED_PATHS:"):
            active = True
            rest = line.split(":", 1)[1].strip()
            if rest:
                globs.extend(g.strip() for g in rest.split(",") if g.strip())
            continue
        if active:
            if not line or re.match(r"^[A-Z][A-Z0-9_ ]+:", line):
                break
            if line.startswith("- "):
                g = line[2:].strip().strip("`")
                if g:
                    globs.append(g)
    return globs


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--allow", action="append", default=[])
    p.add_argument("--allow-file", action="append", default=[],
                   help="task card with an ALLOWED_PATHS block; repeatable; a quoted glob such as \"tasks/*.md\" is expanded")
    p.add_argument("--forbid", action="append", default=[])
    p.add_argument("--max-files", type=int)
    p.add_argument("--max-lines", type=int)
    p.add_argument("--allow-dirty", action="store_true")
    a = p.parse_args()

    allow = list(a.allow)
    for pattern in a.allow_file:
        matches = sorted(glob.glob(pattern)) if any(ch in pattern for ch in "*?[") else [pattern]
        if not matches:
            print("SCOPE: FAIL no files match --allow-file %s" % pattern)
            return 2
        for path in matches:
            try:
                allow.extend(read_allow_file(path))
            except OSError as exc:
                print("SCOPE: FAIL cannot read allow file: %s" % exc)
                return 2
    if not allow:
        print("SCOPE: FAIL no allowed paths given (an empty scope allows nothing)")
        return 2
    for g in allow:
        if g.strip() in ("**", "*", "**/*", "/"):
            print("SCOPE: FAIL allowed glob %r is the whole repository; declare real paths" % g)
            return 1
    allow_re = [(g, glob_to_regex(g)) for g in allow]
    forbid_re = [(g, glob_to_regex(g)) for g in ALWAYS_FORBIDDEN + a.forbid]

    try:
        status = git("diff", "--name-status", "-M", a.base, a.head)
        numstat = git("diff", "--numstat", "-M", a.base, a.head)
        dirty = git("status", "--porcelain")
    except RuntimeError as exc:
        print("SCOPE: FAIL %s" % exc)
        return 2

    touched = []
    for line in status.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        kind = parts[0]
        for path in parts[1:]:
            touched.append((kind, path))

    problems = []
    for kind, path in touched:
        bad = [g for g, rx in forbid_re if rx.match(path)]
        if bad:
            problems.append("FORBIDDEN %s %s (matches %s)" % (kind, path, bad[0]))
            continue
        if not any(rx.match(path) for _, rx in allow_re):
            problems.append("OUT-OF-SCOPE %s %s" % (kind, path))

    files = len({p for _, p in touched})
    lines = 0
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit():
            lines += int(parts[0]) + int(parts[1])
    if a.max_files is not None and files > a.max_files:
        problems.append("TOO-MANY-FILES %d > %d (split the task)" % (files, a.max_files))
    if a.max_lines is not None and lines > a.max_lines:
        problems.append("TOO-MANY-LINES %d > %d (split the task)" % (lines, a.max_lines))
    if dirty.strip() and not a.allow_dirty:
        for d in dirty.splitlines()[:20]:
            problems.append("UNCOMMITTED %s" % d.strip())

    print("base=%s head=%s files=%d changed_lines=%d allowed=%s" % (a.base, a.head, files, lines, ", ".join(allow)))
    for kind, path in touched:
        print("  %s %s" % (kind, path))
    if problems:
        for pr in problems:
            print("PROBLEM: " + pr)
        print("SCOPE: FAIL (%d problems)" % len(problems))
        return 1
    print("SCOPE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
