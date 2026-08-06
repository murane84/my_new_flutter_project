# websocket_routes.py
import json
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from websocket_manager import connect_user, disconnect_user, notify_user

router = APIRouter()

# Aluta in-app voice-call signaling message types, relayed peer-to-peer.
_CALL_SIGNALS = {
    "call_offer",     # caller → callee: SDP offer (starts ringing)
    "call_answer",    # callee → caller: SDP answer (accepted)
    "call_ice",       # both ways: an ICE candidate
    "call_decline",   # callee → caller: rejected
    "call_end",       # either: hang up an ongoing/answered call
    "call_cancel",    # caller → callee: cancelled before it was answered
    "call_busy",      # callee → caller: already in another call
}


@router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: int):
    await connect_user(user_id, websocket)

    try:
        while True:
            # Client may send lightweight realtime events (e.g. "typing").
            # Previously the payload was received and discarded, so the peer
            # never saw the typing indicator — relay it here.
            raw = await websocket.receive_text()
            try:
                data = json.loads(raw)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue

            etype = data.get("type")
            if etype == "typing":
                to = data.get("to")
                if to is not None:
                    try:
                        await notify_user(
                            int(to),
                            {"type": "typing", "user_id": int(user_id)},
                        )
                    except Exception:
                        pass
            elif etype in _CALL_SIGNALS:
                # Aluta voice-call signaling (WebRTC). Relay the whole payload
                # to the target user, stamping who it's `from`, so the two
                # peers can negotiate an internet call in real time. The server
                # is a pure relay here — no media ever passes through it.
                to = data.get("to")
                if to is not None:
                    payload = {k: v for k, v in data.items() if k != "to"}
                    payload["from"] = int(user_id)
                    try:
                        await notify_user(int(to), payload)
                    except Exception:
                        pass
            # (Other event types are still accepted and ignored, keeping the
            #  socket alive as a heartbeat.)

    except WebSocketDisconnect:
        disconnect_user(user_id, websocket)
