"""Languages, notes, email and travel time, with the offline mock model and fakes (nothing is really sent)."""
import asyncio
import base64
import json
import os
import tempfile

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())
os.environ["CJ_FORCE_MOCK"] = "1"

import pytest
from fastapi.testclient import TestClient

from app import config, mac, memory, notes, tools, tts
from app.main import app

client = TestClient(app)
AUTH = {"Authorization": f"Bearer {config.token()}"}


def ask(text, **extra):
    r = client.post("/api/ask", json={"text": text, **extra}, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    notes._save([])
    notes.SESSIONS.clear()
    monkeypatch.setattr(mac, "_pending", None)


# ---- languages ----------------------------------------------------------------------------------------------

@pytest.mark.parametrize("text,lang,voice", [
    ("Hola, ¿cómo estás?", "es", "es-ES-ElviraNeural"),
    ("你好，今天天气很好。", None, "zh-CN-XiaoxiaoNeural"),
    ("مرحبا، كيف حالك؟", None, "ar-SA-ZariyahNeural"),
    ("नमस्ते, आप कैसे हैं?", "hi", "hi-IN-SwaraNeural"),
    ("Kal mausam saaf rahega.", "hinglish", tts.VOICE),
    ("Hello there.", "en", tts.VOICE),
    ("Γεια σου, τι κάνεις;", "el", tts.MULTILINGUAL),
])
def test_each_language_gets_a_native_voice(text, lang, voice):
    assert tts.voice_for(text, lang)[0] == voice


def test_roman_hindi_labelled_hindi_gets_the_hinglish_voice():
    assert tts.voice_for("Mumbai mein abhi halki baarish ho rahi hai.", "hi") == tts.VOICES["hinglish"]


def test_wrong_language_code_does_not_read_hindi_in_an_english_voice():
    assert tts.voice_for("नमस्ते", "en")[0] == "hi-IN-SwaraNeural"


# ---- notes --------------------------------------------------------------------------------------------------

def test_quick_note_is_saved():
    assert ask("take a note call the plumber on monday")["spoken"] == "Noted."
    assert notes.load()[0]["text"] == "call the plumber on monday"


def test_notes_summary_answers_from_todays_notes():
    notes.add("Budget review moved to Friday")
    out = ask("summarise my notes")
    assert "Budget review" in out["details"]


def test_dictation_session_collects_then_summarises(monkeypatch):
    saved = []
    monkeypatch.setattr(mac, "_run", lambda args: saved.append(args) or "")
    sid = ask("start taking notes")["dictation"]

    def chunk(words):
        r = client.post("/api/notes/dictate", headers=AUTH,
                        json={"session": sid, "audio_b64": base64.b64encode(words.encode()).decode()})
        assert r.status_code == 200, r.text
        return r.json()

    assert chunk("we agreed to ship on the 20th")["stopped"] is False
    assert chunk("Ravi will update the deck")["stopped"] is False
    done = chunk("okay stop taking notes")
    assert done["stopped"] is True and "Two points" in done["spoken"] and "Saved to your Notes app" in done["spoken"]
    session = [n for n in notes.load() if n["kind"] == "session"][0]
    assert "ship on the 20th" in session["text"] and "Ravi will update the deck" in session["text"]
    assert "stop taking notes" not in session["text"]
    assert saved and "Mock meeting" in saved[0][2]  # copied into Apple Notes


@pytest.mark.parametrize("said,stop", [("stop taking notes", True), ("okay end the notes now", True),
                                       ("notes band karo", True), ("we should stop the project", False)])
def test_stop_phrases(said, stop):
    assert notes.wants_stop(said) is stop


# ---- email --------------------------------------------------------------------------------------------------

@pytest.fixture
def fake_mail(monkeypatch):
    sent = []

    def fake_run(args):
        script = args[2] if len(args) > 2 else ""
        if "Contacts" in script:
            return "Rahul Sharma, rahul@example.com"
        sent.append(script)
        return ""
    monkeypatch.setattr(mac, "_run", fake_run)
    return sent


def test_email_is_read_back_and_only_sent_after_yes(fake_mail):
    question = ask("email rahul saying running ten minutes late")["spoken"]
    assert question.startswith("Email Rahul Sharma") and "running ten minutes late" in question
    assert fake_mail == []
    assert ask("yes")["spoken"] == "Sent to Rahul Sharma."
    assert 'address:"rahul@example.com"' in fake_mail[0] and "send m" in fake_mail[0]


def test_email_not_sent_on_no(fake_mail):
    ask("email rahul saying hello")
    assert ask("no")["spoken"] == "Okay, I won't."
    assert fake_mail == []


def test_spoken_email_addresses_are_understood():
    assert mac.resolve_recipient("priya at gmail dot com") == ("priya@gmail.com", "priya@gmail.com")


def test_email_text_cannot_break_out_of_applescript(fake_mail):
    mac._send_email({"to": "a@b.co", "subject": 'x" & do shell script "ls', "body": "hi"})
    assert '\\" & do shell script \\"' in fake_mail[0]


# ---- travel time --------------------------------------------------------------------------------------------

def test_travel_time_uses_the_phones_location(monkeypatch):
    seen = {}

    async def fake_travel(destination, mode="driving"):
        seen["where"] = tools.LOCATION.get()
        return f"Driving: about 15 minutes to {destination}"
    monkeypatch.setattr(tools, "travel_time", fake_travel)
    out = ask("how long to the airport", location={"lat": 18.52, "lon": 73.85})
    assert seen["where"] == {"lat": 18.52, "lon": 73.85} and "15 minutes" in out["spoken"]


def test_bad_locations_are_rejected():
    r = client.post("/api/ask", json={"text": "hi", "location": {"lat": 500, "lon": 0}}, headers=AUTH)
    assert r.status_code == 422


def test_words_before_stop_in_the_same_stretch_are_kept():
    assert notes.before_stop("Ravi owns the deck. Okay, stop taking notes.") == "Ravi owns the deck."
    assert notes.before_stop("okay stop taking notes") == ""


# ---- look and do --------------------------------------------------------------------------------------------

@pytest.fixture
def fake_mac(monkeypatch):
    ran = []

    def fake_run(args):
        ran.append(args)
        if args[:2] == ["networksetup", "-listallhardwareports"]:
            return "Hardware Port: Wi-Fi\nDevice: en1\n"
        return ""
    monkeypatch.setattr(mac, "_run", fake_run)
    return ran


def test_calendar_event_from_a_poster(fake_mac):
    said = mac._calendar_add({"title": "Diwali Mela", "date": "2026-11-08", "time": "18:30", "location": "FC Road"})
    assert said == "Added Diwali Mela on 8 November at 18:30 to your calendar."
    script = fake_mac[0][2]
    assert "set month of e0 to 11" in script and "set hours of e0 to 18" in script and '"FC Road"' in script


def test_calendar_needs_a_real_date(fake_mac):
    with pytest.raises(mac.MacError):
        mac._calendar_add({"title": "Party", "date": "next friday"})


def test_contact_from_a_business_card(fake_mac):
    assert mac._contact_add({"name": "Priya Nair", "phone": "+91 98220 12345", "email": "Priya@Acme.in",
                             "company": "Acme"}) == "Saved Priya Nair to your contacts."
    script = fake_mac[0][2]
    assert '"+919822012345"' in script and '"priya@acme.in"' in script and 'last name:"Nair"' in script


def test_wifi_from_a_card_uses_no_shell(fake_mac):
    assert mac._wifi_join({"ssid": "Cafe Blue", "password": "chai; rm -rf ~"}) == "Your Mac is joining Cafe Blue."
    assert fake_mac[-1] == ["networksetup", "-setairportnetwork", "en1", "Cafe Blue", "chai; rm -rf ~"]


def test_call_asks_first_then_the_phone_dials(fake_mac):
    asked = asyncio.run(mac.handle({"mac_action": {"name": "call_number", "args": {"number": "+91 98220-12345",
                                                                               "name": "Priya"}}}))
    assert asked == "Call Priya, + 9 1 9 8 2 2 0 1 2 3 4 5?"

    async def confirm():
        said = await mac.handle({"confirm": True})
        return said, mac.PHONE.get()
    said, phone = asyncio.run(confirm())
    assert said == "Calling Priya." and phone == {"action": "call_number", "number": "+919822012345", "who": "Priya"}


# ---- visual memory ------------------------------------------------------------------------------------------

def _glance(words):
    return client.post("/api/glance", headers=AUTH, json={"image_b64": base64.b64encode(words.encode()).decode()}).json()


def test_glances_are_kept_as_notes_not_photos():
    memory._save([])
    assert _glance("Blue Tokai cafe on Koregaon Park lane 5")["kept"] is True
    assert _glance("   ")["kept"] is False  # a blank wall: nothing worth noting
    saved = memory.load()
    assert len(saved) == 1 and saved[0]["kind"] == "seen" and "base64" not in json.dumps(saved)
    out = ask("what did i see today")
    assert "Blue Tokai" in out["details"]


def test_visual_memory_switch_goes_to_the_phone():
    assert ask("start visual memory")["phone"] == {"action": "visual_memory", "on": True}
    assert ask("pause visual memory")["phone"] == {"action": "visual_memory", "on": False}


def test_translator_starts_on_the_phone():
    out = ask("translate for me in spanish")
    assert out["phone"] == {"action": "translate", "language": "spanish"}



def test_visual_memory_never_pushes_out_what_you_saved(monkeypatch):
    monkeypatch.setattr(memory, "MAX_SEEN", 5)
    memory._save([])
    memory.add("my locker code is 4412")
    for i in range(20):
        memory.add(f"saw a street {i}", kind="seen")
    saved = memory.load()
    assert [n["text"] for n in saved if n["kind"] == "note"] == ["my locker code is 4412"]
    assert len([n for n in saved if n["kind"] == "seen"]) == 5
