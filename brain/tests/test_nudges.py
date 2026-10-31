"""CJ speaking up by itself: shops when you noted something to buy, meetings at the office, leaving home."""
import asyncio
import os
import tempfile

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())
os.environ["CJ_FORCE_MOCK"] = "1"

import pytest

from app import notes, nudges

HOME = {"lat": 18.5300, "lon": 73.8500}
STREET = {"lat": 18.5340, "lon": 73.8500}  # ~445 m north
OFFICE = {"lat": 18.5600, "lon": 73.9100}


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    notes._save([])
    nudges._places_path().unlink(missing_ok=True)
    nudges._shops.clear()

    async def no_shops(here):
        return []
    monkeypatch.setattr(nudges, "nearby_shops", no_shops)


def check(n, here, **kw):
    return asyncio.run(n.check(here, **kw))


def test_leaving_home_offers_to_switch_things_off_once():
    nudges.save_place("home", HOME)
    n = nudges.Nudger()
    assert check(n, HOME, alexa_ready=lambda: True)["say"] == ""
    assert check(n, STREET, alexa_ready=lambda: True)["say"] == ""  # one fix away could be a jumpy reading
    out = check(n, STREET, alexa_ready=lambda: True)
    assert "switch off the lights" in out["say"] and out["converse"]
    assert check(n, STREET, alexa_ready=lambda: True)["say"] == ""


def test_vague_network_fixes_dont_count_as_leaving():
    nudges.save_place("home", HOME)
    n = nudges.Nudger()
    check(n, HOME, alexa_ready=lambda: True)
    vague = {**STREET, "acc": 600}
    for _ in range(3):
        assert check(n, vague, alexa_ready=lambda: True)["say"] == ""
    assert n.at_home is True


def test_leaving_home_is_quiet_without_alexa():
    nudges.save_place("home", HOME)
    n = nudges.Nudger()
    check(n, HOME, alexa_ready=lambda: False)
    check(n, STREET, alexa_ready=lambda: False)
    assert check(n, STREET, alexa_ready=lambda: False)["say"] == ""


def test_meeting_reminder_at_the_office_once():
    nudges.save_place("office", OFFICE)
    n = nudges.Nudger()
    soon = lambda: [("Standup", 10)]
    assert check(n, OFFICE, upcoming=soon)["say"] == "Standup in 10 minutes."
    assert check(n, OFFICE, upcoming=soon)["say"] == ""


def test_shop_with_something_to_buy(monkeypatch):
    notes.add("buy milk and eggs")
    notes.add("call the plumber")

    async def shops(here):
        return [{"id": 7, "name": "More Supermarket"}]
    monkeypatch.setattr(nudges, "nearby_shops", shops)
    n = nudges.Nudger()
    assert check(n, STREET)["say"] == "You're near More Supermarket. You noted: buy milk and eggs."
    assert check(n, STREET)["say"] == ""  # once per trip


def test_no_shop_lookup_when_nothing_to_buy(monkeypatch):
    async def boom(here):
        raise AssertionError("looked up shops for nothing")
    monkeypatch.setattr(nudges, "nearby_shops", boom)
    assert check(nudges.Nudger(), STREET)["say"] == ""


def test_save_place_needs_a_location():
    assert "Allow location" in nudges.save_place("home", None)
    assert nudges.save_place("Office!", OFFICE) == "Got it, this is your office."
    assert nudges.places()["office"] == OFFICE


def test_shop_nudges_not_at_home_and_once_per_item(monkeypatch):
    notes.add("buy milk")
    nudges.save_place("home", HOME)

    async def shops(here):
        return [{"id": here["lat"], "name": "Corner Shop"}]  # a different shop at each spot
    monkeypatch.setattr(nudges, "nearby_shops", shops)
    n = nudges.Nudger()
    assert check(n, HOME)["say"] == ""  # the shop downstairs isn't news
    assert "buy milk" in check(n, STREET)["say"]
    assert check(n, {"lat": 18.5400, "lon": 73.8500})["say"] == ""  # another shop, same milk: already said today


def test_errands_that_arent_shopping_stay_quiet(monkeypatch):
    notes.add("pick up Riya from school")
    notes.add("get the report to Ravi")

    async def shops(here):
        return [{"id": 1, "name": "More"}]
    monkeypatch.setattr(nudges, "nearby_shops", shops)
    assert check(nudges.Nudger(), STREET)["say"] == ""
