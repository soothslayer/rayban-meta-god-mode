"""Anthropic Claude (Messages API). Optional: add a key with  ./set-key.sh claude"""
from __future__ import annotations

import os
import time

import httpx

from .. import config
from .base import Attachment, Completion, Provider, ProviderError

URL = "https://api.anthropic.com/v1/messages"


class Claude(Provider):
    name = "claude"

    def __init__(self) -> None:
        self.model = os.environ.get("CJ_CLAUDE_MODEL") or config.load().get("claude_model") or "claude-sonnet-5-5"

    def available(self) -> bool:
        return bool(config.key("claude"))

    async def complete(self, system, messages, image: Attachment | None = None, json_mode=False) -> Completion:
        turns: list[dict] = []
        for m in messages:  # the API needs alternating roles, starting with the user
            role = "assistant" if m["role"] == "assistant" else "user"
            if turns and turns[-1]["role"] == role:
                turns[-1]["content"][0]["text"] += "\n" + m["text"]
            else:
                turns.append({"role": role, "content": [{"type": "text", "text": m["text"]}]})
        if turns and turns[0]["role"] == "assistant":
            turns.insert(0, {"role": "user", "content": [{"type": "text", "text": "(conversation so far)"}]})
        if image and turns:
            turns[-1]["content"].insert(0, {"type": "image", "source": {"type": "base64", "media_type": image.mime,
                                                                         "data": image.data_b64}})
        body = {"model": self.model, "max_tokens": 800, "system": system, "messages": turns}
        started = time.monotonic()
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.post(URL, json=body, headers={"x-api-key": config.key("claude"),
                                                            "anthropic-version": "2023-06-01"})
        if r.status_code != 200:
            raise ProviderError(f"claude {r.status_code}: {r.text[:200]}")
        data = r.json()
        text = "".join(block.get("text", "") for block in data.get("content", []) if block.get("type") == "text")
        usage = data.get("usage", {})
        return Completion(text, self.name, self.model, int((time.monotonic() - started) * 1000),
                          usage.get("input_tokens", 0), usage.get("output_tokens", 0))
