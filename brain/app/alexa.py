"""Smart home through Alexa: CJ types what you said into Alexa, as if you'd said it to your Echo.

So anything your Alexa can do works from the glasses: lights, plugs, AC, fans, TVs, scenes and routines, and
devices first set up in Google Home or Smart Life as long as they're also linked to Alexa.

This uses the Alexa app's own (unofficial) web API, like the open-source alexa-remote-control script. Setup once:
get a refresh token by signing in with https://github.com/adn77/alexa-cookie-cli, then `./set-key.sh alexa`.
The token lives in ~/.cj (mode 600). It is never your password, and signing out of "Amazon Alexa" devices on
amazon.com/myx revokes it.
"""
from __future__ import annotations

import json
import threading
import time

import httpx

from . import config

TIMEOUT = 15
SESSION_SECONDS = 6 * 3600  # Amazon's cookies last longer; refresh well before they expire
BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) CJ-glasses/1.0"
ECHO_FAMILIES = {"ECHO", "KNIGHT", "ROOK", "TABLET"}  # speakers and Echo Shows can take a text command


class AlexaError(Exception):
    pass


class _Session:
    """Signed-in cookies, the CSRF token and the Echo commands go through. Built on first use, then reused."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._built = 0.0
        self.client: httpx.Client | None = None
        self.customer = ""
        self.device: dict = {}

    def domain(self) -> str:
        return config.load().get("alexa_domain") or "amazon.com"

    def host(self) -> str:
        d = self.domain()
        return "pitangui.amazon.com" if d == "amazon.com" else f"alexa.{d}"

    def ready(self) -> "_Session":
        with self._lock:
            if not self.client or time.time() - self._built > SESSION_SECONDS:
                self._build()
            return self

    def reset(self) -> None:
        with self._lock:
            if self.client:
                self.client.close()
            self.client, self._built = None, 0.0

    def _build(self) -> None:
        token = config.key("alexa")
        if not token:
            raise AlexaError("Alexa isn't set up yet. Run ./set-key.sh alexa on the Mac.")
        domain, host = self.domain(), self.host()
        r = httpx.post(f"https://api.{domain}/ap/exchangetoken/cookies", timeout=TIMEOUT,
                       headers={"x-amzn-identity-auth-domain": f"api.{domain}"},
                       data={"app_name": "Amazon Alexa", "requested_token_type": "auth_cookies",
                             "domain": f"www.{domain}", "source_token_type": "refresh_token", "source_token": token})
        try:
            groups = r.json()["response"]["tokens"]["cookies"]
        except (ValueError, KeyError, TypeError):
            raise AlexaError("Amazon didn't accept the Alexa sign-in. Run ./set-key.sh alexa again.") from None
        client = httpx.Client(timeout=TIMEOUT, follow_redirects=True, headers={
            "User-Agent": BROWSER, "Referer": f"https://alexa.{domain}/spa/index.html", "Origin": f"https://alexa.{domain}"})
        for cookie_domain, cookies in groups.items():
            for c in cookies:
                client.cookies.set(c["Name"], c["Value"], domain=cookie_domain.lstrip("."))
        for path in ("/api/language", "/templates/oobe/d-device-pick.handlebars", "/api/devices-v2/device?cached=false"):
            client.get(f"https://{host}{path}")
            if client.cookies.get("csrf"):
                break
        csrf = client.cookies.get("csrf")
        if not csrf:
            client.close()
            raise AlexaError("Alexa signed in but didn't hand over a security token. Try again in a minute.")
        client.headers["csrf"] = csrf
        self.customer = client.get(f"https://{host}/api/users/me").json().get("id", "")
        self.device = self._pick_echo(client.get(f"https://{host}/api/devices-v2/device?cached=false").json())
        self.client, self._built = client, time.time()

    @staticmethod
    def _pick_echo(listing: dict) -> dict:
        """The Echo that "hears" the command (and says Alexa's reply): the one named in config, else the first online."""
        wanted = (config.load().get("alexa_device") or "").lower()
        echoes = [d for d in listing.get("devices", []) if d.get("deviceFamily") in ECHO_FAMILIES]
        if not echoes:
            raise AlexaError("I couldn't find an Echo on your Alexa account.")
        for d in echoes:
            if wanted and wanted in d.get("accountName", "").lower():
                return d
        return next((d for d in echoes if d.get("online")), echoes[0])


SESSION = _Session()


def _preview(text: str) -> None:
    s = SESSION.ready()
    d = s.device
    node = {"@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode",
            "type": "Alexa.TextCommand", "skillId": "amzn1.ask.1p.tellalexa",
            "operationPayload": {"deviceType": d.get("deviceType"), "deviceSerialNumber": d.get("serialNumber"),
                                 "customerId": s.customer, "locale": config.load().get("alexa_locale") or "en-IN",
                                 "text": text}}
    sequence = {"@type": "com.amazon.alexa.behaviors.model.Sequence",
                "startNode": {"@type": "com.amazon.alexa.behaviors.model.ParallelNode", "nodesToExecute": [node]}}
    r = s.client.post(f"https://{s.host()}/api/behaviors/preview",
                      json={"behaviorId": "PREVIEW", "sequenceJson": json.dumps(sequence), "status": "ENABLED"})
    if r.status_code in (401, 403):
        raise PermissionError
    if r.status_code >= 300:
        raise AlexaError(f"Alexa answered {r.status_code}.")


def command(text: str) -> None:
    """Sends one sentence to Alexa, signing in again once if the session went stale."""
    text = " ".join(str(text).replace('"', "'").split())[:300]
    if not text:
        raise AlexaError("What should I tell Alexa?")
    try:
        try:
            _preview(text)
        except PermissionError:
            SESSION.reset()
            _preview(text)
    except PermissionError:
        raise AlexaError("Alexa's sign-in expired. Run ./set-key.sh alexa again.") from None
    except httpx.HTTPError as e:
        raise AlexaError(f"Couldn't reach Alexa: {e}") from None


def _home(a: dict) -> str:
    command(str(a.get("command", "")))
    return "Okay, told Alexa."


def _routine(a: dict) -> str:
    name = str(a.get("name", "")).strip()
    command(name)  # a routine starts when Alexa hears its phrase
    return f"Okay, told Alexa: {name}."


ACTIONS = {"home": _home, "home_routine": _routine}

PROMPT = """
Smart home (through the user's Alexa: lights, plugs, AC, fans, curtains, scenes, routines, Echo music):
home {command: the request as a short English sentence for Alexa, e.g. "turn off the bedroom lights",
"set the AC to 24 degrees", "dim the living room lights to 30 percent", "turn on the fan"},
home_routine {name} (the phrase that starts an Alexa routine or scene, e.g. "good night", "movie time").
Use these for lights, appliances and rooms in the home, not for the Mac or the TV actions above."""
