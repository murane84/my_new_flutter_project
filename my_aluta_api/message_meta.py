"""Small, validated extras a message can carry (JSON in messages.meta).

  bed   — a song from the pair's Our Playlist that plays softly under a
          voice note / a message, or as a lullaby when a good-night heart
          opens: {"title": str, "url": "/attachments/<id>", "clip": secs}
  date  — a planned meeting day "YYYY-MM-DD" (the chat counts down to it)
  quiet — sent while they sleep: the push arrives without sound
Anything else is dropped, and the whole thing stays tiny.
"""
from __future__ import annotations

import json
import re
from typing import Optional

_URL = re.compile(r"^/attachments/[A-Za-z0-9_-]{1,64}$")
_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")


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
    day = str(data.get("date") or "").strip()
    if _DAY.match(day):
        out["date"] = day
    if data.get("quiet") in (True, 1, "1"):
        out["quiet"] = 1
    return json.dumps(out, separators=(",", ":")) if out else None
