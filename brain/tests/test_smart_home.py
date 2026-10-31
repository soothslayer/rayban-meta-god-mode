"""Smart home through Alexa, against a fake Amazon (no account needed, nothing leaves the Mac)."""
import json
import os
import tempfile

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())
os.environ["CJ_FORCE_MOCK"] = "1"

import httpx
import pytest
from fastapi.testclient import TestClient

from app import alexa, config
from app.main import app

client = TestClient(app)
AUTH = {"Authorization": f"Bearer {config.token()}"}
TOKEN = "Atnr|" + "x" * 120


class FakeAmazon:
    """Answers the handful of Alexa web calls CJ makes, and records the text commands."""

    def __init__(self, expire_first=False):
        self.commands, self.sign_ins, self.expire_first = [], 0, expire_first

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/ap/exchangetoken/cookies":
            self.sign_ins += 1
            assert b"source_token=Atnr" in request.content
            return httpx.Response(200, json={"response": {"tokens": {"cookies": {".amazon.in": [
                {"Name": "at-acbin", "Value": "abc"}, {"Name": "session-id", "Value": "1"}]}}}})
        if path == "/api/language":
            return httpx.Response(200, headers={"set-cookie": "csrf=777; Domain=alexa.amazon.in; Path=/"}, json={})
        if path == "/api/users/me":
            return httpx.Response(200, json={"id": "CUST1"})
        if path == "/api/devices-v2/device":
            return httpx.Response(200, json={"devices": [
                {"accountName": "Fire TV", "deviceFamily": "FIRE_TV", "online": True},
                {"accountName": "Bedroom Echo Dot", "deviceFamily": "ECHO", "deviceType": "A3S5", "serialNumber": "G0", "online": True}]})
        if path == "/api/behaviors/preview":
            assert request.headers["csrf"] == "777"
            if self.expire_first and not self.commands:
                self.commands.append(None)
                return httpx.Response(401)
            seq = json.loads(json.loads(request.content)["sequenceJson"])
            self.commands.append(seq["startNode"]["nodesToExecute"][0])
            return httpx.Response(200)
        return httpx.Response(404)


@pytest.fixture
def amazon(monkeypatch):
    fake = FakeAmazon()
    transport = httpx.MockTransport(fake.handler)
    real_client = httpx.Client
    monkeypatch.setattr(alexa.httpx, "post", lambda url, **kw: real_client(transport=transport).post(url, **kw))
    monkeypatch.setattr(alexa.httpx, "Client", lambda **kw: real_client(transport=transport, **kw))
    real_key, real_load = config.key, config.load
    monkeypatch.setattr(config, "key", lambda p: TOKEN if p == "alexa" else real_key(p))
    monkeypatch.setattr(config, "load", lambda: {**real_load(), "alexa_domain": "amazon.in", "alexa_locale": "en-IN"})
    alexa.SESSION.reset()
    yield fake
    alexa.SESSION.reset()


def ask(text):
    r = client.post("/api/ask", json={"text": text}, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def test_lights_go_to_alexa_as_text(amazon):
    assert ask("turn off the bedroom lights")["spoken"] == "Okay, told Alexa."
    node = amazon.commands[0]
    assert node["type"] == "Alexa.TextCommand"
    assert node["operationPayload"]["text"] == "turn off the bedroom lights"
    assert node["operationPayload"]["deviceSerialNumber"] == "G0"  # the Echo, not the Fire TV
    assert node["operationPayload"]["customerId"] == "CUST1"


def test_session_is_reused(amazon):
    ask("turn on the fan")
    ask("set the ac to 24")
    assert amazon.sign_ins == 1 and len(amazon.commands) == 2


def test_routines(amazon):
    assert ask("start movie time routine")["spoken"] == "Okay, told Alexa: movie time."
    assert amazon.commands[0]["operationPayload"]["text"] == "movie time"


def test_expired_session_signs_in_again(amazon):
    amazon.expire_first = True
    alexa.command("turn on the lamp")
    assert amazon.sign_ins == 2 and amazon.commands[-1]["operationPayload"]["text"] == "turn on the lamp"


def test_quotes_cannot_break_the_command(amazon):
    alexa.command('turn on "the" lamp')
    assert amazon.commands[0]["operationPayload"]["text"] == "turn on 'the' lamp"


def test_not_set_up_says_how(monkeypatch):
    real_key = config.key
    monkeypatch.setattr(config, "key", lambda p: None if p == "alexa" else real_key(p))
    alexa.SESSION.reset()
    assert "set-key.sh alexa" in ask("turn on the kitchen light")["spoken"]
