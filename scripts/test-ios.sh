#!/usr/bin/env bash
# Build and test against the real Python brain, isolated from the user's ~/.cj and AI keys.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
python_bin="${CJ_TEST_PYTHON:-$repo_root/brain/.venv/bin/python}"
if [ ! -x "$python_bin" ]; then
  echo 'Create brain/.venv with Python 3.10+ and install brain/requirements.txt first.' >&2
  exit 1
fi
simulator_id="${CJ_TEST_SIMULATOR:-$(xcrun simctl list devices available -j | "$python_bin" -c 'import json,sys; print(next(d["udid"] for group in json.load(sys.stdin)["devices"].values() for d in group if "iPhone" in d["name"]))')}"
fixture_home="$(mktemp -d -t cj-ios-tests)"
brain_pid=''
cleanup() {
  if [ -n "$brain_pid" ]; then kill "$brain_pid" 2>/dev/null || true; wait "$brain_pid" 2>/dev/null || true; fi
  rm -rf "$fixture_home"
}
trap cleanup EXIT
"$python_bin" - "$fixture_home" <<'PY'
import json, pathlib, socket, sys
with socket.socket() as probe:
    try:
        probe.bind(('127.0.0.1', 18765))
    except OSError:
        raise SystemExit('Port 18765 is already in use. Stop that process before running the iOS fixture.')
path = pathlib.Path(sys.argv[1]) / 'config.json'
path.write_text(json.dumps({'token': 'ios-integration-only'}))
path.chmod(0o600)
PY
# Empty provider keys explicitly override inherited credentials. The fixture never calls a live AI service.
env CJ_HOME="$fixture_home" CJ_FORCE_MOCK=1 CJ_GEMINI_KEY='' CJ_AZURE_SPEECH_KEY='' CJ_CLAUDE_KEY='' CJ_OPENAI_KEY='' CJ_GROQ_KEY='' \
  "$python_bin" -m uvicorn app.main:app --app-dir brain --host 127.0.0.1 --port 18765 > "$fixture_home/server.log" 2>&1 &
brain_pid=$!
"$python_bin" - <<'PY'
import time, urllib.request
for attempt in range(50):
    try:
        urllib.request.urlopen('http://127.0.0.1:18765/health', timeout=1)
        break
    except OSError:
        time.sleep(.2)
else:
    raise SystemExit('The isolated brain fixture failed to start.')
PY
xcodebuild -project ios-app/CJ.xcodeproj -scheme CJ \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath ios-app/build CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -jobs 2 test
