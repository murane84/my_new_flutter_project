"""
Free music — search songs that are LEGALLY free to download.

Aluta owns no music and never points people at pirate mp3 sites. This
searches only libraries whose songs the artists released for free:

  • Jamendo  (Creative Commons; their API allows downloads) — needs a free
    client id: register at https://devportal.jamendo.com and set
    JAMENDO_CLIENT_ID on Railway. Without it, Jamendo is simply skipped.
  • Internet Archive  (audio with a Creative Commons or public-domain licence)

Every result carries its licence and a link to its page so the app can credit
the artist. Results are cached briefly; nothing is stored.
"""
import os
import time
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote

from fastapi import APIRouter, Depends, Query

from auth import get_current_user
from models import User

try:
    import requests
except Exception:  # pragma: no cover
    requests = None

router = APIRouter(prefix="/music/free", tags=["Free music"])

_UA = {"User-Agent": "Aluta/1.0 (aluta.ozilane.com; free-music search)"}
_CACHE: Dict[str, Tuple[float, list]] = {}
_CACHE_TTL = 600
_lock = threading.Lock()
_pool = ThreadPoolExecutor(max_workers=8)


def _cached(key: str) -> Optional[list]:
    with _lock:
        v = _CACHE.get(key)
    if v and time.time() - v[0] < _CACHE_TTL:
        return v[1]
    return None


def _store(key: str, val: list) -> None:
    with _lock:
        if len(_CACHE) > 300:
            _CACHE.clear()
        _CACHE[key] = (time.time(), val)


def _license_name(url: str) -> str:
    u = (url or "").lower()
    if "publicdomain" in u or "/zero/" in u:
        return "Public domain"
    for code in ("by-nc-nd", "by-nc-sa", "by-nc", "by-nd", "by-sa", "by"):
        if f"/licenses/{code}/" in u:
            return "CC " + code.upper()
    return "Creative Commons" if "creativecommons" in u else "Free licence"


# ── Jamendo ──────────────────────────────────────────────────────────────────

def _jamendo(q: str, limit: int) -> List[dict]:
    cid = os.getenv("JAMENDO_CLIENT_ID", "").strip()
    if not cid or requests is None:
        return []
    params = {
        "client_id": cid, "format": "json", "limit": limit,
        "audioformat": "mp32", "audiodlformat": "mp32",
        "include": "licenses", "imagesize": 200,
    }
    if q:
        params["search"] = q
    else:
        params["order"] = "popularity_week"
    try:
        r = requests.get("https://api.jamendo.com/v3.0/tracks/",
                         params=params, headers=_UA, timeout=8)
        data = r.json().get("results", []) if r.ok else []
    except Exception:
        return []
    out = []
    for t in data:
        if not t.get("audiodownload_allowed", True):
            continue
        dl = t.get("audiodownload") or ""
        if not dl:
            continue
        lic = t.get("license_ccurl") or ""
        out.append({
            "id": f"jamendo:{t.get('id')}",
            "source": "Jamendo",
            "title": t.get("name") or "",
            "artist": t.get("artist_name") or "",
            "duration": int(t.get("duration") or 0),
            "cover": t.get("image") or t.get("album_image") or None,
            "stream_url": t.get("audio") or dl,
            "download_url": dl,
            "license": _license_name(lic),
            "license_url": lic or None,
            "page_url": t.get("shareurl") or None,
        })
    return out


# ── Internet Archive ─────────────────────────────────────────────────────────

def _ia_files(identifier: str) -> Optional[dict]:
    try:
        r = requests.get(f"https://archive.org/metadata/{quote(identifier)}",
                         headers=_UA, timeout=6)
        if not r.ok:
            return None
        j = r.json()
    except Exception:
        return None
    best = None
    for f in j.get("files", []) or []:
        name = f.get("name") or ""
        fmt = (f.get("format") or "").lower()
        if not name.lower().endswith(".mp3") or "sample" in name.lower():
            continue
        # Prefer the regular VBR / 128 kbps copies over huge 320s.
        score = 0 if "vbr" in fmt or "128" in fmt else 1
        size = int(f.get("size") or 0)
        if size and size > 40 * 1024 * 1024:
            continue
        if best is None or score < best[0]:
            best = (score, f)
    if not best:
        return None
    f = best[1]
    try:
        dur = int(float(f.get("length") or 0))
    except Exception:
        dur = 0
    url = f"https://archive.org/download/{quote(identifier)}/{quote(f['name'])}"
    return {"url": url, "duration": dur,
            "title": f.get("title"), "artist": f.get("artist") or f.get("creator")}


def _ia(q: str, limit: int) -> List[dict]:
    if requests is None or not q:
        return []
    query = (f"({q}) AND mediatype:audio AND "
             "(licenseurl:*creativecommons* OR licenseurl:*publicdomain*)")
    try:
        r = requests.get("https://archive.org/advancedsearch.php", params={
            "q": query, "fl[]": ["identifier", "title", "creator", "licenseurl"],
            "rows": limit, "output": "json", "sort[]": "downloads desc",
        }, headers=_UA, timeout=8)
        docs = r.json().get("response", {}).get("docs", []) if r.ok else []
    except Exception:
        return []
    futures = [(d, _pool.submit(_ia_files, d.get("identifier", ""))) for d in docs]
    out = []
    for d, fut in futures:
        try:
            f = fut.result(timeout=7)
        except Exception:
            f = None
        if not f:
            continue
        ident = d.get("identifier", "")
        creator = d.get("creator")
        if isinstance(creator, list):
            creator = ", ".join(creator[:2])
        lic = d.get("licenseurl") or ""
        title = d.get("title")
        if isinstance(title, list):
            title = title[0] if title else ""
        out.append({
            "id": f"ia:{ident}",
            "source": "Internet Archive",
            "title": f.get("title") or title or ident,
            "artist": f.get("artist") or creator or "",
            "duration": f.get("duration") or 0,
            "cover": f"https://archive.org/services/img/{quote(ident)}",
            "stream_url": f["url"],
            "download_url": f["url"],
            "license": _license_name(lic),
            "license_url": lic or None,
            "page_url": f"https://archive.org/details/{quote(ident)}",
        })
    return out


@router.get("/search")
def search_free_music(q: str = Query("", max_length=80),
                      current_user: User = Depends(get_current_user)):
    query = " ".join((q or "").split())
    key = query.lower()
    hit = _cached(key)
    if hit is not None:
        return {"results": hit, "jamendo": bool(os.getenv("JAMENDO_CLIENT_ID"))}
    jf = _pool.submit(_jamendo, query, 20)
    iaf = _pool.submit(_ia, query, 10)
    try:
        jam = jf.result(timeout=10)
    except Exception:
        jam = []
    try:
        ia = iaf.result(timeout=12)
    except Exception:
        ia = []
    results = jam + ia
    _store(key, results)
    return {"results": results, "jamendo": bool(os.getenv("JAMENDO_CLIENT_ID"))}
