"""OpenAI GPT models (Chat Completions). Optional: add a key and pick a model with  ./set-key.sh openai"""
from __future__ import annotations

import os
import time

import httpx

from .. import config
from .base import Attachment, Completion, Provider, ProviderError

URL = "https://api.openai.com/v1/chat/completions"


class OpenAI(Provider):
    name = "openai"

    @property
    def model(self) -> str:
        # No built-in default: OpenAI renames models often, so you choose one when adding the key.
        return os.environ.get("CJ_OPENAI_MODEL") or config.load().get("openai_model") or ""

    def available(self) -> bool:
        return bool(config.key("openai") and self.model)

    async def complete(self, system, messages, image: Attachment | None = None, json_mode=False) -> Completion:
        chat = [{"role": "system", "content": system}] + [
            {"role": "assistant" if m["role"] == "assistant" else "user", "content": m["text"]} for m in messages]
        if image and len(chat) > 1:
            chat[-1]["content"] = [{"type": "text", "text": chat[-1]["content"]},
                                   {"type": "image_url", "image_url": {"url": f"data:{image.mime};base64,{image.data_b64}"}}]
        body = {"model": self.model, "messages": chat, "max_completion_tokens": 800}
        if json_mode:
            body["response_format"] = {"type": "json_object"}
        started = time.monotonic()
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.post(URL, json=body, headers={"Authorization": f"Bearer {config.key('openai')}"})
        if r.status_code != 200:
            raise ProviderError(f"openai {r.status_code}: {r.text[:200]}")
        data = r.json()
        usage = data.get("usage", {})
        return Completion(data["choices"][0]["message"].get("content") or "", self.name, self.model,
                          int((time.monotonic() - started) * 1000),
                          usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0))
