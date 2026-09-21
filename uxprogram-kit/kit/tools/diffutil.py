"""Shared git helpers for authorship_scan.py and negative_space.py."""
import re
import subprocess

HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class GitError(RuntimeError):
    pass


def git(*args):
    res = subprocess.run(["git", "-c", "core.quotePath=false"] + list(args), capture_output=True)
    if res.returncode != 0:
        raise GitError("git %s failed: %s" % (" ".join(args), res.stderr.decode("utf-8", "replace").strip()))
    return res.stdout.decode("utf-8", "replace")


def changed_files(base, head):
    """List of (status, old_path, new_path)."""
    out = []
    for line in git("diff", "--name-status", "-M", base, head).splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            out.append((parts[0], parts[1], parts[1]))
        elif len(parts) >= 3:
            out.append((parts[0], parts[1], parts[2]))
    return out


def diff_lines(base, head):
    """Yield (path, sign, line_number, text) for every added (+) or removed (-) line."""
    text = git("diff", "-U0", "--no-color", "-M", base, head)
    old_path = new_path = None
    old_no = new_no = 0
    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            old_path = new_path = None
            continue
        if raw.startswith("--- "):
            old_path = None if raw[4:] == "/dev/null" else raw[4:][2:] if raw[4:].startswith("a/") else raw[4:]
            continue
        if raw.startswith("+++ "):
            new_path = None if raw[4:] == "/dev/null" else raw[4:][2:] if raw[4:].startswith("b/") else raw[4:]
            continue
        m = HUNK.match(raw)
        if m:
            old_no = int(m.group(1))
            new_no = int(m.group(3))
            continue
        if raw.startswith("+") and new_path is not None:
            yield (new_path, "+", new_no, raw[1:])
            new_no += 1
        elif raw.startswith("-") and old_path is not None:
            yield (old_path, "-", old_no, raw[1:])
            old_no += 1


def commits(base, head):
    """List of dicts: sha, author, author_email, committer, committer_email, message."""
    fmt = "%H%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%B%x1e"
    out = []
    for rec in git("log", "--format=" + fmt, "%s..%s" % (base, head)).split("\x1e"):
        rec = rec.strip("\n")
        if not rec.strip():
            continue
        parts = rec.split("\x1f")
        if len(parts) < 6:
            continue
        out.append(dict(sha=parts[0], author=parts[1], author_email=parts[2],
                        committer=parts[3], committer_email=parts[4], message=parts[5]))
    return out


def load_allowlist(path):
    """Each line: <exact text that may match> | <reason>. Returns (entries, problems)."""
    entries, problems = [], []
    if not path:
        return entries, problems
    try:
        content = open(path, encoding="utf-8").read()
    except OSError:
        return entries, problems
    for n, line in enumerate(content.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "|" not in line:
            problems.append("allowlist line %d has no ' | reason'" % n)
            continue
        literal, reason = line.rsplit("|", 1)
        literal, reason = literal.strip(), reason.strip()
        if len(literal) < 8:
            problems.append("allowlist line %d: text must be at least 8 characters (too broad)" % n)
            continue
        if len(reason) < 10:
            problems.append("allowlist line %d: reason too short" % n)
            continue
        entries.append(literal)
    return entries, problems


def allowed(text, entries):
    return any(e in text for e in entries)
