#!/bin/bash
set -euo pipefail
CJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CJ_APP="$CJ_ROOT/mac-app/build/CJ Bridge.app"
CJ_PYTHON="$CJ_ROOT/brain/.venv/bin/python"
if [ ! -x "$CJ_PYTHON" ]; then
  python3 -m venv "$CJ_ROOT/brain/.venv"
  "$CJ_PYTHON" -m pip install -r "$CJ_ROOT/brain/requirements.txt"
fi
mkdir -p "$CJ_APP/Contents/MacOS" "$CJ_APP/Contents/Resources"
CJ_MUSE_ROOT="${CJ_MUSE_SOURCE:-$(dirname "$CJ_ROOT")/muse-voice-ios}"
cj_sources=("$CJ_ROOT/mac-app/CJBridge.swift")
if [ -d "$CJ_MUSE_ROOT/Sources/MuseCore" ]; then
  cj_sources+=(-D CJ_MUSE "$CJ_ROOT/mac-app/MuseBridge.swift")
  for source in Support ChatSession Pairing Noise Wire ReplyCollector HelperPairing HelperTransport; do
    cj_sources+=("$CJ_MUSE_ROOT/Sources/MuseCore/$source.swift")
  done
  for source in MuseAPI MuseConnection BluetoothPairing; do
    cj_sources+=("$CJ_MUSE_ROOT/MuseVoice/$source.swift")
  done
  cp "$CJ_MUSE_ROOT/SDK-LICENSE.txt" "$CJ_MUSE_ROOT/THIRD_PARTY_NOTICES.md" "$CJ_APP/Contents/Resources/"
elif [ -n "${CJ_MUSE_SOURCE:-}" ]; then
  echo "CJ_MUSE_SOURCE must point to a muse-voice-ios checkout." >&2
  exit 1
fi
swiftc -parse-as-library "${cj_sources[@]}" -o "$CJ_APP/Contents/MacOS/CJBridge" -framework AppKit -framework SwiftUI -framework CoreImage
"$CJ_PYTHON" - "$CJ_ROOT" "$CJ_APP" "$CJ_PYTHON" <<'PY'
import json, pathlib, plistlib, sys
root, app, python = sys.argv[1:]
contents = pathlib.Path(app) / 'Contents'
(contents / 'Resources/runtime.json').write_text(json.dumps({'brain': str(pathlib.Path(root) / 'brain'), 'python': python}))
with (contents / 'Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleExecutable':'CJBridge', 'CFBundleIdentifier':'com.soothslayer.cj.bridge',
        'CFBundleName':'CJ Bridge', 'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'0.2.0',
        'CFBundleVersion':'1', 'NSHighResolutionCapable':True,
        'NSBluetoothAlwaysUsageDescription':'Pair this Mac as a Muse gadget when you choose Pair Muse.',
        'NSBluetoothPeripheralUsageDescription':'Let Muse on your iPhone discover CJ Bridge during pairing.',
        'NSLocalNetworkUsageDescription':'Connect your paired iPhone to CJ on this Mac.'}, stream)
PY
codesign --force --sign - "$CJ_APP"
printf 'Built %s\nThis development app uses the Python environment in this checkout.\n' "$CJ_APP"
