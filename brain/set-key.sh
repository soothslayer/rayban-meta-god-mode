#!/usr/bin/env bash
# One-time: save a key.   ./set-key.sh [gemini|groq|azure_speech|claude|openai|alexa]
set -euo pipefail
cd "$(dirname "$0")"
[ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
exec .venv/bin/python -m app.setkey "$@"
