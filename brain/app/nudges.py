"""CJ speaks up on its own when where you are makes something useful.

- Near a shop and you noted something to buy: "You're at More Supermarket. You noted: buy milk."
- At the office with a meeting coming up: "Standup in 10 minutes."
- Leaving home with Alexa set up: "Heading out? Want me to switch off the lights and AC?" (and CJ listens)

The phone sends its position every minute or so while hands-free is on. Places you name ("remember this is my
home") live in ~/.cj/places.json. Shops come from OpenStreetMap, looked up only when there's something to buy.
"""
from __future__ import annotations

import asyncio
import datetime
import json
import math
import re
import time

import httpx

from . import config, notes, tools

HOME_RADIUS, LEFT_HOME = 150, 400  # metres: inside home, and far enough to count as having left
OFFICE_RADIUS = 250
SHOP_RADIUS = 70
SHOP_AGAIN = 3 * 3600  # don't mention the same shop twice in one trip
ITEM_AGAIN = 12 * 3600  # nor the same thing to buy more than twice a day
MEETING_SOON = 20  # minutes
ROUGH = 150  # metres: a fix vaguer than this can't tell home from the street (network location often is)
# "get" and "pick up" also mean "get the report to Ravi", "pick up Riya from school": not shopping.
BUY = re.compile(r"(?i)\b(buy|purchase|grocer\w*|shopping|kharid\w*|lena hai|laana hai|le aana)\b")
OVERPASS = "https://overpass-api.de/api/interpreter"
SHOPS = "supermarket|convenience|grocery|greengrocer|chemist|department_store|mall|bakery|butcher|hardware"


def _places_path():
    return config.home() / "places.json"


def places() -> dict[str, dict]:
    try:
        return json.loads(_places_path().read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_place(name: str, where: dict | None) -> str:
    name = re.sub(r"[^\w ]", "", name.lower()).strip()[:40] or "home"
    if not where:
        return "I can't tell where you are. Allow location for CJ on your phone first."
    saved = {**places(), name: {"lat": where["lat"], "lon": where["lon"]}}
    _places_path().write_text(json.dumps(saved, indent=1))
    _places_path().chmod(0o600)
    return f"Got it, this is your {name}."


def distance(a: dict, b: dict) -> float:
    """Metres between two {lat, lon} points."""
    la1, la2 = math.radians(a["lat"]), math.radians(b["lat"])
    dla, dlo = la2 - la1, math.radians(b["lon"] - a["lon"])
    h = math.sin(dla / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlo / 2) ** 2
    return 6_371_000 * 2 * math.asin(math.sqrt(h))


def shopping_list() -> list[str]:
    """Things you noted to buy in the last two weeks."""
    since = (datetime.datetime.now() - datetime.timedelta(days=14)).isoformat(timespec="minutes")
    return [n["text"] for n in notes.load() if n.get("kind") == "note" and n["t"] >= since and BUY.search(n["text"])][-4:]


_shops: dict[tuple, tuple[float, list[dict]]] = {}


async def nearby_shops(here: dict) -> list[dict]:
    cell = (round(here["lat"], 3), round(here["lon"], 3))
    hit = _shops.get(cell)
    if hit and time.monotonic() - hit[0] < 3600:
        return hit[1]
    lat, lon = here["lat"], here["lon"]
    query = (f'[out:json][timeout:8];(nwr(around:{SHOP_RADIUS},{lat},{lon})[shop~"{SHOPS}"];'
             f'nwr(around:{SHOP_RADIUS},{lat},{lon})[amenity~"pharmacy|marketplace"];);out center 5;')
    async with httpx.AsyncClient(timeout=6, headers=tools.HEADERS) as client:
        try:
            r = await client.post(OVERPASS, data={"data": query})
            r.raise_for_status()
            found = [{"id": e["id"], "name": e.get("tags", {}).get("name") or "a shop"} for e in r.json().get("elements", [])]
        except (httpx.HTTPError, ValueError):
            found = await _search_shops(client, here)  # the public Overpass servers are often at capacity
    _shops[cell] = (time.monotonic(), found)
    return found


async def _search_shops(client: httpx.AsyncClient, here: dict) -> list[dict]:
    """Shops within SHOP_RADIUS via OpenStreetMap's search (one request per kind, within its 1 per second limit)."""
    box = 0.0015  # ~160 m each way
    found = []
    for kind in ("supermarket", "convenience store", "pharmacy"):
        r = await client.get("https://nominatim.openstreetmap.org/search", params={
            "q": kind, "format": "jsonv2", "limit": 5, "bounded": 1,
            "viewbox": f"{here['lon'] - box},{here['lat'] + box},{here['lon'] + box},{here['lat'] - box}"})
        if r.status_code == 200:
            found += [{"id": h["osm_id"], "name": h.get("name") or "a shop"} for h in r.json()
                      if distance(here, {"lat": float(h["lat"]), "lon": float(h["lon"])}) <= SHOP_RADIUS]
        await asyncio.sleep(1.1)
    return found


class Nudger:
    """Remembers what it already said, so each nudge comes once per visit."""

    def __init__(self) -> None:
        self.at_home: bool | None = None
        self.away_fixes = 0
        self.shops_said: dict[int, float] = {}
        self.items_said: dict[str, float] = {}
        self.meetings_said: set[str] = set()

    async def check(self, here: dict, upcoming=None, alexa_ready=None) -> dict:
        saved = places()
        rough = (here.get("acc") or 0) > ROUGH
        if "home" in saved and not rough:
            far = distance(here, saved["home"])
            if far <= HOME_RADIUS:
                self.at_home, self.away_fixes = True, 0
            elif far >= LEFT_HOME:
                self.away_fixes += 1
                # Two fixes in a row away from home, so one jumpy reading doesn't send you "out".
                if self.at_home and self.away_fixes >= 2:
                    self.at_home = False
                    if (alexa_ready or _alexa_ready)():
                        return {"say": "Heading out? Want me to switch off the lights and the AC at home?", "converse": True}
                elif self.at_home is None:
                    self.at_home = False
        if "office" in saved and not rough and distance(here, saved["office"]) <= OFFICE_RADIUS:
            # Calendar via AppleScript takes a while: off the event loop, so live conversations don't stutter.
            for title, minutes in await asyncio.to_thread(upcoming or _upcoming):
                if title not in self.meetings_said and 0 <= minutes <= MEETING_SOON:
                    self.meetings_said.add(title)
                    return {"say": f"{title} in {minutes} minutes." if minutes else f"{title} is starting now.",
                            "converse": False}
        now = time.monotonic()
        items = [i for i in shopping_list() if now - self.items_said.get(i, -ITEM_AGAIN) >= ITEM_AGAIN]
        near_home = "home" in saved and distance(here, saved["home"]) <= LEFT_HOME
        if items and not rough and not near_home:  # the shop downstairs isn't news
            try:
                shops = await nearby_shops(here)
            except (httpx.HTTPError, ValueError):
                shops = []
            for shop in shops:
                if now - self.shops_said.get(shop["id"], -SHOP_AGAIN) >= SHOP_AGAIN:
                    self.shops_said[shop["id"]] = now
                    self.items_said.update({i: now for i in items})
                    where = f"You're near {shop['name']}." if shop["name"] != "a shop" else "There's a shop right here."
                    return {"say": f"{where} You noted: " + "; ".join(i.rstrip(".") for i in items) + ".",
                            "converse": False}
        return {"say": "", "converse": False}


def _alexa_ready() -> bool:
    return bool(config.key("alexa"))


def _upcoming() -> list[tuple[str, int]]:
    """Calendar events starting in the next 20 minutes, as (title, minutes away)."""
    from . import mac  # mac imports a lot; only needed here
    script = f'''set d0 to current date
set d1 to d0 + {MEETING_SOON} * minutes
set out to ""
tell application "Calendar"
  repeat with c in calendars
    repeat with e in (every event of c whose start date ≥ d0 and start date ≤ d1 and allday event is false)
      set out to out & (((start date of e) - d0) div 60) & tab & (summary of e) & linefeed
    end repeat
  end repeat
end tell
return out'''
    try:
        rows = [line.split("\t", 1) for line in mac._osa(script).splitlines() if "\t" in line]
    except Exception:
        return []
    return sorted(((title.strip(), int(minutes)) for minutes, title in rows), key=lambda r: r[1])


NUDGER = Nudger()
