"""CJ brain server. Run from brain/:  uvicorn app.main:app --host 0.0.0.0 --port 8765"""
from __future__ import annotations

import asyncio
import base64
import secrets
import time
from typing import Literal
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, model_validator

from . import agent, config, discovery, live, memory, notes, nudges, phone_agent, tools, tts
from .events import bus
from .models.base import Attachment
from .models import subscription
from .models.base import ProviderError
from .models.router import router
from .modes import assistant
from .modes.common import ask_json


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(discovery.announce())  # so the phone finds the brain after an address change
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="CJ brain", lifespan=lifespan)
DASHBOARD = Path(__file__).parent / "dashboard" / "index.html"


def _valid(token: str) -> bool:
    return secrets.compare_digest(token.encode(), config.token().encode())


def require_auth(authorization: str = Header(default="")) -> None:
    if not _valid(authorization.removeprefix("Bearer ").strip()):
        raise HTTPException(401, "bad or missing pairing token")


class Turn(BaseModel):
    role: str = Field(pattern="^(user|assistant)$")
    text: str


class Location(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    acc: float | None = Field(default=None, ge=0)  # metres; network fixes can be 500 m off


class AskIn(BaseModel):
    """A typed question (text), or a spoken one (audio_b64, a WAV clip) that the model transcribes."""
    text: str = Field(default="", max_length=4000)
    mode: str = "assistant"
    history: list[Turn] = []
    image_b64: str | None = Field(default=None, max_length=8_000_000)
    mime: str = "image/jpeg"
    audio_b64: str | None = Field(default=None, max_length=4_000_000)  # about 90 s of 16 kHz mono
    audio_mime: str = "audio/wav"
    voice: bool = False  # also return the answer as speech (voice_b64 in the reply)
    location: Location | None = None  # the phone's position, for "how long to reach…"
    assistant: Literal["codex", "claude-code"] | None = None

    @model_validator(mode="after")
    def text_or_audio(self):
        if not self.text.strip() and not self.audio_b64:
            raise ValueError("send text or audio")
        return self


@app.get("/health")
async def health():
    selected = subscription.selected()
    return {"name": "CJ", "ok": True, "providers": router.status(), "assistant": selected,
            "voice_mode": "local" if selected in subscription.NAMES else "gemini"}


@app.get("/api/bridge/status", dependencies=[Depends(require_auth)])
async def bridge_status():
    from .pair import lan_ip, PORT
    accounts = await asyncio.gather(*(subscription.account(name) for name in subscription.NAMES))
    return {"assistant": subscription.selected(), "execution": "unrestricted",
            "url": f"http://{lan_ip()}:{PORT}",
            "accounts": dict(zip(subscription.NAMES, accounts))}


@app.post("/api/ask", dependencies=[Depends(require_auth)])
async def ask(body: AskIn, request: Request):
    started = time.monotonic()
    history = [t.model_dump() for t in body.history]
    tools.LOCATION.set(body.location.model_dump(exclude_none=True) if body.location else None)
    provider = body.assistant or subscription.selected()
    if provider in subscription.NAMES:
        if not body.text.strip():
            raise HTTPException(422, "Use the updated iPhone app to transcribe speech locally for subscription mode.")
        image = Attachment(body.image_b64, body.mime) if body.image_b64 else None
        async def disconnected():
            while not await request.is_disconnected():
                await asyncio.sleep(0.25)
        job = asyncio.create_task(subscription.answer(body.text, history, image, provider))
        connection = asyncio.create_task(disconnected())
        try:
            done, _ = await asyncio.wait([job, connection], return_when=asyncio.FIRST_COMPLETED)
            if connection in done:
                raise HTTPException(499, "The phone disconnected; the assistant request was stopped.")
            out = await job
            out["ms"] = int((time.monotonic() - started) * 1000)
            bus.emit("answer", mode="subscription", provider=provider, spoken=out["spoken"], ms=out["ms"])
            # Speech is rendered on the iPhone; never call an API voice provider.
            return out
        except ProviderError as error:
            raise HTTPException(503, str(error)) from error
        finally:
            job.cancel(); connection.cancel()
            await asyncio.gather(job, connection, return_exceptions=True)
    try:
        if body.audio_b64 and not body.text.strip():
            out = await assistant.ask_spoken(Attachment(body.audio_b64, body.audio_mime), history)
            bus.emit("heard", mode=body.mode, text=out["heard"] or "(no clear speech)", has_image=False, spoken=True)
        else:
            bus.emit("heard", mode=body.mode, text=body.text, has_image=bool(body.image_b64))
            image = Attachment(body.image_b64, body.mime) if body.image_b64 else None
            out = await assistant.ask(body.text, history, image)
    except Exception as e:
        bus.emit("error", where="ask", error=str(e)[:200])
        raise HTTPException(502, f"no AI provider could answer: {e}"[:300]) from e
    if body.voice and out["spoken"]:
        audio = await tts.speak(out["spoken"], out.get("language"))
        if audio:
            out["voice_b64"] = base64.b64encode(audio).decode()
    out["ms"] = int((time.monotonic() - started) * 1000)
    if out["needs_photo"]:
        bus.emit("needs_photo", mode=body.mode, text=out["heard"], ms=out["ms"])
    else:
        bus.emit("answer", mode=body.mode, spoken=out["spoken"], language=out["language"], ms=out["ms"])
    return out


class DictateIn(BaseModel):
    session: str = Field(min_length=1, max_length=40)
    audio_b64: str = Field(min_length=1, max_length=4_000_000)
    audio_mime: str = "audio/wav"


@app.post("/api/notes/dictate", dependencies=[Depends(require_auth)])
async def notes_dictate(body: DictateIn):
    """One chunk of "start taking notes". When the user says "stop taking notes", the reply has the summary."""
    try:
        out = await assistant.dictate(Attachment(body.audio_b64, body.audio_mime), body.session)
    except Exception as e:
        bus.emit("error", where="dictate", error=str(e)[:200])
        raise HTTPException(502, f"couldn't transcribe: {e}"[:300]) from e
    bus.emit("dictation", heard=out["heard"][:200], stopped=out["stopped"])
    if out["stopped"] and out.get("spoken"):
        audio = await tts.speak(out["spoken"])
        if audio:
            out["voice_b64"] = base64.b64encode(audio).decode()
    return out


@app.get("/api/notes", dependencies=[Depends(require_auth)])
async def notes_list():
    return {"notes": notes.load()}


class GlanceIn(BaseModel):
    image_b64: str = Field(min_length=1, max_length=8_000_000)
    mime: str = "image/jpeg"


_last_glance = ""


@app.post("/api/glance", dependencies=[Depends(require_auth)])
async def glance(body: GlanceIn):
    """Visual memory (opt-in): one automatic photo. Only a short note is kept; the photo itself is not stored."""
    global _last_glance
    note = await assistant.glance(Attachment(body.image_b64, body.mime), _last_glance)
    if note:
        _last_glance = note
        bus.emit("glance", note=note)
    return {"kept": bool(note)}


class HearIn(BaseModel):
    audio_b64: str = Field(min_length=1, max_length=4_000_000)
    audio_mime: str = "audio/wav"


@app.post("/api/hear", dependencies=[Depends(require_auth)])
async def hear(body: HearIn):
    """Just what was said (no answer): the phone agent's "should I?" questions."""
    data, _ = await ask_json("transcribe", assistant.TRANSCRIBE, [{"role": "user", "text": "(audio)"}],
                             Attachment(body.audio_b64, body.audio_mime))
    return {"heard": str(data.get("heard", "")).strip()}


class AgentStepIn(BaseModel):
    goal: str = Field(min_length=1, max_length=500)
    screen: list[dict] = Field(default_factory=list, max_length=400)
    history: list[str] = Field(default_factory=list, max_length=60)
    approved: str = Field(default="", max_length=200)  # the risky button the user just said yes to


@app.post("/api/agent/step", dependencies=[Depends(require_auth)])
async def agent_step(body: AgentStepIn):
    """Phone agent: the next tap, text or question for the goal, given what's on the phone's screen now."""
    out = await phone_agent.step(body.goal, body.screen, body.history, body.approved)
    bus.emit("phone_agent", goal=body.goal, step=out.get("do"), say=out.get("say", ""))
    if out.get("say") and out["do"] in ("done", "ask", "confirm"):
        audio = await tts.speak(out["say"])
        if audio:
            out["voice_b64"] = base64.b64encode(audio).decode()
    return out


class NudgeIn(BaseModel):
    location: Location


@app.post("/api/nudge", dependencies=[Depends(require_auth)])
async def nudge(body: NudgeIn):
    """The phone's position while hands-free is on. Returns something to say when the place makes it useful."""
    out = await nudges.NUDGER.check(body.location.model_dump(exclude_none=True))
    if out["say"]:
        bus.emit("nudge", text=out["say"])
        audio = await tts.speak(out["say"])
        if audio:
            out["voice_b64"] = base64.b64encode(audio).decode()
    return out


class SpeakIn(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


@app.post("/api/speak", dependencies=[Depends(require_auth)])
async def speak(body: SpeakIn):
    """CJ's voice for things the phone says on its own, like a timer going off."""
    audio = await tts.speak(body.text)
    return {"voice_b64": base64.b64encode(audio).decode() if audio else ""}


@app.get("/api/jobs/done", dependencies=[Depends(require_auth)])
async def jobs_done():
    """Claude Code jobs that finished since the phone last asked; the phone reads each summary aloud once."""
    return {"jobs": [{"project": j.project, "state": j.state, "summary": j.summary} for j in agent.take_finished()]}


@app.get("/api/memory", dependencies=[Depends(require_auth)])
async def memory_list():
    return {"notes": memory.load()}


@app.get("/dashboard")
async def dashboard():
    return FileResponse(DASHBOARD)


@app.websocket("/ws/live")
async def ws_live(ws: WebSocket, token: str = ""):
    """Real-time conversation (and live translation) with Gemini Live; see live.py. The phone sends its pairing
    token as a header, so it doesn't show up in the server's request log."""
    token = ws.headers.get("authorization", "").removeprefix("Bearer ").strip() or token
    if not _valid(token):
        await ws.close(code=4401)
        return
    await ws.accept()
    try:
        if subscription.selected() in subscription.NAMES:
            await ws.send_json({"type": "error", "text": "Use the updated CJ iPhone app for subscription voice. Speech recognition and playback run on the phone."})
            return
        await live.Bridge(ws).run()
    except WebSocketDisconnect:
        pass
    finally:
        try:
            await ws.close()
        except (RuntimeError, WebSocketDisconnect):
            pass  # the phone already hung up


@app.websocket("/ws/dashboard")
async def ws_dashboard(ws: WebSocket, token: str = ""):
    if not _valid(token):
        await ws.close(code=4401)
        return
    await ws.accept()
    for event in list(bus.history):
        await ws.send_json(event)
    queue = bus.subscribe()
    try:
        while True:
            await ws.send_json(await queue.get())
    except WebSocketDisconnect:
        pass
    finally:
        bus.unsubscribe(queue)
