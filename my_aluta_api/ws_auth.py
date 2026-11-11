"""WebSocket login without the token in the URL.

Tokens in the address end up in every proxy / platform access log (Railway
logs printed them in full). New apps connect to a bare /ws/... address and
send the token as their FIRST message:  {"type": "auth", "token": "<jwt>"}.

Apps already installed still pass ?token=… — accepted for now so nobody is
cut off mid-update; drop that path once every user has updated.
"""
import asyncio
import json

from fastapi import WebSocket

AUTH_TIMEOUT_S = 10


async def ws_token(websocket: WebSocket, url_token: str = "") -> str:
    """The caller's JWT: the legacy ?token= if given, else the first frame.
    Returns "" when nothing valid arrives in time (the caller closes 4401).
    Call after websocket.accept()."""
    if url_token:
        return url_token
    try:
        raw = await asyncio.wait_for(websocket.receive_text(), AUTH_TIMEOUT_S)
        msg = json.loads(raw)
        if isinstance(msg, dict) and msg.get("type") == "auth":
            return str(msg.get("token") or "")
    except Exception:
        pass
    return ""
