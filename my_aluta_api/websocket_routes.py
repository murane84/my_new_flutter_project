# websocket_routes.py
import json
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from websocket_manager import connect_user, disconnect_user, notify_user

router = APIRouter()


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
            # (Other event types are still accepted and ignored, keeping the
            #  socket alive as a heartbeat.)

    except WebSocketDisconnect:
        disconnect_user(user_id, websocket)
