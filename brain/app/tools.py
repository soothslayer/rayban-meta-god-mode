"""Live information CJ can look up: weather, news, quick facts, exchange rates, and a morning briefing.

All free services with no API key. Each tool returns a short plain-text fact sheet; the model then turns it
into a spoken answer in the user's language. Results are data, not instructions (see TOOL_ANSWER).
"""
from __future__ import annotations

import contextvars
import datetime
import os
import time
import urllib.parse
import xml.etree.ElementTree as ElementTree
from zoneinfo import ZoneInfo

import httpx

TIMEOUT = 10
# Wikipedia refuses (403) a User-Agent without a link in it; this one works and carries no personal details.
HEADERS = {"User-Agent": "CJ-glasses/1.0 (https://en.wikipedia.org/wiki/User-Agent_policy; personal, non-commercial)"}

# Open-Meteo weather codes, shortened: https://open-meteo.com/en/docs
WEATHER = {0: "clear sky", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog",
           51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
           71: "light snow", 73: "snow", 75: "heavy snow", 80: "light showers", 81: "showers",
           82: "violent showers", 95: "thunderstorm", 96: "thunderstorm with hail", 99: "severe thunderstorm"}


class ToolError(Exception):
    pass


# Where the user is right now ({"lat": .., "lon": ..}), sent by the phone with each question when allowed.
LOCATION: contextvars.ContextVar[dict | None] = contextvars.ContextVar("location", default=None)
ROUTERS = {"driving": "routed-car", "walking": "routed-foot", "cycling": "routed-bike"}


async def _geocode(place: str, near: dict | None) -> dict:
    params = {"q": place, "format": "json", "limit": 1}
    if near:  # prefer matches around the user ("the airport" means the nearest one)
        lat, lon = near["lat"], near["lon"]
        params["viewbox"] = f"{lon - 0.6},{lat + 0.6},{lon + 0.6},{lat - 0.6}"
    hits = (await _get("https://nominatim.openstreetmap.org/search", **params)).json()
    if not hits and near:
        hits = (await _get("https://nominatim.openstreetmap.org/search", q=place, format="json", limit=1)).json()
    if not hits:
        raise ToolError(f"couldn't find {place} on the map")
    return {"lat": float(hits[0]["lat"]), "lon": float(hits[0]["lon"]), "name": hits[0].get("display_name", place)}


async def travel_time(destination: str, mode: str = "driving") -> str:
    """Route time and distance from the user's location (OpenStreetMap; no live traffic)."""
    try:
        here = LOCATION.get()
        if not here:
            raise ToolError("the phone didn't share its location: ask the user to allow location for CJ")
        if not destination.strip():
            raise ToolError("no destination given")
        mode = mode if mode in ROUTERS else "driving"
        there = await _geocode(destination, here)
        coords = f"{here['lon']},{here['lat']};{there['lon']},{there['lat']}"
        route = (await _get(f"https://routing.openstreetmap.de/{ROUTERS[mode]}/route/v1/{mode}/{coords}",
                            overview="false")).json()
        if route.get("code") != "Ok" or not route.get("routes"):
            raise ToolError(f"no {mode} route found to {destination}")
        r = route["routes"][0]
        minutes, km = round(r["duration"] / 60), r["distance"] / 1000
        link = f"https://www.google.com/maps/dir/?api=1&destination={there['lat']},{there['lon']}&travelmode={mode}"
        return (f"Destination: {there['name'][:160]}\n{mode.title()}: about {minutes} minutes, {km:.1f} km "
                f"(OpenStreetMap route, without live traffic; real times can be longer at rush hour)\nMap: {link}")
    except (ToolError, httpx.HTTPError, ValueError, KeyError) as e:
        return f"LOOKUP FAILED: {e}"


async def _get(url: str, **params) -> httpx.Response:
    async with httpx.AsyncClient(timeout=TIMEOUT, headers=HEADERS, follow_redirects=True) as client:
        r = await client.get(url, params=params or None)
    if r.status_code != 200:
        raise ToolError(f"{urllib.parse.urlparse(url).netloc} answered {r.status_code}")
    return r


async def weather(place: str) -> str:
    place = place.strip()
    if not place:
        raise ToolError("no place given: ask the user which city")
    found = (await _get("https://geocoding-api.open-meteo.com/v1/search", name=place, count=1)).json().get("results")
    if not found:
        raise ToolError(f"couldn't find a place called {place}")
    loc = found[0]
    f = (await _get("https://api.open-meteo.com/v1/forecast", latitude=loc["latitude"], longitude=loc["longitude"],
                    current="temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m",
                    daily="temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code",
                    timezone="auto", forecast_days=3)).json()
    c, d = f["current"], f["daily"]
    lines = [f"Place: {loc['name']}, {loc.get('admin1', '')}, {loc.get('country', '')}",
             f"Now: {c['temperature_2m']}°C (feels {c['apparent_temperature']}°C), "
             f"{WEATHER.get(c['weather_code'], 'unknown')}, humidity {c['relative_humidity_2m']}%, "
             f"wind {c['wind_speed_10m']} km/h"]
    for i, day in enumerate(d["time"]):
        label = ["Today", "Tomorrow", "Day after"][i] + f" ({day})"
        lines.append(f"{label}: {d['temperature_2m_min'][i]}–{d['temperature_2m_max'][i]}°C, "
                     f"{WEATHER.get(d['weather_code'][i], 'unknown')}, rain chance {d['precipitation_probability_max'][i]}%")
    return "\n".join(lines)


async def news(topic: str = "") -> str:
    base = "https://news.google.com/rss"
    params = {"hl": "en-IN", "gl": "IN", "ceid": "IN:en"}
    url = f"{base}/search" if topic.strip() else base
    if topic.strip():
        params["q"] = topic.strip()
    root = ElementTree.fromstring((await _get(url, **params)).text)
    items = root.findall("./channel/item")[:6]
    if not items:
        raise ToolError(f"no news found for {topic or 'top stories'}")
    return "Headlines" + (f" about {topic}" if topic else "") + ":\n" + "\n".join(
        f"- {i.findtext('title', '').strip()} ({(i.findtext('pubDate') or '')[:16]})" for i in items)


async def wiki(query: str) -> str:
    query = query.strip()
    if not query:
        raise ToolError("nothing to look up")
    hits = (await _get("https://en.wikipedia.org/w/api.php", action="opensearch", search=query, limit=1,
                       namespace=0, format="json")).json()
    if not hits[1]:
        raise ToolError(f"Wikipedia has nothing on {query}")
    title = hits[1][0]
    page = (await _get("https://en.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_")))).json()
    return f"Wikipedia, {page.get('title', title)}: {page.get('extract', '')[:1200]}"


async def exchange_rate(base: str, quote: str, amount: float = 1) -> str:
    base, quote = (base or "USD").upper()[:3], (quote or "INR").upper()[:3]
    data = (await _get("https://api.frankfurter.app/latest", amount=amount, **{"from": base, "to": quote})).json()
    rate = data.get("rates", {}).get(quote)
    if rate is None:
        raise ToolError(f"no rate for {base} to {quote}")
    return f"{amount:g} {base} = {rate} {quote} (European Central Bank reference rate, {data.get('date')})"


async def briefing(place: str = "") -> str:
    zone = os.environ.get("CJ_TIMEZONE", "Asia/Kolkata")
    now = datetime.datetime.now(ZoneInfo(zone))
    parts = [f"Today is {now:%A %d %B %Y}, {now:%H:%M}."]
    for job in ([weather(place)] if place else []) + [news()]:
        try:
            parts.append(await job)
        except (ToolError, httpx.HTTPError) as e:
            parts.append(f"(unavailable: {e})")
    if not place:
        parts.append("(No home city known for weather. Suggest the user says 'remember my city is ...'.)")
    return "\n".join(parts)


# Seconds a lookup stays fresh: a follow-up ("and tomorrow?") reuses the answer instead of fetching again.
FRESH = {"weather": 600, "news": 600, "wiki": 86400, "exchange_rate": 1800}
_cache: dict[str, tuple[float, str]] = {}


async def run(name: str, args: dict) -> str:
    """Runs a lookup tool. Returns the fact sheet, or a note saying why it failed (the model explains it)."""
    key = f"{name}:{sorted((k, str(v).strip().lower()) for k, v in args.items())}"
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < FRESH.get(name, 0):
        return hit[1]
    result = await _run(name, args)
    if name in FRESH and not result.startswith("LOOKUP FAILED"):
        _cache[key] = (time.monotonic(), result)
    return result


async def _run(name: str, args: dict) -> str:
    try:
        if name == "weather":
            return await weather(str(args.get("place", "")))
        if name == "news":
            return await news(str(args.get("topic", "")))
        if name == "wiki":
            return await wiki(str(args.get("query", "")))
        if name == "exchange_rate":
            return await exchange_rate(str(args.get("from", "USD")), str(args.get("to", "INR")), float(args.get("amount", 1) or 1))
        if name == "briefing":
            return await briefing(str(args.get("place", "")))
    except (ToolError, httpx.HTTPError, ValueError, KeyError, ElementTree.ParseError) as e:
        return f"LOOKUP FAILED: {e}"
    return f"LOOKUP FAILED: unknown tool {name}"


LOOKUPS = {"weather", "news", "wiki", "exchange_rate", "briefing"}
