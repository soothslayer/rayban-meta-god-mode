"""CJ's memory: things you ask it to remember, plus what it saw through the glasses.

"Remember I parked on level 2" -> a note. Every glasses photo answer is also saved as a "seen" note, so
"where did I leave my keys?" can find the last time CJ saw them. Stored in ~/.cj/memory.json on your Mac.
"""
from __future__ import annotations

import datetime
import json
import math
import re
from collections import Counter

from . import config

MAX_NOTES = 2000
MAX_SEEN = 1500  # visual memory adds ~100 notes a day: it gets its own budget, so it never pushes out what you saved


def _path():
    return config.home() / "memory.json"


def load() -> list[dict]:
    try:
        return json.loads(_path().read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def _save(notes: list[dict]) -> None:
    seen = [n for n in notes if n["kind"] == "seen"][-MAX_SEEN:]
    mine = [n for n in notes if n["kind"] != "seen"][-MAX_NOTES:]
    keep = {id(n) for n in seen + mine}
    _path().write_text(json.dumps([n for n in notes if id(n) in keep], ensure_ascii=False, indent=1))
    _path().chmod(0o600)


def add(text: str, kind: str = "note") -> dict:
    note = {"t": datetime.datetime.now().isoformat(timespec="minutes"), "kind": kind, "text": text.strip()[:500]}
    if note["text"]:
        _save(load() + [note])
    return note


def forget(query: str) -> int:
    notes = load()
    hits = {id(n) for n in search(query, k=3, notes=notes)}
    kept = [n for n in notes if id(n) not in hits]
    _save(kept)
    return len(notes) - len(kept)


def _tokens(text: str) -> list[str]:
    return [t for t in re.findall(r"\w+", text.lower()) if len(t) > 1]


def search(query: str, k: int = 5, notes: list[dict] | None = None) -> list[dict]:
    """Word overlap, weighted towards rarer words and newer notes."""
    notes = load() if notes is None else notes
    q = Counter(_tokens(query))
    if not notes or not q:
        return []
    docs = [Counter(_tokens(n["text"])) for n in notes]
    df = Counter(t for d in docs for t in d)
    scored = []
    for age, (note, d) in enumerate(zip(reversed(notes), reversed(docs))):
        score = sum(math.log(1 + len(notes) / df[t]) for t in q if t in d)
        if score > 0:
            scored.append((score / (1 + age * 0.01), note))
    scored.sort(key=lambda s: -s[0])
    return [n for _, n in scored[:k]]


def seen_since(hours: int) -> list[dict]:
    """What the glasses noticed in the last few hours, oldest first (at most 40)."""
    since = (datetime.datetime.now() - datetime.timedelta(hours=hours)).isoformat(timespec="minutes")
    return [m for m in load() if m["kind"] == "seen" and m["t"] >= since][-40:]


def recent(n: int = 12) -> list[dict]:
    return [m for m in load() if m["kind"] == "note"][-n:]


def describe(notes: list[dict]) -> str:
    return "\n".join(f"- [{m['t'].replace('T', ' ')}] {'(seen) ' if m['kind'] == 'seen' else ''}{m['text']}" for m in notes)


def prompt() -> str:
    """Recent notes go into every prompt, so CJ knows your city, preferences and so on without being asked."""
    notes = recent()
    return "\nThings the user asked you to remember (use them when relevant):\n" + describe(notes) if notes else ""
