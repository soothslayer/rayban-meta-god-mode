"""The live bridge's own logic, without Gemini: tool calls, goodbyes, photos and interpreter routing."""
import asyncio
import json
import os
import tempfile

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())

import pytest

from app import live, mac, memory, nudges, tools


class FakePhone:
    def __init__(self):
        self.events, self.audio = [], []

    async def send_text(self, text):
        self.events.append(json.loads(text))

    async def send_bytes(self, data):
        self.audio.append((self.events[-1]["to"] if self.events and self.events[-1]["type"] == "route" else None, data))


class FakeGemini:
    def __init__(self):
        self.sent = []

    async def send(self, text):
        self.sent.append(json.loads(text))


@pytest.fixture
def bridge():
    b = live.Bridge(FakePhone())
    b.gemini = FakeGemini()
    return b


def run(coro):
    return asyncio.run(coro)


def test_every_tool_has_a_clean_declaration():
    names = [f["name"] for f in live.FUNCTIONS]
    assert len(names) == len(set(names))
    for f in live.FUNCTIONS:
        for prop in f.get("parameters", {}).get("properties", {}).values():
            assert prop["type"] in ("STRING", "NUMBER", "INTEGER", "BOOLEAN")


def test_lookup_tool_answers_gemini(bridge, monkeypatch):
    async def fake(name, args):
        return f"{name} {args}"
    monkeypatch.setattr(tools, "run", fake)
    run(bridge._tool({"id": "1", "name": "exchange_rate", "args": {"from_currency": "USD", "to_currency": "INR"}}))
    reply = bridge.gemini.sent[-1]["toolResponse"]["functionResponses"][0]
    assert reply["id"] == "1" and "'from': 'USD'" in reply["response"]["result"]


def test_device_action_with_confirmation_then_call_goes_to_phone(bridge, monkeypatch):
    monkeypatch.setattr(mac, "_pending", None)

    async def go():
        asked = await bridge._run("device_action", {"action": "call_number", "args_json": '{"number": "98220 12345", "name": "Priya"}'})
        done = await bridge._run("confirm_action", {"yes": True})
        return asked, done
    asked, done = run(go())
    assert asked.startswith("Call Priya") and "confirm_action" in asked
    assert done == "Calling Priya."
    assert bridge.phone.events[-1] == {"type": "phone", "action": "call_number", "number": "9822012345", "who": "Priya"}


def test_goodbye_ends_after_the_turn_even_without_the_tool(bridge):
    bridge.heard, bridge.said = ["Okay thanks, I've got to go."], ["Bye!"]
    run(bridge._turn_done())
    assert [e["type"] for e in bridge.phone.events] == ["turn_done", "end"]


def test_look_waits_for_the_photo_and_sends_it_to_gemini(bridge):
    async def go():
        task = asyncio.create_task(bridge._look())
        await asyncio.sleep(0)
        assert bridge.phone.events[-1]["type"] == "need_photo"
        bridge.photo.set_result("JPEGDATA")
        return await task
    assert "latest video frame" in run(go())
    assert bridge.gemini.sent[-1]["realtimeInput"]["video"]["data"] == "JPEGDATA"


def test_what_was_seen_is_remembered(bridge):
    memory._save([])
    bridge.looked, bridge.heard, bridge.said = True, ["what is this"], ["A bottle of Paper Boat aam panna."]
    run(bridge._turn_done())
    assert memory.load()[-1]["kind"] == "seen" and "aam panna" in memory.load()[-1]["text"]


def test_interpreter_holds_audio_until_it_knows_who_it_is_for(bridge):
    bridge.mode, bridge.start = "interpreter", {"user_language": "English", "language": "Spanish"}

    async def go():
        await bridge._content({"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm", "data": "AAAA"}}]}})
        assert bridge.phone.audio == []  # held
        await bridge._content({"outputTranscription": {"text": "Está a diez minutos"}})
    run(go())
    assert bridge.phone.events[-1] == {"type": "route", "to": "partner"} or {"type": "route", "to": "partner"} in bridge.phone.events
    assert bridge.phone.audio and bridge.phone.audio[0][0] == "partner"


@pytest.mark.parametrize("text,lang", [("Do you know where the station is?", "en"), ("¿Dónde está la estación?", "es"),
                                       ("Merci beaucoup, c'est très gentil", "fr"), ("ये कितने का है", "hi"),
                                       ("駅はどこですか", "ja")])
def test_language_of(text, lang):
    assert live._language_of(text) == lang


def test_save_place_uses_the_live_location(bridge):
    nudges._places_path().unlink(missing_ok=True)
    tools.LOCATION.set({"lat": 18.5, "lon": 73.8})
    assert run(bridge._run("save_place", {"name": "home"})) == "Got it, this is your home."



@pytest.mark.parametrize("heard,bye", [("Bye!", True), ("Okay thanks, I've got to go.", True), ("that's all, thanks CJ bye", True),
                                       ("How do you say bye in French and in Spanish?", False),
                                       ("Remind me to call him before I have to go to the airport tomorrow", False)])
def test_goodbye_rule_matches_the_phone(heard, bye):
    assert live._goodbye(heard) is bye


def test_reconnect_failure_tells_the_phone_instead_of_hanging(bridge, monkeypatch):
    import websockets

    class Dropped:
        async def recv(self):
            raise websockets.ConnectionClosed(None, None)

    async def no_network():
        raise OSError("network is down")
    bridge.gemini = Dropped()
    monkeypatch.setattr(bridge, "_connect", no_network)
    run(bridge.from_gemini())
    assert bridge.closed.is_set() and bridge.phone.events[-1]["type"] == "error"


def test_interrupted_translation_is_dropped(bridge):
    bridge.mode, bridge.start = "interpreter", {"user_language": "English"}

    async def go():
        await bridge._content({"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm", "data": "AAAA"}}]}})
        await bridge._content({"interrupted": True})
        await bridge._content({"outputTranscription": {"text": "Hello there friend"}})
    run(go())
    assert bridge.phone.audio == []


def test_background_speech_rule_is_in_the_prompt():
    assert "stay silent for a TV" in live.LIVE
