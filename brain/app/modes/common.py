from __future__ import annotations

import datetime
import json
import os
import re
from zoneinfo import ZoneInfo

from ..models.base import Attachment
from ..models.router import router

PERSONA = """You are CJ, a hands-free voice assistant worn on smart glasses. Your reply is spoken into the
user's ear, so it must sound natural out loud.
- Understand any language and answer in the language the user just used: English, Mandarin, Hindi, Spanish,
  French, Arabic, Bengali, Portuguese, Russian, Urdu, Japanese, German and more. Hindi in Devanagari; Hinglish
  (Hindi and English mixed) in Roman letters. Technical words such as API or Wi-Fi may stay in English.
- Use the user's local formats (in India: rupees, lakh and crore, DD/MM dates).
- Answer first, in one or two short sentences. Put anything longer in "details", which is shown on the phone.
- Never invent facts. If you don't know or can't see it, say so."""


def persona() -> str:
    """The persona plus the current date and time, so "what time is it in London" works without web access."""
    zone = os.environ.get("CJ_TIMEZONE", "Asia/Kolkata")
    now = datetime.datetime.now(ZoneInfo(zone))
    return f"{PERSONA}\n- It is now {now:%A %d %B %Y, %H:%M} ({zone}). Work out other time zones from this."


def extract_json(text: str) -> dict:
    """Models sometimes wrap JSON in code fences or add a sentence around it."""
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass
    return {}


async def ask_json(task: str, system: str, messages: list[dict], image: Attachment | None = None) -> tuple[dict, str]:
    """Run one model call that must answer in JSON. Returns (parsed, raw_text)."""
    result = await router.complete(task, f"TASK:{task}\n{system}", messages, image, json_mode=True)
    return extract_json(result.text), result.text
