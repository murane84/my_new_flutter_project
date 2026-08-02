# websocket_routes.py
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from websocket_manager import connect_user, disconnect_user

router = APIRouter()

@router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: int):
    await connect_user(user_id, websocket)

    try:
        while True:
            # Keep connection alive (heartbeat)
            await websocket.receive_text()

    except WebSocketDisconnect:
        disconnect_user(user_id, websocket)