"""Conversation (DM + group) data access.

Design notes:
- A DM is a Conversation with is_group=False and exactly two members. Existing
  1:1 history is folded into DM conversations by the boot backfill; new DM
  messages are stamped with conversation_id at send time (dual-write) so the
  legacy 1:1 endpoints keep working unchanged.
- WhatsApp-style receipts use PER-MEMBER POINTERS on ConversationMember
  (last_delivered_message_id / last_read_message_id). A member has
  delivered/read every message with id <= their pointer. This gives per-member
  unread counts, "delivered/read by all" ticks, and seen-by lists without a row
  per (message, member).
"""
from datetime import datetime, timezone

from sqlalchemy import func
from sqlalchemy.orm import Session

from models import Conversation, ConversationMember, Message, User


def _now() -> datetime:
    return datetime.now(timezone.utc)


# ── Lookups ──────────────────────────────────────────────────────────────────

def get_conversation(db: Session, conversation_id: int) -> Conversation | None:
    return (
        db.query(Conversation).filter(Conversation.id == conversation_id).first()
    )


def get_member(db: Session, conversation_id: int, user_id: int) -> ConversationMember | None:
    return (
        db.query(ConversationMember)
        .filter(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
        .first()
    )


def is_member(db: Session, conversation_id: int, user_id: int) -> bool:
    return get_member(db, conversation_id, user_id) is not None


def is_admin(db: Session, conversation_id: int, user_id: int) -> bool:
    m = get_member(db, conversation_id, user_id)
    return bool(m and m.role == "admin")


def member_ids(db: Session, conversation_id: int) -> list[int]:
    return [
        r[0]
        for r in db.query(ConversationMember.user_id)
        .filter(ConversationMember.conversation_id == conversation_id)
        .all()
    ]


# ── Create ───────────────────────────────────────────────────────────────────

def get_or_create_dm_conversation(db: Session, u1: int, u2: int) -> Conversation:
    """Find (or create) the DM conversation between two users. Idempotent: the
    same pair always resolves to the same conversation."""
    a, b = sorted((int(u1), int(u2)))
    row = (
        db.query(ConversationMember.conversation_id)
        .join(Conversation, Conversation.id == ConversationMember.conversation_id)
        .filter(
            Conversation.is_group == False,  # noqa: E712
            ConversationMember.user_id.in_([a, b]),
        )
        .group_by(ConversationMember.conversation_id)
        .having(func.count(func.distinct(ConversationMember.user_id)) == 2)
        .first()
    )
    if row:
        return get_conversation(db, row[0])
    conv = Conversation(is_group=False)
    db.add(conv)
    db.flush()
    db.add(ConversationMember(conversation_id=conv.id, user_id=a, role="member"))
    db.add(ConversationMember(conversation_id=conv.id, user_id=b, role="member"))
    db.flush()
    return conv


def create_group(
    db: Session,
    creator_id: int,
    title: str,
    members: list[int],
    avatar_url: str | None = None,
) -> Conversation:
    conv = Conversation(
        is_group=True,
        title=(title or "Group").strip() or "Group",
        avatar_url=avatar_url,
        created_by=int(creator_id),
    )
    db.add(conv)
    db.flush()
    ids = {int(x) for x in members} | {int(creator_id)}
    for uid in ids:
        db.add(
            ConversationMember(
                conversation_id=conv.id,
                user_id=uid,
                role="admin" if uid == int(creator_id) else "member",
            )
        )
    db.commit()
    db.refresh(conv)
    return conv


# ── Messages ─────────────────────────────────────────────────────────────────

def add_message(db: Session, conversation_id: int, sender_id: int, payload) -> Message:
    """Append a message to a conversation (group send). `payload` carries
    content + optional media fields (a GroupMessageCreate)."""
    msg = Message(
        sender_id=int(sender_id),
        receiver_id=None,  # group message: no single receiver
        conversation_id=int(conversation_id),
        content=(getattr(payload, "content", "") or ""),
        message_type=(getattr(payload, "message_type", None) or "text"),
        media_url=getattr(payload, "media_url", None),
        media_name=getattr(payload, "media_name", None),
        media_mime=getattr(payload, "media_mime", None),
        media_size=getattr(payload, "media_size", None),
        media_duration=getattr(payload, "media_duration", None),
        timestamp=_now(),
        is_read=False,
        delivered=False,
        visible_to_sender=True,
        visible_to_receiver=True,
    )
    db.add(msg)
    # The sender has trivially "read" their own message.
    sender_member = get_member(db, conversation_id, sender_id)
    db.commit()
    db.refresh(msg)
    if sender_member:
        sender_member.last_read_message_id = msg.id
        sender_member.last_read_at = msg.timestamp
        sender_member.last_delivered_message_id = msg.id
        sender_member.last_delivered_at = msg.timestamp
    conv = get_conversation(db, conversation_id)
    if conv:
        conv.updated_at = _now()
    db.commit()
    return msg


def get_messages(db: Session, conversation_id: int, skip: int = 0, limit: int = 20):
    """Newest-first page of a conversation's (non-deleted-for-sender) messages."""
    return (
        db.query(Message)
        .filter(Message.conversation_id == conversation_id)
        .order_by(Message.id.desc())
        .offset(skip)
        .limit(limit)
        .all()
    )


def last_message(db: Session, conversation_id: int) -> Message | None:
    return (
        db.query(Message)
        .filter(
            Message.conversation_id == conversation_id,
            Message.is_deleted == False,  # noqa: E712
        )
        .order_by(Message.id.desc())
        .first()
    )


def latest_message_id(db: Session, conversation_id: int) -> int:
    row = (
        db.query(func.max(Message.id))
        .filter(Message.conversation_id == conversation_id)
        .scalar()
    )
    return int(row or 0)


# ── Receipts (per-member pointers) ───────────────────────────────────────────

def mark_delivered_up_to(db: Session, conversation_id: int, user_id: int, up_to: int) -> bool:
    m = get_member(db, conversation_id, user_id)
    if not m:
        return False
    if (m.last_delivered_message_id or 0) < up_to:
        m.last_delivered_message_id = up_to
        m.last_delivered_at = _now()
        db.commit()
        return True
    return False


def mark_read_up_to(db: Session, conversation_id: int, user_id: int, up_to: int) -> bool:
    m = get_member(db, conversation_id, user_id)
    if not m:
        return False
    changed = (m.last_read_message_id or 0) < up_to
    if changed:
        now = _now()
        m.last_read_message_id = up_to
        m.last_read_at = now
        if (m.last_delivered_message_id or 0) < up_to:
            m.last_delivered_message_id = up_to
            m.last_delivered_at = now
        db.commit()
    return changed


def unread_count(db: Session, conversation_id: int, user_id: int) -> int:
    m = get_member(db, conversation_id, user_id)
    last = (m.last_read_message_id or 0) if m else 0
    return (
        db.query(func.count(Message.id))
        .filter(
            Message.conversation_id == conversation_id,
            Message.id > last,
            Message.sender_id != user_id,
            Message.is_deleted == False,  # noqa: E712
        )
        .scalar()
        or 0
    )


def message_receipts(db: Session, conversation_id: int, message_id: int, sender_id: int) -> dict:
    """WhatsApp ticks for a SENT message: delivered/read counts across the OTHER
    members, plus 'all' flags used to paint the single/double/blue ticks."""
    others = (
        db.query(ConversationMember)
        .filter(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id != sender_id,
        )
        .all()
    )
    total = len(others)
    delivered = sum(1 for m in others if (m.last_delivered_message_id or 0) >= message_id)
    read = sum(1 for m in others if (m.last_read_message_id or 0) >= message_id)
    return {
        "total": total,
        "delivered": delivered,
        "read": read,
        "delivered_all": total > 0 and delivered == total,
        "read_all": total > 0 and read == total,
    }


def seen_by(db: Session, conversation_id: int, message_id: int, exclude_user: int | None = None) -> list[dict]:
    q = (
        db.query(ConversationMember)
        .filter(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.last_read_message_id >= message_id,
        )
    )
    if exclude_user is not None:
        q = q.filter(ConversationMember.user_id != exclude_user)
    out = []
    for m in q.all():
        u = db.query(User).filter(User.id == m.user_id).first()
        out.append(
            {
                "user_id": m.user_id,
                "username": (u.username if u else str(m.user_id)),
                "avatar_url": (u.avatar_url if u else None),
                "read_at": m.last_read_at,
            }
        )
    return out


# ── Membership admin ─────────────────────────────────────────────────────────

def add_members(db: Session, conversation_id: int, user_ids: list[int]) -> list[int]:
    added = []
    for uid in user_ids:
        uid = int(uid)
        if not is_member(db, conversation_id, uid):
            db.add(
                ConversationMember(
                    conversation_id=conversation_id, user_id=uid, role="member"
                )
            )
            added.append(uid)
    if added:
        db.commit()
    return added


def remove_member(db: Session, conversation_id: int, user_id: int) -> bool:
    m = get_member(db, conversation_id, int(user_id))
    if not m:
        return False
    db.delete(m)
    db.commit()
    return True


def set_role(db: Session, conversation_id: int, user_id: int, role: str) -> None:
    m = get_member(db, conversation_id, int(user_id))
    if m:
        m.role = role
        db.commit()


def rename_group(db: Session, conversation_id: int, title: str) -> None:
    conv = get_conversation(db, conversation_id)
    if conv:
        new = (title or "").strip()
        if new:
            conv.title = new
        conv.updated_at = _now()
        db.commit()


# ── Listing ──────────────────────────────────────────────────────────────────

def conversations_for_user(db: Session, user_id: int) -> list[Conversation]:
    ids = [
        r[0]
        for r in db.query(ConversationMember.conversation_id)
        .filter(ConversationMember.user_id == user_id)
        .all()
    ]
    if not ids:
        return []
    return (
        db.query(Conversation)
        .filter(Conversation.id.in_(ids))
        .order_by(Conversation.updated_at.desc())
        .all()
    )
