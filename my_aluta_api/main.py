import asyncio
from contextlib import asynccontextmanager
import mimetypes
import os
import shutil
import socket

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

import config
from database import engine
from models import Base

from auth import router as auth_router
from routers import messages as messages_router
from routers import users as users_router
from routers import upload
from routers import live as live_router
from websocket_routes import router as websocket_router
import websocket_manager


# ✅ Lifespan (modern way instead of @on_event)
@asynccontextmanager
async def lifespan(app: FastAPI):
    websocket_manager.main_loop = asyncio.get_running_loop()
    yield


# ✅ Create FastAPI app ONCE
app = FastAPI(lifespan=lifespan)


# ✅ CORS — added early. Uses "*" origins with credentials disabled, which is
# the spec-compliant combination (the app authenticates with Bearer tokens,
# not cookies, so credentials aren't needed).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ✅ Ensure the media directory exists BEFORE mounting it. On a fresh host
# (e.g. Railway) the folder won't exist yet and StaticFiles would crash at
# import time.
MEDIA_DIR = "media"
os.makedirs(os.path.join(MEDIA_DIR, "audio"), exist_ok=True)
app.mount("/media", StaticFiles(directory=MEDIA_DIR), name="media")


# ✅ Include Routers
app.include_router(auth_router, prefix="/auth", tags=["Authentication"])
app.include_router(users_router.router)
app.include_router(messages_router.router)
app.include_router(upload.router)
app.include_router(live_router.router)
app.include_router(websocket_router)


# ✅ Create DB tables on startup (idempotent; safe for first deploy).
Base.metadata.create_all(bind=engine)


# ✅ Health / discovery endpoint — Flutter uses this to detect the server.
@app.get("/health")
def health_check():
    hostname = socket.gethostname()
    return {
        "status": "ok",
        "app": "aluta",
        "host": hostname,
    }


# ✅ API welcome (kept under /api so "/" can serve the web app when built)
@app.get("/api")
def api_root():
    return {
        "message": "Welcome to My Aluta API",
        "environment": config.ENVIRONMENT,
    }


# ✅ Flutter web PWA. If a built copy exists in ./webapp it is served at "/";
# otherwise "/" returns a small JSON hint. The actual mount is added at the very
# END of this file so that all API routes take precedence over the static app.
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/manifest+json", ".webmanifest")
mimetypes.add_type("application/vnd.android.package-archive", ".apk")
WEBAPP_DIR = "webapp"
_HAS_WEBAPP = os.path.isfile(os.path.join(WEBAPP_DIR, "index.html"))

if not _HAS_WEBAPP:
    @app.get("/")
    def read_root():
        return {
            "message": "Welcome to My Aluta API",
            "environment": config.ENVIRONMENT,
            "webapp": "not_built",
        }


# ✅ App downloads (APK / Windows zip) — stored on a Railway VOLUME, never in Git.
# Railway sets RAILWAY_VOLUME_MOUNT_PATH when a volume is attached; we keep the
# binaries under <volume>/downloads. Locally it falls back to ./volume_data.
VOLUME_DIR = os.getenv("RAILWAY_VOLUME_MOUNT_PATH") or os.path.join(os.getcwd(), "volume_data")
DOWNLOADS_DIR = os.path.join(VOLUME_DIR, "downloads")
os.makedirs(DOWNLOADS_DIR, exist_ok=True)

# Only these filenames are allowed (blocks path traversal / arbitrary hosting).
ALLOWED_DOWNLOADS = {"aluta.apk", "aluta-windows.zip"}


@app.get("/downloads/{filename}")
def get_download(filename: str):
    if filename not in ALLOWED_DOWNLOADS:
        raise HTTPException(status_code=404, detail="Not found")
    path = os.path.join(DOWNLOADS_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="This build hasn't been uploaded yet")
    return FileResponse(path, filename=filename)


@app.post("/admin/upload")
async def upload_build(
    key: str = Form(...),
    name: str = Form(...),
    file: UploadFile = File(...),
):
    """Push a new build to the volume. Protected by the UPLOAD_KEY env var."""
    expected = os.getenv("UPLOAD_KEY")
    if not expected or key != expected:
        raise HTTPException(status_code=401, detail="Unauthorized")
    if name not in ALLOWED_DOWNLOADS:
        raise HTTPException(status_code=400, detail=f"name must be one of {sorted(ALLOWED_DOWNLOADS)}")
    dest = os.path.join(DOWNLOADS_DIR, name)
    with open(dest, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
    return {"ok": True, "saved": name, "bytes": os.path.getsize(dest)}


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


# ✅ Mount the built Flutter web app LAST, so every API route above wins first.
# html=True serves index.html at "/", which is all a Flutter web PWA needs.
# Drop your `flutter build web` output into my_aluta_api/webapp/ to enable this.
if _HAS_WEBAPP:
    app.mount("/", StaticFiles(directory=WEBAPP_DIR, html=True), name="webapp")


# ✅ Run server (local dev only — Railway uses the Procfile start command).
if __name__ == "__main__":
    port = int(os.getenv("PORT", 8001))
    reload = config.ENVIRONMENT == "development"
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=reload)
