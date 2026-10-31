"""CJ as a note-taker: quick notes, hands-free dictation for meetings and lectures, and summaries.

- "Take a note: call the plumber on Monday" -> one note.
- "Start taking notes" -> the phone keeps recording; each chunk is transcribed and added to a session
  (/api/notes/dictate) until you say "stop taking notes". CJ then summarises the session, saves it, and copies
  it into Apple Notes on the Mac.
- "Summarise today's notes", "what did I note about the budget?" -> answered from your notes.

Stored in ~/.cj/notes.json on your Mac.
"""
from __future__ import annotations

import datetime
import json
import re
import uuid

from . import config

STOP = re.compile(r"(?i)\b(stop|end|finish|done)\b.{0,12}\b(notes?|note[- ]taking|dictation|recording)\b|"
                  r"\bnotes? (band|bas|khatam)\b|नोट्स? बंद")


def _path():
    return config.home() / "notes.json"


def load() -> list[dict]:
    try:
        return json.loads(_path().read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def _save(notes: list[dict]) -> None:
    _path().write_text(json.dumps(notes, ensure_ascii=False, indent=1))
    _path().chmod(0o600)


def _now() -> str:
    return datetime.datetime.now().isoformat(timespec="minutes")


def add(text: str, title: str = "", summary: str = "", kind: str = "note") -> dict:
    note = {"id": uuid.uuid4().hex[:8], "t": _now(), "kind": kind, "title": title.strip()[:120],
            "text": text.strip()[:50_000], "summary": summary.strip()[:4000]}
    _save(load() + [note])
    return note


def since(period: str) -> list[dict]:
    """Notes from today, this week, or all of them."""
    notes = load()
    today = datetime.date.today()
    if period == "today":
        return [n for n in notes if n["t"][:10] == today.isoformat()]
    if period == "week":
        start = (today - datetime.timedelta(days=7)).isoformat()
        return [n for n in notes if n["t"][:10] >= start]
    return notes


def search(query: str, k: int = 6) -> list[dict]:
    words = [w for w in re.findall(r"\w+", query.lower()) if len(w) > 2]
    scored = []
    for n in load():
        hay = f"{n['title']} {n['text']} {n['summary']}".lower()
        score = sum(hay.count(w) for w in words)
        if score:
            scored.append((score, n))
    scored.sort(key=lambda s: (-s[0], s[1]["t"]), reverse=False)
    return [n for _, n in scored[:k]]


def describe(notes: list[dict], limit: int = 12_000) -> str:
    out = []
    for n in notes:
        body = n["summary"] or n["text"]
        out.append(f"[{n['t'].replace('T', ' ')}] {n['title'] + ': ' if n['title'] else ''}{body}")
    return "\n".join(out)[-limit:]


# ---- dictation sessions -------------------------------------------------------------------------------------

SESSIONS: dict[str, list[str]] = {}


def start_session() -> str:
    sid = uuid.uuid4().hex[:8]
    SESSIONS[sid] = []
    return sid


def append(sid: str, text: str) -> None:
    SESSIONS.setdefault(sid, []).append(text.strip())


def wants_stop(text: str) -> bool:
    return bool(STOP.search(text))


def before_stop(text: str) -> str:
    """What was said before "stop taking notes" in the same stretch ("okay" and the like dropped)."""
    m = STOP.search(text)
    head = text[:m.start()] if m else text
    head = re.sub(r"(?i)[\s,]*\b(ok(ay)?|alright|so|cj|and|now|please)\b[\s,.]*$", "", head).strip()
    return head if len(head.split()) > 2 else ""


def transcript(sid: str) -> str:
    return "\n".join(t for t in SESSIONS.get(sid, []) if t)
