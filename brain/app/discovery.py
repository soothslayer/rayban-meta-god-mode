"""Announces the brain on the local network (Bonjour, like AirPrint), so the phone can find it again when the
Mac gets a new Wi-Fi address. Uses macOS's own `dns-sd` tool, which also keeps the announcement up to date
when the address changes. Only the port is announced; every request still needs the pairing token."""
from __future__ import annotations

import asyncio
import logging
import shutil
import socket

from .pair import PORT

SERVICE = "_cjbrain._tcp"
log = logging.getLogger("cj.discovery")


async def announce() -> None:
    """Runs until cancelled. Does nothing where dns-sd doesn't exist (Linux, tests)."""
    if not shutil.which("dns-sd"):
        return
    name = f"CJ brain on {socket.gethostname().split('.')[0][:40]}"
    proc = await asyncio.create_subprocess_exec("dns-sd", "-R", name, SERVICE, "local", str(PORT), "v=1",
                                                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    log.info("announcing %s on port %s", SERVICE, PORT)
    try:
        await proc.wait()
    finally:
        if proc.returncode is None:
            proc.terminate()
