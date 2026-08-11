"""Group + DM conversation endpoints.

DMs continue to use the legacy /messages/{friend_id} routes unchanged; these
routes are additive and power groups (and a unified conversation list). Receipts
are WhatsApp-style via per-member pointers (see crud_conversations).
"""
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session

import crud
import crud_conversations as cc
import schemas
from database import get_db
from models import User, Conversation, ConversationMember, Message
from .users import get_current_user
from websocket_manager import safe_notify_user, safe_broadcast_users
from push import send_push_to_user

router = APIRouter(prefix="/conversations", tags=["Conversations"])


# ── Serialization helpers ─────────────────────────────────────────────────────

def _serialize(msg: Message) -> dict:
    data = schemas.MessageWithSender.model_validate(msg).model_dump()
    for k, v in list(data.items()):
        if isinstance(v, datetime):
            data[k] = v.isoformat()
    # `sender` is a nested UserOut; make sure any datetime inside is stringified.
    if isinstance(data.get("sender"), dict):
        for sk, sv in list(data["sender"].items()):
            if isinstance(sv, datetime):
                data["sender"][sk] = sv.isoformat()
    return data


def _conversation_out(db: Session, conv: Conversation, me: int) -> schemas.ConversationOut:
    members = (
        db.query(ConversationMember)
        .filter(ConversationMember.conversation_id == conv.id)
        .all()
    )
    member_outs: List[schemas.ConversationMemberOut] = []
    other_user: Optional[schemas.UserOut] = None
    my_role: Optional[str] = None
    for m in members:
        u = db.query(User).filter(User.id == m.user_id).first()
        if u is None:
            continue
        member_outs.append(
            schemas.ConversationMemberOut(
                user_id=u.id,
                username=u.username,
                avatar_url=u.avatar_url,
                phone=u.phone,
                is_online=bool(u.is_online),
                role=m.role,
            )
        )
        if m.user_id == me:
            my_role = m.role
        elif not conv.is_group:
            other_user = schemas.UserOut.model_validate(u)
    last = cc.last_message(db, conv.id)
    return schemas.ConversationOut(
        id=conv.id,
        is_group=conv.is_group,
        title=conv.title,
        avatar_url=conv.avatar_url,
        created_by=conv.created_by,
        updated_at=conv.updated_at,
        members=member_outs,
        other_user=other_user,
        last_message=(crud.list_preview(last) if last else None),
        last_timestamp=(last.timestamp if last else None),
        last_sender_id=(last.sender_id if last else None),
        unread_count=cc.unread_count(db, conv.id, me),
        my_role=my_role,
    )


def _require_member(db: Session, cid: int, me: int) -> Conversation:
    conv = cc.get_conversation(db, cid)
    if not conv or not cc.is_member(db, cid, me):
        raise HTTPException(status_code=404, detail="Conversation not found")
    return conv


# ── List / create ─────────────────────────────────────────────────────────────

@router.get("", response_model=List[schemas.ConversationOut])
def list_conversations(
    db: Session = Depends(get_db), current_user: User = Depends(get_current_user)
):
    convs = cc.conversations_for_user(db, current_user.id)
    return [_conversation_out(db, c, current_user.id) for c in convs]


@router.post("/group", response_model=schemas.ConversationOut)
def create_group(
    payload: schemas.GroupCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    if not (payload.title or "").strip():
        raise HTTPException(status_code=400, detail="Group needs a name")
    conv = cc.create_group(
        db, current_user.id, payload.title, payload.member_ids, payload.avatar_url
    )
    # Tell the other members they've been added to a new group.
    safe_broadcast_users(
        cc.member_ids(db, conv.id),
        {"type": "conversation_created", "conversation_id": conv.id},
        exclude=current_user.id,
    )
    return _conversation_out(db, conv, current_user.id)


@router.get("/{cid}", response_model=schemas.ConversationOut)
def get_one(
    cid: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    conv = _require_member(db, cid, current_user.id)
    return _conversation_out(db, conv, current_user.id)


@router.get("/{cid}/call")
def get_call_state(
    cid: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Whether a GROUP call is live in this conversation right now. The client
    polls this when a group opens so a member who missed or declined the ring
    still sees a 'call in progress · Join' banner and can reconnect."""
    conv = _require_member(db, cid, current_user.id)
    # Import here to avoid a circular import at module load.
    from websocket_routes import _group_rooms
    participants = _group_rooms.get(cid) or set()
    title = getattr(conv, "title", None) or "Group call"
    return {
        "active": len(participants) > 0,
        "count": len(participants),
        "title": title,
    }


# ── Messages ───────────────────────────────────────────────────────────────────

@router.get("/{cid}/messages", response_model=List[schemas.MessageWithSender])
def get_messages(
    cid: int,
    skip: int = 0,
    limit: int = 20,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    _require_member(db, cid, current_user.id)
    msgs = cc.get_messages(db, cid, skip, limit)
    # Fetching = delivered on this device; advance our delivered pointer and let
    # the other members' sent-message ticks catch up.
    top = cc.latest_message_id(db, cid)
    if top and cc.mark_delivered_up_to(db, cid, current_user.id, top):
        safe_broadcast_users(
            cc.member_ids(db, cid),
            {
                "type": "conversation_receipts",
                "conversation_id": cid,
                "user_id": current_user.id,
                "delivered_up_to": top,
            },
            exclude=current_user.id,
        )
    return [schemas.MessageWithSender.model_validate(m) for m in msgs]


@router.post("/{cid}/messages", response_model=schemas.MessageWithSender)
def send_message(
    cid: int,
    payload: schemas.GroupMessageCreate,
    background: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    conv = _require_member(db, cid, current_user.id)
    msg = cc.add_message(db, cid, current_user.id, payload)
    validated = schemas.MessageWithSender.model_validate(msg)
    serialized = _serialize(msg)
    members = cc.member_ids(db, cid)
    safe_broadcast_users(
        members, {"type": "new_message", "data": serialized}, exclude=current_user.id
    )
    safe_notify_user(current_user.id, {"type": "message_sent", "data": serialized})
    # Best-effort push to the other members.
    preview = crud.list_preview(msg)
    is_group = bool(conv.is_group)
    for uid in members:
        if uid == current_user.id:
            continue
        background.add_task(
            send_push_to_user,
            int(uid),
            {
                "type": "new_message",
                "conversation_id": str(cid),
                "sender_id": str(current_user.id),
                "sender_name": (current_user.username or "New message"),
                "group_title": (conv.title or "") if is_group else "",
                "message_id": str(msg.id),
                "body": preview,
            },
        )
    return validated


@router.patch("/{cid}/read")
def mark_read(
    cid: int,
    payload: Optional[schemas.ReadUpTo] = None,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    _require_member(db, cid, current_user.id)
    up_to = (
        payload.message_id
        if (payload and payload.message_id)
        else cc.latest_message_id(db, cid)
    )
    if up_to and cc.mark_read_up_to(db, cid, current_user.id, up_to):
        safe_broadcast_users(
            cc.member_ids(db, cid),
            {
                "type": "conversation_receipts",
                "conversation_id": cid,
                "user_id": current_user.id,
                "read_up_to": up_to,
            },
            exclude=current_user.id,
        )
    return {"read_up_to": up_to}


@router.get("/{cid}/messages/{mid}/seen", response_model=List[schemas.SeenByEntry])
def message_seen_by(
    cid: int,
    mid: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    _require_member(db, cid, current_user.id)
    return cc.seen_by(db, cid, mid, exclude_user=current_user.id)


@router.get("/{cid}/messages/{mid}/info", response_model=schemas.MessageInfoOut)
def message_info(
    cid: int,
    mid: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """WhatsApp-style message info: who has read / received / not-yet-received a
    message. Excludes the message's own sender from every bucket."""
    _require_member(db, cid, current_user.id)
    msg = (
        db.query(Message)
        .filter(Message.id == mid, Message.conversation_id == cid)
        .first()
    )
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")
    return cc.message_info(db, cid, mid, msg.sender_id)


# ── Membership admin ───────────────────────────────────────────────────────────

@router.post("/{cid}/members")
def add_members(
    cid: int,
    payload: schemas.AddMembers,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    conv = _require_member(db, cid, current_user.id)
    if not conv.is_group:
        raise HTTPException(status_code=400, detail="Not a group")
    if not cc.is_admin(db, cid, current_user.id):
        raise HTTPException(status_code=403, detail="Only admins can add members")
    added = cc.add_members(db, cid, payload.user_ids)
    if added:
        safe_broadcast_users(
            cc.member_ids(db, cid),
            {"type": "conversation_updated", "conversation_id": cid},
        )
        for uid in added:
            safe_notify_user(
                int(uid), {"type": "conversation_created", "conversation_id": cid}
            )
    return {"added": added}


@router.delete("/{cid}/members/{uid}")
def remove_member(
    cid: int,
    uid: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    conv = _require_member(db, cid, current_user.id)
    if not conv.is_group:
        raise HTTPException(status_code=400, detail="Not a group")
    # Leaving (removing yourself) is always allowed; removing others needs admin.
    if uid != current_user.id and not cc.is_admin(db, cid, current_user.id):
        raise HTTPException(status_code=403, detail="Only admins can remove members")
    targets = cc.member_ids(db, cid)
    cc.remove_member(db, cid, uid)
    safe_broadcast_users(
        targets, {"type": "conversation_updated", "conversation_id": cid}
    )
    return {"removed": uid}


@router.post("/{cid}/leave")
def leave(
    cid: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    _require_member(db, cid, current_user.id)
    targets = cc.member_ids(db, cid)
    cc.remove_member(db, cid, current_user.id)
    safe_broadcast_users(
        targets, {"type": "conversation_updated", "conversation_id": cid}
    )
    return {"left": cid}


@router.patch("/{cid}", response_model=schemas.ConversationOut)
def update_group(
    cid: int,
    payload: schemas.RenameGroup,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    conv = _require_member(db, cid, current_user.id)
    if not conv.is_group:
        raise HTTPException(status_code=400, detail="Not a group")
    if not cc.is_admin(db, cid, current_user.id):
        raise HTTPException(status_code=403, detail="Only admins can edit the group")
    cc.update_group(db, cid, title=payload.title, avatar_url=payload.avatar_url)
    safe_broadcast_users(
        cc.member_ids(db, cid),
        {"type": "conversation_updated", "conversation_id": cid},
    )
    return _conversation_out(db, cc.get_conversation(db, cid), current_user.id)
