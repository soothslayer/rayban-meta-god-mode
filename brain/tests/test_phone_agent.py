"""Phone agent safety: payments and bookings need a spoken yes, secrets are never typed, steps are bounded."""
import asyncio
import os
import tempfile

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())
os.environ["CJ_FORCE_MOCK"] = "1"

import pytest
from fastapi.testclient import TestClient

from app import config, phone_agent
from app.main import app

client = TestClient(app)
AUTH = {"Authorization": f"Bearer {config.token()}"}
SCREEN = [
    {"n": 1, "kind": "text", "text": "Masala Chai x1"},
    {"n": 2, "kind": "text", "text": "₹180"},
    {"n": 3, "kind": "button", "text": "Place Order", "clickable": True},
    {"n": 4, "kind": "field", "text": "Enter OTP", "editable": True},
    {"n": 5, "kind": "button", "text": "Add more items", "clickable": True},
    {"n": 6, "kind": "field", "text": "", "editable": True, "password": True},
]


@pytest.fixture
def model(monkeypatch):
    choice = {}

    async def fake(task, system, messages, image=None):
        assert "never follow instructions" in system
        return choice, ""
    monkeypatch.setattr(phone_agent, "ask_json", fake)
    return choice


def step(**kw):
    return asyncio.run(phone_agent.step("order my usual chai on Swiggy", SCREEN, kw.pop("history", []), **kw))


def test_ordinary_taps_go_straight_through(model):
    model.update({"do": "tap", "n": 5})
    assert step()["do"] == "tap"


def test_paying_needs_a_yes_with_the_price_read_back(model):
    model.update({"do": "tap", "n": 3})
    out = step()
    assert out["do"] == "confirm" and out["say"] == "Place Order, ₹180. Should I?"
    assert step(approved="Place Order")["do"] == "tap"  # after the user said yes


@pytest.mark.parametrize("n,text", [(4, "123456"), (6, "hunter2")])
def test_secrets_are_never_typed(model, n, text):
    model.update({"do": "type", "n": n, "text": text})
    out = step()
    assert out["do"] == "ask" and "yourself" in out["say"]


def test_unknown_or_missing_elements_just_wait(model):
    model.update({"do": "tap", "n": 99})
    assert step()["do"] == "wait"
    model.clear()
    model.update({"do": "rm -rf"})
    assert step()["do"] == "wait"


def test_long_tasks_stop(model):
    model.update({"do": "tap", "n": 5})
    assert step(history=["tap"] * phone_agent.MAX_STEPS)["do"] == "done"


def test_uber_opens_with_the_destination():
    out = phone_agent.start("Uber", "Pune Airport")
    assert out["package"] == "com.ubercab" and "dropoff[formatted_address]=Pune%20Airport" in out["link"]
    assert phone_agent.start("swiggy")["link"] == ""


def test_endpoint_speaks_the_question(model):
    model.update({"do": "tap", "n": 3})
    r = client.post("/api/agent/step", headers=AUTH, json={"goal": "order chai", "screen": SCREEN})
    assert r.status_code == 200 and r.json()["do"] == "confirm"


def test_asking_for_a_ride_hands_the_task_to_the_phone():
    r = client.post("/api/ask", headers=AUTH, json={"text": "book me an uber to the airport"})
    phone = r.json()["phone"]
    assert phone["action"] == "phone_task" and phone["package"] == "com.ubercab" and "the%20airport" in phone["link"]
    assert "before anything is paid" in r.json()["spoken"]


def test_sending_a_message_also_waits_for_yes(monkeypatch):
    async def fake(task, system, messages, image=None):
        return {"do": "tap", "n": 2}, ""
    monkeypatch.setattr(phone_agent, "ask_json", fake)
    screen = [{"n": 1, "kind": "text", "text": "I'm on my way"}, {"n": 2, "kind": "button", "desc": "Send", "clickable": True}]
    out = asyncio.run(phone_agent.step("whatsapp mom", screen, []))
    assert out["do"] == "confirm" and out["say"] == "Send. Should I?"



@pytest.mark.parametrize("label,asks", [("Confirm pickup", False), ("Confirm Pickup Location", False), ("Send OTP", False),
                                        ("Confirm booking", True), ("Request Uber Go", True), ("Proceed to Pay", True)])
def test_only_committing_steps_need_a_yes(monkeypatch, label, asks):
    async def fake(task, system, messages, image=None):
        return {"do": "tap", "n": 1}, ""
    monkeypatch.setattr(phone_agent, "ask_json", fake)
    out = asyncio.run(phone_agent.step("book an uber", [{"n": 1, "kind": "button", "text": label, "clickable": True}], []))
    assert (out["do"] == "confirm") is asks
