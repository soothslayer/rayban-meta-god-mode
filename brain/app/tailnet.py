"""Discover a private Tailscale Serve endpoint for CJ without altering other listeners."""
import json
from pathlib import Path
import re
import shutil
import subprocess

from .pair import PORT


def occupied_ports(config: dict) -> set[str]:
    ports = set(config.get("TCP") or {})
    hosts = set(config.get("Web") or {})
    hosts.update(host for host, enabled in (config.get("AllowFunnel") or {}).items() if enabled)
    ports.update(host.rsplit(":", 1)[-1] for host in hosts)
    for session in (config.get("Foreground") or {}).values():
        ports.update(occupied_ports(session))
    return ports


def private_url(dns: str, serve: dict) -> str | None:
    host = dns.rstrip(".").lower()
    if not re.fullmatch(r"(?:[a-z0-9-]+\.)+ts\.net", host):
        return None
    loopbacks = {f"http://{name}:{PORT}" for name in ("127.0.0.1", "localhost", "[::1]")}
    for port, listener in (serve.get("TCP") or {}).items():
        if not port.isdecimal() or not 1 <= int(port) <= 65535 or not listener.get("HTTPS"):
            continue
        key = f"{host}:{port}"
        if (serve.get("AllowFunnel") or {}).get(key):
            continue
        if any(port in occupied_ports(session) for session in (serve.get("Foreground") or {}).values()):
            continue
        handlers = ((serve.get("Web") or {}).get(key) or {}).get("Handlers") or {}
        # The phone sends its pairing credential to several paths on the origin.
        if handlers.keys() != {"/"} or handlers["/"].get("Proxy", "").rstrip("/") not in loopbacks:
            continue
        return f"https://{host}" if port == "443" else f"https://{key}"
    return None


def discover() -> tuple[str | None, str]:
    cli = shutil.which("tailscale")
    if not cli:
        bundled = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        if not bundled.is_file():
            return None, "Install Tailscale on your Mac and connect it to your tailnet."
        cli = str(bundled)

    def status(*args):
        output = subprocess.run([cli, *args, "--json"], capture_output=True, check=True, timeout=4)
        return json.loads(output.stdout) or {}

    try:
        state = status("status")
        if state.get("BackendState") != "Running":
            return None, "Connect Tailscale on your Mac, then refresh."
        serve = status("serve", "status")
        url = private_url((state.get("Self") or {}).get("DNSName", ""), serve)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, "Open Tailscale on your Mac, check its connection, then refresh."
    if url:
        return url, "Connect Tailscale on your iPhone, then scan this code in CJ."
    used = occupied_ports(serve)
    for port in ("8443", "9443", "10443"):
        if port not in used:
            return None, f"Run this in Terminal, then refresh:\ntailscale serve --bg --https={port} http://127.0.0.1:{PORT}"
    return None, "Choose a free HTTPS port for CJ in Tailscale Serve, then refresh."
