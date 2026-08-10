"""Song recognition (Shazam-style).

The client records a short clip from the mic and POSTs it here. We try to
identify it in two stages:

1. AudD (https://audd.io) — commercial, best for noisy mic captures. Needs
   AUDD_API_TOKEN. Returns rich data (artwork + Spotify/Apple links).
2. AcoustID (https://acoustid.org) — free/open fallback via Chromaprint's
   `fpcalc`. Needs ACOUSTID_API_KEY plus the `fpcalc`/`ffmpeg` binaries on the
   host (installed by nixpacks.toml). Best for clean audio; returns title/artist
   only. Used when AudD has no match / isn't configured.

Both tokens are read from the environment so they never ship in the app. If
neither is configured the endpoint returns 503 and the client shows a friendly
"not set up" message.
"""
import json
import os
import subprocess
import tempfile

import requests
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from models import User
from .users import get_current_user

router = APIRouter(prefix="/recognize", tags=["Recognition"])

AUDD_API_URL = os.getenv("AUDD_API_URL", "https://api.audd.io/")
AUDD_API_TOKEN = os.getenv("AUDD_API_TOKEN")

ACOUSTID_API_URL = os.getenv("ACOUSTID_API_URL", "https://api.acoustid.org/v2/lookup")
ACOUSTID_API_KEY = os.getenv("ACOUSTID_API_KEY")

# A clip is a few hundred KB; refuse anything absurd.
_MAX_BYTES = 6 * 1024 * 1024


# ── AudD ───────────────────────────────────────────────────────────────────

def _artwork_from(result: dict) -> str | None:
    apple = result.get("apple_music") or {}
    art = apple.get("artwork")
    if isinstance(art, dict) and art.get("url"):
        return str(art["url"]).replace("{w}", "300").replace("{h}", "300")
    spotify = result.get("spotify") or {}
    album = spotify.get("album") or {}
    imgs = album.get("images") or []
    if imgs and isinstance(imgs[0], dict) and imgs[0].get("url"):
        return imgs[0]["url"]
    return None


def _audd_lookup(contents: bytes, filename: str | None, content_type: str | None) -> dict | None:
    """Return a normalised match dict, or None on no-match / error."""
    try:
        resp = requests.post(
            AUDD_API_URL,
            data={"api_token": AUDD_API_TOKEN, "return": "apple_music,spotify"},
            files={"file": (filename or "clip.m4a", contents, content_type or "audio/mp4")},
            timeout=25,
        )
        payload = resp.json()
    except Exception:
        return None
    if payload.get("status") != "success":
        print(f"[recognize] AudD non-success: {payload.get('error') or payload}")
        return None
    result = payload.get("result")
    if not result:
        return None
    apple = result.get("apple_music") or {}
    spotify = result.get("spotify") or {}
    return {
        "matched": True,
        "source": "audd",
        "title": result.get("title"),
        "artist": result.get("artist"),
        "album": result.get("album"),
        "release_date": result.get("release_date"),
        "label": result.get("label"),
        "song_link": result.get("song_link"),
        "artwork": _artwork_from(result),
        "spotify_url": (spotify.get("external_urls") or {}).get("spotify"),
        "apple_url": apple.get("url"),
    }


# ── AcoustID (free fallback) ─────────────────────────────────────────────────

def _acoustid_lookup(contents: bytes) -> dict | None:
    """Fingerprint the clip with fpcalc and look it up on AcoustID. Returns a
    normalised match dict (title/artist/album), or None."""
    if not ACOUSTID_API_KEY:
        return None
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".m4a") as f:
            f.write(contents)
            tmp_path = f.name
        try:
            proc = subprocess.run(
                ["fpcalc", "-json", "-length", "20", tmp_path],
                capture_output=True, text=True, timeout=25,
            )
        except FileNotFoundError:
            print("[recognize] fpcalc not installed — AcoustID fallback unavailable")
            return None
        if proc.returncode != 0:
            print(f"[recognize] fpcalc failed: {proc.stderr.strip()[:200]}")
            return None
        fp = json.loads(proc.stdout or "{}")
        fingerprint = fp.get("fingerprint")
        duration = int(fp.get("duration") or 0)
        if not fingerprint or duration <= 0:
            return None
        resp = requests.post(
            ACOUSTID_API_URL,
            data={
                "client": ACOUSTID_API_KEY,
                "duration": duration,
                "fingerprint": fingerprint,
                "meta": "recordings+releasegroups",
            },
            timeout=20,
        )
        data = resp.json()
        if data.get("status") != "ok":
            print(f"[recognize] AcoustID error: {data.get('error') or data}")
            return None
        for r in data.get("results") or []:
            for rec in r.get("recordings") or []:
                title = rec.get("title")
                if not title:
                    continue
                artists = rec.get("artists") or []
                artist = ", ".join(
                    a.get("name", "") for a in artists if a.get("name")
                ).strip()
                album = None
                rgs = rec.get("releasegroups") or []
                if rgs and isinstance(rgs[0], dict):
                    album = rgs[0].get("title")
                return {
                    "matched": True,
                    "source": "acoustid",
                    "title": title,
                    "artist": artist or None,
                    "album": album,
                    "release_date": None,
                    "label": None,
                    "song_link": None,
                    "artwork": None,
                    "spotify_url": None,
                    "apple_url": None,
                }
        return None
    except Exception as e:
        print(f"[recognize] AcoustID exception: {e}")
        return None
    finally:
        if tmp_path:
            try:
                os.remove(tmp_path)
            except Exception:
                pass


# ── Endpoint ─────────────────────────────────────────────────────────────────

@router.post("")
async def recognize(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
):
    if not AUDD_API_TOKEN and not ACOUSTID_API_KEY:
        raise HTTPException(status_code=503, detail="Recognition not configured")

    try:
        contents = await file.read()
    except Exception:
        raise HTTPException(status_code=400, detail="Could not read audio")
    if not contents:
        raise HTTPException(status_code=400, detail="Empty audio clip")
    if len(contents) > _MAX_BYTES:
        raise HTTPException(status_code=413, detail="Clip too large")

    # 1) AudD (best for noisy mic clips).
    if AUDD_API_TOKEN:
        match = _audd_lookup(contents, file.filename, file.content_type)
        if match:
            return match

    # 2) AcoustID (free fallback; best for cleaner audio).
    match = _acoustid_lookup(contents)
    if match:
        return match

    return {"matched": False}
