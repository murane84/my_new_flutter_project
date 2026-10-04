"""Background notifier for Love Capsules (§5.5, slice 2).

A love capsule withholds its content until `unlock_at`. When that moment
arrives, BOTH partners should be pinged — a push to the phone and a live
`capsule_unlocked` socket event — exactly once. The create/open endpoints run
only on request, so this small poller is what fires the unlock at the right
time without an external cron.

It runs as an asyncio task started in the app lifespan. Each tick does the DB
work in a worker thread (so it never blocks the event loop) and marks each
fired capsule with `notified_at` so it is never notified twice.
"""
import asyncio
import logging
from datetime import datetime, timezone

from database import SessionLocal
from models import LoveCapsule, User
from websocket_manager import safe_notify_user

try:
    from push import send_push_to_user
except Exception:  # push is optional
    send_push_to_user = None

logger = logging.getLogger("capsule_notifier")


def _partner_ids(pair_key: str) -> list:
    """Both user ids from a 'lo:hi' pair_key."""
    try:
        lo, hi = (pair_key or "").split(":")
        return [int(lo), int(hi)]
    except Exception:
        return []


def _fire_due_once() -> int:
    """Notify every capsule whose unlock time has passed and that hasn't been
    announced yet. Returns how many were fired. Runs in a worker thread."""
    db = SessionLocal()
    fired = 0
    try:
        now = datetime.now(timezone.utc)
        rows = (
            db.query(LoveCapsule)
            .filter(LoveCapsule.notified_at.is_(None))
            .all()
        )
        for c in rows:
            ua = c.unlock_at
            if ua is None:
                continue
            if ua.tzinfo is None:
                ua = ua.replace(tzinfo=timezone.utc)
            if ua > now:
                continue  # still sealed

            creator = (
                db.query(User).filter(User.id == c.created_by).first()
            )
            who = creator.username if creator else "Your partner"
            sync = (c.mode == "sync_listen")
            for uid in _partner_ids(c.pair_key):
                if uid == c.created_by:
                    line = "Your love capsule just unlocked \U0001F48C"
                else:
                    line = f"{who}'s love capsule just unlocked \U0001F48C"
                if sync:
                    line += " — press play together \U0001F3A7"
                try:
                    safe_notify_user(uid, {
                        "type": "capsule_unlocked",
                        "data": {
                            "capsule_id": c.id,
                            "mode": c.mode,
                            "line": line,
                        },
                    })
                except Exception:
                    pass
                if send_push_to_user is not None:
                    try:
                        send_push_to_user(uid, {
                            "type": "capsule_unlocked",
                            "title": "Love capsule \U0001F48C",
                            "body": line,
                        })
                    except Exception:
                        pass
            c.notified_at = now
            fired += 1
        if fired:
            db.commit()
        return fired
    except Exception as e:
        logger.warning(f"capsule notify tick failed: {e}")
        try:
            db.rollback()
        except Exception:
            pass
        return 0
    finally:
        db.close()


async def capsule_unlock_loop(interval_seconds: int = 30):
    """Poll for due capsules forever. Cancelled on app shutdown."""
    while True:
        try:
            await asyncio.to_thread(_fire_due_once)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning(f"capsule loop error: {e}")
        await asyncio.sleep(interval_seconds)
