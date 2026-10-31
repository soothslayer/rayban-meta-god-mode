#!/usr/bin/env bash
# Point CJ at your TV for voice control:  ./set-tv.sh 192.168.1.21
# On the TV first turn on ADB debugging (Fire TV: Settings -> My Fire TV -> Developer Options).
set -euo pipefail
cd "$(dirname "$0")"
IP="${1:?usage: ./set-tv.sh <tv ip address>}"
[ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
exec .venv/bin/python - "$IP" <<'PY'
import ipaddress, sys
from app import config
ip = str(ipaddress.ip_address(sys.argv[1]))
cfg = config.load()
cfg["tv_host"] = ip
config.save(cfg)
print(f"CJ will control the TV at {ip}. The first command shows 'Allow USB debugging?' on the TV: accept it.")
PY
