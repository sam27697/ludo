#!/usr/bin/env python3
"""Compute user effort per core flow from .uxprogram/flows.md.

Usage:  python .uxprogram/kit/tools/effort_calc.py .uxprogram/flows.md [--json OUT.json]

flows.md format (one block per flow, blank lines and lines starting with # ignored):
  FLOW: start-match | Start a match with 2 friends from app launch
  STEPS: N T M T N K*6 T W:1.5 N T

Operators (Keystroke-Level Model values, Card, Moran and Newell):
  T     tap or click, aim plus press       1.20 s   counts 1 tap
  G     gesture: swipe, scroll, drag       1.20 s   counts 1 gesture
  K*n   n keystrokes (K alone = 1)         0.20 s each
  M     a decision the user must make      1.35 s   counts 1 decision
  H     hand moves keyboard <-> pointer    0.40 s
  W:x   waiting for the system x seconds   x s
  N     a new screen or major view          0 s     counts 1 screen
Values are for comparing versions of the same flow, not absolute predictions.
Exit 0 ok, 1 parse error (a wrong count must never pass silently).
"""
import json
import re
import sys

COST = {"T": 1.2, "G": 1.2, "K": 0.2, "M": 1.35, "H": 0.4}
TOKEN = re.compile(r"^(?:(T|G|M|H|N)|K(?:\*(\d+))?|W:(\d+(?:\.\d+)?))$")


def parse(path):
    flows, errors, current = [], [], None
    for n, raw in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.upper().startswith("FLOW:"):
            body = line.split(":", 1)[1]
            fid, _, desc = body.partition("|")
            current = {"id": fid.strip(), "description": desc.strip(), "steps": None, "line": n}
            if not current["id"]:
                errors.append("line %d: FLOW needs an id" % n)
            flows.append(current)
        elif line.upper().startswith("STEPS:"):
            if current is None:
                errors.append("line %d: STEPS before any FLOW" % n)
                continue
            if current["steps"] is not None:
                errors.append("line %d: flow %s has two STEPS lines" % (n, current["id"]))
            current["steps"] = line.split(":", 1)[1].split()
        else:
            errors.append("line %d: expected FLOW: or STEPS:, got %r" % (n, line[:60]))
    return flows, errors


def measure(flow, errors):
    m = dict(taps=0, gestures=0, keystrokes=0, decisions=0, hand_moves=0, screens=0, wait_s=0.0, klm_s=0.0)
    if not flow["steps"]:
        errors.append("flow %s has no STEPS" % flow["id"])
        return m
    for tok in flow["steps"]:
        t = TOKEN.match(tok)
        if not t:
            errors.append("flow %s: unknown operator %r" % (flow["id"], tok))
            continue
        op, kcount, wait = t.group(1), t.group(2), t.group(3)
        if wait is not None:
            m["wait_s"] += float(wait)
            m["klm_s"] += float(wait)
        elif op is None:
            k = int(kcount) if kcount else 1
            m["keystrokes"] += k
            m["klm_s"] += k * COST["K"]
        elif op == "N":
            m["screens"] += 1
        else:
            key = {"T": "taps", "G": "gestures", "M": "decisions", "H": "hand_moves"}[op]
            m[key] += 1
            m["klm_s"] += COST[op]
    m["klm_s"] = round(m["klm_s"], 2)
    m["wait_s"] = round(m["wait_s"], 2)
    return m


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 1
    out_json = None
    if "--json" in args:
        i = args.index("--json")
        out_json = args[i + 1] if i + 1 < len(args) else None
    flows, errors = parse(args[0])
    ids = [f["id"] for f in flows]
    for d in sorted({x for x in ids if ids.count(x) > 1}):
        errors.append("duplicate flow id %s" % d)
    rows = []
    for f in flows:
        rows.append(dict(id=f["id"], description=f["description"], **measure(f, errors)))
    print("| Flow | Taps | Gestures | Keys | Decisions | Screens | Wait s | KLM s |")
    print("|------|------|----------|------|-----------|---------|--------|-------|")
    for r in rows:
        print("| %s | %d | %d | %d | %d | %d | %.2f | %.2f |" % (
            r["id"], r["taps"], r["gestures"], r["keystrokes"], r["decisions"], r["screens"], r["wait_s"], r["klm_s"]))
    if out_json:
        with open(out_json, "w", encoding="utf-8") as fh:
            json.dump(rows, fh, indent=2, ensure_ascii=False)
    if errors:
        for e in errors:
            print("ERROR " + e)
        print("EFFORT: FAIL (%d parse errors)" % len(errors))
        return 1
    print("EFFORT: OK (%d flows)" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
