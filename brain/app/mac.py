"""Control this MacBook by voice from the glasses.

Only the fixed actions below can run, never an arbitrary command: a misheard word or text on a web page must
not be able to delete files or run scripts. App names are matched against the apps actually installed, URLs
must be http(s), and every command runs as an argument list, never through a shell. Actions that could lose
work ask for a spoken "yes" first.
"""
from __future__ import annotations

import asyncio
import contextvars
import glob
import os
import re
import subprocess
import tempfile
import time
import urllib.parse
from dataclasses import dataclass
from typing import Callable

from . import agent, alexa, tv
from .events import bus

CONFIRM_SECONDS = 30


class MacError(Exception):
    pass


def _run(args: list[str]) -> str:
    """Runs one command (no shell). Replaced in tests."""
    done = subprocess.run(args, capture_output=True, text=True, timeout=15)
    if done.returncode != 0:
        err = done.stderr.strip()
        if "not allowed to send keystrokes" in err or "assistive access" in err or "-1719" in err or "-25211" in err:
            raise MacError("I need Accessibility permission for that. In System Settings, Privacy and Security, "
                           "Accessibility, turn on the app running CJ's brain.")
        if "-1743" in err or "Not authorized to send Apple events" in err:
            raise MacError("macOS blocked that. Allow Automation for the app running CJ's brain in System Settings, "
                           "Privacy and Security, Automation.")
        raise MacError(err[:200] or f"{args[0]} failed")
    return done.stdout.strip()


def _osa(script: str) -> str:
    return _run(["osascript", "-e", script])


def installed_apps() -> list[str]:
    paths = ["/Applications/*.app", "/Applications/*/*.app", "/System/Applications/*.app",
             "/System/Applications/Utilities/*.app", os.path.expanduser("~/Applications/*.app")]
    return sorted({os.path.basename(p)[:-4] for pattern in paths for p in glob.glob(pattern)})


def find_app(name: str) -> str:
    """Matches a spoken name ("chrome", "vs code") to an installed app ("Google Chrome", "Visual Studio Code")."""
    spoken = re.sub(r"[^a-z0-9]", "", name.lower())
    aliases = {"vscode": "visualstudiocode", "code": "visualstudiocode", "chrome": "googlechrome",
               "browser": "safari", "settings": "systemsettings", "files": "finder"}
    spoken = aliases.get(spoken, spoken)
    if not spoken:
        raise MacError("Which app?")
    apps = installed_apps()
    keyed = {re.sub(r"[^a-z0-9]", "", a.lower()): a for a in apps}
    if spoken in keyed:
        return keyed[spoken]
    partial = [a for k, a in keyed.items() if spoken in k]
    if len(partial) == 1:
        return partial[0]
    raise MacError(f"I couldn't find an app called {name}." if not partial
                   else f"Which one: {', '.join(partial[:3])}?")


def _media_app() -> str:
    running = _osa('tell application "System Events" to get name of every process whose background only is false')
    return "Spotify" if "Spotify" in running else "Music"


def _volume_level() -> int:
    return int(_osa("output volume of (get volume settings)") or 0)


def _open_app(a: dict) -> str:
    app = find_app(str(a.get("app", "")))
    _run(["open", "-a", app])
    return f"Opened {app}."


def _quit_app(a: dict) -> str:
    app = find_app(str(a.get("app", "")))
    _osa(f'tell application "{app}" to quit')  # safe to quote: app comes from the installed list
    return f"Quit {app}."


def _open_website(a: dict) -> str:
    url = str(a.get("url", "")).strip()
    if not re.match(r"^https?://[^\s]+$", url):
        url = "https://" + url if re.match(r"^[\w.-]+\.[a-z]{2,}(/\S*)?$", url) else ""
    if not url:
        raise MacError("That doesn't look like a website address.")
    _run(["open", url])
    return f"Opened {urllib.parse.urlparse(url).netloc}."


def _web_search(a: dict) -> str:
    query = str(a.get("query", "")).strip()[:200]
    if not query:
        raise MacError("What should I search for?")
    _run(["open", "https://www.google.com/search?q=" + urllib.parse.quote_plus(query)])
    return f"Searching for {query}."


def _set_volume(a: dict) -> str:
    level = max(0, min(100, int(a.get("level", 50))))
    _osa(f"set volume output volume {level}")
    return f"Volume {level}."


def _volume_step(step: int) -> Callable[[dict], str]:
    def run(_: dict) -> str:
        level = max(0, min(100, _volume_level() + step))
        _osa(f"set volume output volume {level}")
        return f"Volume {level}."
    return run


def _media(a: dict) -> str:
    command = {"play": "play", "pause": "pause", "next": "next track", "previous": "previous track",
               "playpause": "playpause"}.get(str(a.get("command", "playpause")).lower())
    if not command:
        raise MacError("Play, pause, next or previous?")
    app = _media_app()
    _osa(f'tell application "{app}" to {command}')
    return {"play": "Playing.", "pause": "Paused.", "next track": "Next track.",
            "previous track": "Previous track.", "playpause": "Done."}[command]


def _battery(_: dict) -> str:
    out = _run(["pmset", "-g", "batt"])
    match = re.search(r"(\d+)%;\s*([^;]+);\s*([^\s;]+(?: remaining)?)?", out)
    if not match:
        return "I couldn't read the battery."
    percent, state, remaining = match.group(1), match.group(2).strip(), (match.group(3) or "").strip()
    extra = f", {remaining.replace(' remaining', '')} left" if remaining and ":" in remaining and state == "discharging" else ""
    return f"Your Mac is at {percent} percent, {state}{extra}."


def _applescript_text(text: str) -> str:
    """Text as an AppleScript string literal, so it can only ever be note content, never code."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _make_note(a: dict) -> str:
    text = str(a.get("text", "")).strip()[:2000]
    if not text:
        raise MacError("What should the note say?")
    title = text.split("\n")[0][:60]
    _osa(f'tell application "Notes" to make new note with properties {{name:{_applescript_text(title)}, '
         f'body:{_applescript_text(text)}}}')
    return "Saved a note on your Mac."


def _running_apps(_: dict) -> str:
    names = _osa('tell application "System Events" to get name of every process whose background only is false')
    apps = [n.strip() for n in names.split(",") if n.strip() and n.strip() != "Finder"]
    return "Open now: " + ", ".join(apps[:8]) + ("." if len(apps) <= 8 else f", and {len(apps) - 8} more.")


def screenshot() -> str:
    """A downscaled JPEG of the screen, base64. Needs Screen Recording permission for the app running the brain."""
    import base64
    path = os.path.join(tempfile.gettempdir(), f"cj-screen-{os.getpid()}.jpg")
    try:
        _run(["screencapture", "-x", "-t", "jpg", path])
        _run(["sips", "-Z", "1600", path])
        with open(path, "rb") as f:
            return base64.b64encode(f.read()).decode()
    finally:
        if os.path.exists(path):
            os.remove(path)


TERMINALS = {"Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty", "WezTerm", "Hyper", "Tabby"}

# Spoken key name -> (key code, modifiers). A fixed list: CJ can't press arbitrary key combinations.
KEYS: dict[str, tuple[int, list[str]]] = {
    "enter": (36, []), "escape": (53, []), "tab": (48, []), "space": (49, []),
    "page_down": (121, []), "page_up": (116, []), "scroll_down": (125, []), "scroll_up": (126, []),
    "new_tab": (17, ["command"]), "close_tab": (13, ["command"]), "reload": (15, ["command"]),
    "next_tab": (48, ["control"]), "previous_tab": (48, ["control", "shift"]),
    "back": (33, ["command"]), "forward": (30, ["command"]), "copy": (8, ["command"]), "paste": (9, ["command"]),
    "undo": (6, ["command"]), "redo": (6, ["command", "shift"]), "select_all": (0, ["command"]),
    "save": (1, ["command"]), "find": (3, ["command"]), "full_screen": (3, ["command", "control"]),
    "new_window": (45, ["command"]), "minimize": (46, ["command"]), "spotlight": (49, ["command"]),
    "zoom_in": (24, ["command"]), "zoom_out": (27, ["command"]),
}

DOCUMENTS = {".pdf", ".doc", ".docx", ".xls", ".xlsx", ".csv", ".ppt", ".pptx", ".key", ".pages", ".numbers",
             ".txt", ".md", ".rtf", ".png", ".jpg", ".jpeg", ".heic", ".gif", ".mp4", ".mov", ".mp3", ".m4a"}


def _frontmost() -> str:
    return _osa('tell application "System Events" to get name of first process whose frontmost is true')


def _press_key(a: dict) -> str:
    key = str(a.get("key", "")).lower().replace(" ", "_").replace("-", "_")
    if key == "return":
        key = "enter"
    if key not in KEYS:
        raise MacError(f"I can't press {key or 'that'}.")
    if key == "enter" and _frontmost() in TERMINALS:
        raise MacError("I won't press Enter in a terminal, so a misheard word can't run a command.")
    code, mods = KEYS[key]
    using = f" using {{{', '.join(m + ' down' for m in mods)}}}" if mods else ""
    _osa(f'tell application "System Events" to key code {code}{using}')
    return "Done."


def _type_text(a: dict) -> str:
    # One line, no control characters, and never followed by Enter.
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(a.get("text", ""))).strip()[:500]
    if not text:
        raise MacError("What should I type?")
    _osa(f'tell application "System Events" to keystroke {_applescript_text(text)}')
    return "Typed it."


def _brightness(step: int) -> Callable[[dict], str]:
    def run(_: dict) -> str:
        code = 144 if step > 0 else 145
        for _ in range(3):
            _osa(f'tell application "System Events" to key code {code}')
        return "Brighter." if step > 0 else "Dimmer."
    return run


def _dark_mode(a: dict) -> str:
    want = str(a.get("mode", "toggle")).lower()
    value = {"on": "true", "dark": "true", "off": "false", "light": "false"}.get(want, "not dark mode")
    _osa(f'tell application "System Events" to tell appearance preferences to set dark mode to {value}')
    return "Done."


def _open_file(a: dict) -> str:
    """Finds a document by name in your home folder (newest match) and opens it. Never apps or scripts."""
    name = re.sub(r"[^\w .\-]", " ", str(a.get("name", ""))).strip()[:80]
    if not name:
        raise MacError("Which file?")
    home = os.path.expanduser("~")
    hits = [p for p in _run(["mdfind", "-onlyin", home, "-name", name]).splitlines()
            if p.startswith(home + "/") and "/Library/" not in p and "/." not in p
            and (os.path.splitext(p)[1].lower() in DOCUMENTS or (os.path.isdir(p) and not p.endswith((".app", ".bundle"))))]
    if not hits:
        raise MacError(f"I couldn't find a document called {name}.")
    best = max(hits[:200], key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0)
    _run(["open", best])
    return f"Opened {os.path.basename(best)}."


def _shortcuts() -> list[str]:
    return [s for s in _run(["shortcuts", "list"]).splitlines() if s.strip()]


def _run_shortcut(a: dict) -> str:
    wanted = re.sub(r"[^a-z0-9]", "", str(a.get("name", "")).lower())
    names = _shortcuts()
    matches = [s for s in names if wanted and wanted in re.sub(r"[^a-z0-9]", "", s.lower())]
    exact = [s for s in matches if re.sub(r"[^a-z0-9]", "", s.lower()) == wanted]
    choice = (exact or matches or [None])[0]
    if not choice:
        raise MacError(f"You don't have a shortcut called {a.get('name')}." if names else "You don't have any Shortcuts yet.")
    _run(["shortcuts", "run", choice])  # one of your own Shortcuts, by its exact name
    return f"Ran {choice}."


def _list_shortcuts(_: dict) -> str:
    names = _shortcuts()
    return ("Your shortcuts: " + ", ".join(names[:10]) + ".") if names else "You don't have any Shortcuts yet."


def _calendar_today(_: dict) -> str:
    script = '''set d0 to current date
set hours of d0 to 0
set minutes of d0 to 0
set seconds of d0 to 0
set d1 to d0 + 1 * days
set out to ""
tell application "Calendar"
  repeat with c in calendars
    repeat with e in (every event of c whose start date ≥ d0 and start date < d1)
      set out to out & (time string of (start date of e)) & " " & (summary of e) & linefeed
    end repeat
  end repeat
end tell
return out'''
    events = [e for e in _osa(script).splitlines() if e.strip()]
    if not events:
        return "Nothing on your calendar today."
    return f"{len(events)} event{'s' * (len(events) != 1)} today: " + "; ".join(e.replace(":00 ", " ", 1) for e in sorted(events)[:6]) + "."


def _make_reminder(a: dict) -> str:
    text = str(a.get("text", "")).strip()[:300]
    if not text:
        raise MacError("What should the reminder say?")
    _osa(f'tell application "Reminders" to make new reminder with properties {{name:{_applescript_text(text)}}}')
    return "Added to your Reminders."


DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})$")


def _calendar_add(a: dict) -> str:
    """"Add this to my calendar" while looking at a poster or invite: the model reads the details off the photo."""
    title = str(a.get("title", "")).strip()[:200]
    date, at = str(a.get("date", "")).strip(), str(a.get("time", "") or "").strip()
    d, t = DATE_RE.match(date), TIME_RE.match(at) if at else None
    if not title or not d:
        raise MacError("I couldn't read the event's name and date.")
    if at and not t:
        raise MacError("I couldn't read the event's time.")
    year, month, day = (int(x) for x in d.groups())
    hour, minute = (int(x) for x in t.groups()) if t else (0, 0)
    minutes = max(15, min(24 * 60, int(float(a.get("duration_minutes") or 60))))
    place = str(a.get("location", "") or "").strip()[:200]
    end = f"set e1 to e0 + {minutes} * minutes" if t else "set e1 to e0 + 1 * days"
    _osa(f'''set e0 to current date
set day of e0 to 1
set year of e0 to {year}
set month of e0 to {month}
set day of e0 to {day}
set hours of e0 to {hour}
set minutes of e0 to {minute}
set seconds of e0 to 0
{end}
tell application "Calendar"
  set c to first calendar whose writable is true
  make new event at end of events of c with properties {{summary:{_applescript_text(title)}, start date:e0, end date:e1, location:{_applescript_text(place)}, allday event:{"false" if t else "true"}}}
end tell''')
    when = f"{day} {('January February March April May June July August September October November December').split()[month - 1]}"
    return f"Added {title} on {when}" + (f" at {hour}:{minute:02d}" if t else "") + " to your calendar."


def _contact_add(a: dict) -> str:
    """"Save this contact" while looking at a business card."""
    name = str(a.get("name", "")).strip()[:120]
    phone = re.sub(r"[^\d+]", "", str(a.get("phone", "") or ""))[:20]
    email = str(a.get("email", "") or "").strip().lower()[:120]
    if not name or not (phone or (email and EMAIL_RE.match(email))):
        raise MacError("I couldn't read a name and a number or email.")
    first, _, last = name.partition(" ")
    lines = [f'set p to make new person with properties {{first name:{_applescript_text(first)}, '
             f'last name:{_applescript_text(last)}, organization:{_applescript_text(str(a.get("company", "") or "")[:120])}}}']
    if phone:
        lines.append(f'make new phone at end of phones of p with properties {{label:"mobile", value:{_applescript_text(phone)}}}')
    if email and EMAIL_RE.match(email):
        lines.append(f'make new email at end of emails of p with properties {{label:"work", value:{_applescript_text(email)}}}')
    _osa('tell application "Contacts"\n  ' + "\n  ".join(lines) + "\n  save\nend tell")
    return f"Saved {name} to your contacts."


def _wifi_device() -> str:
    ports = _run(["networksetup", "-listallhardwareports"]).splitlines()
    for i, line in enumerate(ports):
        if line.strip() in ("Hardware Port: Wi-Fi", "Hardware Port: AirPort") and i + 1 < len(ports):
            return ports[i + 1].split(":", 1)[1].strip()
    return "en0"


def _wifi_join(a: dict) -> str:
    """"Connect to this Wi-Fi" while looking at the card with the network name and password."""
    ssid, password = str(a.get("ssid", "")).strip()[:32], str(a.get("password", "") or "").strip()[:63]
    if not ssid:
        raise MacError("I couldn't read the Wi-Fi name.")
    out = _run(["networksetup", "-setairportnetwork", _wifi_device(), ssid, *([password] if password else [])])
    if out:  # networksetup prints only when it failed
        raise MacError(f"Couldn't join {ssid}: {out[:120]}")
    return f"Your Mac is joining {ssid}."


# Actions the phone carries out (it holds the SIM). The brain confirms first, then hands them back with the answer.
PHONE: contextvars.ContextVar[dict | None] = contextvars.ContextVar("phone_action", default=None)
PHONE_ACTIONS = {"call_number"}


def _call_number(a: dict) -> str:
    number = re.sub(r"[^\d+]", "", str(a.get("number", "")))
    if len(number.lstrip("+")) < 3:
        raise MacError("I couldn't read the number.")
    return f"Calling {a.get('name') or ' '.join(number)}."


def _storage(_: dict) -> str:
    fields = _run(["df", "-k", "/System/Volumes/Data"]).splitlines()[-1].split()
    free_gb = int(fields[3]) / 1024 / 1024
    return f"You have {free_gb:.0f} gigabytes free."


def _clipboard(_: dict) -> str:
    text = _run(["pbpaste"]).strip()
    return ("Your clipboard says: " + text[:300]) if text else "Your clipboard is empty."


def _save_screenshot(_: dict) -> str:
    path = os.path.expanduser(f"~/Desktop/CJ screenshot {time.strftime('%Y-%m-%d at %H.%M.%S')}.png")
    _run(["screencapture", "-x", path])
    return "Saved a screenshot to your Desktop."


def _hide_app(a: dict) -> str:
    app = find_app(str(a.get("app", "")))
    _osa(f'tell application "System Events" to set visible of process "{app}" to false')
    return f"Hid {app}."


def _youtube(a: dict) -> str:
    query = str(a.get("query", "")).strip()[:200]
    if not query:
        raise MacError("What should I look for on YouTube?")
    _run(["open", "https://www.youtube.com/results?search_query=" + urllib.parse.quote_plus(query)])
    return f"Here's {query} on YouTube."


def _spotify_search(a: dict) -> str:
    query = str(a.get("query", "")).strip()[:200]
    if not query:
        raise MacError("What should I look for on Spotify?")
    _run(["open", "spotify:search:" + urllib.parse.quote(query)])
    return f"Searching Spotify for {query}."


@dataclass(frozen=True)
class Action:
    run: Callable[[dict], str]
    confirm: str | None = None  # question asked before running; None = runs straight away


ACTIONS: dict[str, Action] = {
    "open_app": Action(_open_app),
    "quit_app": Action(_quit_app, confirm="Quit {app}? Unsaved work could be lost."),
    "open_website": Action(_open_website),
    "web_search": Action(_web_search),
    "set_volume": Action(_set_volume),
    "volume_up": Action(_volume_step(+15)),
    "volume_down": Action(_volume_step(-15)),
    "mute": Action(lambda a: (_osa("set volume with output muted"), "Muted.")[1]),
    "unmute": Action(lambda a: (_osa("set volume without output muted"), "Unmuted.")[1]),
    "media": Action(_media),
    "lock_screen": Action(lambda a: (_run(["pmset", "displaysleepnow"]), "Locked.")[1]),
    "sleep_mac": Action(lambda a: (_run(["pmset", "sleepnow"]), "Going to sleep.")[1],
                        confirm="Put your Mac to sleep?"),
    "battery": Action(_battery),
    "running_apps": Action(_running_apps),
    "make_note": Action(_make_note),
    "press_key": Action(_press_key),
    "type_text": Action(_type_text),
    "brightness_up": Action(_brightness(+1)),
    "brightness_down": Action(_brightness(-1)),
    "dark_mode": Action(_dark_mode),
    "open_file": Action(_open_file),
    "run_shortcut": Action(_run_shortcut),
    "list_shortcuts": Action(_list_shortcuts),
    "calendar_today": Action(_calendar_today),
    "make_reminder": Action(_make_reminder),
    "storage": Action(_storage),
    "read_clipboard": Action(_clipboard),
    "save_screenshot": Action(_save_screenshot),
    "hide_app": Action(_hide_app),
    "youtube": Action(_youtube),
    "spotify_search": Action(_spotify_search),
    # Claude Code remote (agent.py): runs in the background; CJ announces the result when it's done.
    "claude_code": Action(lambda a: _claude_code(a), confirm="Ask Claude Code to {task} in {project}?"),
    "claude_code_status": Action(lambda a: agent.status()),
    # Email (Mail app): always read back and sent only after a spoken yes.
    "calendar_add": Action(_calendar_add),
    "contact_add": Action(_contact_add),
    "wifi_join": Action(_wifi_join),
    "call_number": Action(_call_number, confirm="Call {spoken_number}?"),
    "send_email": Action(lambda a: _send_email(a),
                         confirm="Email {name}, subject {subject}. It says: {preview}. Send it?"),
    # TV control (tv.py): Fire TV or Android TV over network debugging.
    **{name: Action(run) for name, run in tv.ACTIONS.items()},
    # Smart home (alexa.py): lights, plugs, AC and routines, through the user's Alexa.
    **{name: Action(run) for name, run in alexa.ACTIONS.items()},
    # "whats_on_screen" and "code_help" are handled in modes/assistant.py: they need a vision call.
}


EMAIL_RE = re.compile(r"^[\w.+\-]+@[\w\-]+(\.[\w\-]+)+$")


def resolve_recipient(spoken: str) -> tuple[str, str]:
    """An email address as said, or a name looked up in the Mac's Contacts. Returns (name, address)."""
    spoken = spoken.strip().strip(".")
    compact = spoken.replace(" at ", "@").replace(" dot ", ".").replace(" ", "").lower()
    if EMAIL_RE.match(compact):
        return compact, compact
    if not spoken:
        raise MacError("Who should I email?")
    found = _osa(f'tell application "Contacts" to get {{name, value of first email}} of '
                 f'(first person whose name contains {_applescript_text(spoken)} and (count of emails) > 0)')
    parts = [p.strip() for p in found.split(",")]
    if len(parts) < 2 or not EMAIL_RE.match(parts[-1]):
        raise MacError(f"I couldn't find an email address for {spoken} in your Contacts.")
    return parts[0], parts[-1]


def _send_email(a: dict) -> str:
    """Sends through the Mail app with the account already set up there; no password ever reaches CJ."""
    address = str(a.get("to", ""))
    if not EMAIL_RE.match(address):
        raise MacError("That isn't a valid email address.")
    _osa(f'''tell application "Mail"
  set m to make new outgoing message with properties {{subject:{_applescript_text(str(a.get("subject", "")))}, content:{_applescript_text(str(a.get("body", "")))}, visible:false}}
  tell m to make new to recipient at end of to recipients with properties {{address:{_applescript_text(address)}}}
  send m
end tell''')
    return f"Sent to {a.get('name') or address}."


def _claude_code(a: dict) -> str:
    job = agent.start(str(a.get("project", "")), str(a.get("task", "")), bool(a.get("continue")))
    return f"Claude Code is on it in {job.project}. I'll tell you when it's done."

PROMPT = """
You can also control the user's MacBook. When they clearly ask for something on their Mac, laptop or
computer (or an obvious computer action like "new tab" or "type this"), set "mac_action" to
{"name": ..., "args": {...}} and make "spoken" a short acknowledgement. Actions:
open_app {app} (also "switch to"), quit_app {app}, hide_app {app}, running_apps, open_website {url},
web_search {query}, youtube {query}, spotify_search {query}, set_volume {level 0-100}, volume_up, volume_down,
mute, unmute, media {command: play|pause|next|previous}, brightness_up, brightness_down,
dark_mode {mode: on|off|toggle}, press_key {key: enter|escape|tab|space|page_down|page_up|scroll_down|
scroll_up|new_tab|close_tab|next_tab|previous_tab|reload|back|forward|copy|paste|undo|redo|select_all|save|
find|full_screen|new_window|minimize|spotlight|zoom_in|zoom_out}, type_text {text}, open_file {name}
(a document or folder by name), run_shortcut {name} (one of the user's macOS Shortcuts), list_shortcuts,
calendar_today, make_reminder {text}, make_note {text}, storage, read_clipboard, save_screenshot,
lock_screen, sleep_mac, battery, whats_on_screen, code_help {question} (looks at the code or error on the
Mac's screen and helps with it like a senior engineer).
Look and do (usually with a photo from the glasses: read the details off it exactly, never guess missing ones):
calendar_add {title, date: YYYY-MM-DD, time: HH:MM 24h or empty for all day, duration_minutes, location} ("add this
to my calendar" at a poster or invite), contact_add {name, phone, email, company} ("save this contact" at a business
card), wifi_join {ssid, password} ("connect to this Wi-Fi" at the card with the network details), call_number
{number, name} ("call this number"; the phone makes the call after the user says yes). For "turn this whiteboard /
page into notes", use the note_add tool with a clean, complete write-up of what the photo shows.
Email: send_email {to (a name from Contacts or an email address), subject, body (write the email from what the user
 said: short, polite, in their language)}; it is read back and only sent after the user says yes.
Claude Code on the Mac: claude_code {project, task, continue: true to follow up on the last job} (gives a coding
task to Claude Code in one of the user's projects; write the task clearly in English), claude_code_status.
""" + tv.PROMPT + alexa.PROMPT + """
Mac, TV, smart home and Claude Code actions always go in "mac_action" (never in "tool"), and "spoken" must not claim
the action already happened. Otherwise "mac_action" is null. Never use it for anything not on this list,
and only when the user clearly asked for it."""

_pending: tuple[str, dict, float] | None = None


def pending_prompt() -> str:
    """Added to the prompt while a risky action waits for a spoken yes or no."""
    if not _pending or time.time() - _pending[2] > CONFIRM_SECONDS:
        return ""
    name, args, _ = _pending
    return (f'\nWaiting for confirmation: {name} {args}. If the user agrees (yes, haan, ok, kar do) set "confirm": true; '
            'if they decline set "confirm": false; otherwise leave "confirm" out.')


async def handle(data: dict) -> str | None:
    """Runs the action the model chose, or a confirmed pending one. Returns what to say, or None if nothing ran."""
    global _pending
    if _pending and "confirm" in data:
        name, args, asked_at = _pending
        _pending = None
        if data["confirm"] is True and time.time() - asked_at <= CONFIRM_SECONDS:
            return await _execute(name, args)
        if data["confirm"] is False:
            return "Okay, I won't."
    _pending = None
    choice = data.get("mac_action")
    if not isinstance(choice, dict) or choice.get("name") not in ACTIONS:
        return None
    name = choice["name"]
    args = choice.get("args") if isinstance(choice.get("args"), dict) else {}
    question = ACTIONS[name].confirm
    if question:
        try:
            # Contacts and project lookups take a second or two: off the event loop, so live audio keeps flowing.
            args = await asyncio.to_thread(_prepare, name, args)
        except (MacError, agent.AgentError) as e:
            return str(e)
        _pending = (name, args, time.time())
        bus.emit("mac_confirm", action=name, args=args)
        return question.format(**args) if "{" in question else question
    return await _execute(name, args)


def _prepare(name: str, args: dict) -> dict:
    """Fills in what the "are you sure?" question needs: the real app, project, contact or number."""
    if "app" in args:
        args = {**args, "app": find_app(str(args["app"]))}
    if name == "claude_code":
        args = {**args, "project": agent.find_project(str(args.get("project", "")))[0],
                "task": str(args.get("task", "")).strip().rstrip(".")}
    if name == "call_number":
        number = re.sub(r"[^\d+]", "", str(args.get("number", "")))
        if len(number.lstrip("+")) < 3:
            raise MacError("I couldn't read the number.")
        who = str(args.get("name", "") or "").strip()
        args = {**args, "number": number, "spoken_number": f"{who}, " * bool(who) + " ".join(number)}
    if name == "send_email":
        person, address = resolve_recipient(str(args.get("to", "")))
        body = re.sub(r"\s+", " ", str(args.get("body", ""))).strip()
        if not body:
            raise MacError("What should the email say?")
        args = {**args, "to": address, "name": person, "body": body,
                "subject": str(args.get("subject") or body[:60]).strip(), "preview": body[:160].rstrip(" .!?")}
    return args


async def _execute(name: str, args: dict) -> str:
    try:
        result = await asyncio.to_thread(ACTIONS[name].run, args)
        if name in PHONE_ACTIONS:
            PHONE.set({"action": name, "number": args.get("number", ""), "who": args.get("name", "")})
        bus.emit("mac_action", action=name, args=args, result=result)
        return result
    except (MacError, tv.TVError, alexa.AlexaError, agent.AgentError) as e:
        bus.emit("mac_action", action=name, args=args, error=str(e)[:200])
        return str(e)
    except (subprocess.TimeoutExpired, ValueError) as e:
        bus.emit("mac_action", action=name, args=args, error=str(e)[:200])
        return "That didn't work."
