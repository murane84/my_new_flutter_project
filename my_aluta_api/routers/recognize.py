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
import shutil
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


def _audd_lookup(
    contents: bytes, filename: str | None, content_type: str | None
) -> tuple[str, dict | str | None]:
    """Query AudD and classify the outcome so callers can tell a genuine
    no-match apart from a provider problem:
      ("match",   {..})   — a song was recognised
      ("nomatch", None)   — AudD ran fine but found nothing in its catalogue
      ("error",   reason) — bad/expired token, quota exceeded, timeout, or the
                            service being down (reason is a short diagnostic)
    """
    try:
        resp = requests.post(
            AUDD_API_URL,
            data={"api_token": AUDD_API_TOKEN, "return": "apple_music,spotify"},
            files={"file": (filename or "clip.m4a", contents, content_type or "audio/mp4")},
            timeout=25,
        )
    except Exception as e:  # network / timeout → service unreachable
        print(f"[recognize] AudD request failed: {e.__class__.__name__}: {e}")
        return ("error", f"unreachable ({e.__class__.__name__})")
    try:
        payload = resp.json()
    except Exception:
        print(f"[recognize] AudD non-JSON response: HTTP {resp.status_code}")
        return ("error", f"http {resp.status_code}")
    status = payload.get("status")
    if status == "error":
        err = payload.get("error") or {}
        code = err.get("error_code")
        msg = err.get("error_message") or str(err)
        # 900 = missing/invalid token, 901 = out of requests/limit reached, etc.
        print(f"[recognize] AudD error {code}: {msg}")
        return ("error", f"audd {code}: {msg}")
    if status != "success":
        print(f"[recognize] AudD unexpected status: {payload}")
        return ("error", f"unexpected status {status}")
    result = payload.get("result")
    if not result:
        return ("nomatch", None)
    apple = result.get("apple_music") or {}
    spotify = result.get("spotify") or {}
    return ("match", {
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
    })


# ── AcoustID (free fallback) ─────────────────────────────────────────────────

def _acoustid_lookup(contents: bytes) -> tuple[str, dict | str | None]:
    """Fingerprint the clip with fpcalc and look it up on AcoustID. Returns a
    discriminated result like _audd_lookup:
      ("match", {..}) | ("nomatch", None) | ("error", reason) | ("skip", None)
    ("skip" = not configured, so AcoustID was not really attempted.)"""
    if not ACOUSTID_API_KEY:
        return ("skip", None)
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
            return ("error", "fpcalc_missing")
        if proc.returncode != 0:
            print(f"[recognize] fpcalc failed: {proc.stderr.strip()[:200]}")
            return ("error", "fpcalc_failed")
        fp = json.loads(proc.stdout or "{}")
        fingerprint = fp.get("fingerprint")
        duration = int(fp.get("duration") or 0)
        if not fingerprint or duration <= 0:
            return ("error", "no_fingerprint")
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
            return ("error", "acoustid_api")
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
                return ("match", {
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
                })
        return ("nomatch", None)
    except Exception as e:
        print(f"[recognize] AcoustID exception: {e}")
        return ("error", "exception")
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

    audd_error: str | None = None

    # 1) AudD (best for noisy mic clips).
    if AUDD_API_TOKEN:
        kind, data = _audd_lookup(contents, file.filename, file.content_type)
        if kind == "match":
            return data
        if kind == "error":
            audd_error = data if isinstance(data, str) else "error"

    # 2) AcoustID (free fallback; best for cleaner audio).
    ac_kind, ac_data = _acoustid_lookup(contents)
    if ac_kind == "match":
        return ac_data

    # Decide the final "not found" answer:
    #  • if AcoustID actually looked and found nothing -> a GENUINE no-match
    #    (even while AudD is out of quota), so don't cry "service down".
    #  • only report a service error when no provider could perform a lookup
    #    (AudD errored AND AcoustID errored or isn't usable).
    if ac_kind == "nomatch":
        return {"matched": False}
    provider_error = audd_error or (
        ac_data if (ac_kind == "error" and isinstance(ac_data, str)) else None
    )
    if provider_error is not None:
        return {"matched": False, "error": "service_error", "detail": provider_error}
    return {"matched": False}



@router.get("/health")
def recognize_health():
    """Quick self-check for the recognition pipeline. Exposes NO secret values —
    only whether each provider is configured and whether the AcoustID binaries
    are actually present & runnable on the host. Hit it in a browser:
    GET /recognize/health .
    """
    def _binary(name: str) -> dict:
        path = shutil.which(name)
        info: dict = {"found": path is not None}
        if path:
            info["path"] = path
            try:
                ver = subprocess.run(
                    [name, "-version"], capture_output=True, text=True, timeout=8
                )
                out = (ver.stdout or ver.stderr or "").strip().splitlines()
                info["version"] = out[0][:120] if out else ""
            except Exception as e:  # noqa: BLE001
                info["version_error"] = e.__class__.__name__
        return info

    fpcalc = _binary("fpcalc")
    ffmpeg = _binary("ffmpeg")
    acoustid_ready = bool(ACOUSTID_API_KEY) and fpcalc["found"] and ffmpeg["found"]
    return {
        "audd_configured": bool(AUDD_API_TOKEN),
        "acoustid_key_set": bool(ACOUSTID_API_KEY),
        "fpcalc": fpcalc,
        "ffmpeg": ffmpeg,
        # True only when AcoustID can actually run end-to-end (key + both bins).
        "acoustid_ready": acoustid_ready,
        # What the pipeline will do for a request right now.
        "note": (
            "AudD primary; AcoustID fallback ready"
            if AUDD_API_TOKEN and acoustid_ready
            else "AcoustID only"
            if acoustid_ready
            else "AudD only"
            if AUDD_API_TOKEN
            else "NOT CONFIGURED"
        ),
    }
