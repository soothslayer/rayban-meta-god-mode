"""CJ's voice: Microsoft Azure Speech (Olivia by default; pick another with tools/azure_voice_samples.py).

Each reply is spoken by a native voice for its language. The model reports the reply's language (an ISO 639-1
code like "es", or "hinglish"); when it doesn't, the script of the text decides, and anything else goes to a
multilingual voice. Needs the "azure_speech" key and "azure_region" in ~/.cj/config.json. Without them, or when
Azure fails, the phone falls back to its own text-to-speech.
"""
from __future__ import annotations

import os
import re
from xml.sax.saxutils import escape

import httpx

from . import config

VOICE = os.environ.get("CJ_VOICE", "en-US-Olivia:MAI-Voice-2.1-Flash")  # natural and expressive; set CJ_VOICE to change it
MULTILINGUAL = "en-US-AvaMultilingualNeural"  # speaks most languages; used when there's no native voice below

# Language code -> (Azure voice, SSML locale). All female, natural ("Neural") voices.
VOICES = {
    "en": (VOICE, "en-US"), "hinglish": (VOICE, "en-US"),
    "hi": (os.environ.get("CJ_VOICE_HINDI", "hi-IN-SwaraNeural"), "hi-IN"),
    "zh": ("zh-CN-XiaoxiaoNeural", "zh-CN"), "es": ("es-ES-ElviraNeural", "es-ES"), "fr": ("fr-FR-DeniseNeural", "fr-FR"),
    "ar": ("ar-SA-ZariyahNeural", "ar-SA"), "bn": ("bn-IN-TanishaaNeural", "bn-IN"), "pt": ("pt-BR-FranciscaNeural", "pt-BR"),
    "ru": ("ru-RU-SvetlanaNeural", "ru-RU"), "ur": ("ur-IN-GulNeural", "ur-IN"), "ja": ("ja-JP-NanamiNeural", "ja-JP"),
    "de": ("de-DE-KatjaNeural", "de-DE"), "ko": ("ko-KR-SunHiNeural", "ko-KR"), "it": ("it-IT-ElsaNeural", "it-IT"),
    "tr": ("tr-TR-EmelNeural", "tr-TR"), "id": ("id-ID-GadisNeural", "id-ID"), "ta": ("ta-IN-PallaviNeural", "ta-IN"),
    "te": ("te-IN-ShrutiNeural", "te-IN"), "mr": ("mr-IN-AarohiNeural", "mr-IN"), "gu": ("gu-IN-DhwaniNeural", "gu-IN"),
}

# When the model gives no language: the writing system is a strong hint.
SCRIPTS = [(r"[ऀ-ॿ]", "hi"), (r"[一-鿿]", "zh"), (r"[぀-ヿ]", "ja"), (r"[가-힯]", "ko"),
           (r"[؀-ۿ]", "ar"), (r"[ঀ-৿]", "bn"), (r"[Ѐ-ӿ]", "ru"), (r"[஀-௿]", "ta"),
           (r"[ఀ-౿]", "te"), (r"[઀-૿]", "gu")]


def available() -> bool:
    return bool(config.key("azure_speech") and config.load().get("azure_region"))


# Languages written in their own script. Labelled with one of these but written in Roman letters, the reply is
# Hinglish-style ("Mumbai mein baarish ho rahi hai"), which a Hindi or Japanese voice reads badly.
OWN_SCRIPT = {"hi", "zh", "ar", "bn", "ru", "ur", "ja", "ko", "ta", "te", "mr", "gu"}


def voice_for(text: str, language: str | None = None) -> tuple[str, str]:
    code = (language or "").lower().strip()
    if code in OWN_SCRIPT and text.isascii():
        return VOICES["hinglish"]
    if code in VOICES and not (code in ("en", "hinglish") and not text.isascii()):
        return VOICES[code]
    for pattern, script_code in SCRIPTS:
        if re.search(pattern, text):
            return VOICES[script_code]
    return VOICES["en"] if text.isascii() else (MULTILINGUAL, "en-US")


async def speak(text: str, language: str | None = None) -> bytes | None:
    """24 kHz 16-bit mono WAV of [text], or None if Azure isn't set up or fails."""
    if not text.strip() or not available():
        return None
    voice, lang = voice_for(text, language)
    ssml = (f'<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="{lang}">'
            f'<voice name="{voice}">{escape(text[:2000])}</voice></speak>')
    region = config.load()["azure_region"]
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            r = await client.post(f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1",
                                  content=ssml.encode(), headers={
                                      "Ocp-Apim-Subscription-Key": config.key("azure_speech"),
                                      "Content-Type": "application/ssml+xml",
                                      "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
                                      "User-Agent": "CJ"})
    except httpx.HTTPError:
        return None
    return r.content if r.status_code == 200 else None
