"""Offline stand-in used by tests and when no API key is set, so the whole pipeline runs without quota."""
from __future__ import annotations

import base64
import json
import re

from .base import Completion, Attachment, Provider


def _decode(data_b64: str) -> str:
    try:
        return base64.b64decode(data_b64).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


def _mac_intent(text: str, system: str) -> dict:
    """Tiny stand-in for the model's choice of Mac action, so tests can drive mac.py."""
    low = text.lower().strip()
    if "Waiting for confirmation" in system and low in ("yes", "no"):
        return {"confirm": low == "yes"}
    if m := re.match(r"(open|quit) (.+)", low):
        return {"mac_action": {"name": f"{m[1]}_app", "args": {"app": m[2]}}}
    if m := re.match(r"volume (\d+)", low):
        return {"mac_action": {"name": "set_volume", "args": {"level": int(m[1])}}}
    if m := re.match(r"go to (.+)", low):
        return {"mac_action": {"name": "open_website", "args": {"url": m[1]}}}
    if m := re.match(r"weather in (.+)", low):
        return {"tool": {"name": "weather", "args": {"place": m[1]}}}
    if m := re.match(r"remember (.+)", low):
        return {"tool": {"name": "remember", "args": {"fact": m[1]}}, "spoken": ""}
    if m := re.match(r"where (?:is|are|did) (.+)", low):
        return {"tool": {"name": "recall", "args": {"query": m[1]}}}
    if m := re.match(r"timer (\d+)", low):
        return {"tool": {"name": "timer", "args": {"seconds": int(m[1]), "label": "test"}}, "spoken": ""}
    if m := re.match(r"book me an uber to (.+)", low):
        return {"tool": {"name": "phone_task", "args": {"goal": f"book an Uber to {m[1]}", "app": "uber", "destination": m[1]}}}
    if m := re.match(r"translate for me in (\w+)", low):
        return {"tool": {"name": "translate_start", "args": {"other_language": m[1]}}}
    if low == "what did i see today":
        return {"tool": {"name": "timeline", "args": {"hours": 12}}}
    if m := re.match(r"(start|pause) visual memory", low):
        return {"tool": {"name": "visual_memory", "args": {"on": m[1] == "start"}}}
    if m := re.match(r"take a note (.+)", low):
        return {"tool": {"name": "note_add", "args": {"text": m[1]}}, "spoken": ""}
    if low == "start taking notes":
        return {"tool": {"name": "notes_start", "args": {}}}
    if low == "summarise my notes":
        return {"tool": {"name": "notes_summary", "args": {"period": "today"}}}
    if m := re.match(r"email (\S+) saying (.+)", low):
        return {"mac_action": {"name": "send_email", "args": {"to": m[1], "subject": "Hi", "body": m[2]}}}
    if m := re.match(r"how long to (.+)", low):
        return {"tool": {"name": "travel_time", "args": {"destination": m[1], "mode": "driving"}}}
    if m := re.match(r"ask claude code to (.+) in (\S+)", low):
        return {"mac_action": {"name": "claude_code", "args": {"task": m[1], "project": m[2]}}}
    if m := re.match(r"(turn (?:on|off) the .+|set the ac to .+)", low):
        return {"tool": {"name": "home", "args": {"command": m[1]}}}  # misfiled on purpose: _normalise moves it
    if m := re.match(r"start (.+) routine", low):
        return {"mac_action": {"name": "home_routine", "args": {"name": m[1]}}}
    if m := re.match(r"tv open (.+)", low):
        return {"mac_action": {"name": "tv_open", "args": {"app": m[1]}}}
    if m := re.match(r"tv press (.+)", low):
        return {"mac_action": {"name": "tv_key", "args": {"key": m[1]}}}
    if low == "help with this code":
        return {"mac_action": {"name": "code_help", "args": {}}}
    if m := re.match(r"note (.+)", low):
        return {"mac_action": {"name": "make_note", "args": {"text": m[1]}}}
    if low in ("battery", "what's on my screen", "delete everything"):
        name = {"battery": "battery", "what's on my screen": "whats_on_screen"}.get(low, "delete_files")
        return {"mac_action": {"name": name, "args": {}}}
    return {}


def _hindi(text: str) -> bool:
    return bool(re.search(r"[ऀ-ॿ]", text))


class Mock(Provider):
    name = "mock"

    def available(self) -> bool:
        return True

    async def complete(self, system, messages, image: Attachment | None = None, json_mode=False) -> Completion:
        last = messages[-1]["text"] if messages else ""
        if "TASK:assistant_audio" in system:
            # Tests send a clip whose bytes are the words, so "look" questions can be exercised offline.
            heard = _decode(image.data_b64) if image else ""
            look = "look" in heard.lower() or "kya hai" in heard.lower()
            out = {"heard": heard, "needs_photo": look, "spoken": "" if look else f"Mock reply: {heard[:60]}",
                   "details": "", "language": "en"}
        elif "TASK:glance" in system:
            seen = _decode(image.data_b64) if image else ""
            out = {"worth": bool(seen.strip()), "note": seen.strip()}
        elif "TASK:dictate" in system:
            out = {"heard": _decode(image.data_b64) if image else ""}
        elif "TASK:summarise" in system:
            out = {"title": "Mock meeting", "summary": "- " + last[:80], "spoken": "Two points, one action item."}
        elif "TASK:tool_answer" in system:
            result = last.split("RESULT:", 1)[-1].strip()
            out = {"spoken": f"From lookup: {result[:80]}", "details": result[:300]}
        else:
            reply = "यह एक परीक्षण उत्तर है।" if _hindi(last) else f"Mock reply: {last[:60]}"
            out = {"spoken": reply, "details": "", "language": "hi" if _hindi(last) else "en", "mac_action": None}
            if "TASK:assistant" in system:
                out.update(_mac_intent(last, system))
        return Completion(json.dumps(out, ensure_ascii=False), self.name, "mock", 1)
