#!/usr/bin/env python3
"""Run the UX program with a fresh agent session every time.

  python run_program.py init    --project PATH
  python run_program.py probe   --project PATH --engine NAME
  python run_program.py run     --project PATH [--once] [--max-sessions N] [--stall-limit N] [--dry-run]
  python run_program.py status  --project PATH

init   copies kit/ into PATH/.uxprogram/kit, excludes .uxprogram/ from git locally,
       and creates PROJECT_CONFIG.md and runner_config.json if they are missing.
probe  proves an engine can write a file headlessly before you trust a long run.
run    loops: run every PENDING role dispatch on its configured engine, then start
       one orchestrator session. Stops on DONE, BLOCKED, a stall (no progress for
       --stall-limit sessions), or --max-sessions. Progress is judged from files on
       disk, never from an engine's exit code.
Exit codes: 0 done | 2 setup or config error | 10 blocked | 11 stalled | 12 max sessions | 13 locked
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KIT_SRC = os.path.join(HERE, "kit")
BOOTSTRAP = ("You are the lead of a UI and UX improvement program in this repository. "
             "Before doing anything else, read the file .uxprogram/kit/PROGRAM.md completely "
             "and follow its section 0, Session start, exactly. If that file is missing, change nothing "
             "and reply only with: KIT MISSING.")
ROLE_PROMPT = ("You are running one role in a UI and UX improvement program in this repository. "
               "Read the file {role_file} completely, then read the dispatch file {dispatch} and do exactly "
               "what they say. Write only what your role and the dispatch file allow. "
               "Do not start any other agent, model or agent command line tool.")
ROLES = ["orchestrator", "R1", "R2", "R3", "R4", "R5"]


def now():
    return dt.datetime.now(dt.timezone.utc)


def stamp():
    return now().strftime("%Y%m%d-%H%M%S")


def say(msg):
    print("[runner %s] %s" % (now().strftime("%H:%M:%S"), msg), flush=True)


def git(project, *args):
    return subprocess.run(["git", "-C", project] + list(args), capture_output=True, text=True)


def paths(project):
    ux = os.path.join(project, ".uxprogram")
    return dict(ux=ux, kit=os.path.join(ux, "kit"), state=os.path.join(ux, "STATE.md"),
                dispatch=os.path.join(ux, "dispatch"), config=os.path.join(ux, "runner_config.json"),
                logs=os.path.join(ux, "runner_logs"), lock=os.path.join(ux, "runner.lock"),
                project_config=os.path.join(ux, "PROJECT_CONFIG.md"))


# ------------------------------------------------------------------ init
def cmd_init(project):
    top = git(project, "rev-parse", "--show-toplevel")
    if top.returncode != 0:
        print("SETUP: FAIL %s is not a git repository. The program needs git for rollback." % project)
        return 2
    project = top.stdout.strip()
    p = paths(project)
    if not os.path.isfile(os.path.join(KIT_SRC, "PROGRAM.md")):
        print("SETUP: FAIL kit/PROGRAM.md not found next to run_program.py")
        return 2
    os.makedirs(p["ux"], exist_ok=True)
    if os.path.isdir(p["kit"]):
        shutil.rmtree(p["kit"])
    shutil.copytree(KIT_SRC, p["kit"], ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    exclude = git(project, "rev-parse", "--git-path", "info/exclude").stdout.strip()
    exclude = exclude if os.path.isabs(exclude) else os.path.join(project, exclude)
    os.makedirs(os.path.dirname(exclude), exist_ok=True)
    current = open(exclude, encoding="utf-8").read() if os.path.isfile(exclude) else ""
    if ".uxprogram/" not in current.splitlines():
        with open(exclude, "a", encoding="utf-8") as fh:
            fh.write(("" if current.endswith("\n") or not current else "\n") + ".uxprogram/\n")
    created = []
    if not os.path.isfile(p["project_config"]):
        shutil.copy(os.path.join(KIT_SRC, "PROJECT_CONFIG.template.md"), p["project_config"])
        created.append(".uxprogram/PROJECT_CONFIG.md")
    if not os.path.isfile(p["config"]):
        shutil.copy(os.path.join(HERE, "runner_config.example.json"), p["config"])
        created.append(".uxprogram/runner_config.json")
    with open(os.path.join(p["ux"], "BOOTSTRAP.txt"), "w", encoding="utf-8") as fh:
        fh.write(BOOTSTRAP + "\n")
    ignored = git(project, "check-ignore", "-q", ".uxprogram/STATE.md").returncode == 0
    print("kit installed: %s" % p["kit"])
    print("git ignores .uxprogram/: %s" % ("yes" if ignored else "NO - check .git/info/exclude"))
    for c in created:
        print("created: %s" % c)
    print("next: edit PROJECT_CONFIG.md (optional) and runner_config.json, run the selftest,")
    print("      probe every engine you configured, then: python run_program.py run --project %s" % project)
    return 0 if ignored else 2


# ------------------------------------------------------------------ integrity
def kit_integrity(project):
    """Restore kit files a session changed or deleted, remove files it added. Returns the changes."""
    p = paths(project)
    changes = []
    src_files = set()
    for base, dirs, files in os.walk(KIT_SRC):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in files:
            if name.endswith(".pyc"):
                continue
            rel = os.path.relpath(os.path.join(base, name), KIT_SRC)
            src_files.add(rel)
            dst = os.path.join(p["kit"], rel)
            src = os.path.join(KIT_SRC, rel)
            if not os.path.isfile(dst) or open(dst, "rb").read() != open(src, "rb").read():
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
                changes.append("restored kit/%s" % rel.replace(os.sep, "/"))
    for base, dirs, files in os.walk(p["kit"]):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in files:
            rel = os.path.relpath(os.path.join(base, name), p["kit"])
            if rel not in src_files and not name.endswith(".pyc"):
                os.remove(os.path.join(base, name))
                changes.append("removed added file kit/%s" % rel.replace(os.sep, "/"))
    return changes


def watch_known_failures(project):
    p = paths(project)
    kf = os.path.join(p["ux"], "known_failures.txt")
    marker = os.path.join(p["ux"], "runner_known_failures.count")
    if not os.path.isfile(kf):
        return []
    count = sum(1 for line in open(kf, encoding="utf-8", errors="replace") if line.strip())
    if not os.path.isfile(marker):
        with open(marker, "w") as fh:
            fh.write("%d,%d" % (count, count))
        return []
    first, seen = (int(x) for x in (open(marker).read().strip() or "0,0").split(","))
    if count <= seen:
        return []
    with open(marker, "w") as fh:
        fh.write("%d,%d" % (first, count))
    return ["known_failures.txt grew from %d to %d entries after setup" % (first, count)]


def record_integrity(project, items):
    if not items:
        return
    path = os.path.join(paths(project)["ux"], "INTEGRITY_WARNINGS.md")
    new = not os.path.isfile(path)
    with open(path, "a", encoding="utf-8") as fh:
        if new:
            fh.write("# Integrity warnings (written by the runner; every unexplained entry is an S0 note)\n\n")
        for item in items:
            fh.write("- %s %s\n" % (now().isoformat(), item))
    for item in items:
        say("INTEGRITY: " + item)


# ------------------------------------------------------------------ config and launching
def load_config(project):
    p = paths(project)
    try:
        cfg = json.load(open(p["config"], encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return None, "cannot read %s: %s" % (p["config"], exc)
    engines, roles = cfg.get("engines", {}), cfg.get("roles", {})
    for role in ROLES:
        name = roles.get(role)
        if name not in engines:
            return None, "role %s uses engine %r which is not defined in engines" % (role, name)
    for name in sorted({roles[r] for r in ROLES}):
        eng = engines[name]
        cmd = eng.get("command")
        if not cmd or not isinstance(cmd, list):
            return None, "engine %s needs a command list" % name
        if any("<EDIT" in str(part) for part in cmd):
            return None, "engine %s still has <EDIT> placeholders" % name
        if not any(("{prompt_file}" in part or "{prompt_text}" in part) for part in cmd):
            return None, "engine %s command must contain {prompt_file} or {prompt_text}" % name
    return cfg, None


def build_command(engine, prompt_text, prompt_file, project):
    cmd = [part.replace("{prompt_file}", prompt_file).replace("{prompt_text}", prompt_text).replace("{project}", project)
           for part in engine["command"]]
    exe = shutil.which(cmd[0]) or cmd[0]
    cmd[0] = exe
    if os.name == "nt" and exe.lower().endswith((".cmd", ".bat")):
        cmd = ["cmd", "/c"] + cmd
    return cmd


def kill_tree(proc):
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def launch(project, engine_name, engine, prompt_text, label):
    p = paths(project)
    os.makedirs(p["logs"], exist_ok=True)
    base = os.path.join(p["logs"], "%s-%s" % (stamp(), re.sub(r"[^A-Za-z0-9._-]+", "-", label)))
    prompt_file = base + ".prompt.txt"
    with open(prompt_file, "w", encoding="utf-8") as fh:
        fh.write(prompt_text + "\n")
    cmd = build_command(engine, prompt_text, os.path.abspath(prompt_file), project)
    env = dict(os.environ)
    env.update({k: str(v) for k, v in engine.get("env", {}).items()})
    log_path = base + ".log"
    timeout = int(engine.get("timeout_minutes", 60)) * 60
    say("start %s on %s (timeout %d min) log=%s" % (label, engine_name, timeout // 60, os.path.relpath(log_path, project)))
    started = time.time()
    with open(log_path, "wb") as log:
        log.write(("COMMAND: %s\nSTARTED: %s\n---\n" % (subprocess.list2cmdline(cmd), now().isoformat())).encode("utf-8"))
        log.flush()
        kw = dict(cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        if os.name == "nt":
            kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            kw["start_new_session"] = True
        try:
            proc = subprocess.Popen(cmd, **kw)
        except OSError as exc:
            log.write(("\n[runner] cannot start engine: %s\n" % exc).encode("utf-8"))
            say("cannot start %s: %s" % (engine_name, exc))
            return 127, log_path, started
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            code = 124
            log.write(b"\n[runner] TIMEOUT: engine killed\n")
        log.write(("\n---\nEXIT_CODE: %s\nFINISHED: %s\n" % (code, now().isoformat())).encode("utf-8"))
    say("end %s exit=%s after %.1f min" % (label, code, (time.time() - started) / 60))
    return code, log_path, started


# ------------------------------------------------------------------ state and dispatch files
def read_kv(path):
    data = {}
    try:
        for line in open(path, encoding="utf-8").read().splitlines():
            m = re.match(r"^([A-Z_]+):\s*(.*)$", line)
            if m and m.group(1) not in data:
                data[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    return data


def set_kv(path, updates):
    lines = open(path, encoding="utf-8").read().splitlines()
    for key, value in updates.items():
        for i, line in enumerate(lines):
            if line.startswith(key + ":"):
                lines[i] = "%s: %s" % (key, value)
                break
        else:
            lines.append("%s: %s" % (key, value))
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def dispatch_files(project):
    d = paths(project)["dispatch"]
    if not os.path.isdir(d):
        return []
    files = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".md")]
    return sorted(files, key=os.path.getmtime)


def fingerprint(project):
    p = paths(project)
    h = hashlib.sha256()
    try:
        state = open(p["state"], encoding="utf-8").read()
        h.update("\n".join(l for l in state.splitlines() if not l.startswith("UPDATED:")).encode("utf-8"))
    except OSError:
        h.update(b"no-state")
    for f in dispatch_files(project):
        h.update(("%s=%s" % (os.path.basename(f), read_kv(f).get("STATUS", ""))).encode("utf-8"))
    return h.hexdigest()


def run_dispatch(project, cfg, path):
    kv = read_kv(path)
    did, role, output = kv.get("DISPATCH_ID", os.path.basename(path)), kv.get("ROLE", ""), kv.get("OUTPUT", "")
    if role not in cfg["roles"] or role == "orchestrator":
        set_kv(path, {"STATUS": "FAILED", "RESULT_NOTE": "unknown ROLE %r" % role})
        return
    role_file = kv.get("ROLE_FILE", "")
    if not role_file or not os.path.isfile(os.path.join(project, role_file)):
        set_kv(path, {"STATUS": "FAILED", "RESULT_NOTE": "ROLE_FILE missing: %s" % role_file})
        return
    if not output:
        set_kv(path, {"STATUS": "FAILED", "RESULT_NOTE": "OUTPUT missing"})
        return
    engine_name = cfg["roles"][role]
    author = {"R2": cfg["roles"]["orchestrator"], "R5": cfg["roles"]["R3"]}.get(role)
    if author:
        set_kv(path, {"AUTHOR_ENGINE": author, "INDEPENDENCE_HINT": "L3" if author != engine_name else "L2"})
    rel = os.path.relpath(path, project).replace(os.sep, "/")
    prompt = ROLE_PROMPT.format(role_file=role_file, dispatch=rel)
    set_kv(path, {"STATUS": "RUNNING", "ENGINE": engine_name, "STARTED": now().isoformat()})
    code, log_path, started = launch(project, engine_name, cfg["engines"][engine_name], prompt, did)
    out_path = os.path.join(project, output)
    fresh = os.path.isfile(out_path) and os.path.getsize(out_path) > 0 and os.path.getmtime(out_path) >= started - 1
    set_kv(path, {"STATUS": "DONE" if fresh else "FAILED", "FINISHED": now().isoformat(),
                  "ENGINE_EXIT": str(code), "RUNNER_LOG": os.path.relpath(log_path, project).replace(os.sep, "/"),
                  "RESULT_NOTE": "output written" if fresh else "output file missing, empty or not updated by this run"})
    say("dispatch %s -> %s" % (did, "DONE" if fresh else "FAILED"))


# ------------------------------------------------------------------ commands
def cmd_probe(project, engine_name):
    try:
        cfg = json.load(open(paths(project)["config"], encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print("PROBE: FAIL cannot read runner_config.json: %s" % exc)
        return 2
    engine = cfg.get("engines", {}).get(engine_name)
    if not engine or not isinstance(engine.get("command"), list):
        print("PROBE: FAIL engine %s not in runner_config.json" % engine_name)
        return 2
    if any("<EDIT" in str(part) for part in engine["command"]):
        print("PROBE: FAIL engine %s still has <EDIT> placeholders" % engine_name)
        return 2
    token = "READY-" + hashlib.sha1(str(time.time()).encode()).hexdigest()[:8]
    target = ".uxprogram/probe/%s.txt" % engine_name
    os.makedirs(os.path.join(project, ".uxprogram", "probe"), exist_ok=True)
    try:
        os.remove(os.path.join(project, target))
    except OSError:
        pass
    prompt = ("This is a capability probe. Create the file %s containing exactly this text: %s . "
              "Then stop. Do not change anything else." % (target, token))
    probe_engine = dict(engine)
    probe_engine["timeout_minutes"] = min(int(engine.get("timeout_minutes", 10)), 10)
    code, log_path, _ = launch(project, engine_name, probe_engine, prompt, "probe-" + engine_name)
    try:
        ok = token in open(os.path.join(project, target), encoding="utf-8", errors="replace").read()
    except OSError:
        ok = False
    print("PROBE: %s engine=%s exit=%s log=%s" % ("PASS" if ok else "FAIL", engine_name, code, os.path.relpath(log_path, project)))
    if not ok:
        print("The engine did not write the file. Check the log: permission flags, sign-in, certificates, or a timeout.")
    return 0 if ok else 1


def cmd_status(project):
    p = paths(project)
    if not os.path.isfile(p["state"]):
        print("no STATE.md yet (program not started)")
    else:
        text = open(p["state"], encoding="utf-8").read()
        head = [l for l in text.splitlines()[:14] if re.match(r"^[A-Z_]+:", l)]
        print("\n".join(head))
        rows = [l for l in text.splitlines() if re.match(r"^\|\s*(\d+|F)\s*\|", l)]
        done = sum(1 for r in rows if "CLOSED" in r or "NOT-NEEDED" in r)
        print("schedule rows closed: %d of %d" % (done, len(rows)))
    warn = os.path.join(p["ux"], "INTEGRITY_WARNINGS.md")
    if os.path.isfile(warn):
        lines = [l for l in open(warn, encoding="utf-8").read().splitlines() if l.startswith("- ")]
        print("integrity warnings: %d (see .uxprogram/INTEGRITY_WARNINGS.md)" % len(lines))
    for f in dispatch_files(project):
        kv = read_kv(f)
        if kv.get("STATUS") in ("PENDING", "RUNNING", "FAILED"):
            print("dispatch %s %s role=%s" % (kv.get("DISPATCH_ID", os.path.basename(f)), kv.get("STATUS"), kv.get("ROLE")))
    return 0


def acquire_lock(p):
    if os.path.isfile(p["lock"]):
        age_h = (time.time() - os.path.getmtime(p["lock"])) / 3600
        if age_h < 12:
            print("RUN: FAIL another runner holds %s (%.1f h old). Delete it only if no runner is active." % (p["lock"], age_h))
            return False
    with open(p["lock"], "w") as fh:
        fh.write("pid=%d started=%s\n" % (os.getpid(), now().isoformat()))
    return True


def cmd_run(project, once, max_sessions, stall_limit, dry_run):
    p = paths(project)
    if not os.path.isfile(os.path.join(p["kit"], "PROGRAM.md")):
        print("RUN: FAIL kit not installed. Run: python run_program.py init --project %s" % project)
        return 2
    if git(project, "check-ignore", "-q", ".uxprogram/STATE.md").returncode != 0:
        print("RUN: FAIL .uxprogram/ is not ignored by git. Run init again.")
        return 2
    cfg, err = load_config(project)
    if err:
        print("RUN: FAIL config: %s" % err)
        return 2
    max_sessions = max_sessions or int(cfg.get("max_sessions", 400))
    stall_limit = stall_limit or int(cfg.get("stall_limit", 2))
    if dry_run:
        for role in ROLES:
            eng = cfg["roles"][role]
            text = BOOTSTRAP if role == "orchestrator" else ROLE_PROMPT.format(role_file="<role file>", dispatch="<dispatch file>")
            print("%-12s %-8s %s" % (role, eng, subprocess.list2cmdline(build_command(cfg["engines"][eng], text, "<prompt file>", project))))
        print("RUN: DRY-RUN OK")
        return 0
    if not acquire_lock(p):
        return 13
    try:
        for f in dispatch_files(project):
            if read_kv(f).get("STATUS") == "RUNNING":
                set_kv(f, {"STATUS": "PENDING", "RESULT_NOTE": "reset to PENDING after a runner restart"})
        sessions, stall = 0, 0
        while True:
            record_integrity(project, kit_integrity(project))
            for f in dispatch_files(project):
                if read_kv(f).get("STATUS") == "PENDING":
                    run_dispatch(project, cfg, f)
                    record_integrity(project, kit_integrity(project))
            record_integrity(project, watch_known_failures(project))
            state = read_kv(p["state"])
            status = state.get("PROGRAM_STATUS", "")
            if status == "DONE":
                say("program DONE")
                return 0
            if status == "BLOCKED":
                say("program BLOCKED: read .uxprogram/STATE.md and the ESCALATION files")
                return 10
            if sessions >= max_sessions:
                say("stopped: max sessions %d reached" % max_sessions)
                return 12
            before = fingerprint(project)
            orch = cfg["roles"]["orchestrator"]
            launch(project, orch, cfg["engines"][orch], BOOTSTRAP, "orchestrator-s%03d" % (sessions + 1))
            sessions += 1
            record_integrity(project, kit_integrity(project))
            after = fingerprint(project)
            pending = any(read_kv(f).get("STATUS") == "PENDING" for f in dispatch_files(project))
            stall = 0 if (after != before or pending) else stall + 1
            if stall >= stall_limit:
                say("STALLED: %d sessions in a row changed nothing on disk. Read the last runner_logs." % stall)
                return 11
            if once:
                say("--once: stopping after one session")
                return 0
            with open(p["lock"], "a") as fh:
                fh.write("alive %s session=%d\n" % (now().isoformat(), sessions))
    finally:
        try:
            os.remove(p["lock"])
        except OSError:
            pass


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="UX program runner")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("init", "probe", "run", "status"):
        sp = sub.add_parser(name)
        sp.add_argument("--project", required=True)
        if name == "probe":
            sp.add_argument("--engine", required=True)
        if name == "run":
            sp.add_argument("--once", action="store_true")
            sp.add_argument("--max-sessions", type=int)
            sp.add_argument("--stall-limit", type=int)
            sp.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    project = os.path.abspath(a.project)
    if a.cmd == "init":
        return cmd_init(project)
    top = git(project, "rev-parse", "--show-toplevel")
    if top.returncode == 0:
        project = top.stdout.strip()
    if a.cmd == "probe":
        return cmd_probe(project, a.engine)
    if a.cmd == "status":
        return cmd_status(project)
    return cmd_run(project, a.once, a.max_sessions, a.stall_limit, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
