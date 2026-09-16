#!/usr/bin/env python3
"""Look for the ways a change can look done without being done.

Usage (run from the repository root):
  python .uxprogram/kit/tools/negative_space.py --base REV [--head REV]
         [--allow-file .uxprogram/negative_allow.txt]

FAIL signals: deleted test files, net assertions removed from a test file, added
skip/only markers, added lint or type suppressions, added empty catch blocks,
added TODO/FIXME/not-implemented/lorem ipsum.
WARN signals: added console.log/debugPrint, !important, fixed sleeps in tests.
Allowlist lines look like:  exact added text | reason   (min 8 chars, reviewed).
Prints NEGATIVE-SPACE: PASS or NEGATIVE-SPACE: FAIL. Exit 0 pass, 1 fail, 2 git error.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diffutil  # noqa: E402

TEST_PATH = re.compile(
    r"(^|/)(tests?|__tests__|specs?|e2e|integration_test|androidTest|uitests?)/"
    r"|\.(test|spec)\.[cm]?[jt]sx?$|_test\.(py|dart|go)$|(^|/)test_[^/]*\.py$|Tests?\.(swift|kt|java)$",
    re.IGNORECASE)
ASSERTION = re.compile(
    r"\bexpect\s*\(|\bassert\w*\b|\bshould\b|\.to(Be|Equal|Have|Contain|Match)\w*\(|XCTAssert|assertThat|\bverify\s*\(|matchesGoldenFile|meetsGuideline")

FAIL_ADDED = [
    ("skip-or-only", r"\b(?:it|test|describe|context)\.(?:skip|only)\s*\(|\bx(?:it|describe|test)\s*\(|@pytest\.mark\.skip|\bpytest\.skip\s*\(|@unittest\.skip|@Ignore\b|@Disabled\b|\bskip:\s*(?:true|['\"])"),
    ("suppression", r"@ts-ignore|@ts-nocheck|eslint-disable|#\s*type:\s*ignore|#\s*noqa|//\s*ignore(?:_for_file)?:|@SuppressWarnings|#pragma warning disable|swiftlint:disable|stylelint-disable"),
    ("empty-catch", r"catch\s*(?:\([^)]*\))?\s*\{\s*\}|except[^:\n]*:\s*pass\b|\.catch\(\s*\(\s*\w*\s*\)\s*=>\s*\{\s*\}\s*\)|\.catch\(\s*\(\s*\)\s*=>\s*(?:null|undefined)\s*\)"),
    ("placeholder", r"\bTODO\b|\bFIXME\b|\bXXX\b|(?i:lorem ipsum)|NotImplementedError|UnimplementedError|(?i:not implemented)"),
]
WARN_ADDED = [
    ("debug-output", r"\bconsole\.(?:log|debug)\s*\(|\bdebugPrint\s*\("),
    ("important", r"!important"),
]
WARN_TEST_ADDED = [
    ("fixed-sleep", r"waitForTimeout\s*\(|\bsleep\s*\(|Future\.delayed\s*\(|Thread\.sleep\s*\("),
]


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--allow-file", default=".uxprogram/negative_allow.txt")
    a = p.parse_args()

    entries, allow_problems = diffutil.load_allowlist(a.allow_file)
    fails = ["allowlist " + x for x in allow_problems]
    warns = []
    try:
        files = diffutil.changed_files(a.base, a.head)
        lines = list(diffutil.diff_lines(a.base, a.head))
    except diffutil.GitError as exc:
        print("NEGATIVE-SPACE: FAIL %s" % exc)
        return 2

    for status, old, new in files:
        if old.startswith(".uxprogram/"):
            continue
        if status.startswith("D") and TEST_PATH.search(old):
            fails.append("deleted-test-file %s" % old)
        if status.startswith("R") and TEST_PATH.search(old) and not TEST_PATH.search(new):
            fails.append("test-file-moved-out-of-tests %s -> %s" % (old, new))

    per_file = {}
    for path, sign, no, text in lines:
        if path.startswith(".uxprogram/"):
            continue
        is_test = bool(TEST_PATH.search(path))
        if is_test and ASSERTION.search(text):
            added, removed = per_file.get(path, (0, 0))
            per_file[path] = (added + (sign == "+"), removed + (sign == "-"))
        if sign != "+" or diffutil.allowed(text, entries):
            continue
        for name, rx in FAIL_ADDED:
            if re.search(rx, text):
                fails.append("%s %s:%d :: %s" % (name, path, no, text.strip()[:160]))
        for name, rx in WARN_ADDED + (WARN_TEST_ADDED if is_test else []):
            if re.search(rx, text):
                warns.append("%s %s:%d :: %s" % (name, path, no, text.strip()[:160]))

    for path, (added, removed) in sorted(per_file.items()):
        if removed > added:
            fails.append("net-assertions-removed %s (removed %d, added %d)" % (path, removed, added))

    print("scanned files=%d changed_lines=%d" % (len(files), len(lines)))
    for w in warns:
        print("WARN " + w)
    for f in fails:
        print("FAIL " + f)
    if fails:
        print("NEGATIVE-SPACE: FAIL (%d fail, %d warn)" % (len(fails), len(warns)))
        return 1
    print("NEGATIVE-SPACE: PASS (%d warn)" % len(warns))
    return 0


if __name__ == "__main__":
    sys.exit(main())
