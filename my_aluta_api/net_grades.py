"""Last Listen Together network-check grade per user (good / fair / weak /
offline), held in memory only — no history is stored. Friends see it as a
small signal dot next to an online friend, so they can tell before inviting
whether the other side's connection can carry a session. A grade older than
15 minutes is treated as unknown."""
import threading
import time
from typing import Dict, Optional, Tuple

_GRADES = {"good", "fair", "weak", "offline"}
_TTL_S = 15 * 60
_lock = threading.Lock()
_by_user: Dict[int, Tuple[str, float]] = {}


def set_grade(user_id: int, grade: str) -> bool:
    g = (grade or "").strip().lower()
    if g not in _GRADES:
        return False
    with _lock:
        _by_user[user_id] = (g, time.time())
    return True


def grade_of(user_id: int) -> Optional[str]:
    with _lock:
        v = _by_user.get(user_id)
    if not v:
        return None
    g, at = v
    if time.time() - at > _TTL_S:
        return None
    return g
