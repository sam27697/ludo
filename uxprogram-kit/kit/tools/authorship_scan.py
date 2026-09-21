#!/usr/bin/env python3
"""Fail if the product change carries AI or model authorship tells.

Usage (run from the repository root):
  python .uxprogram/kit/tools/authorship_scan.py --base REV [--head REV]
         [--allow-file .uxprogram/authorship_allow.txt]

Scans, for base..head:
  - every commit message (trailers such as Co-Authored-By, model names, emoji, em dashes)
  - commit author and committer identities (bot, agent or model identities)
  - every added line in the diff (model names, AI phrases, style tells, em dashes)
Allowlist file lines look like:  exact text that is legitimately present | reason
Entries must be at least 8 characters and carry a reason. The reviewer checks them.
Prints AUTHORSHIP: PASS or AUTHORSHIP: FAIL. Exit 0 pass, 1 fail, 2 usage or git error.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diffutil  # noqa: E402

PATTERNS = [
    ("trailer", r"co-authored-by\s*:"),
    ("trailer", r"\bgenerated (?:with|by)\b"),
    ("model-name", r"\bclaude\b"),
    ("model-name", r"\banthropic\b"),
    ("model-name", r"\bchat ?gpt\b"),
    ("model-name", r"\bopenai\b"),
    ("model-name", r"\bgpt-?\d"),
    ("model-name", r"\bgemini\b"),
    ("model-name", r"\bgrok\b"),
    ("model-name", r"\bcopilot\b"),
    ("model-name", r"\bcursor[- ]agent\b"),
    ("model-name", r"\bantigravity\b"),
    ("model-name", r"\bdeepseek\b"),
    ("model-name", r"\bllm\b"),
    ("model-name", r"\blarge language model\b"),
    ("ai-phrase", r"\bai[- ](?:generated|assisted|written)\b"),
    ("ai-phrase", r"\bas an ai\b"),
    ("ai-phrase", r"\b(?:generated|written|created) by (?:an? )?(?:ai|assistant|model|agent)\b"),
    ("ai-phrase", r"\bi hope this helps\b"),
    ("style-tell", r"\bnote that\b"),
    ("style-tell", r"\bthis ensures\b"),
    ("style-tell", r"\bit'?s worth noting\b"),
    ("style-tell", r"\bdelve\b"),
    ("em-dash", "\u2014"),
]
COMPILED = [(cat, re.compile(rx, re.IGNORECASE)) for cat, rx in PATTERNS]
EMOJI = re.compile("[\U0001F300-\U0001FAFF\u2600-\u27BF\u2B50\u2B55]")
IDENTITY = re.compile(r"(\bbot\b|\[bot\]|agent|assistant|claude|anthropic|openai|copilot|cursor|grok|gemini|antigravity|noreply@(?:anthropic|openai|x\.ai))", re.IGNORECASE)
# This tool takes no argument that lets a caller pass an exclusion prefix in
# (checked: --base, --head and --allow-file are the whole interface), so the
# workflow cannot supply this repository's path and this line is edited by
# hand instead. This repository vendors the kit at uxprogram-kit/, not at
# .uxprogram/ -- .uxprogram/ is this project's own gitignored runtime
# directory, unrelated to where the kit lives here. A future re-sync of the
# kit from upstream will silently overwrite this line back to the kit's own
# default and put uxprogram-kit/ back inside the scanned tree; whoever does
# that re-sync has to reapply this change.
SKIP_PREFIXES = ("uxprogram-kit/",)


def scan_text(text):
    hits = []
    for cat, rx in COMPILED:
        m = rx.search(text)
        if m:
            hits.append((cat, m.group(0)))
    return hits


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--allow-file", default=".uxprogram/authorship_allow.txt")
    a = p.parse_args()

    entries, allow_problems = diffutil.load_allowlist(a.allow_file)
    findings = ["ALLOWLIST " + pr for pr in allow_problems]
    try:
        commit_list = diffutil.commits(a.base, a.head)
        lines = list(diffutil.diff_lines(a.base, a.head))
    except diffutil.GitError as exc:
        print("AUTHORSHIP: FAIL %s" % exc)
        return 2

    for c in commit_list:
        short = c["sha"][:10]
        for field in ("author", "author_email", "committer", "committer_email"):
            if IDENTITY.search(c[field]) and not diffutil.allowed(c[field], entries):
                findings.append("identity commit %s %s=%s" % (short, field, c[field]))
        for n, mline in enumerate(c["message"].splitlines(), 1):
            if diffutil.allowed(mline, entries):
                continue
            for cat, match in scan_text(mline):
                findings.append("%s commit %s message line %d :: %s" % (cat, short, n, mline.strip()[:160]))
            if EMOJI.search(mline):
                findings.append("emoji commit %s message line %d :: %s" % (short, n, mline.strip()[:160]))

    for path, sign, no, text in lines:
        if sign != "+" or path.startswith(SKIP_PREFIXES):
            continue
        if diffutil.allowed(text, entries):
            continue
        for cat, match in scan_text(text):
            findings.append("%s %s:%d :: %s" % (cat, path, no, text.strip()[:160]))

    print("scanned commits=%d added_lines=%d allowlist_entries=%d" % (
        len(commit_list), sum(1 for l in lines if l[1] == "+"), len(entries)))
    if findings:
        for f in findings:
            print("FAIL " + f)
        print("AUTHORSHIP: FAIL (%d findings)" % len(findings))
        return 1
    print("AUTHORSHIP: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
