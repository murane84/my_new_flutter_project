"""Preset wallpaper gallery.

These are APP-OWNED background images (not user data): a curated set that any
signed-in user may browse and pick for an Our Space background or a Circle chat
wallpaper. They live as static files bundled with the deploy under
``my_aluta_api/assets/wallpapers``; the catalogue below is the source of truth.

Consistent with the "server is a relay, not a warehouse" stance, the user's
*choice* of wallpaper is stored on the device (per-chat) or as a plain URL on
their own Space row — never as user media on the server. Only these shared,
read-only presets are hosted here.

Each preset may have an optional WIDE (landscape) companion file
``<id>_wide.jpg`` for desktop / tablet screens; when present it is served at
``/wallpapers/<id>/wide`` and advertised as ``wide_url`` in the catalogue, so a
wide screen can show a proper landscape image instead of a tiled portrait. The
wide files are optional — the catalogue degrades gracefully until they exist.
"""

import os

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse

from models import User
from auth import get_current_user_flexible

router = APIRouter(prefix="/wallpapers", tags=["Wallpapers"])

# Absolute path to the bundled asset directory, resolved once at import.
_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "assets", "wallpapers")
)

# id -> display name. The portrait file is "<id>.jpg"; an optional landscape
# companion is "<id>_wide.jpg". Add rows here to grow the gallery.
_CATALOGUE = [
    ("w01", "Purple Shore"),
    ("w02", "Teal Wood"),
    ("w03", "Crimson Peak"),
    ("w04", "Window in the Clouds"),
    ("w05", "Neon Drive"),
    ("w06", "City Dusk"),
    ("w07", "Bold Abstract"),
    ("w08", "Snow Globe"),
    ("w09", "Dewdrops"),
    ("w10", "Blue Gradient"),
    ("w11", "Daddy + Me"),
    ("w12", "I Love You"),
    ("w13", "Moonlit Embrace"),
    ("w14", "Purple Proposal"),
    ("w15", "Moonlit Proposal"),
    ("w16", "Heart & Moon"),
    ("w17", "Hand in Hand"),
    ("w18", "Under the Moon"),
    ("w19", "Hearts Swing"),
    ("w20", "Mommy & Me"),
]

_IDS = {wid for wid, _ in _CATALOGUE}


def _portrait_path(wid: str) -> str:
    return os.path.join(_DIR, f"{wid}.jpg")


def _wide_path(wid: str) -> str:
    return os.path.join(_DIR, f"{wid}_wide.jpg")


@router.get("")
def list_wallpapers(current_user: User = Depends(get_current_user_flexible)):
    """Catalogue of preset wallpapers. Auth required (signed-in users only), but
    no ownership check — these are shared app assets. Only presets whose portrait
    file is actually present are returned, so a half-added row never 404s a
    client. ``wide_url`` is included only when a landscape companion exists."""
    out = []
    for wid, name in _CATALOGUE:
        if not os.path.isfile(_portrait_path(wid)):
            continue
        item = {
            "id": wid,
            "name": name,
            "url": f"/wallpapers/{wid}",
        }
        if os.path.isfile(_wide_path(wid)):
            item["wide_url"] = f"/wallpapers/{wid}/wide"
        out.append(item)
    return {"wallpapers": out}


@router.get("/{wallpaper_id}")
def get_wallpaper(
    wallpaper_id: str,
    current_user: User = Depends(get_current_user_flexible),
):
    """Serve a preset's portrait image to any signed-in user."""
    if wallpaper_id not in _IDS:
        raise HTTPException(status_code=404, detail="Wallpaper not found")
    path = _portrait_path(wallpaper_id)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Wallpaper not found")
    return FileResponse(
        path,
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@router.get("/{wallpaper_id}/wide")
def get_wallpaper_wide(
    wallpaper_id: str,
    current_user: User = Depends(get_current_user_flexible),
):
    """Serve a preset's optional landscape image for wide screens. 404 when no
    wide companion has been added yet — the client then tiles the portrait."""
    if wallpaper_id not in _IDS:
        raise HTTPException(status_code=404, detail="Wallpaper not found")
    path = _wide_path(wallpaper_id)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="No wide variant")
    return FileResponse(
        path,
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
