from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from typing import List
import crud, schemas
from database import get_db
from models import User, Message
from .users import get_current_user
from datetime import datetime
from websocket_manager import safe_notify_user

router = APIRouter(
    prefix="/messages",
    tags=["Messages"]
)

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

# 1️⃣ SEND MESSAGE
@router.post("/", response_model=schemas.MessageWithSender)
def send_message(message: schemas.MessageCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    db_message = crud.create_message(db, sender_id=current_user.id, message=message)
    validated_message = schemas.MessageWithSender.model_validate(db_message)
    serialized = serialize_message(validated_message)

    # Notify receiver
    safe_notify_user(message.receiver_id, {"type": "new_message", "data": serialized})
    # Notify sender
    safe_notify_user(current_user.id, {"type": "message_sent", "data": serialized})

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
    if current_user.id not in [message.sender_id, message.receiver_id]:
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
        safe_notify_user(message.receiver_id, {
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
    if current_user.id not in [message.sender_id, message.receiver_id]:
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

    other_id = (
        message.receiver_id
        if current_user.id == message.sender_id
        else message.sender_id
    )
    safe_notify_user(other_id, {
        "type": "message_reaction",
        "data": {"message_id": message_id, "reactions": message.reactions},
    })
    return {"message_id": message_id, "reactions": message.reactions}

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

    message.content = payload.content or ""
    message.edited = True
    db.commit()
    db.refresh(message)

    validated = schemas.MessageWithSender.model_validate(message)
    serialized = serialize_message(validated)
    safe_notify_user(message.receiver_id, {"type": "message_edited", "data": serialized})
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
