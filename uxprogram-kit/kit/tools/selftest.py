#!/usr/bin/env python3
"""Prove the kit's gate tools work on this machine before trusting any program run.

Usage:  python .uxprogram/kit/tools/selftest.py
Creates a throwaway git repository in a temp folder, plants known defects,
and checks that every tool catches them and passes clean input.
Prints SELFTEST: PASS or SELFTEST: FAIL. Exit 0 or 1. Deletes the temp folder.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
START_DIR = os.getcwd()
results = []
skipped = []

BAD_PAGE = """<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>bad</title>
<style>body{margin:0} header{position:fixed;top:0;left:0;right:0;height:60px;background:#222}
.bar{position:fixed;bottom:0;left:0;right:0;height:80px;background:#333} .row{height:160px}
.wide{width:500px;height:10px} .tiny{width:16px;height:16px;padding:0;border:0}</style></head><body>
<header></header><button id="first" style="display:block;height:48px">First</button><div class="wide"></div>
<div><button class="tiny" aria-label="close"></button><button class="tiny" id="noname"></button></div>
<div class="row"></div><div class="row"></div><div class="row"></div><div class="row"></div><div class="row"></div><div class="row"></div>
<button id="last" style="display:block;height:48px">Send</button><div class="bar"></div></body></html>"""

GOOD_PAGE = """<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>good</title>
<style>body{margin:0;padding:64px 16px 96px;font-family:sans-serif} header{position:fixed;top:0;left:0;right:0;height:60px;background:#222}
.bar{position:fixed;bottom:0;left:0;right:0;height:80px;background:#333} .row{height:160px} button{min-width:48px;min-height:48px}</style></head><body>
<header></header><button>First</button><div class="row"></div><div class="row"></div><div class="row"></div><div class="row"></div>
<button>Send</button><div class="bar"></div></body></html>"""


def sh(args, cwd, check=False):
    res = subprocess.run(args, cwd=cwd, capture_output=True)
    out = res.stdout.decode("utf-8", "replace") + res.stderr.decode("utf-8", "replace")
    if check and res.returncode != 0:
        raise RuntimeError("command failed: %s\n%s" % (args, out))
    return res.returncode, out


def tool(name, args, cwd):
    return sh([PY, os.path.join(TOOLS, name)] + args, cwd)


def expect(label, got_code, want_code, output="", must_contain=None):
    ok = got_code == want_code and (must_contain is None or must_contain in output)
    results.append((ok, label))
    print("%s  %s (exit %s, expected %s)" % ("PASS" if ok else "FAIL", label, got_code, want_code))
    if not ok:
        print("      output: " + output.strip().replace("\n", "\n      ")[:1500])


def write(root, rel, content):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)


def commit(root, msg):
    sh(["git", "add", "-A"], root, check=True)
    sh(["git", "commit", "-q", "-m", msg], root, check=True)
    return sh(["git", "rev-parse", "HEAD"], root, check=True)[1].strip()


def log_with(root, name, text, code=0):
    rc, out = tool("evidence.py", [name, "--", PY, "-c", "print(%r); raise SystemExit(%d)" % (text, code)], root)
    line = [l for l in out.splitlines() if l.startswith("EVIDENCE: ")][-1]
    return line.split()[1]


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    root = tempfile.mkdtemp(prefix="uxkit-selftest-")
    try:
        sh(["git", "init", "-q"], root, check=True)
        sh(["git", "config", "user.name", "Test Person"], root, check=True)
        sh(["git", "config", "user.email", "person@example.com"], root, check=True)
        sh(["git", "config", "commit.gpgsign", "false"], root, check=True)
        os.makedirs(os.path.join(root, ".uxprogram", "logs"))
        with open(os.path.join(root, ".git", "info", "exclude"), "a") as fh:
            fh.write("\n.uxprogram/\n")
        write(root, "src/app.js", "export const add = (a, b) => a + b;\n")
        write(root, "tests/app.test.js", "expect(add(1, 2)).toBe(3);\nexpect(add(2, 2)).toBe(4);\n")
        base = commit(root, "Initial commit")

        # evidence.py
        rc, out = tool("evidence.py", ["probe", "--", PY, "-c", "print('hello'); raise SystemExit(3)"], root)
        expect("evidence keeps the real exit code", rc, 3, out, "EXIT_CODE=3")
        logrel = [l for l in out.splitlines() if l.startswith("EVIDENCE: ")][-1].split()[1]
        rc, out = tool("evidence.py", ["--verify", os.path.join(root, logrel)], root)
        expect("evidence log verifies", rc, 0, out, "VERIFY: PASS")
        full = os.path.join(root, logrel)
        data = open(full, "rb").read().replace(b"EXIT_CODE: 3", b"EXIT_CODE: 0")
        open(full, "wb").write(data)
        rc, out = tool("evidence.py", ["--verify", full], root)
        expect("edited evidence log is rejected", rc, 1, out, "SHA256 mismatch")
        rc, out = tool("evidence.py", ["slow", "--timeout", "1", "--", PY, "-c", "import time; time.sleep(8)"], root)
        expect("evidence timeout exits 124", rc, 124, out)

        # scope_check.py
        write(root, "src/app.js", "export const add = (a, b) => a + b;\nexport const sub = (a, b) => a - b;\n")
        write(root, "docs/notes.md", "notes\n")
        head = commit(root, "T01: add subtraction")
        rc, out = tool("scope_check.py", ["--base", base, "--allow", "src/**"], root)
        expect("scope fails on out-of-scope file", rc, 1, out, "OUT-OF-SCOPE")
        rc, out = tool("scope_check.py", ["--base", base, "--allow", "src/**", "--allow", "docs/*.md"], root)
        expect("scope passes when all paths allowed", rc, 0, out, "SCOPE: PASS")
        rc, out = tool("scope_check.py", ["--base", base, "--allow", "**"], root)
        expect("scope rejects whole-repo glob", rc, 1, out)
        write(root, ".uxprogram/task.md", "TASK: T01\nALLOWED_PATHS:\n- src/**\n- docs/notes.md\n\nACCEPTANCE:\n- x\n")
        rc, out = tool("scope_check.py", ["--base", base, "--allow-file", ".uxprogram/task.md"], root)
        expect("scope reads ALLOWED_PATHS from a task card", rc, 0, out, "SCOPE: PASS")
        write(root, "src/extra.js", "dirty\n")
        rc, out = tool("scope_check.py", ["--base", base, "--allow", "src/**", "--allow", "docs/**"], root)
        expect("scope fails on uncommitted work", rc, 1, out, "UNCOMMITTED")
        os.remove(os.path.join(root, "src/extra.js"))

        # authorship_scan.py
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship passes clean history", rc, 0, out, "AUTHORSHIP: PASS")
        write(root, "src/app.js", "export const add = (a, b) => a + b; // generated by AI\n")
        sh(["git", "add", "-A"], root, check=True)
        sh(["git", "commit", "-q", "-m", "Tweak add\n\nCo-Authored-By: Claude <noreply@anthropic.com>"], root, check=True)
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship catches trailer and AI comment", rc, 1, out, "trailer commit")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)
        write(root, "src/labels.js", "export const sign = 'Gemini \u2014 twins';\n")
        commit(root, "Add zodiac label")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship catches model name and em dash", rc, 1, out, "em-dash")
        write(root, ".uxprogram/authorship_allow.txt", "export const sign = 'Gemini \u2014 twins'; | zodiac sign label shown to users, not authorship\n")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship respects a reasoned allowlist entry", rc, 0, out, "AUTHORSHIP: PASS")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        write(root, "docs/refresh.md", "Nightly refresh completed without errors.\n")
        commit(root, "Refresh output\n\nThe output generated by the fixed script is byte-for-byte identical.")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship passes prose that says generated by", rc, 0, out, "AUTHORSHIP: PASS")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        write(root, "src/shuffle.js", "export const shuffled = [3, 1, 2];\n// values generated with the seeded shuffle below\n")
        commit(root, "Add shuffle helper")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship passes a code comment that says generated with", rc, 0, out, "AUTHORSHIP: PASS")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        write(root, "src/tweak.js", "export const steady = 1;\n")
        commit(root, "Tweak add\n\nGenerated with [Toolname](https://example.com/toolname)")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship catches a bracketed generated-with trailer", rc, 1, out, "trailer commit")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        write(root, "src/tweak.js", "export const steady = 1;\n")
        commit(root, "Tweak add\n\nGenerated with Cursor")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship catches a bare generated-with trailer line", rc, 1, out, "trailer commit")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        write(root, "src/tweak.js", "export const steady = 1;\n")
        commit(root, "Tweak add\n\nRelease notes generated by [Toolname](https://example.com)")
        rc, out = tool("authorship_scan.py", ["--base", base], root)
        expect("authorship catches generated-by followed by a link", rc, 1, out, "trailer commit")
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        # negative_space.py
        rc, out = tool("negative_space.py", ["--base", base], root)
        expect("negative space passes clean change", rc, 0, out, "NEGATIVE-SPACE: PASS")
        write(root, "tests/app.test.js", "it.skip('adds', () => {});\n")
        write(root, "src/app.js", "// @ts-ignore\ntry { run(); } catch (e) {}\n// TODO finish\n")
        commit(root, "T02: change")
        rc, out = tool("negative_space.py", ["--base", base], root)
        expect("negative space catches skip, suppression, empty catch, TODO, removed asserts", rc, 1, out, "net-assertions-removed")
        for word in ("skip-or-only", "suppression", "empty-catch", "placeholder"):
            expect("negative space reports " + word, 0, 0, out, word)
        sh(["git", "reset", "-q", "--hard", head], root, check=True)

        # effort_calc.py
        write(root, ".uxprogram/flows.md", "FLOW: start | start a match\nSTEPS: N T M T K*5 W:1.5 N\n")
        rc, out = tool("effort_calc.py", [".uxprogram/flows.md"], root)
        expect("effort computes KLM 6.25 s", rc, 0, out, "| start | 2 | 0 | 5 | 1 | 2 | 1.50 | 6.25 |")
        write(root, ".uxprogram/flows.md", "FLOW: start | x\nSTEPS: T Q\n")
        rc, out = tool("effort_calc.py", [".uxprogram/flows.md"], root)
        expect("effort rejects unknown operators", rc, 1, out, "unknown operator")

        # report_gate.py review
        logs = {
            "scope": log_with(root, "scope", "SCOPE: PASS"),
            "auth": log_with(root, "auth", "AUTHORSHIP: PASS"),
            "gate": log_with(root, "gate", "GATE: PASS"),
            "neg": log_with(root, "neg", "NEGATIVE-SPACE: PASS"),
            "effort": log_with(root, "effort", "EFFORT: OK (3 flows)"),
            "probe": log_with(root, "probe", "PROBE: PASS"),
            "gatefail": log_with(root, "gatefail", "GATE: FAIL tests", 1),
        }
        cov_rows = []
        special = {"C02": logs["scope"], "C03": logs["auth"], "C04": logs["gate"], "C05": logs["neg"], "C09": logs["effort"]}
        for i in range(1, 17):
            cid = "C%02d" % i
            if cid == "C15":
                cov_rows.append("| C15 | Previous notes | N/A | round 1 has no previous notes to verify | |")
            else:
                cov_rows.append("| %s | area %s | YES | re-ran the check | %s |" % (cid, cid, special.get(cid, logs["probe"])))

        def review(round_no, verdict, notes, cov=None, indep="L3"):
            return ("# Review\nROUND: %d\nINDEPENDENCE: %s\nVERDICT: %s\n\n## Coverage\n| ID | Area | Checked | How | Evidence |\n|---|---|---|---|---|\n%s\n\n"
                    "## Notes\n| ID | Status | Sev | Where | Finding | Measured | Evidence | Fix or reason |\n|---|---|---|---|---|---|---|---|\n%s\n"
                    % (round_no, indep, verdict, "\n".join(cov or cov_rows), "\n".join(notes)))

        write(root, ".uxprogram/r1_clean.md", review(1, "PASS", []))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r1_clean.md", "--require-zero-open"], root)
        expect("review with full coverage and zero notes passes", rc, 0, out, "REPORT-GATE: PASS")
        write(root, ".uxprogram/r1_stamp.md", review(1, "PASS", [], cov=cov_rows[:3]))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r1_stamp.md", "--require-zero-open"], root)
        expect("rubber-stamp review with thin coverage fails", rc, 1, out, "coverage C04 is missing")
        fake = os.path.join(root, ".uxprogram", "logs", "20990101-000000-fake.log")
        open(fake, "w").write("TOOL: evidence.py v2\nGATE: PASS\nEXIT_CODE: 0\nSHA256: 00\n")
        bad_cov = [r.replace(logs["gate"], ".uxprogram/logs/20990101-000000-fake.log") for r in cov_rows]
        write(root, ".uxprogram/r1_fake.md", review(1, "PASS", [], cov=bad_cov))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r1_fake.md"], root)
        expect("hand-written log is rejected", rc, 1, out, "rejected")
        gatefail_cov = [r.replace(logs["gate"], logs["gatefail"]) for r in cov_rows]
        write(root, ".uxprogram/r1_gatefail.md", review(1, "PASS", [], cov=gatefail_cov))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r1_gatefail.md"], root)
        expect("failed gate with zero notes is rejected", rc, 1, out, "no open note records")
        note = "| A1-N01 | OPEN | S1 | src/app.js:1 | send button covered at scroll end | 62%% overlap > 15%% | %s | pad the list |" % logs["probe"]
        write(root, ".uxprogram/r1_open.md", review(1, "FAIL", [note]))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r1_open.md", "--require-zero-open"], root)
        expect("valid review with open notes exits 3", rc, 3, out, "OPEN NOTES: A1-N01")
        cov2 = [r if not r.startswith("| C15") else "| C15 | Previous notes | YES | verified A1-N01 fix | %s |" % logs["probe"] for r in cov_rows]
        write(root, ".uxprogram/r2_dropped.md", review(2, "PASS", [], cov=cov2))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r2_dropped.md", "--previous", ".uxprogram/r1_open.md"], root)
        expect("round 2 that drops a note fails", rc, 1, out, "dropped")
        closed = note.replace("| OPEN |", "| CLOSED-FIXED |")
        write(root, ".uxprogram/r2_closed.md", review(2, "PASS", [closed], cov=cov2))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r2_closed.md", "--previous", ".uxprogram/r1_open.md", "--require-zero-open"], root)
        expect("round 2 closing the note passes", rc, 0, out, "REPORT-GATE: PASS")
        deferred = note.replace("| OPEN |", "| CLOSED-DEFERRED |")
        write(root, ".uxprogram/r2_defer.md", review(2, "PASS", [deferred], cov=cov2))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r2_defer.md", "--previous", ".uxprogram/r1_open.md"], root)
        expect("an S1 note cannot be deferred", rc, 1, out, "never be deferred")
        write(root, ".uxprogram/r1_l1.md", review(1, "PASS", [], indep="L1"))
        rc, out = tool("report_gate.py", ["review", ".uxprogram/r1_l1.md"], root)
        expect("same-session review (L1) is rejected", rc, 1, out, "INDEPENDENCE")

        # report_gate.py test
        fresh = log_with(root, "fresh", "build id abc123 matches")
        pair = log_with(root, "pairwise", "18 combinations")
        matrix = ("# Test\nFRESHNESS: %s\nPAIRWISE_GENERATOR: %s\n\n## Matrix\n| Cell | Tier | Target | Condition | Status | Evidence | Note |\n|---|---|---|---|---|---|---|\n"
                  "| T1-01 | T1 | home | 390x844 light | PASS | %s | |\n"
                  "| T2-01 | T2 | checkout | offline + huge list | FAIL | %s | A1-N02 |\n"
                  "| T3-01 | T3 | T01 form | Arabic IME input | N/A | | headless browser has no IME; see human_checklist.md H01 |\n"
                  "| T4-01 | T4 | VoiceOver | real iPhone | HUMAN | | human_checklist.md H02 |\n") % (fresh, pair, logs["probe"], logs["probe"])
        write(root, ".uxprogram/test_ok.md", matrix)
        rc, out = tool("report_gate.py", ["test", ".uxprogram/test_ok.md"], root)
        expect("complete test matrix passes", rc, 0, out, "FAIL=1")
        write(root, ".uxprogram/test_bad.md", matrix.replace("| PASS | %s |" % logs["probe"], "|  | |"))
        rc, out = tool("report_gate.py", ["test", ".uxprogram/test_bad.md"], root)
        expect("matrix with an empty status fails", rc, 1, out, "empty cells are not allowed")

        # plan scores and evaluation
        scores = ("## Scores\n| Area | Concept | Tier | Impact | Principles | Distinctiveness | Effort | Safety | Maintainability | Weighted | Reason |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
                  "| onboarding | guided tour | Safe | 3 | 3 | 2 | 3 | 5 | 5 | 3.25 | proven pattern, low risk |\n"
                  "| onboarding | learn by playing | Bold | 4 | 5 | 4 | 4 | 3 | 3 | 4.00 | teaches through the core loop |\n"
                  "| onboarding | no onboarding, smart defaults | Wild | 4 | 4 | 4 | 5 | 3 | 3 | 3.95 | zero screens before first fun |\n")
        write(root, ".uxprogram/scores.md", scores)
        rc, out = tool("report_gate.py", ["plan-scores", ".uxprogram/scores.md"], root)
        expect("plan scores pass and flag the wild spike", rc, 0, out, "SPIKE REQUIRED")
        write(root, ".uxprogram/scores_bad.md", scores.replace("| 4.00 |", "| 4.90 |"))
        rc, out = tool("report_gate.py", ["plan-scores", ".uxprogram/scores_bad.md"], root)
        expect("wrong weighted arithmetic is caught", rc, 1, out, "the weights give 4.00")
        evaluation = ("# Plan evaluation\nVERDICT: APPROVE\nINDEPENDENCE: L3\n\n## Notes\n| ID | Sev | Where | Finding | Reason | Required change |\n|---|---|---|---|---|---|\n"
                      "| E01 | S2 | T03 | no empty state planned | list can be empty for new users | add empty state task |\n\n"
                      "## Blind scores\n| Concept | Impact | Principles | Distinctiveness | Effort | Safety | Maintainability | Reason |\n|---|---|---|---|---|---|---|---|\n"
                      "| guided tour | 3 | 3 | 2 | 3 | 5 | 5 | safe and forgettable |\n"
                      "| learn by playing | 2 | 4 | 4 | 4 | 3 | 3 | great idea but tutorial levels are costly |\n"
                      "| no onboarding, smart defaults | 4 | 4 | 4 | 5 | 3 | 3 | fastest time to fun |\n")
        write(root, ".uxprogram/eval.md", evaluation)
        rc, out = tool("report_gate.py", ["plan-eval", ".uxprogram/eval.md", "--scores", ".uxprogram/scores.md"], root)
        expect("plan evaluation passes", rc, 0, out, "REPORT-GATE: PASS")
        rc, out = tool("report_gate.py", ["score-diff", ".uxprogram/scores.md", ".uxprogram/eval.md"], root)
        expect("score divergence is reported", rc, 0, out, "DIVERGENCE: learn by playing | Impact | planner=4 evaluator=2")
        write(root, ".uxprogram/eval_bad.md", evaluation.replace("| E01 | S2 |", "| E01 | S1 |"))
        rc, out = tool("report_gate.py", ["plan-eval", ".uxprogram/eval_bad.md"], root)
        expect("APPROVE with an S1 note fails", rc, 1, out, "VERDICT APPROVE with S0/S1")

        # research
        research = "\n".join(["## %d Section" % n + ("\n- a\n- b\n- c\n- d\n- e" if n in (2, 6) else "\n- item") for n in range(1, 8)])
        research += ("\n## References\n- Pattern A in product X [VERIFIED https://example.com/a 2026-09-16]\n"
                     "- Pattern B remembered from product Y [UNVERIFIED]\n")
        write(root, ".uxprogram/research.md", research)
        rc, out = tool("report_gate.py", ["research", ".uxprogram/research.md"], root)
        expect("labelled research passes", rc, 0, out, "verified=1 unverified=1")
        write(root, ".uxprogram/research_bad.md", research + "- Unlabelled claim about product Z\n")
        rc, out = tool("report_gate.py", ["research", ".uxprogram/research_bad.md"], root)
        expect("unlabelled reference fails", rc, 1, out, "reference without")
        # ux_probe.mjs (web and hybrid projects); skipped visibly when node or playwright is missing
        node = shutil.which("node")
        probe = os.path.join(TOOLS, "ux_probe.mjs")
        if not node:
            skipped.append("web probe: node not found")
        else:
            pages = os.path.join(root, "pages")
            os.makedirs(pages)
            write(root, "pages/bad.html", BAD_PAGE)
            write(root, "pages/good.html", GOOD_PAGE)
            bad_url = pathlib.Path(os.path.join(pages, "bad.html")).as_uri()
            good_url = pathlib.Path(os.path.join(pages, "good.html")).as_uri()
            rc, out = sh([node, probe, "--url", bad_url, "--out", os.path.join(root, "probe-bad"), "--viewports", "390x844,1440x900"], START_DIR)
            if rc == 2 and ("playwright not found" in out or "cannot launch" in out):
                skipped.append("web probe: " + out.strip().splitlines()[-1][:160])
            else:
                expect("probe fails the page with planted defects", rc, 1, out, "PROBE: FAIL")
                for check in ("obscured", "target-size", "no-name", "h-overflow"):
                    expect("probe reports " + check, 0, 0, out, check)
                rc, out = sh([node, probe, "--url", good_url, "--out", os.path.join(root, "probe-good"), "--viewports", "390x844,1440x900"], START_DIR)
                expect("probe passes the clean page", rc, 0, out, "PROBE: PASS")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    failed = [label for ok, label in results if not ok]
    print("")
    for sk in skipped:
        print("SKIP  " + sk)
    extra = (", %d skipped" % len(skipped)) if skipped else ""
    if failed:
        print("SELFTEST: FAIL (%d of %d checks failed%s)" % (len(failed), len(results), extra))
        return 1
    print("SELFTEST: PASS (%d checks%s)" % (len(results), extra))
    return 0


if __name__ == "__main__":
    sys.exit(main())
