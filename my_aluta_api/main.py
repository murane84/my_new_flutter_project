import asyncio
from contextlib import asynccontextmanager
import config
import os
import socket

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi
from fastapi.staticfiles import StaticFiles

from config import DATABASE_URL
from database import engine
from models import Base

from auth import router as auth_router
from routers import messages as messages_router
from routers import users as users_router
from routers import upload
from routers import attachments
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


# ✅ Mount media folder
app.mount("/media", StaticFiles(directory="media"), name="media")


# ✅ Include Routers
app.include_router(auth_router, prefix="/auth", tags=["Authentication"])
app.include_router(users_router.router)
app.include_router(messages_router.router)
app.include_router(upload.router)
app.include_router(attachments.router)
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
        "ALTER TABLE messages ALTER COLUMN content DROP NOT NULL",
        # Direct-call phone number + profile picture on the user profile.
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url VARCHAR",
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


# ✅ Serve the Flutter web app (built into ./webapp) at the site root. Mounted
#    LAST so it only catches paths the API routers / /health / /api / /media
#    didn't already handle. html=True serves index.html for "/". If the build
#    folder is missing the API still runs (root just 404s) — so a bad deploy
#    never takes the whole API down.
_WEBAPP_DIR = os.path.join(os.path.dirname(__file__), "webapp")
if os.path.isdir(_WEBAPP_DIR):
    app.mount("/", StaticFiles(directory=_WEBAPP_DIR, html=True), name="webapp")


# ✅ Run server
if __name__ == "__main__":
    ip = socket.gethostbyname(socket.gethostname())
    print(f"🔗 Server running on: http://{ip}:8001")

    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8001, reload=True)
