"""Small, validated extras a message can carry (JSON in messages.meta).

Today: a song "bed" — a song from the pair's Our Playlist that plays softly
under a voice note, or as a short lullaby when a good-night heart opens:
    {"bed": {"title": str, "url": "/attachments/<id>" | None, "clip": secs}}
Anything else is dropped, and the whole thing stays tiny.
"""
from __future__ import annotations

import json
import re
from typing import Optional

_URL = re.compile(r"^/attachments/[A-Za-z0-9_-]{1,64}$")


def clean_meta(raw) -> Optional[str]:
    if raw in (None, ""):
        return None
    try:
        data = json.loads(raw) if isinstance(raw, str) else dict(raw)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    out: dict = {}
    bed = data.get("bed")
    if isinstance(bed, dict):
        title = str(bed.get("title") or "").strip()[:160]
        if title:
            b: dict = {"title": title}
            url = str(bed.get("url") or "").strip()
            if _URL.match(url):
                b["url"] = url
            try:
                clip = int(bed.get("clip") or 0)
            except (TypeError, ValueError):
                clip = 0
            if 0 < clip <= 60:
                b["clip"] = clip
            out["bed"] = b
    return json.dumps(out, separators=(",", ":")) if out else None
