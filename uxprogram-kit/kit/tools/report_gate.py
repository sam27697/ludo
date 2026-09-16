#!/usr/bin/env python3
"""Validate program reports so that a rubber stamp cannot pass as a review.

Usage (run from the repository root):
  python .uxprogram/kit/tools/report_gate.py review FILE [--previous FILE] [--require-zero-open] [--final]
  python .uxprogram/kit/tools/report_gate.py test FILE
  python .uxprogram/kit/tools/report_gate.py plan-eval FILE [--scores 04_plan_scores.md]
  python .uxprogram/kit/tools/report_gate.py plan-scores FILE
  python .uxprogram/kit/tools/report_gate.py score-diff PLAN_SCORES_FILE PLAN_EVAL_FILE
  python .uxprogram/kit/tools/report_gate.py research FILE [--library FILE] [--min-new N]

Evidence cells must name files that exist. Files under .uxprogram/logs/ must be
intact evidence.py logs. Coverage rows that name a tool must point to a log of
that tool's real output.

Exit codes: 0 pass | 1 report invalid | 2 unreadable or usage |
            3 report valid but open notes remain (review with --require-zero-open)
"""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence  # noqa: E402

try:
    ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                          text=True, check=True).stdout.strip()
except Exception:
    ROOT = os.getcwd()

COVERAGE_IDS = ["C%02d" % i for i in range(1, 17)]
COVERAGE_ALWAYS_YES = {"C01", "C02", "C03", "C04", "C05"}
COVERAGE_MARKERS = {"C02": "SCOPE:", "C03": "AUTHORSHIP:", "C04": "GATE:",
                    "C05": "NEGATIVE-SPACE:", "C09": "EFFORT:"}
NOTE_STATUSES = {"OPEN", "REOPENED", "CLOSED-FIXED", "CLOSED-REJECTED", "CLOSED-DEFERRED"}
SEVERITIES = {"S0", "S1", "S2", "S3"}
TIERS = ["T1", "T2", "T3", "T4"]
CRITERIA = ["Impact", "Principles", "Distinctiveness", "Effort", "Safety", "Maintainability"]
WEIGHTS = {"Impact": 0.30, "Principles": 0.20, "Distinctiveness": 0.15,
           "Effort": 0.15, "Safety": 0.10, "Maintainability": 0.10}
PATH_TOKEN = re.compile(r"[^\s|,;()\[\]<>\"'`]+")


# ---------------------------------------------------------------- parsing helpers
def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def preamble(text):
    m = re.search(r"^## ", text, re.M)
    return text[:m.start()] if m else text


def header_value(block, key):
    m = re.search(r"^\s*%s\s*:\s*(.*?)\s*$" % re.escape(key), block, re.M | re.I)
    return m.group(1).strip() if m else None


def section(text, title_prefix):
    out, active = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if active:
                break
            if line[3:].strip().lower().startswith(title_prefix.lower()):
                active = True
            continue
        if active:
            out.append(line)
    return "\n".join(out) if active else None


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", s)]


def first_table(block):
    header, rows, started = None, [], False
    for line in (block or "").splitlines():
        s = line.strip()
        if s.startswith("|"):
            cells = split_row(s)
            if header is None:
                header, started = cells, True
                continue
            if not rows and all(re.fullmatch(r":?-+:?", c) for c in cells if c):
                continue
            rows.append(cells)
        elif started:
            break
    return header, rows


def colmap(header, names):
    low = [h.lower() for h in (header or [])]
    idx = {}
    for name in names:
        hit = next((i for i, h in enumerate(low) if h == name.lower() or h.startswith(name.lower())), None)
        if hit is None:
            return None, name
        idx[name] = hit
    return idx, None


def list_items(block):
    return [l.strip() for l in (block or "").splitlines()
            if re.match(r"^\s*(?:[-*]|\d+[.)])\s+\S", l)]


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


# ---------------------------------------------------------------- evidence helpers
def check_evidence(cell):
    """Return (existing_paths, verified_logs, problems)."""
    good, logs, problems = [], [], []
    for tok in PATH_TOKEN.findall(cell or ""):
        if tok.startswith(("http://", "https://")):
            continue
        t = tok.rstrip(".:")
        t = re.sub(r"(?::\d+(?:-\d+)?)+$", "", t).split("#", 1)[0]
        looks_like_path = ("/" in t or "\\" in t) and re.search(r"\.[A-Za-z0-9]{1,6}$", t)
        if not looks_like_path:
            continue
        full = t if os.path.isabs(t) else os.path.join(ROOT, t)
        if not os.path.isfile(full):
            problems.append("evidence file does not exist: %s" % t)
            continue
        rel = t.replace("\\", "/")
        if rel.startswith(".uxprogram/logs/") and rel.endswith(".log"):
            ok, msg = evidence.verify(full)
            if not ok:
                problems.append("evidence log %s rejected: %s" % (t, msg))
                continue
            logs.append(full)
        good.append(t)
    return good, logs, problems


def log_contains(logs, marker):
    for path in logs:
        with open(path, encoding="utf-8", errors="replace") as fh:
            if marker in fh.read():
                return path
    return None


def table_or_error(text, title, columns, errs):
    block = section(text, title)
    if block is None:
        errs.append("missing section '## %s'" % title)
        return None, []
    header, rows = first_table(block)
    if not header:
        errs.append("section '## %s' has no table" % title)
        return None, []
    cm, missing = colmap(header, columns)
    if cm is None:
        errs.append("table in '## %s' is missing column '%s'" % (title, missing))
        return None, []
    good_rows = []
    for n, r in enumerate(rows, 1):
        if all(not c for c in r):
            continue
        if len(r) != len(header):
            errs.append("'## %s' row %d has %d cells but the header has %d (escape | inside text as \\|)"
                        % (title, n, len(r), len(header)))
            continue
        good_rows.append(r)
    return cm, good_rows


def finish(errs, summary, open_exit=False):
    for e in errs:
        print("FAIL: " + e)
    if errs:
        print("REPORT-GATE: FAIL (%d problems) %s" % (len(errs), summary))
        return 1
    if open_exit:
        print("REPORT-GATE: FAIL (open notes remain) %s" % summary)
        return 3
    print("REPORT-GATE: PASS %s" % summary)
    return 0


# ---------------------------------------------------------------- review
def gate_review(path, previous=None, require_zero=False, final=False):
    errs = []
    text = read(path)
    pre = preamble(text)
    try:
        rnd = int(header_value(pre, "ROUND") or "")
    except ValueError:
        rnd = None
        errs.append("ROUND: missing or not a number")
    indep = (header_value(pre, "INDEPENDENCE") or "").upper()
    if indep not in ("L2", "L3"):
        errs.append("INDEPENDENCE must be L2 or L3 for a review (got %r)" % indep)
    verdict = (header_value(pre, "VERDICT") or "").upper()
    if verdict not in ("PASS", "FAIL"):
        errs.append("VERDICT must be PASS or FAIL")

    gate_exit = None
    cm, rows = table_or_error(text, "Coverage", ["ID", "Area", "Checked", "How", "Evidence"], errs)
    if cm:
        seen = {}
        for r in rows:
            cid = r[cm["ID"]].upper()
            if cid in seen:
                errs.append("coverage %s is listed twice" % cid)
            seen[cid] = r
        for cid in COVERAGE_IDS:
            r = seen.get(cid)
            if r is None:
                errs.append("coverage %s is missing (all of C01-C16 are required)" % cid)
                continue
            checked = r[cm["Checked"]].upper().replace("NA", "N/A")
            how, ev = r[cm["How"]], r[cm["Evidence"]]
            must_yes = cid in COVERAGE_ALWAYS_YES or (cid == "C15" and rnd is not None and rnd >= 2)
            if checked == "YES":
                good, logs, probs = check_evidence(ev)
                errs.extend("coverage %s: %s" % (cid, p) for p in probs)
                if not good:
                    errs.append("coverage %s says YES but names no existing evidence file" % cid)
                marker = COVERAGE_MARKERS.get(cid)
                if marker:
                    hit = log_contains(logs, marker)
                    if not hit:
                        errs.append("coverage %s needs an evidence.py log containing %r: re-run that tool" % (cid, marker))
                    elif cid == "C04":
                        gate_exit = evidence.exit_code_of(hit)
            elif checked == "N/A":
                if must_yes:
                    errs.append("coverage %s cannot be N/A" % cid)
                elif len((how + " " + ev).strip()) < 15:
                    errs.append("coverage %s is N/A without a reason" % cid)
            else:
                errs.append("coverage %s: Checked must be YES or N/A (got %r)" % (cid, checked))

    nm, notes = table_or_error(text, "Notes", ["ID", "Status", "Sev", "Where", "Finding", "Measured", "Evidence", "Fix"], errs)
    ids, open_ids, counts = set(), [], {s: 0 for s in SEVERITIES}
    prev_ids = set()
    if previous:
        ptext = read(previous)
        try:
            prnd = int(header_value(preamble(ptext), "ROUND") or "")
            if rnd is not None and rnd != prnd + 1:
                errs.append("ROUND should be %d because the previous review is round %d" % (prnd + 1, prnd))
        except ValueError:
            errs.append("previous review has no ROUND")
        pm, prows = table_or_error(ptext, "Notes", ["ID"], [])
        if pm:
            prev_ids = {r[pm["ID"]] for r in prows if r[pm["ID"]]}
    if nm:
        for r in notes:
            nid, st, sev = r[nm["ID"]], r[nm["Status"]].upper(), r[nm["Sev"]].upper()
            where, finding, measured = r[nm["Where"]], r[nm["Finding"]], r[nm["Measured"]]
            ev, fix = r[nm["Evidence"]], r[nm["Fix"]]
            label = nid or "(no id)"
            if not nid:
                errs.append("a note has no ID")
            elif nid in ids:
                errs.append("note %s appears twice" % nid)
            ids.add(nid)
            if st not in NOTE_STATUSES:
                errs.append("note %s: Status %r is not one of %s" % (label, st, ", ".join(sorted(NOTE_STATUSES))))
                continue
            if sev not in SEVERITIES:
                errs.append("note %s: Sev must be S0-S3" % label)
                continue
            if rnd == 1 and st != "OPEN":
                errs.append("note %s: round 1 notes can only be OPEN" % label)
            if nid in prev_ids and st == "OPEN":
                errs.append("note %s existed in the previous round: use REOPENED or a CLOSED status" % label)
            good, logs, probs = check_evidence(ev)
            errs.extend("note %s: %s" % (label, p) for p in probs)
            if st in ("OPEN", "REOPENED"):
                open_ids.append(nid)
                counts[sev] += 1
                if not (where and finding and measured):
                    errs.append("note %s: Where, Finding and Measured are all required" % label)
                if not good:
                    errs.append("note %s: needs an existing evidence file" % label)
            elif st == "CLOSED-FIXED":
                if not good:
                    errs.append("note %s: CLOSED-FIXED needs evidence that the fix was verified" % label)
            elif st == "CLOSED-REJECTED":
                if len(fix) < 15 or not good:
                    errs.append("note %s: CLOSED-REJECTED needs a reason and evidence" % label)
                if sev in ("S0", "S1") and not logs:
                    errs.append("note %s: rejecting an %s needs an evidence.py log" % (label, sev))
            elif st == "CLOSED-DEFERRED":
                if final:
                    errs.append("note %s: nothing can be deferred in the final round" % label)
                if sev in ("S0", "S1"):
                    errs.append("note %s: %s notes can never be deferred" % (label, sev))
                if "queue_" not in fix:
                    errs.append("note %s: a deferral must name the queue file it was copied to" % label)
        dropped = sorted(prev_ids - ids)
        if dropped:
            errs.append("notes from the previous round were dropped: %s (carry every note forward)" % ", ".join(dropped))

    if verdict == "PASS" and open_ids:
        errs.append("VERDICT PASS with open notes: %s" % ", ".join(open_ids))
    if verdict == "FAIL" and not open_ids and nm:
        errs.append("VERDICT FAIL with zero open notes: record the notes or pass")
    if gate_exit not in (None, 0) and not open_ids:
        errs.append("the gate log exited %s but no open note records the failure" % gate_exit)
    summary = "open=%d (S0=%d S1=%d S2=%d S3=%d) notes_total=%d" % (
        len(open_ids), counts["S0"], counts["S1"], counts["S2"], counts["S3"], len(ids))
    if open_ids:
        print("OPEN NOTES: " + ", ".join(open_ids))
    return finish(errs, summary, open_exit=bool(require_zero and open_ids))


# ---------------------------------------------------------------- test report
def gate_test(path):
    errs = []
    text = read(path)
    pre = preamble(text)
    for key, need_zero in (("FRESHNESS", True), ("PAIRWISE_GENERATOR", False)):
        val = header_value(pre, key)
        if not val:
            errs.append("%s: missing (give the evidence.py log path)" % key)
            continue
        good, logs, probs = check_evidence(val)
        errs.extend("%s: %s" % (key, p) for p in probs)
        if not logs:
            errs.append("%s must point to an intact evidence.py log" % key)
        elif need_zero and evidence.exit_code_of(logs[0]) != 0:
            errs.append("%s log did not exit 0: the build under test is not proven fresh" % key)
    cm, rows = table_or_error(text, "Matrix", ["Cell", "Tier", "Target", "Condition", "Status", "Evidence", "Note"], errs)
    counts = {"PASS": 0, "FAIL": 0, "N/A": 0, "HUMAN": 0}
    tiers, cells = set(), set()
    if cm:
        for r in rows:
            cell, tier, st = r[cm["Cell"]], r[cm["Tier"]].upper(), r[cm["Status"]].upper()
            ev, note = r[cm["Evidence"]], r[cm["Note"]]
            label = cell or "(no id)"
            if not cell:
                errs.append("a matrix row has no Cell id")
            elif cell in cells:
                errs.append("cell %s appears twice" % cell)
            cells.add(cell)
            if tier not in TIERS:
                errs.append("cell %s: Tier must be T1-T4" % label)
            tiers.add(tier)
            if not (r[cm["Target"]] and r[cm["Condition"]]):
                errs.append("cell %s: Target and Condition are required" % label)
            if st not in counts:
                errs.append("cell %s: Status must be PASS, FAIL, N/A or HUMAN (empty cells are not allowed)" % label)
                continue
            counts[st] += 1
            if st in ("PASS", "FAIL"):
                good, logs, probs = check_evidence(ev)
                errs.extend("cell %s: %s" % (label, p) for p in probs)
                if not good:
                    errs.append("cell %s: %s needs an existing evidence file" % (label, st))
                if st == "FAIL" and not note:
                    errs.append("cell %s: FAIL needs the note ID in the Note column" % label)
            elif st == "N/A" and len(note) < 15:
                errs.append("cell %s: N/A needs a reason in the Note column" % label)
            elif st == "HUMAN" and "human_checklist" not in (note + " " + ev).lower():
                errs.append("cell %s: HUMAN must reference its human_checklist.md item" % label)
        for t in TIERS:
            if t not in tiers:
                errs.append("tier %s has no rows" % t)
    summary = "cells=%d PASS=%d FAIL=%d N/A=%d HUMAN=%d" % (
        len(cells), counts["PASS"], counts["FAIL"], counts["N/A"], counts["HUMAN"])
    return finish(errs, summary)


# ---------------------------------------------------------------- plan scores and evaluation
def parse_scores(text, errs, need_area):
    cols = (["Area", "Concept", "Tier"] if need_area else ["Concept"]) + CRITERIA + ["Reason"]
    title = "Scores" if need_area else "Blind scores"
    cm, rows = table_or_error(text, title, cols, errs)
    out = []
    if not cm:
        return out
    for r in rows:
        name = r[cm["Concept"]]
        entry = {"concept": name, "area": r[cm["Area"]] if need_area else "",
                 "tier": r[cm["Tier"]].upper() if need_area else "", "scores": {}, "raw": r, "cm": cm}
        for c in CRITERIA:
            val = r[cm[c]]
            if not re.fullmatch(r"[1-5]", val):
                errs.append("%s: %s must be a whole number 1-5 (got %r)" % (name or "(no concept)", c, val))
            else:
                entry["scores"][c] = int(val)
        if len(r[cm["Reason"]]) < 10:
            errs.append("%s: every score row needs a reason" % (name or "(no concept)"))
        out.append(entry)
    return out


def weighted(scores):
    return round(sum(WEIGHTS[c] * scores[c] for c in CRITERIA), 2)


def gate_plan_scores(path):
    errs = []
    text = read(path)
    rows = parse_scores(text, errs, need_area=True)
    header, _ = first_table(section(text, "Scores") or "")
    cm_weight, _missing = colmap(header, ["Weighted"]) if header else (None, "Weighted")
    if header and not cm_weight:
        errs.append("Scores table needs a Weighted column")
    areas = {}
    for e in rows:
        if len(e["scores"]) != len(CRITERIA):
            continue
        calc = weighted(e["scores"])
        e["calc"] = calc
        if cm_weight:
            given = e["raw"][cm_weight["Weighted"]]
            try:
                if abs(float(given) - calc) > 0.011:
                    errs.append("%s: Weighted is %s but the weights give %.2f" % (e["concept"], given, calc))
            except ValueError:
                errs.append("%s: Weighted must be a number (correct value %.2f)" % (e["concept"], calc))
        if e["tier"] not in ("SAFE", "BOLD", "WILD"):
            errs.append("%s: Tier must be Safe, Bold or Wild" % e["concept"])
        areas.setdefault(e["area"], []).append(e)
    for area, items in sorted(areas.items()):
        tiers = {i["tier"] for i in items}
        for t in ("SAFE", "BOLD", "WILD"):
            if t not in tiers:
                errs.append("area %r has no %s concept" % (area, t.title()))
        scored = [i for i in items if "calc" in i]
        if not scored:
            continue
        best = max(scored, key=lambda i: i["calc"])
        ties = [i["concept"] for i in scored if i["calc"] == best["calc"]]
        print("AREA %s: winner %s (%.2f)%s" % (area, best["concept"], best["calc"],
                                              " TIE: " + ", ".join(ties) if len(ties) > 1 else ""))
        wilds = [i for i in scored if i["tier"] == "WILD" and i is not best]
        for w in wilds:
            if w["calc"] >= 0.9 * best["calc"]:
                print("SPIKE REQUIRED: area %s concept %s (%.2f is within 10%% of %.2f)" % (
                    area, w["concept"], w["calc"], best["calc"]))
    return finish(errs, "concepts=%d areas=%d" % (len(rows), len(areas)))


def gate_plan_eval(path, scores_path=None):
    errs = []
    text = read(path)
    pre = preamble(text)
    verdict = (header_value(pre, "VERDICT") or "").upper()
    if verdict not in ("APPROVE", "APPROVE_WITH_CHANGES", "REJECT"):
        errs.append("VERDICT must be APPROVE, APPROVE_WITH_CHANGES or REJECT")
    indep = (header_value(pre, "INDEPENDENCE") or "").upper()
    if indep not in ("L2", "L3"):
        errs.append("INDEPENDENCE must be L2 or L3 for a plan evaluation (got %r)" % indep)
    cm, rows = table_or_error(text, "Notes", ["ID", "Sev", "Where", "Finding", "Reason", "Required change"], errs)
    blocking = []
    if cm:
        for r in rows:
            nid = r[cm["ID"]] or "(no id)"
            sev = r[cm["Sev"]].upper()
            if sev not in SEVERITIES:
                errs.append("note %s: Sev must be S0-S3" % nid)
            if not all(r[cm[k]] for k in ("Where", "Finding", "Reason", "Required change")):
                errs.append("note %s: Where, Finding, Reason and Required change are all required" % nid)
            if sev in ("S0", "S1"):
                blocking.append(nid)
    blind = parse_scores(text, errs, need_area=False)
    if not blind:
        errs.append("'## Blind scores' needs at least one scored concept")
    if verdict == "APPROVE" and blocking:
        errs.append("VERDICT APPROVE with S0/S1 notes %s: use APPROVE_WITH_CHANGES or REJECT" % ", ".join(blocking))
    if scores_path:
        planned = parse_scores(read(scores_path), [], need_area=True)
        have = {norm(b["concept"]) for b in blind}
        missing = [p["concept"] for p in planned if norm(p["concept"]) not in have]
        if missing:
            errs.append("concepts not blind-scored: %s" % ", ".join(missing))
    return finish(errs, "verdict=%s notes=%d blocking=%d blind_scored=%d" % (verdict, len(rows), len(blocking), len(blind)))


def score_diff(plan_path, eval_path):
    errs = []
    planned = parse_scores(read(plan_path), errs, need_area=True)
    blind = {norm(b["concept"]): b for b in parse_scores(read(eval_path), errs, need_area=False)}
    divergences = 0
    for p in planned:
        b = blind.get(norm(p["concept"]))
        if not b:
            print("NOT BLIND-SCORED: %s" % p["concept"])
            continue
        for c in CRITERIA:
            if c in p["scores"] and c in b["scores"] and abs(p["scores"][c] - b["scores"][c]) >= 2:
                divergences += 1
                print("DIVERGENCE: %s | %s | planner=%d evaluator=%d" % (p["concept"], c, p["scores"][c], b["scores"][c]))
    for e in errs:
        print("PARSE: " + e)
    print("SCORE-DIFF: %d divergences of 2 or more points" % divergences)
    return 2 if errs else 0


# ---------------------------------------------------------------- research
def gate_research(path, library=None, min_new=5):
    errs = []
    text = read(path)
    for n in range(1, 8):
        if section(text, str(n)) is None:
            errs.append("missing heading '## %d ...'" % n)
    if len(list_items(section(text, "2"))) < 5:
        errs.append("section 2 needs at least 5 cross-industry items")
    if len(list_items(section(text, "6"))) < 3:
        errs.append("section 6 needs at least 3 'nobody does this yet' items")
    refs = list_items(section(text, "References"))
    if section(text, "References") is None:
        errs.append("missing '## References'")
    verified = unverified = new = 0
    lib = read(library) if library and os.path.isfile(library) else ""
    lib_norm = norm(lib)
    for item in refs:
        mv = re.search(r"\[VERIFIED\s+(https?://\S+)\s+(\d{4}-\d{2}-\d{2})\]", item)
        mu = re.search(r"\[UNVERIFIED\]", item)
        if mv:
            verified += 1
            if library and mv.group(1) not in lib:
                new += 1
        elif mu:
            unverified += 1
            key = norm(item[:item.find("[UNVERIFIED]")])[:60]
            if library and key and key not in lib_norm:
                new += 1
        else:
            errs.append("reference without [VERIFIED <url> <YYYY-MM-DD>] or [UNVERIFIED]: %s" % item[:100])
    if not refs:
        errs.append("no references listed")
    if library and new < min_new:
        errs.append("only %d references are new to the library (need %d)" % (new, min_new))
    return finish(errs, "references=%d verified=%d unverified=%d new=%s" % (
        len(refs), verified, unverified, new if library else "n/a"))


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="kind", required=True)
    r = sub.add_parser("review")
    r.add_argument("file")
    r.add_argument("--previous")
    r.add_argument("--require-zero-open", action="store_true")
    r.add_argument("--final", action="store_true")
    t = sub.add_parser("test")
    t.add_argument("file")
    e = sub.add_parser("plan-eval")
    e.add_argument("file")
    e.add_argument("--scores")
    s = sub.add_parser("plan-scores")
    s.add_argument("file")
    d = sub.add_parser("score-diff")
    d.add_argument("plan_scores")
    d.add_argument("plan_eval")
    q = sub.add_parser("research")
    q.add_argument("file")
    q.add_argument("--library")
    q.add_argument("--min-new", type=int, default=5)
    a = p.parse_args()
    try:
        if a.kind == "review":
            return gate_review(a.file, a.previous, a.require_zero_open, a.final)
        if a.kind == "test":
            return gate_test(a.file)
        if a.kind == "plan-eval":
            return gate_plan_eval(a.file, a.scores)
        if a.kind == "plan-scores":
            return gate_plan_scores(a.file)
        if a.kind == "score-diff":
            return score_diff(a.plan_scores, a.plan_eval)
        return gate_research(a.file, a.library, a.min_new)
    except OSError as exc:
        print("REPORT-GATE: FAIL cannot read report: %s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
