"""Bonding maths for "Our Space": shared-listen days → streaks, "days in a song",
"your song", and the next milestone. All derived on demand from the
shared_listen_days table (no background job) — same efficiency mandate as the
rest of Spaces.
"""
from __future__ import annotations

from datetime import date, timedelta
from typing import Optional

from sqlalchemy.orm import Session

from models import SharedListenDay


def pair_key(a: int, b: int) -> str:
    lo, hi = sorted((int(a), int(b)))
    return f"{lo}:{hi}"


def record_shared_listen(db: Session, a: int, b: int,
                         song_title: Optional[str] = None) -> None:
    """Mark that users a and b listened together TODAY (idempotent per day).
    Best-effort: a race that hits the unique constraint is swallowed."""
    if int(a) == int(b):
        return
    pk = pair_key(a, b)
    today = date.today()
    existing = db.query(SharedListenDay).filter(
        SharedListenDay.pair_key == pk,
        SharedListenDay.day == today,
    ).first()
    if existing is not None:
        # Fill in the song if we didn't have one yet.
        if song_title and not existing.song_title:
            existing.song_title = song_title[:255]
            try:
                db.commit()
            except Exception:
                db.rollback()
        return
    db.add(SharedListenDay(
        pair_key=pk, day=today,
        song_title=(song_title[:255] if song_title else None)))
    try:
        db.commit()
    except Exception:
        db.rollback()  # another connection recorded the same day — fine


def _streak(days: set) -> int:
    """Consecutive-day streak anchored at today (or yesterday, so a streak isn't
    'broken' during a day before you've listened yet)."""
    if not days:
        return 0
    today = date.today()
    anchor = today if today in days else (today - timedelta(days=1))
    if anchor not in days:
        return 0
    n = 0
    d = anchor
    while d in days:
        n += 1
        d -= timedelta(days=1)
    return n


_STREAK_MARKS = [3, 7, 14, 30, 60, 100, 365]
_ANNIV_MARKS = [30, 100, 180, 365, 730]
_ANNIV_LABEL = {30: "1 month", 100: "100 days", 180: "6 months",
                365: "1 year", 730: "2 years"}


def _next_milestone(streak: int, days_together: Optional[int]) -> Optional[dict]:
    if streak > 0:
        for t in _STREAK_MARKS:
            if streak < t:
                return {"kind": "streak", "target": t,
                        "remaining": t - streak, "label": f"{t}-day streak"}
    if days_together is not None:
        for t in _ANNIV_MARKS:
            if days_together < t:
                return {"kind": "anniversary", "target": t,
                        "remaining": t - days_together,
                        "label": f"{_ANNIV_LABEL.get(t, str(t) + ' days')} close"}
    return None


def _reached_milestone(streak: int, days_together: Optional[int]) -> Optional[dict]:
    """A milestone hit RIGHT NOW (exact match) → the client celebrates it."""
    if streak in _STREAK_MARKS:
        return {"kind": "streak", "value": streak,
                "label": f"{streak} days in a row"}
    if days_together is not None and days_together in _ANNIV_MARKS:
        return {"kind": "anniversary", "value": days_together,
                "label": _ANNIV_LABEL.get(days_together, f"{days_together} days")}
    return None


def bond_stats(db: Session, a: int, b: int,
               close_since: Optional[date] = None) -> dict:
    pk = pair_key(a, b)
    rows = db.query(SharedListenDay).filter(
        SharedListenDay.pair_key == pk).all()
    days = {r.day for r in rows}
    days_in_song = len(days)
    streak = _streak(days)

    # "Your song" = the title logged on the most distinct days.
    counts: dict = {}
    for r in rows:
        t = (r.song_title or "").strip()
        if t:
            counts[t] = counts.get(t, 0) + 1
    your_song = None
    if counts:
        title, cnt = max(counts.items(), key=lambda kv: kv[1])
        your_song = {"title": title, "artist": "", "count": cnt}

    days_together = None
    if close_since is not None:
        days_together = max(0, (date.today() - close_since).days)

    return {
        "days_in_song": days_in_song,
        "listen_streak": streak,
        "your_song": your_song,
        "next_milestone": _next_milestone(streak, days_together),
        "milestone_reached": _reached_milestone(streak, days_together),
    }
