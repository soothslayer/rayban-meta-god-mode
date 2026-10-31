"""Speed safeguards: a slow Gemini request gets a backup instead of a long wait, and lookups are reused."""
import asyncio
import json
import os
import tempfile
import time

os.environ.setdefault("CJ_HOME", tempfile.mkdtemp())

import httpx
import pytest

from app import tools
from app.models import gemini

OK = {"candidates": [{"content": {"parts": [{"text": "{\"spoken\": \"hi\"}"}]}}]}


@pytest.fixture
def fake_google(monkeypatch):
    calls = []
    behaviour = {}

    async def handler(request):
        model = request.url.path.split("/")[-1].split(":")[0]
        body = json.loads(request.content)
        calls.append((model, "thinkingConfig" in body["generationConfig"]))
        n = len(calls)
        action = behaviour.get(n) or behaviour.get(model) or "ok"
        if action == "slow":
            await asyncio.sleep(3)
        if action == "busy":
            return httpx.Response(429, text="busy")
        if action == "no_thinking" and "thinkingConfig" in body["generationConfig"]:
            return httpx.Response(400, text="Thinking level MINIMAL is not supported")
        return httpx.Response(200, json=OK)

    real = httpx.AsyncClient
    monkeypatch.setattr(gemini.httpx, "AsyncClient", lambda **kw: real(transport=httpx.MockTransport(handler), **kw))
    monkeypatch.setattr(gemini.config, "key", lambda p: "test-key")
    monkeypatch.setattr(gemini, "HEDGE_SECONDS", 0.2)
    return calls, behaviour


def run(provider):
    started = time.monotonic()
    result = asyncio.run(provider.complete("system", [{"role": "user", "text": "hi"}], json_mode=True))
    return result, time.monotonic() - started


def test_slow_request_gets_a_backup(fake_google):
    calls, behaviour = fake_google
    behaviour[1] = "slow"
    result, took = run(gemini.Gemini())
    assert took < 1.5 and result.text == OK["candidates"][0]["content"]["parts"][0]["text"]
    assert calls[1][0] == calls[0][0]  # the same fast model, asked again


def test_slow_is_not_benched_but_busy_is(fake_google):
    calls, behaviour = fake_google
    g = gemini.Gemini()
    behaviour[1] = "slow"
    run(g)
    assert g._order()[0] == g.models[0]
    behaviour.clear()
    behaviour[g.models[0]] = "busy"
    run(g)
    assert g._order()[0] != g.models[0]


def test_model_without_minimal_thinking_is_retried_plainly(fake_google):
    calls, behaviour = fake_google
    g = gemini.Gemini()
    behaviour[g.models[0]] = "no_thinking"
    result, _ = run(g)
    assert calls[:2] == [(g.models[0], True), (g.models[0], False)]
    run(g)
    assert calls[-1] == (g.models[0], False)  # remembered


def test_lookups_are_reused_for_a_while(monkeypatch):
    fetched = []

    async def fake_weather(place):
        fetched.append(place)
        return f"Place: {place}"
    monkeypatch.setattr(tools, "weather", fake_weather)
    tools._cache.clear()
    assert asyncio.run(tools.run("weather", {"place": "Pune"})) == "Place: Pune"
    assert asyncio.run(tools.run("weather", {"place": "pune "})) == "Place: Pune"
    assert fetched == ["Pune"]
