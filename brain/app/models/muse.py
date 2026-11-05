"""Paired Muse gadget chat, hosted by the native Mac bridge."""
import asyncio
import json
import os
from pathlib import Path
import time
from uuid import UUID, uuid4

from .base import Attachment, Completion, Provider, ProviderError


async def _exchange(path: str, payload: bytes):
    reader, writer = await asyncio.open_unix_connection(path)
    try:
        writer.write(len(payload).to_bytes(4, "big") + payload)
        await writer.drain()
        size = int.from_bytes(await reader.readexactly(4), "big")
        if not 0 < size <= 64000:
            raise ValueError("invalid frame")
        return json.loads(await reader.readexactly(size))
    finally:
        writer.close()
        await writer.wait_closed()


class Muse(Provider):
    name = "muse"

    def available(self) -> bool:
        path = os.environ.get("CJ_MUSE_SOCKET")
        return bool(path and Path(path).is_socket())

    async def reply(self, text: str, conversation: UUID | None = None) -> str:
        if not self.available():
            raise ProviderError("Open a Muse-enabled CJ Bridge on the Mac and choose Pair Muse.")
        payload = json.dumps({"text": text, "conversation": str(conversation or uuid4())}, ensure_ascii=False).encode()
        if len(payload) > 64000:
            raise ProviderError("This message is too long for Muse.")
        try:
            response = await asyncio.wait_for(_exchange(os.environ["CJ_MUSE_SOCKET"], payload), 180)
        except asyncio.TimeoutError as exc:
            raise ProviderError("Muse timed out. Check the conversation in Muse before sending again.") from exc
        except (OSError, asyncio.IncompleteReadError, ValueError) as exc:
            raise ProviderError("The Muse connection closed. Check CJ Bridge on the Mac.") from exc
        if isinstance(response, dict):
            if isinstance(response.get("error"), str):
                raise ProviderError(response["error"][:400])
            if isinstance(response.get("reply"), str) and response["reply"].strip():
                return response["reply"].strip()
        raise ProviderError("Muse returned an unreadable reply.")

    @staticmethod
    def require_text(image: Attachment | None):
        if image:
            raise ProviderError("Muse gadget chat accepts text and transcribed speech. Choose Codex or Claude Code to send a glasses photo.")

    async def answer(self, text: str, image: Attachment | None, conversation: UUID | None) -> dict:
        self.require_text(image)
        reply = await self.reply(text, conversation)
        return {"spoken": reply, "heard": text, "provider": self.name}

    async def complete(self, system: str, messages: list[dict], image: Attachment | None = None,
                       json_mode: bool = False) -> Completion:
        self.require_text(image)
        start = time.monotonic()
        prompt = system + "\n" + json.dumps(messages, ensure_ascii=False)
        if json_mode:
            prompt += "\nReturn the requested JSON object."
        return Completion(await self.reply(prompt), self.name, "Muse gadget", int((time.monotonic() - start) * 1000))
