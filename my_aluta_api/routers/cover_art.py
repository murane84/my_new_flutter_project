"""Cover art for songs that have none — GET /music/cover?title=&artist=.

The app asks once per untagged song that has a known artist and keeps the
answer on the device. We look it up in the free iTunes Search API (no key)
and only answer when BOTH the title and the artist match closely, so a song
never gets someone else's cover. Nothing about the user is sent anywhere:
just the song's title and artist. Answers are cached here too.
"""
import difflib
import re
import threading
import time
from typing import Dict, Optional, Tuple

from fastapi import APIRouter, Depends, Query

from auth import get_current_user
from models import User

try:
    import requests
except Exception:  # pragma: no cover
    requests = None

router = APIRouter(prefix="/music", tags=["Cover art"])

_UA = {"User-Agent": "Aluta/1.0 (aluta.ozilane.com; cover art)"}
_CACHE: Dict[str, Tuple[float, Optional[str]]] = {}
_TTL = 7 * 24 * 3600
_lock = threading.Lock()


def _norm(s: str) -> str:
    s = (s or "").lower()
    s = re.sub(r"[\(\[].*?[\)\]]", " ", s)          # (feat. …), [Remix] …
    s = re.sub(r"\b(feat\.?|ft\.?|featuring)\b.*", " ", s)
    s = re.sub(r"[^a-z0-9À-ɏ ]+", " ", s)
    return " ".join(s.split())


def _close(a: str, b: str, need: float) -> bool:
    a, b = _norm(a), _norm(b)
    if not a or not b:
        return False
    if a in b or b in a:
        return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= need


def _lookup(title: str, artist: str) -> Optional[str]:
    if requests is None:
        return None
    try:
        r = requests.get(
            "https://itunes.apple.com/search",
            params={"term": f"{artist} {title}", "entity": "song", "limit": 8},
            headers=_UA, timeout=8)
        if r.status_code != 200:
            return None
        for it in (r.json() or {}).get("results", []):
            if (_close(it.get("trackName", ""), title, 0.72)
                    and _close(it.get("artistName", ""), artist, 0.72)):
                url = it.get("artworkUrl100") or ""
                if url:
                    return url.replace("100x100bb", "300x300bb")
    except Exception:
        return None
    return None


@router.get("/cover")
def cover(title: str = Query("", max_length=120),
          artist: str = Query("", max_length=120),
          current_user: User = Depends(get_current_user)):
    title, artist = " ".join(title.split()), " ".join(artist.split())
    if not title or not artist:
        return {"url": None}
    key = f"{_norm(artist)}|{_norm(title)}"
    with _lock:
        hit = _CACHE.get(key)
    if hit and time.time() - hit[0] < _TTL:
        return {"url": hit[1]}
    url = _lookup(title, artist)
    with _lock:
        if len(_CACHE) > 5000:
            _CACHE.clear()
        _CACHE[key] = (time.time(), url)
    return {"url": url}
