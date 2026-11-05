"""Picks a provider for each request and falls back down the chain when one fails or is rate limited.

Your main brain comes first (config "provider", or CJ_PROVIDER: gemini | claude | openai), then the free ones:
gemini -> groq (text only) -> mock. Speech is always heard by Gemini, the only one here that takes audio.
"""
from __future__ import annotations

import os

from .. import config
from ..events import bus
from .base import Attachment, Completion, Provider, ProviderError
from .claude import Claude
from .gemini import Gemini
from .groq import Groq
from .mock import Mock
from .openai import OpenAI
from .subscription import Subscription, NAMES

AUDIO = "gemini"
NO_IMAGES = {"groq"}


class Router:
    def __init__(self) -> None:
        self.providers: dict[str, Provider] = {p.name: p for p in (Gemini(), Claude(), OpenAI(), Groq(),
                                                                 Subscription("codex"), Subscription("claude-code"))}
        self.mock = Mock()

    def preferred(self) -> str:
        """The main brain you picked, if its key is set; otherwise Gemini."""
        name = os.environ.get("CJ_PROVIDER") or config.load().get("provider") or AUDIO
        if name in NAMES:
            return name  # Never silently switch subscription requests to a paid API.
        p = self.providers.get(name)
        return name if p and p.available() else AUDIO

    def chain(self, attachment: Attachment | None = None) -> list[Provider]:
        if os.environ.get("CJ_FORCE_MOCK") == "1":
            return [self.mock]
        if self.preferred() in NAMES:
            return [self.providers[self.preferred()]]
        if attachment and attachment.mime.startswith("audio/"):
            names = [AUDIO]
        else:
            names = list(dict.fromkeys([self.preferred(), "gemini", "groq"]))
            if attachment:
                names = [n for n in names if n not in NO_IMAGES]
        usable = [self.providers[n] for n in names if self.providers[n].available()]
        return usable or [self.mock]

    def status(self) -> dict:
        return {name: p.available() for name, p in self.providers.items()} | {"mock": True}

    async def complete(self, task: str, system: str, messages: list[dict], image: Attachment | None = None,
                       json_mode: bool = True) -> Completion:
        last_error: Exception | None = None
        for provider in self.chain(image):
            try:
                result = await provider.complete(system, messages, image, json_mode)
                bus.emit("model_call", task=task, provider=result.provider, model=result.model,
                         latency_ms=result.latency_ms, tokens_in=result.input_tokens,
                         tokens_out=result.output_tokens)
                return result
            except Exception as e:  # network error, rate limit, bad response: try the next one
                last_error = e
                bus.emit("model_failed", task=task, provider=provider.name, error=f"{type(e).__name__}: {e}"[:200])
        raise ProviderError(f"all providers failed: {type(last_error).__name__}: {last_error}")


router = Router()
