"""Claude Code remote: give coding tasks to Claude Code on your Mac by voice, hear what it did.

"CJ, ask Claude Code to add a dark mode toggle in my portfolio project" -> CJ asks "are you sure?" -> on "yes"
it runs `claude -p` in that project in the background. When the job finishes, the phone picks it up from
/api/jobs/done and CJ reads a short summary into your ear.

Guard rails:
- Projects are only git repositories in your usual code folders (CODE_DIRS), matched by name.
- Claude Code may read and edit files, and run read-only git commands. No other shell commands.
- One job per project at a time; each job stops after JOB_TIMEOUT.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass, field

from .events import bus

CODE_DIRS = ["~/Documents", "~/Developer", "~/Projects", "~/code", "~/src"]
ALLOWED_TOOLS = "Read Edit Write Glob Grep Bash(git status) Bash(git diff:*) Bash(git log:*)"
JOB_TIMEOUT = 20 * 60


class AgentError(Exception):
    pass


@dataclass
class Job:
    id: str
    project: str
    path: str
    task: str
    state: str = "running"  # running | done | failed
    summary: str = ""
    started: float = field(default_factory=time.time)
    announced: bool = False


JOBS: dict[str, Job] = {}
_lock = threading.Lock()


def claude_bin() -> str:
    path = os.environ.get("CJ_CLAUDE_CODE_BIN") or shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    if not os.path.exists(path):
        raise AgentError("Claude Code isn't installed on this Mac. Install it from claude.com/claude-code.")
    return path


def projects() -> dict[str, str]:
    """Git repositories in the usual code folders, by folder name."""
    found: dict[str, str] = {}
    for d in CODE_DIRS:
        base = os.path.expanduser(d)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if os.path.isdir(os.path.join(path, ".git")):
                found.setdefault(name, path)
    return found


def find_project(spoken: str) -> tuple[str, str]:
    key = re.sub(r"[^a-z0-9]", "", spoken.lower())
    if not key:
        raise AgentError("Which project?")
    repos = projects()
    exact = [(n, p) for n, p in repos.items() if re.sub(r"[^a-z0-9]", "", n.lower()) == key]
    close = [(n, p) for n, p in repos.items() if key in re.sub(r"[^a-z0-9]", "", n.lower())]
    match = exact or close
    if len(match) == 1 or exact:
        return match[0]
    if not match:
        raise AgentError(f"I couldn't find a project called {spoken}. I look for git repos in Documents, Developer and Projects.")
    raise AgentError("Which one: " + ", ".join(n for n, _ in match[:3]) + "?")


def _summary(result: str) -> str:
    """The first two sentences of Claude Code's final message, short enough to say out loud."""
    text = re.sub(r"[`*#_>]+", "", result).strip()
    sentences = re.split(r"(?<=[.!?])\s+", text)
    return " ".join(sentences[:2])[:350] or "It finished without saying anything."


def _run(job: Job, cont: bool) -> None:
    args = [claude_bin(), "-p", job.task, "--output-format", "json", "--permission-mode", "acceptEdits",
            "--allowedTools", ALLOWED_TOOLS]
    if cont:
        args.append("--continue")
    try:
        done = subprocess.run(args, cwd=job.path, capture_output=True, text=True, timeout=JOB_TIMEOUT)
        data = json.loads(done.stdout or "{}") if done.stdout.strip().startswith("{") else {}
        result = data.get("result") or done.stdout.strip() or done.stderr.strip()
        failed = done.returncode != 0 or data.get("is_error")
        if failed and re.search(r"(?i)authenticat|oauth|log ?in|401", result):
            job.summary = "Claude Code needs you to sign in again. On your Mac, run claude in Terminal and log in."
        else:
            job.summary = ("Claude Code hit a problem: " if failed else "") + _summary(result)
        job.state = "failed" if failed else "done"
    except subprocess.TimeoutExpired:
        job.state, job.summary = "failed", f"Claude Code didn't finish within {JOB_TIMEOUT // 60} minutes, so I stopped it."
    except (OSError, ValueError, AgentError) as e:
        job.state, job.summary = "failed", f"Couldn't run Claude Code: {e}"
    bus.emit("claude_code", project=job.project, state=job.state, summary=job.summary)


def start(project: str, task: str, cont: bool = False) -> Job:
    name, path = find_project(project)
    task = task.strip()[:2000]
    if not task:
        raise AgentError("What should Claude Code do?")
    claude_bin()
    with _lock:
        if any(j.state == "running" and j.path == path for j in JOBS.values()):
            raise AgentError(f"Claude Code is already working in {name}. Ask me how it's going.")
        job = Job(uuid.uuid4().hex[:8], name, path, task)
        JOBS[job.id] = job
    bus.emit("claude_code", project=name, state="running", task=task[:200])
    threading.Thread(target=_run, args=(job, cont), daemon=True).start()
    return job


def status() -> str:
    jobs = sorted(JOBS.values(), key=lambda j: -j.started)
    if not jobs:
        return "Claude Code hasn't been given anything yet."
    running = [j for j in jobs if j.state == "running"]
    if running:
        j = running[0]
        return f"Claude Code is still working in {j.project}, for {int(time.time() - j.started) // 60} minutes so far."
    j = jobs[0]
    return f"Last job in {j.project}: {j.summary}"


def take_finished() -> list[Job]:
    """Finished jobs the phone hasn't announced yet (each is returned once)."""
    with _lock:
        ready = [j for j in JOBS.values() if j.state != "running" and not j.announced]
        for j in ready:
            j.announced = True
    return ready
