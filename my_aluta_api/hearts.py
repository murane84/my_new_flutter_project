"""Secret hearts (message_type 'heart') — moods, timed unsealing, opened receipts.

* heart_mood   — the sender's chosen feeling (love / miss / sorry / thanks /
                 proud). Purely presentational; the client colours + decorates
                 the heart by it. Unknown values are dropped.
* unlock_at    — a TIMED heart ("open tonight at 8"). While sealed the note is
                 held in `sealed_content` and `content` stays EMPTY for every
                 reader (sender included), so it genuinely can't be peeked —
                 not in the app, not in the API, not in the local cache. The
                 notifier loop (or an on-demand /heart/unseal call) moves it
                 back into `content` once the time arrives and tells both sides.
* opened_at    — the first time the recipient opened the heart. The sender
                 gets a live `heart_opened` event + a tender push.

* media        — a heart may carry ONE photo or short clip (the usual media_*
                 columns). A timed heart holds them in `sealed_media` while
                 sealed, so the file link can't be read before its moment.
* heart_for    — a GROUP heart meant for one member. Everyone sees that it
                 exists ("for Neema"), but only that member and the sender get
                 its note + media; every other copy is redacted server-side
                 (`redact`), and the attachment route refuses them the file.

Note text is NOT encrypted at rest; a sealed heart is protected by the server
withholding it, an open heart by the client's cover / unlock gate.
"""
import json
import logging
from datetime import datetime, timedelta, timezone

logger = logging.getLogger("hearts")

MOODS = {"love", "miss", "sorry", "thanks", "proud"}
# Shortest/longest schedule we accept for a timed heart.
MIN_DELAY = timedelta(seconds=30)
MAX_DELAY = timedelta(days=400)


def _aware(dt):
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def heart_kwargs(payload, content: str, allow_timed: bool = True) -> dict:
    """Column values for a new message from the send payload. Non-heart
    messages just get their content. Timed hearts are DM-only
    (allow_timed=False for groups)."""
    if (getattr(payload, "message_type", None) or "text").lower() != "heart":
        return {"content": content}
    out = {"content": content}
    mood = (getattr(payload, "heart_mood", None) or "").strip().lower()
    if mood in MOODS:
        out["heart_mood"] = mood
    ua = _aware(getattr(payload, "unlock_at", None))
    now = datetime.now(timezone.utc)
    if allow_timed and ua is not None and now + MIN_DELAY <= ua <= now + MAX_DELAY:
        out["unlock_at"] = ua
        out["sealed_content"] = content
        out["content"] = ""
    return out


_MEDIA_COLS = ("media_url", "media_name", "media_mime", "media_size",
               "media_duration")


def seal_media(msg) -> None:
    """A timed heart with a photo/clip: hold the media fields back with the
    note until it unseals."""
    if not is_sealed(msg) or not getattr(msg, "media_url", None):
        return
    msg.sealed_media = json.dumps({c: getattr(msg, c, None) for c in _MEDIA_COLS})
    for c in _MEDIA_COLS:
        setattr(msg, c, None)


def clean_target(payload, sender_id: int, member_ids) -> "int | None":
    """The member a group heart is for — only a real OTHER member counts."""
    if (getattr(payload, "message_type", None) or "").lower() != "heart":
        return None
    raw = getattr(payload, "heart_for", None)
    try:
        uid = int(raw) if raw is not None else None
    except (TypeError, ValueError):
        return None
    if uid is None or uid == int(sender_id):
        return None
    return uid if uid in {int(m) for m in member_ids} else None


def can_open(msg, user_id: int) -> bool:
    """Whether this user may see a heart's contents."""
    target = getattr(msg, "heart_for", None)
    return target is None or int(user_id) in (int(target), int(msg.sender_id))


def redact(data: dict, viewer_id: int) -> dict:
    """A serialized message as `viewer_id` may receive it: a group heart meant
    for someone else loses its note and file link (the kind of media stays,
    so the bubble can hint 'a photo is inside')."""
    if not isinstance(data, dict) or (data.get("message_type") or "") != "heart":
        return data
    target = data.get("heart_for")
    if target is None:
        return data
    try:
        if int(viewer_id) in (int(target), int(data.get("sender_id") or 0)):
            return data
    except (TypeError, ValueError):
        pass
    out = dict(data)
    out["content"] = ""
    for c in ("media_url", "media_name", "media_size", "media_duration"):
        out[c] = None
    out["heart_locked"] = True
    return out


def is_sealed(msg) -> bool:
    return getattr(msg, "sealed_content", None) is not None


def unseal(msg) -> bool:
    """Move a due heart's note into `content`. Returns True if it changed."""
    if not is_sealed(msg):
        return False
    ua = _aware(msg.unlock_at)
    if ua is not None and ua > datetime.now(timezone.utc):
        return False
    msg.content = msg.sealed_content or ""
    msg.sealed_content = None
    if getattr(msg, "sealed_media", None):
        try:
            media = json.loads(msg.sealed_media) or {}
            for c in _MEDIA_COLS:
                setattr(msg, c, media.get(c))
        except Exception:
            pass
        msg.sealed_media = None
    return True


def _announce_unsealed(db, msg):
    """Tell everyone in the thread a timed heart just opened up (socket with the
    full message so clients swap content in place) + push the recipients."""
    from routers.messages import serialize_message, _access_ids
    import schemas
    from websocket_manager import safe_notify_user
    try:
        from push import send_push_to_user
    except Exception:
        send_push_to_user = None
    data = serialize_message(schemas.MessageWithSender.model_validate(msg))
    sender = msg.sender
    who = (sender.username if sender else None) or "Someone"
    for uid in _access_ids(db, msg):
        try:
            safe_notify_user(int(uid), {"type": "heart_unsealed",
                                        "data": redact(data, uid)})
        except Exception:
            pass
        if send_push_to_user is None or int(uid) == int(msg.sender_id):
            continue
        try:
            send_push_to_user(int(uid), {
                "type": "heart_ready",
                "sender_id": str(msg.sender_id),
                "sender_name": who,
                # Groups only (DMs open by sender_id on the client).
                "conversation_id": (str(msg.conversation_id or "")
                                    if msg.receiver_id is None else ""),
                "message_id": str(msg.id),
                "body": "",
            })
        except Exception:
            pass


def unseal_due_once() -> int:
    """Notifier tick: unseal every timed heart whose moment has come."""
    from database import SessionLocal
    from models import Message
    db = SessionLocal()
    n = 0
    try:
        now = datetime.now(timezone.utc)
        rows = (
            db.query(Message)
            .filter(Message.sealed_content.isnot(None))
            .filter(Message.unlock_at <= now)
            .all()
        )
        for m in rows:
            if m.is_deleted:
                m.sealed_content = None
                continue
            if unseal(m):
                n += 1
        if rows:
            db.commit()
        for m in rows:
            if not m.is_deleted:
                try:
                    db.refresh(m)
                    _announce_unsealed(db, m)
                except Exception as e:
                    logger.warning(f"heart announce failed: {e}")
        return n
    except Exception as e:
        logger.warning(f"heart unseal tick failed: {e}")
        try:
            db.rollback()
        except Exception:
            pass
        return 0
    finally:
        db.close()
