import asyncio
from contextlib import asynccontextmanager
import config
import os
import socket

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, Response

from config import DATABASE_URL
from database import engine
from models import Base

from auth import router as auth_router
from routers import messages as messages_router
from routers import users as users_router
from routers import upload
from routers import attachments
from routers import devices as devices_router
from routers import live as live_router
from routers import conversations as conversations_router
from routers import recognize as recognize_router
from routers import stories as stories_router
from websocket_routes import router as websocket_router
import websocket_manager
from sqlalchemy import text


# ✅ Lifespan (modern way instead of @on_event)
@asynccontextmanager
async def lifespan(app: FastAPI):
    websocket_manager.main_loop = asyncio.get_running_loop()
    yield


# ✅ Create FastAPI app ONCE
app = FastAPI(lifespan=lifespan)


# ⚠️ The public StaticFiles mount at /media was REMOVED: it served every
# uploaded file with no auth, so any URL was world-readable. Disk media (legacy
# /media/audio/*) is now served by an authenticated, participant-checked route
# in routers/attachments.py; DB attachments go through /attachments/{id}, also
# authenticated. See attachments.py.


# ✅ Include Routers
app.include_router(auth_router, prefix="/auth", tags=["Authentication"])
app.include_router(users_router.router)
app.include_router(messages_router.router)
app.include_router(upload.router)
app.include_router(attachments.router)
# Device (FCM) token registration for push notifications.
app.include_router(devices_router.router)
# Group + DM conversations (create group, list, fetch/send/read, members).
app.include_router(conversations_router.router)
# Listen-together (live session) endpoints: POST /live/sessions, /live/ws/{id},
# /live/sessions/{id}/end. Without this include the whole /live prefix 404s and
# starting a listen-together session fails.
app.include_router(live_router.router)
# Shazam-style song recognition (proxied to AudD; needs AUDD_API_TOKEN set).
app.include_router(recognize_router.router)
# Ephemeral 24h Stories (friends-only): post/feed/view/viewers/delete + media.
app.include_router(stories_router.router)
app.include_router(websocket_router)


# ✅ Create DB tables (creates new tables like media_assets; does NOT alter
#    existing ones).
Base.metadata.create_all(bind=engine)


# ✅ Idempotently add the media columns to the existing `messages` table.
#    create_all() won't ALTER an existing table, so we add them by hand. Uses
#    Postgres "ADD COLUMN IF NOT EXISTS" so it's safe to run on every boot.
def ensure_media_schema():
    stmts = [
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS message_type VARCHAR DEFAULT 'text'",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_url VARCHAR",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_name VARCHAR",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_mime VARCHAR",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_size INTEGER",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_duration INTEGER",
        # Conversation features: reactions / edit marker / delete tombstone.
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS reactions TEXT",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited BOOLEAN DEFAULT FALSE",
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT FALSE",
        # Pin-a-message: expiry timestamp (NULL = not pinned).
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ",
        "ALTER TABLE messages ALTER COLUMN content DROP NOT NULL",
        # Group conversations: every message belongs to a conversation; group
        # messages have no single receiver, so receiver_id becomes nullable
        # (DMs still set it, keeping the 1:1 path unchanged).
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS conversation_id INTEGER",
        "ALTER TABLE messages ALTER COLUMN receiver_id DROP NOT NULL",
        # Direct-call phone number + profile picture on the user profile.
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url VARCHAR",
        # Two-factor / password-recovery via TOTP (Google Authenticator).
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_secret VARCHAR",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN DEFAULT FALSE",
        # Owner of a DB-stored attachment, for the authenticated media endpoint.
        # New uploads set this at upload time; pre-existing rows stay NULL and
        # are handled by the endpoint's legacy path (see routers/attachments.py).
        "ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS uploader_id INTEGER",
        # Ephemeral shared songs: bytes are purged after the recipient caches
        # them locally (or after a 7-day TTL), keeping the row as a reference.
        # `data` must be nullable so it can be emptied on purge.
        "ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS ephemeral BOOLEAN DEFAULT FALSE",
        "ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS cached_at TIMESTAMPTZ",
        "ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS purged_at TIMESTAMPTZ",
        "ALTER TABLE media_assets ALTER COLUMN data DROP NOT NULL",
        # QR device-linking: the desktop's platform/label carried on the pending
        # link (added here too in case login_links was created before these).
        "ALTER TABLE login_links ADD COLUMN IF NOT EXISTS device_label VARCHAR",
        "ALTER TABLE login_links ADD COLUMN IF NOT EXISTS device_platform VARCHAR",
    ]
    try:
        with engine.begin() as conn:
            for s in stmts:
                try:
                    conn.execute(text(s))
                except Exception as e:  # noqa: BLE001
                    print(f"⚠️ ensure_media_schema stmt skipped: {e}")
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ ensure_media_schema failed: {e}")


ensure_media_schema()


# ✅ One-time backfill: fold every existing 1:1 message pair into a DM
#    conversation and stamp conversation_id onto those rows. Idempotent — it
#    only touches messages whose conversation_id is still NULL, so it no-ops on
#    every boot after the first (new messages are stamped at send time).
def backfill_dm_conversations():
    from database import SessionLocal
    import crud_conversations as cc
    from sqlalchemy import text as _text
    db = SessionLocal()
    try:
        pairs = db.execute(_text(
            """
            SELECT DISTINCT LEAST(sender_id, receiver_id)  AS a,
                            GREATEST(sender_id, receiver_id) AS b
            FROM messages
            WHERE conversation_id IS NULL
              AND receiver_id IS NOT NULL
              AND sender_id <> receiver_id
            """
        )).fetchall()
        made = 0
        for a, b in pairs:
            conv = cc.get_or_create_dm_conversation(db, int(a), int(b))
            db.execute(
                _text(
                    """
                    UPDATE messages SET conversation_id = :cid
                    WHERE conversation_id IS NULL
                      AND ((sender_id = :a AND receiver_id = :b)
                        OR (sender_id = :b AND receiver_id = :a))
                    """
                ),
                {"cid": conv.id, "a": int(a), "b": int(b)},
            )
            made += 1
        db.commit()
        if made:
            print(f"[migrate] backfilled {made} DM conversation(s)")
    except Exception as e:  # noqa: BLE001
        db.rollback()
        print(f"⚠️ backfill_dm_conversations failed: {e}")
    finally:
        db.close()


backfill_dm_conversations()


# ✅ Log whether push notifications can actually be sent. If this prints
#    "push=DISABLED", the backend has no Firebase service account, so incoming
#    calls / messages will NEVER wake a backgrounded or closed phone (the app
#    still works over the WebSocket while open). Set FIREBASE_SERVICE_ACCOUNT_JSON
#    and FIREBASE_PROJECT_ID on Railway to enable it.
def log_push_status():
    try:
        import push
        if push.push_available():
            print(f"[push] ENABLED (Firebase project={push._project_id()})")
        else:
            has_json = bool(config.FIREBASE_SERVICE_ACCOUNT_JSON)
            has_file = bool(config.FIREBASE_SERVICE_ACCOUNT_FILE)
            has_pid = bool(config.FIREBASE_PROJECT_ID)
            print(
                "[push] DISABLED — backgrounded phones will NOT wake on calls. "
                f"service_account_json={has_json} service_account_file={has_file} "
                f"project_id={has_pid}. Set FIREBASE_SERVICE_ACCOUNT_JSON + "
                "FIREBASE_PROJECT_ID to enable."
            )
    except Exception as e:  # noqa: BLE001
        print(f"[push] status check failed: {e}")


log_push_status()


# ✅ Health / discovery endpoint — Flutter uses this to auto-detect server IP
@app.get("/health")
def health_check():
    hostname = socket.gethostname()
    return {
        "status": "ok",
        "app": "aluta",
        "host": hostname,
    }


# ✅ API info endpoint. The site root ("/") now serves the Flutter web app (see
#    the StaticFiles mount at the bottom of this file), so the JSON welcome
#    message moved here to /api.
@app.get("/api")
def api_info():
    environment = os.getenv("ENVIRONMENT", "development")
    response = {"message": "Welcome to My Aluta API"}
    if environment == "development":
        response["database_url"] = DATABASE_URL
    return response


# ✅ CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ✅ Swagger Authorize Button
def custom_openapi():
    if app.openapi_schema:
        return app.openapi_schema

    openapi_schema = get_openapi(
        title="My Aluta API",
        version="1.0.0",
        description="API for My Aluta App with JWT Auth",
        routes=app.routes,
    )

    openapi_schema["components"]["securitySchemes"] = {
        "BearerAuth": {
            "type": "http",
            "scheme": "bearer",
            "bearerFormat": "JWT",
        }
    }

    for path in openapi_schema["paths"].values():
        for method in path.values():
            method["security"] = [{"BearerAuth": []}]

    app.openapi_schema = openapi_schema
    return app.openapi_schema


app.openapi = custom_openapi


# ✅ Serve the Flutter web app (built into ./webapp) at the site root.
#
#    IMPORTANT: this is a GET-only catch-all, NOT `app.mount("/", StaticFiles)`.
#    A Mount at "/" also matches WEBSOCKET scopes and can swallow the /ws and
#    /live/ws upgrade handshakes (which breaks chat read-receipts and listen-
#    together with "was not upgraded to websocket"). A plain @app.get route can
#    never match a WebSocket, so the API's WebSocket routes always win. It also
#    gives SPA deep-link fallback to index.html. Declared LAST so it only
#    handles GET paths the API routers / /health / /api / /media didn't.
_WEBAPP_DIR = os.path.join(os.path.dirname(__file__), "webapp")


@app.get("/{full_path:path}", include_in_schema=False)
async def _serve_web_app(full_path: str):
    if os.path.isdir(_WEBAPP_DIR):
        # Serve the requested static file if it exists (assets, js, wasm, …),
        # guarding against path traversal, else fall back to index.html.
        candidate = os.path.normpath(os.path.join(_WEBAPP_DIR, full_path))
        if (full_path
                and candidate.startswith(_WEBAPP_DIR)
                and os.path.isfile(candidate)):
            return FileResponse(candidate)
        index = os.path.join(_WEBAPP_DIR, "index.html")
        if os.path.isfile(index):
            return FileResponse(index)
    return Response(status_code=404)


# ✅ Run server
if __name__ == "__main__":
    ip = socket.gethostbyname(socket.gethostname())
    print(f"🔗 Server running on: http://{ip}:8001")

    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8001, reload=True)
