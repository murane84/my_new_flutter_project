"""'Deliver at their morning' — hold a DM until the friend's local morning.

A held message becomes a normal message (same fan-out as POST /messages:
socket to both + push to the receiver) when the receiver first connects after
`deliver_after` (their next local 05:00), or at the latest LATEST_AFTER past
it, so it is never stuck if they don't open the app.
"""
from datetime import datetime, timedelta, timezone

from database import SessionLocal
from models import HeldMessage, UserClock, User

MORNING_HOUR = 5
LATEST_AFTER = timedelta(hours=4)   # → ~09:00 their time at the latest
DEFAULT_OFFSET = 180                # East Africa (UTC+3) until we hear otherwise


def offset_for(db, user_id: int) -> int:
    row = db.query(UserClock).filter(UserClock.user_id == user_id).first()
    return int(row.tz_offset_min) if row is not None else DEFAULT_OFFSET


def save_offset(db, user_id: int, minutes: int) -> None:
    if not (-14 * 60 <= minutes <= 14 * 60):
        return
    row = db.query(UserClock).filter(UserClock.user_id == user_id).first()
    if row is None:
        db.add(UserClock(user_id=user_id, tz_offset_min=minutes))
    elif int(row.tz_offset_min) != minutes:
        row.tz_offset_min = minutes
        row.updated_at = datetime.now(timezone.utc)
    else:
        return
    db.commit()


def next_morning_utc(offset_min: int, now: datetime | None = None) -> datetime:
    """Their next local 05:00, as UTC. Before 05:00 → today; else tomorrow."""
    now = now or datetime.now(timezone.utc)
    off = timedelta(minutes=offset_min)
    local = now + off
    target = local.replace(hour=MORNING_HOUR, minute=0, second=0, microsecond=0)
    if local >= target:
        target += timedelta(days=1)
    return target - off


def is_their_morning(offset_min: int, now: datetime | None = None) -> bool:
    """05:00–10:59 their time: 'deliver at their morning' just sends now."""
    now = now or datetime.now(timezone.utc)
    hour = (now + timedelta(minutes=offset_min)).hour
    return MORNING_HOUR <= hour < 11


def _aware(dt):
    return dt.replace(tzinfo=timezone.utc) if dt is not None and dt.tzinfo is None else dt


def _deliver(db, row: HeldMessage) -> None:
    import crud
    import schemas
    from routers.messages import serialize_message
    from websocket_manager import safe_notify_user
    from push import send_push_to_user
    held_id, sid, rid, content = row.id, row.sender_id, row.receiver_id, row.content
    # Remove the hold first, so a second trigger can never send it twice.
    db.delete(row)
    db.commit()
    msg = crud.create_message(db, sender_id=sid, message=schemas.MessageCreate(
        receiver_id=rid, content=content))
    data = serialize_message(schemas.MessageWithSender.model_validate(msg))
    safe_notify_user(rid, {"type": "new_message", "data": data})
    safe_notify_user(sid, {"type": "message_sent", "data": data})
    safe_notify_user(sid, {"type": "held_released",
                           "data": {"id": held_id, "receiver_id": rid}})
    sender = db.query(User).filter(User.id == sid).first()
    try:
        send_push_to_user(int(rid), {
            "type": "new_message",
            "sender_id": str(sid),
            "sender_name": (sender.username if sender else None) or "New message",
            "message_id": str(msg.id),
            "body": crud.list_preview(msg),
        })
    except Exception:
        pass


def release_for(receiver_id: int) -> None:
    """Receiver just came online: deliver everything whose morning has come."""
    db = SessionLocal()
    try:
        now = datetime.now(timezone.utc)
        rows = db.query(HeldMessage).filter(
            HeldMessage.receiver_id == receiver_id).order_by(HeldMessage.id).all()
        for r in rows:
            if _aware(r.deliver_after) <= now:
                _deliver(db, r)
    except Exception as e:  # noqa: BLE001
        print(f"[morning] release_for {receiver_id} failed: {e}")
        db.rollback()
    finally:
        db.close()


def release_overdue_once() -> None:
    """Background sweep: anything LATEST_AFTER past its morning goes out."""
    db = SessionLocal()
    try:
        cutoff = datetime.now(timezone.utc) - LATEST_AFTER
        rows = db.query(HeldMessage).filter(
            HeldMessage.deliver_after <= cutoff).order_by(HeldMessage.id).all()
        for r in rows:
            _deliver(db, r)
    except Exception as e:  # noqa: BLE001
        print(f"[morning] sweep failed: {e}")
        db.rollback()
    finally:
        db.close()
