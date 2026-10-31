"""Gemini over its REST API (free tier with a key from Google AI Studio)."""
from __future__ import annotations

import asyncio
import logging
import os
import time

import httpx

from .. import config
from .base import Completion, Attachment, Provider, ProviderError

URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
BUSY = {429, 500, 503}  # overloaded or rate limited: bench it and try the next model
HEDGE_SECONDS = 2.5  # no answer yet: send another request alongside and take whichever comes back first
TOTAL_SECONDS = 30
BENCH_SECONDS = 300
log = logging.getLogger("cj.gemini")

# Google's free tier shifts load between models: on 30 Oct the "latest" alias took 15-25 s while
# gemini-3.1-flash-lite answered in ~1 s. The same model is also spiky: most answers in ~1 s, some in 10-20 s.
# So a slow request gets company (the same model again, then the next one) instead of a long wait.
DEFAULT_MODELS = "gemini-3.1-flash-lite,gemini-flash-lite-latest,gemini-flash-latest"
# Thinking made simple answers take ~6 s instead of ~1 s. Models that reject the setting are retried without it.
FAST = {"thinkingLevel": "minimal"}


class Gemini(Provider):
    name = "gemini"

    def __init__(self) -> None:
        self.models = [m.strip() for m in os.environ.get("CJ_GEMINI_MODELS", DEFAULT_MODELS).split(",") if m.strip()]
        self._benched: dict[str, float] = {}
        self._no_fast: set[str] = set()  # models that reject the thinking setting

    def available(self) -> bool:
        return bool(config.key("gemini"))

    def _order(self) -> list[str]:
        """Healthy models first (in preference order), benched ones last as a final resort."""
        now = time.monotonic()
        healthy = [m for m in self.models if self._benched.get(m, 0) <= now]
        return healthy + [m for m in self.models if m not in healthy]

    def _bench(self, model: str, why: str) -> None:
        self._benched[model] = time.monotonic() + BENCH_SECONDS
        log.warning("benching %s for %d s: %s", model, BENCH_SECONDS, why)

    def _attempts(self) -> list[str]:
        """The best model twice (its slow answers are flukes), then the others as backups."""
        order = self._order()
        return [order[0], *order] if order else []

    async def _post(self, client: httpx.AsyncClient, model: str, body: dict) -> httpx.Response:
        sent = body if model in self._no_fast else \
            {**body, "generationConfig": {**body["generationConfig"], "thinkingConfig": FAST}}
        r = await client.post(URL.format(model=model), json=sent, timeout=TOTAL_SECONDS,
                              headers={"x-goog-api-key": config.key("gemini")})
        if r.status_code == 400 and model not in self._no_fast:
            self._no_fast.add(model)
            return await self._post(client, model, body)
        return r

    async def complete(self, system, messages, image: Attachment | None = None, json_mode=False) -> Completion:
        contents = [{"role": "model" if m["role"] == "assistant" else "user",
                     "parts": [{"text": m["text"]}]} for m in messages]
        if image and contents:
            contents[-1]["parts"].append({"inlineData": {"mimeType": image.mime, "data": image.data_b64}})
        body = {"systemInstruction": {"parts": [{"text": system}]}, "contents": contents,
                "generationConfig": {"temperature": 0.6, "maxOutputTokens": 800}}
        if json_mode:
            body["generationConfig"]["responseMimeType"] = "application/json"
        started = time.monotonic()
        waiting = self._attempts()
        running: dict[asyncio.Task, str] = {}
        last_error = "no model tried"
        async with httpx.AsyncClient() as client:
            try:
                while waiting or running:
                    if waiting and (not running or time.monotonic() - started > HEDGE_SECONDS * len(running)):
                        model = waiting.pop(0)
                        running[asyncio.create_task(self._post(client, model, body))] = model
                    left = TOTAL_SECONDS - (time.monotonic() - started)
                    if left <= 0:
                        break
                    done, _ = await asyncio.wait(running, timeout=min(left, HEDGE_SECONDS) if waiting else left,
                                                 return_when=asyncio.FIRST_COMPLETED)
                    for task in done:
                        model = running.pop(task)
                        try:
                            r = task.result()
                        except httpx.HTTPError as e:
                            last_error = f"{model}: {e or type(e).__name__}"
                            continue
                        if r.status_code in BUSY or r.status_code == 404:
                            self._bench(model, f"HTTP {r.status_code}")
                            last_error = f"{model} {r.status_code}: {r.text[:120]}"
                            waiting = [m for m in waiting if m != model]
                            continue
                        if r.status_code != 200:
                            raise ProviderError(f"gemini {model} {r.status_code}: {r.text[:200]}")
                        return self._completion(r.json(), model, started)
            finally:
                for task in running:
                    task.cancel()
        raise ProviderError(f"every Gemini model was slow or busy (last: {last_error})")

    def _completion(self, data: dict, model: str, started: float) -> Completion:
        try:
            text = "".join(p.get("text", "") for p in data["candidates"][0]["content"]["parts"])
        except (KeyError, IndexError) as e:
            raise ProviderError(f"gemini returned no text: {str(data)[:200]}") from e
        usage = data.get("usageMetadata", {})
        return Completion(text, self.name, model, int((time.monotonic() - started) * 1000),
                          usage.get("promptTokenCount", 0), usage.get("candidatesTokenCount", 0))
