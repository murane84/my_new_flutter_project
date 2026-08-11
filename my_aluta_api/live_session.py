"""
In-memory live "listen together" session manager.

A live session lets a host stream a LOCAL audio file to invited listener(s) in
real time. Audio bytes and playback-control messages are relayed through this
process purely in memory and are NEVER written to disk or the database. When the
host ends the session (or disconnects), the session is torn down and nothing is
persisted.

This is intentionally ephemeral: sessions live only in `MANAGER.sessions` for the
lifetime of the process / session.
"""
from __future__ import annotations

import asyncio
import json
from typing import Dict, List, Optional
from fastapi import WebSocket


# How long the session survives after the HOST's socket drops before we give up
# and end it for everyone. A brief network glitch (WiFi blip, cell handover)
# should NOT kill a live session — the host reconnects within this window and
# playback resumes. Only a genuinely-gone host (closed app, long outage) lets
# the timer fire and ends the session.
HOST_GRACE_SECONDS = 45


class LiveSession:
    def __init__(self, session_id: str, host_id: int, invited_ids: List[int],
                 track: dict, host_username: str = ""):
        self.session_id = session_id
        self.host_id = host_id
        # Shown in the invite prompt (also when re-delivering a pending invite
        # to a listener who was offline when it was first sent).
        self.host_username = host_username
        self.invited_ids: List[int] = list(invited_ids)
        # Listeners who explicitly declined — don't re-deliver the invite to them.
        self.declined_ids: set[int] = set()
        # Everyone allowed in the session (host + invited listeners).
        self.allowed_ids: set[int] = {host_id, *invited_ids}
        # Metadata only — title/duration/mime. NOT the audio itself.
        self.track: dict = track or {}
        # Live socket connections, keyed by user id.
        self.connections: Dict[int, WebSocket] = {}
        # Last known playback state, so a listener that joins slightly late can
        # be told where the host currently is.
        self.is_playing: bool = False
        self.position_ms: int = 0
        # Pending "end the session because the host never came back" timer.
        # Set when the host drops, cancelled if the host reconnects in time.
        self.close_task: Optional["asyncio.Task"] = None

    def other_connections(self, sender_id: int) -> List[WebSocket]:
        return [ws for uid, ws in self.connections.items() if uid != sender_id]


class LiveSessionManager:
    def __init__(self) -> None:
        self.sessions: Dict[str, LiveSession] = {}

    # ---- lifecycle ---------------------------------------------------------
    def create(self, session_id: str, host_id: int, invited_ids: List[int],
               track: dict, host_username: str = "") -> LiveSession:
        session = LiveSession(session_id, host_id, invited_ids, track,
                              host_username=host_username)
        self.sessions[session_id] = session
        return session

    def pending_invites_for(self, user_id: int) -> List[LiveSession]:
        """Open invites waiting for [user_id]: they're an invited listener (not
        the host), the host IS connected, and they haven't joined yet. Used to
        re-deliver an invite to a listener who was offline when it was sent."""
        out: List[LiveSession] = []
        for s in self.sessions.values():
            if (user_id in s.allowed_ids
                    and user_id != s.host_id
                    and user_id not in s.declined_ids
                    and user_id not in s.connections
                    and s.host_id in s.connections):
                out.append(s)
        return out

    def get(self, session_id: str) -> Optional[LiveSession]:
        return self.sessions.get(session_id)

    def remove(self, session_id: str) -> None:
        self.sessions.pop(session_id, None)

    # ---- connections -------------------------------------------------------
    def attach(self, session_id: str, user_id: int, websocket: WebSocket) -> None:
        session = self.sessions.get(session_id)
        if session is not None:
            session.connections[user_id] = websocket

    def detach(self, session_id: str, user_id: int) -> None:
        session = self.sessions.get(session_id)
        if session is not None:
            session.connections.pop(user_id, None)

    def host_connected(self, session_id: str) -> bool:
        session = self.sessions.get(session_id)
        return session is not None and session.host_id in session.connections

    # ---- host reconnection grace window ------------------------------------
    def schedule_host_timeout(self, session_id: str, seconds: int = HOST_GRACE_SECONDS) -> None:
        """Arm a timer that ends the session if the host doesn't return in time.

        Called when the host's socket drops. Cancels any timer already armed so
        repeated blips just keep extending the same grace window.
        """
        session = self.sessions.get(session_id)
        if session is None:
            return
        if session.close_task is not None and not session.close_task.done():
            session.close_task.cancel()
        session.close_task = asyncio.create_task(
            self._end_if_host_absent(session_id, seconds)
        )

    def cancel_host_timeout(self, session_id: str) -> None:
        """Host came back — stop the pending end-the-session timer."""
        session = self.sessions.get(session_id)
        if session is None:
            return
        task = session.close_task
        session.close_task = None
        if task is not None and not task.done():
            task.cancel()

    async def _end_if_host_absent(self, session_id: str, seconds: int) -> None:
        try:
            await asyncio.sleep(seconds)
        except asyncio.CancelledError:
            return
        session = self.sessions.get(session_id)
        if session is None:
            return
        # Host reconnected during the grace window → nothing to do.
        if session.host_id in session.connections:
            return
        # Host never came back — end the session for the remaining listener(s).
        await self.broadcast_text(
            session_id, json.dumps({"type": "end", "reason": "host_left"})
        )
        self.remove(session_id)

    # ---- relaying ----------------------------------------------------------
    async def relay_text(self, session_id: str, sender_id: int, message: str) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        for ws in session.other_connections(sender_id):
            try:
                await ws.send_text(message)
            except Exception:
                pass

    async def relay_bytes(self, session_id: str, sender_id: int, data: bytes) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        for ws in session.other_connections(sender_id):
            try:
                await ws.send_bytes(data)
            except Exception:
                pass

    async def broadcast_text(self, session_id: str, message: str) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        for ws in list(session.connections.values()):
            try:
                await ws.send_text(message)
            except Exception:
                pass


# Single process-wide manager instance.
MANAGER = LiveSessionManager()
