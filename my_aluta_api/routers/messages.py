from fastapi import APIRouter, Depends, HTTPException, Query, BackgroundTasks
from sqlalchemy.orm import Session
from typing import List
import crud, schemas
from database import get_db
from models import User, Message
from .users import get_current_user
from datetime import datetime, timedelta, timezone
from websocket_manager import safe_notify_user
from push import send_push_to_user
import crud_conversations

router = APIRouter(
    prefix="/messages",
    tags=["Messages"]
)

# How long after posting a text message it can still be edited. Past this, the
# edit endpoint returns 403 and the client hides the Edit action.
EDIT_WINDOW = timedelta(hours=1)

# 🔒 General: User and friend helper routes
@router.get("/users/all", response_model=List[schemas.UserOut], operation_id="messages_get_all_users")
def get_users(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return crud.get_all_users(db, current_user.id)

@router.get("/friends/unread_counts", response_model=List[schemas.FriendWithUnread], operation_id="messages_get_friends_unread_counts")
def get_friends_with_unread_counts(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return crud.get_friends_with_unread_counts(db, current_user.id)


# In messages.py: replace all WebSocket sends with _serialize_event

from websocket_manager import safe_notify_user
from datetime import datetime

# Helper to serialize messages for WebSocket
def serialize_message(msg):
    data = msg.model_dump()  # Schema object to dict
    for key, value in data.items():
        if isinstance(value, datetime):
            data[key] = value.isoformat()
    return data


def _access_ids(db, msg) -> list:
    """User ids allowed to see/act on a message: a DM's two parties, or a
    group's members. Lets group members react/edit/delete/pin (not just the
    sender/receiver)."""
    if getattr(msg, "conversation_id", None):
        conv = crud_conversations.get_conversation(db, msg.conversation_id)
        if conv and conv.is_group:
            return crud_conversations.member_ids(db, msg.conversation_id)
    ids = []
    if msg.sender_id:
        ids.append(msg.sender_id)
    if msg.receiver_id:
        ids.append(msg.receiver_id)
    return ids


def _fanout_others(db, msg, me: int, event: dict):
    """Notify everyone who can see the message except the actor (works for both
    DMs — the other party — and groups — every other member)."""
    for uid in _access_ids(db, msg):
        if uid != me:
            safe_notify_user(int(uid), event)

# 1️⃣ SEND MESSAGE
@router.post("/", response_model=schemas.MessageWithSender)
def send_message(message: schemas.MessageCreate, background: BackgroundTasks, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    db_message = crud.create_message(db, sender_id=current_user.id, message=message)
    validated_message = schemas.MessageWithSender.model_validate(db_message)
    serialized = serialize_message(validated_message)

    # Notify receiver
    safe_notify_user(message.receiver_id, {"type": "new_message", "data": serialized})
    # Notify sender
    safe_notify_user(current_user.id, {"type": "message_sent", "data": serialized})

    # Push (best-effort, after the response) so the receiver is woken when their
    # app is backgrounded or closed and the WebSocket is dead. A short type +
    # sender + preview is enough for the client to build the local notification.
    background.add_task(
        send_push_to_user,
        int(message.receiver_id),
        {
            "type": "new_message",
            "sender_id": str(current_user.id),
            "sender_name": current_user.username or "New message",
            "message_id": str(db_message.id),
            "body": crud.list_preview(db_message),
        },
    )

    return validated_message

# 2️⃣ MESSAGE DELIVERED (auto when fetching messages)
@router.get("/{friend_id}/all_messages", response_model=List[schemas.MessageWithSender])
def get_all_messages_with_friend(friend_id: int, skip: int = 0, limit: int = 20, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    all_messages = crud.get_all_messages_with_friend(db, current_user.id, friend_id, skip, limit)
    updated_messages = []

    for msg in all_messages:
        if msg.receiver_id == current_user.id and not msg.delivered:
            msg.delivered = True
            updated_messages.append(msg)

    if updated_messages:
        db.commit()
        for msg in updated_messages:
            safe_notify_user(msg.sender_id, {
                "type": "message_delivered",
                "data": serialize_message(schemas.MessageWithSender.model_validate(msg))
            })

    return [schemas.MessageWithSender.model_validate(msg) for msg in all_messages]

# 3️⃣ MESSAGE READ
@router.patch("/{sender_id}/read")
def mark_messages_as_read(sender_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    unread_messages = crud.get_unread_messages_with_friend(db, current_user.id, sender_id)
    updated_ids = []

    for msg in unread_messages:
        # NOTE: the mapped column is `is_read` — assigning `msg.read` set an
        # unmapped attribute that never persisted, so reads were lost and the
        # unread badge kept coming back. Set the real column.
        msg.is_read = True
        updated_ids.append(msg.id)

    if updated_ids:
        db.commit()
        safe_notify_user(sender_id, {
            "type": "messages_read",
            "data": {
                "message_ids": updated_ids,
                "reader_id": current_user.id
            }
        })

    return {"updated_count": len(updated_ids)}

# 4️⃣ MESSAGE DELETED
@router.delete("/{message_id}/delete")
def delete_single_message(message_id: int, delete_for_all: bool = Query(False), db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    message = db.query(Message).filter(Message.id == message_id).first()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if current_user.id not in _access_ids(db, message):
        raise HTTPException(status_code=403, detail="Not authorized")

    if delete_for_all:
        if current_user.id != message.sender_id:
            raise HTTPException(status_code=403, detail="Only sender can delete for everyone")
        # Soft-delete: keep the row as a tombstone so both sides render
        # "This message was deleted" rather than the bubble silently vanishing.
        message.is_deleted = True
        message.content = ""
        message.message_type = "text"
        message.media_url = None
        message.media_name = None
        message.media_mime = None
        message.media_size = None
        message.media_duration = None
        message.reactions = None
        db.commit()
        _fanout_others(db, message, current_user.id, {
            "type": "message_deleted",
            "data": {
                "message_id": message_id,
                "deleted_for_all": True
            }
        })
    else:
        if current_user.id == message.sender_id:
            message.visible_to_sender = False
        else:
            message.visible_to_receiver = False
        db.commit()

    return {"detail": "Message deleted"}

# 4️⃣.b REACT TO MESSAGE — toggle the current user's emoji (one per user).
@router.post("/{message_id}/react")
def react_to_message(
    message_id: int,
    emoji: str = Query(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    import json
    message = db.query(Message).filter(Message.id == message_id).first()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if current_user.id not in _access_ids(db, message):
        raise HTTPException(status_code=403, detail="Not authorized")
    if message.is_deleted:
        raise HTTPException(status_code=400, detail="Cannot react to a deleted message")

    try:
        reactions = json.loads(message.reactions) if message.reactions else {}
    except Exception:
        reactions = {}
    key = str(current_user.id)
    # Same emoji again = remove (toggle); a different one replaces it.
    if reactions.get(key) == emoji:
        reactions.pop(key, None)
    else:
        reactions[key] = emoji
    message.reactions = json.dumps(reactions) if reactions else None
    db.commit()

    _fanout_others(db, message, current_user.id, {
        "type": "message_reaction",
        "data": {"message_id": message_id, "reactions": message.reactions},
    })
    return {"message_id": message_id, "reactions": message.reactions}


# 4️⃣.b PIN MESSAGE — either participant, for a chosen duration (hours).
@router.post("/{message_id}/pin", response_model=schemas.MessageWithSender)
def pin_message(
    message_id: int,
    hours: int = Query(24, ge=1, le=8760),  # 1 hour … 1 year
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    message = db.query(Message).filter(Message.id == message_id).first()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if current_user.id not in _access_ids(db, message):
        raise HTTPException(status_code=403, detail="Not authorized")
    if message.is_deleted:
        raise HTTPException(status_code=400, detail="Cannot pin a deleted message")

    # One active pin per conversation: clear any other pins in this SAME thread
    # first (by conversation_id for groups, or the DM pair), so the banner always
    # reflects the newest pinned message.
    if getattr(message, "conversation_id", None):
        db.query(Message).filter(
            Message.conversation_id == message.conversation_id,
            Message.id != message_id,
            Message.pinned_until.isnot(None),
        ).update({Message.pinned_until: None}, synchronize_session=False)
    else:
        a, b = message.sender_id, message.receiver_id
        db.query(Message).filter(
            (((Message.sender_id == a) & (Message.receiver_id == b)) |
             ((Message.sender_id == b) & (Message.receiver_id == a))),
            Message.id != message_id,
            Message.pinned_until.isnot(None),
        ).update({Message.pinned_until: None}, synchronize_session=False)

    message.pinned_until = datetime.now(timezone.utc) + timedelta(hours=hours)
    db.commit()
    db.refresh(message)

    validated = schemas.MessageWithSender.model_validate(message)
    serialized = serialize_message(validated)
    _fanout_others(db, message, current_user.id,
                   {"type": "message_pinned", "data": serialized})
    return validated


# 4️⃣.b UNPIN MESSAGE — either participant.
@router.post("/{message_id}/unpin", response_model=schemas.MessageWithSender)
def unpin_message(
    message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    message = db.query(Message).filter(Message.id == message_id).first()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if current_user.id not in _access_ids(db, message):
        raise HTTPException(status_code=403, detail="Not authorized")

    message.pinned_until = None
    db.commit()
    db.refresh(message)

    _fanout_others(db, message, current_user.id, {
        "type": "message_unpinned",
        "data": {"message_id": message_id},
    })
    return schemas.MessageWithSender.model_validate(message)


# 4️⃣.c EDIT MESSAGE — sender only, text messages only.
@router.patch("/{message_id}/edit", response_model=schemas.MessageWithSender)
def edit_message(
    message_id: int,
    payload: schemas.MessageEdit,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    message = db.query(Message).filter(Message.id == message_id).first()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if current_user.id != message.sender_id:
        raise HTTPException(status_code=403, detail="Only the sender can edit")
    if message.is_deleted:
        raise HTTPException(status_code=400, detail="Cannot edit a deleted message")
    if (message.message_type or "text") != "text":
        raise HTTPException(status_code=400, detail="Only text messages can be edited")
    # Editing is locked once a message is older than EDIT_WINDOW (WhatsApp-style).
    # Enforced server-side so the client's own gate can't be bypassed.
    ts = message.timestamp
    if ts is not None:
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        if datetime.now(timezone.utc) - ts > EDIT_WINDOW:
            raise HTTPException(
                status_code=403,
                detail="This message is too old to edit",
            )

    message.content = payload.content or ""
    message.edited = True
    db.commit()
    db.refresh(message)

    validated = schemas.MessageWithSender.model_validate(message)
    serialized = serialize_message(validated)
    _fanout_others(db, message, current_user.id,
                   {"type": "message_edited", "data": serialized})
    return validated

# 5️⃣ Single message delivery endpoint
@router.put("/{message_id}/delivered", response_model=schemas.Message)
def mark_delivered(message_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    message = crud.mark_single_message_as_delivered(db, message_id, current_user.id)
    serialized = serialize_message(schemas.MessageWithSender.model_validate(message))
    safe_notify_user(message.sender_id, {"type": "message_delivered", "data": serialized})
    return message

# ✅ Specific GET endpoints for message status (read-only)
@router.get("/{friend_id}/unread", response_model=List[schemas.MessageWithSender], operation_id="messages_get_unread_messages_with_friend")
def get_unread_messages_with_friend(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return crud.get_unread_messages_with_friend(db, current_user.id, friend_id)

@router.get("/{friend_id}/unread_count", response_model=int, operation_id="messages_get_unread_count_with_friend")
def get_unread_count_with_friend(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return crud.get_unread_messages_count_with_friend(db, current_user.id, friend_id)

@router.get("/{friend_id}/last_message", response_model=schemas.MessageWithSender, operation_id="messages_get_last_message_with_friend")
def get_last_message_with_friend(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    last_message = crud.get_last_message_with_friend(db, current_user.id, friend_id)
    if not last_message:
        raise HTTPException(status_code=404, detail="No messages found")
    return schemas.MessageWithSender.model_validate(last_message)

@router.get("/{friend_id}/last_message_time", response_model=datetime, operation_id="messages_get_last_message_time_with_friend")
def get_last_message_time_with_friend(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    last_message_time = crud.get_last_message_time_with_friend(db, current_user.id, friend_id)
    if not last_message_time:
        raise HTTPException(status_code=404, detail="No messages found")
    return last_message_time


@router.get("/{friend_id}/all_messages_count", response_model=int, operation_id="messages_get_all_messages_count_with_friend")
def get_all_messages_count_with_friend(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return crud.get_all_messages_count_with_friend(db, current_user.id, friend_id)


# ✅ DELETE chat with friend
@router.delete("/{friend_id}", status_code=200, operation_id="messages_delete_chat_with_friend")
def delete_chat_with_friend(friend_id: int, delete_for_all: bool = Query(False), db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return crud.clear_chat_messages(db, current_user.id, friend_id, delete_for_all)




@router.get("/{user1_id}/{user2_id}", response_model=List[schemas.MessageWithSender], operation_id="messages_get_chat_history_between_users")
def get_chat_history(
    user1_id: int,
    user2_id: int,
    skip: int = 0,
    limit: int = 20,
    after: datetime = Query(None),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if after:
        return crud.get_messages_after(db, user1_id, user2_id, after)
    else:
        return crud.get_messages_between_users(db, user1_id, user2_id, skip, limit)
