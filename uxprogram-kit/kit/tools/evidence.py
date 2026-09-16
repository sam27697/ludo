#!/usr/bin/env python3
"""Run a command and keep its real output as evidence.

Usage (run from the repository root):
  python .uxprogram/kit/tools/evidence.py NAME [--timeout SEC] [--tail N] -- COMMAND [ARGS...]
  python .uxprogram/kit/tools/evidence.py NAME [--timeout SEC] [--tail N] --shell "COMMAND STRING"
  python .uxprogram/kit/tools/evidence.py --verify LOGFILE

Writes .uxprogram/logs/<UTC time>-<NAME>.log containing the command, working
directory, times, the combined stdout/stderr bytes exactly as produced, the exit
code, and a SHA256 line that makes later hand edits detectable.
Prints the last N output lines, the log path and the exit code.
Exits with the command's exit code (124 on timeout, 127 if it cannot start).
"""
import argparse
import datetime as _dt
import hashlib
import os
import re
import signal
import subprocess
import sys

TOOL_ID = "TOOL: evidence.py v2"
START_MARK = b"--- OUTPUT START ---\n"
END_MARK = b"\n--- OUTPUT END ---\n"


def _utf8_stdout():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def repo_root():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return os.getcwd()


def now_iso():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def verify(path):
    """Return (ok, message)."""
    try:
        data = open(path, "rb").read()
    except OSError as exc:
        return False, "cannot read log: %s" % exc
    idx = data.rfind(b"SHA256: ")
    if idx < 0:
        return False, "no SHA256 line (not written by evidence.py)"
    prefix = data[:idx]
    claimed = data[idx + 8:].strip().decode("ascii", "replace")
    if TOOL_ID.encode() not in prefix[:400]:
        return False, "missing tool header (not written by evidence.py)"
    if not re.search(rb"\nEXIT_CODE: -?\d+\n", prefix):
        return False, "missing EXIT_CODE line"
    actual = hashlib.sha256(prefix).hexdigest()
    if actual != claimed:
        return False, "SHA256 mismatch: the log was edited after it was written"
    return True, "log is intact"


def exit_code_of(path):
    data = open(path, "rb").read()
    m = re.search(rb"\nEXIT_CODE: (-?\d+)\n", data)
    return int(m.group(1)) if m else None


def kill_tree(proc):
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                           capture_output=True)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def main():
    _utf8_stdout()
    argv = sys.argv[1:]
    if argv[:1] == ["--verify"]:
        if len(argv) != 2:
            print("usage: evidence.py --verify LOGFILE")
            return 2
        ok, msg = verify(argv[1])
        code = exit_code_of(argv[1]) if ok else None
        print("VERIFY: %s | %s | EXIT_CODE=%s" % ("PASS" if ok else "FAIL", msg, code))
        return 0 if ok else 1

    command = None
    if "--" in argv:
        cut = argv.index("--")
        argv, command = argv[:cut], argv[cut + 1:]
    parser = argparse.ArgumentParser(description="Run a command and keep its real output.")
    parser.add_argument("name")
    parser.add_argument("--shell", help="command string run through the system shell")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--tail", type=int, default=40)
    args = parser.parse_args(argv)
    if bool(command) == bool(args.shell):
        print("give exactly one of: -- COMMAND ARGS...  or  --shell \"COMMAND\"")
        return 2

    root = repo_root()
    log_dir = os.path.join(root, ".uxprogram", "logs")
    os.makedirs(log_dir, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", args.name).strip("-")[:60] or "run"
    stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    path = os.path.join(log_dir, "%s-%s.log" % (stamp, safe))
    n = 2
    while os.path.exists(path):
        path = os.path.join(log_dir, "%s-%s-%d.log" % (stamp, safe, n))
        n += 1

    shown = args.shell if args.shell else subprocess.list2cmdline(command)
    started = now_iso()
    popen_kw = dict(cwd=os.getcwd(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if os.name == "nt":
        popen_kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        popen_kw["start_new_session"] = True
    output = b""
    try:
        if args.shell:
            proc = subprocess.Popen(args.shell, shell=True, **popen_kw)
        else:
            proc = subprocess.Popen(command, **popen_kw)
        try:
            output, _ = proc.communicate(timeout=args.timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            try:
                output, _ = proc.communicate(timeout=10)
            except Exception:
                output = output or b""
            output = (output or b"") + b"\n[evidence.py] TIMEOUT after %d seconds\n" % args.timeout
            code = 124
    except OSError as exc:
        output = ("[evidence.py] could not start command: %s\n" % exc).encode("utf-8")
        code = 127

    header = "\n".join([
        TOOL_ID,
        "NAME: %s" % args.name,
        "COMMAND: %s" % shown,
        "CWD: %s" % os.getcwd(),
        "STARTED: %s" % started,
        "",
    ]).encode("utf-8")
    footer = ("EXIT_CODE: %d\nFINISHED: %s\n" % (code, now_iso())).encode("utf-8")
    body = header + START_MARK + (output or b"") + END_MARK + footer
    digest = hashlib.sha256(body).hexdigest()
    with open(path, "wb") as fh:
        fh.write(body + ("SHA256: %s\n" % digest).encode("ascii"))

    text = (output or b"").decode("utf-8", "replace").splitlines()
    if args.tail > 0 and text:
        if len(text) > args.tail:
            print("[... %d earlier lines are in the log ...]" % (len(text) - args.tail))
        print("\n".join(text[-args.tail:]))
    rel = os.path.relpath(path, root).replace(os.sep, "/")
    print("EVIDENCE: %s EXIT_CODE=%d" % (rel, code))
    return code


if __name__ == "__main__":
    sys.exit(main())
