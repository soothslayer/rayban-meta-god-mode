"""Control a Fire TV or Android / Google TV by voice, over Android's network debugging (ADB).

Setup once: turn on ADB debugging on the TV (Fire TV: Settings -> My Fire TV -> Developer Options), then
`./set-tv.sh <tv ip>`. The first command shows "Allow USB debugging?" on the TV; accept it. The key that
identifies this Mac to the TV lives in ~/.cj/adbkey.

Like Mac control, this is a fixed list: open an app, press a remote button, search YouTube. No shell access.
"""
from __future__ import annotations

import os
import re
import threading
import urllib.parse

from . import config

KEYS = {  # spoken name -> Android key code
    "home": 3, "back": 4, "up": 19, "down": 20, "left": 21, "right": 22, "select": 23, "ok": 23,
    "volume_up": 24, "volume_down": 25, "mute": 164, "play_pause": 85, "play": 126, "pause": 127,
    "next": 87, "previous": 88, "fast_forward": 90, "rewind": 89, "sleep": 223, "wake": 224, "power": 26,
}
APPS = {  # spoken name -> words to look for in installed package names
    "youtube": ["youtube"], "netflix": ["netflix"], "prime video": ["avod", "primevideo", "firebat"],
    "hotstar": ["hotstar"], "jiocinema": ["jio"], "spotify": ["spotify"], "stremio": ["stremio"],
    "disney": ["disney", "hotstar"], "zee5": ["zee5"], "sonyliv": ["sonyliv"], "plex": ["plex"],
    "vlc": ["vlc"], "kodi": ["kodi", "xbmc"], "browser": ["silk", "browser", "tvwebbrowser"],
}


class TVError(Exception):
    pass


class _Link:
    """One ADB connection to the TV, reused between commands. Replaced in tests."""

    def __init__(self) -> None:
        self._device = None
        self._host = None
        self._lock = threading.Lock()

    def shell(self, command: str) -> str:
        host = config.load().get("tv_host")
        if not host:
            raise TVError("No TV set up yet. Run set-tv.sh with your TV's IP address.")
        with self._lock:
            try:
                if self._device is None or self._host != host:
                    self._device, self._host = self._connect(host), host
                return (self._device.shell(command, timeout_s=10) or "").strip()
            except TVError:
                raise
            except Exception as e:  # dropped connection: reconnect once
                self._device = None
                try:
                    self._device = self._connect(host)
                    return (self._device.shell(command, timeout_s=10) or "").strip()
                except Exception:
                    raise TVError("I can't reach the TV. Is it on, with ADB debugging enabled?") from e

    @staticmethod
    def _connect(host: str):
        try:
            from adb_shell.adb_device import AdbDeviceTcp
            from adb_shell.auth.keygen import keygen
            from adb_shell.auth.sign_pythonrsa import PythonRSASigner
        except ImportError as e:
            raise TVError("TV control needs the adb-shell package: pip install -r requirements.txt") from e
        key = str(config.home() / "adbkey")
        if not os.path.exists(key):
            keygen(key)
        with open(key) as f, open(key + ".pub") as g:
            signer = PythonRSASigner(g.read(), f.read())
        device = AdbDeviceTcp(host, 5555, default_transport_timeout_s=8.0)
        device.connect(rsa_keys=[signer], auth_timeout_s=30)  # first time: accept the prompt on the TV
        return device


link = _Link()


def _installed() -> list[str]:
    return [line.removeprefix("package:").strip() for line in link.shell("pm list packages").splitlines()]


def _find_package(app: str) -> tuple[str, str]:
    spoken = app.lower().strip()
    hints = next((v for k, v in APPS.items() if k in spoken or spoken in k), [re.sub(r"[^a-z0-9]", "", spoken)])
    packages = _installed()
    for hint in hints:
        hits = sorted((p for p in packages if hint and hint in p.replace(".", "")), key=len)
        if hits:
            return hits[0], next((k for k, v in APPS.items() if hint in v), app)
    raise TVError(f"{app} isn't installed on the TV.")


def _open(a: dict) -> str:
    package, label = _find_package(str(a.get("app", "")))
    # Leanback is the TV launcher category; phone-style apps only have the normal one.
    out = link.shell(f"monkey -p {package} -c android.intent.category.LEANBACK_LAUNCHER 1")
    if "No activities found" in out:
        link.shell(f"monkey -p {package} -c android.intent.category.LAUNCHER 1")
    return f"Opening {label.title() if label.islower() else label} on the TV."


def _key(a: dict) -> str:
    key = str(a.get("key", "")).lower().replace(" ", "_").replace("-", "_")
    if key not in KEYS:
        raise TVError(f"I can't press {key or 'that'} on the TV.")
    link.shell(f"input keyevent {KEYS[key]}")
    return "Done."


def _volume(a: dict) -> str:
    direction = "volume_up" if str(a.get("direction", "up")).lower() in ("up", "louder", "increase") else "volume_down"
    steps = max(1, min(10, int(a.get("steps", 3) or 3)))
    for _ in range(steps):
        link.shell(f"input keyevent {KEYS[direction]}")
    return "Louder." if direction == "volume_up" else "Quieter."


def _youtube(a: dict) -> str:
    query = str(a.get("query", "")).strip()[:150]
    if not query:
        raise TVError("What should I look for on YouTube?")
    package, _ = _find_package("youtube")
    url = "https://www.youtube.com/results?search_query=" + urllib.parse.quote_plus(query)
    link.shell(f"am start -a android.intent.action.VIEW -d '{url}' -p {package}")  # query is URL-encoded: no quotes inside
    return f"Searching YouTube on the TV for {query}."


def _whats_playing(_: dict) -> str:
    out = link.shell("dumpsys window | grep -m1 mCurrentFocus")
    match = re.search(r"\s([\w.]+)/", out)
    package = match.group(1) if match else ""
    name = next((k for k, hints in APPS.items() if any(h in package.replace(".", "") for h in hints)), package or "nothing")
    return f"The TV is showing {name}."


ACTIONS = {"tv_open": _open, "tv_key": _key, "tv_volume": _volume, "tv_youtube": _youtube, "tv_now": _whats_playing}

PROMPT = """
TV control (Fire TV or Android TV): tv_open {app} (youtube, netflix, prime video, hotstar, spotify…),
tv_key {key: home|back|up|down|left|right|select|play_pause|play|pause|next|previous|fast_forward|rewind|mute|
sleep|wake|power}, tv_volume {direction: up|down, steps}, tv_youtube {query}, tv_now (what's on).
Use these only when the user mentions the TV."""
