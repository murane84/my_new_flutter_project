"""Daily rhythms for timed hearts.

* Wake time — the first time someone comes online each day (after 01:00
  UTC, i.e. after the night in East Africa) is kept for two weeks. Their
  USUAL wake time (the median, once there are a few days) lets a sealed
  heart open "when she wakes up". Shown only to people allowed to see
  their last seen.
* "Next time we're together" — a sealed heart whose meta says
  {"open_when": "together"} opens the next time the sender and the
  receiver are both online at once (one of them comes online while the
  other already is).
"""
import json
import logging
from datetime import date, datetime, timedelta, timezone
from typing import Iterable, Optional

logger = logging.getLogger(__name__)

KEEP_DAYS = 14
MIN_DAYS = 3
NIGHT_END_UTC_HOUR = 1


def record_first_online(uid: int) -> None:
    """The first socket of the day → remember when they woke (best-effort)."""
    from database import SessionLocal
    from models import UserWake
    now = datetime.now(timezone.utc)
    if now.hour < NIGHT_END_UTC_HOUR:
        return
    db = SessionLocal()
    try:
        day = now.date()
        hit = (db.query(UserWake)
               .filter(UserWake.user_id == uid, UserWake.day == day)
               .first())
        if hit is not None:
            return
        db.add(UserWake(user_id=uid, day=day, first_at=now))
        cutoff = day - timedelta(days=KEEP_DAYS)
        (db.query(UserWake)
         .filter(UserWake.user_id == uid, UserWake.day < cutoff)
         .delete(synchronize_session=False))
        db.commit()
    except Exception as e:
        logger.debug(f"wake record skipped: {e}")
        try:
            db.rollback()
        except Exception:
            pass
    finally:
        db.close()


def usual_wake_minute(db, uid: int) -> Optional[int]:
    """Minutes after midnight UTC of their usual wake time, or None."""
    from models import UserWake
    rows = (db.query(UserWake.first_at)
            .filter(UserWake.user_id == uid,
                    UserWake.day >= date.today() - timedelta(days=KEEP_DAYS))
            .all())
    mins = sorted(
        (r[0].hour * 60 + r[0].minute) for r in rows if r[0] is not None)
    if len(mins) < MIN_DAYS:
        return None
    return mins[len(mins) // 2]


def _wants_together(msg) -> bool:
    raw = getattr(msg, "meta", None)
    if not raw:
        return False
    try:
        return (json.loads(raw) or {}).get("open_when") == "together"
    except Exception:
        return False


def open_together_hearts(uid: int, online: Iterable[int]) -> int:
    """[uid] just came online: open every sealed "next time we're together"
    heart between them and someone already online."""
    from database import SessionLocal
    from models import Message
    import hearts
    here = {int(x) for x in online if int(x) != int(uid)}
    if not here:
        return 0
    db = SessionLocal()
    n = 0
    try:
        rows = (db.query(Message)
                .filter(Message.sealed_content.isnot(None),
                        Message.receiver_id.isnot(None),
                        Message.meta.isnot(None),
                        # Held back by a block → never "together".
                        Message.visible_to_receiver.isnot(False))
                .filter(((Message.sender_id == uid)
                         & Message.receiver_id.in_(here))
                        | ((Message.receiver_id == uid)
                           & Message.sender_id.in_(here)))
                .all())
        due = [m for m in rows if not m.is_deleted and _wants_together(m)]
        now = datetime.now(timezone.utc)
        for m in due:
            m.unlock_at = now
            if hearts.unseal(m):
                n += 1
        if due:
            db.commit()
            for m in due:
                try:
                    db.refresh(m)
                    hearts._announce_unsealed(db, m)
                except Exception as e:
                    logger.warning(f"together heart announce failed: {e}")
        return n
    except Exception as e:
        logger.warning(f"together hearts failed: {e}")
        try:
            db.rollback()
        except Exception:
            pass
        return 0
    finally:
        db.close()
