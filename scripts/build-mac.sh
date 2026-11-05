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
swiftc -parse-as-library "$CJ_ROOT/mac-app/CJBridge.swift" -o "$CJ_APP/Contents/MacOS/CJBridge" -framework AppKit -framework SwiftUI -framework CoreImage
"$CJ_PYTHON" - "$CJ_ROOT" "$CJ_APP" "$CJ_PYTHON" <<'PY'
import json, pathlib, plistlib, sys
root, app, python = sys.argv[1:]
contents = pathlib.Path(app) / 'Contents'
(contents / 'Resources/runtime.json').write_text(json.dumps({'brain': str(pathlib.Path(root) / 'brain'), 'python': python}))
with (contents / 'Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleExecutable':'CJBridge', 'CFBundleIdentifier':'com.soothslayer.cj.bridge',
        'CFBundleName':'CJ Bridge', 'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'0.2.0',
        'CFBundleVersion':'1', 'NSHighResolutionCapable':True,
        'NSLocalNetworkUsageDescription':'Connect your paired iPhone to CJ on this Mac.'}, stream)
PY
codesign --force --sign - "$CJ_APP"
printf 'Built %s\nThis development app uses the Python environment in this checkout.\n' "$CJ_APP"
