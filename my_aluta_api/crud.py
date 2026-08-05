# ------------------ Imports ------------------
from sqlalchemy.orm import Session
from fastapi import HTTPException
from datetime import datetime, timezone
from sqlalchemy import func

from models import Message, User, Friend, MuteStatus, BlockStatus
from schemas import MessageCreate, FriendWithUnread


# ------------------ User Status ------------------
def update_user_status(db: Session, user_id: int, is_online: bool):
    user = db.query(User).filter(User.id == user_id).first()
    if user:
        user.is_online = is_online
        if not is_online:
            user.last_seen = datetime.now(timezone.utc)
        db.commit()
        db.refresh(user)
    return user


# ------------------ Messaging Core ------------------
def create_message(db: Session, sender_id: int, message: MessageCreate) -> Message:
    db_message = Message(
        sender_id=sender_id,
        receiver_id=message.receiver_id,
        content=message.content or "",
        message_type=(message.message_type or "text"),
        media_url=message.media_url,
        media_name=message.media_name,
        media_mime=message.media_mime,
        media_size=message.media_size,
        media_duration=message.media_duration,
        timestamp=datetime.now(timezone.utc),
        is_read=False,
        delivered=False,
        visible_to_sender=True,
        visible_to_receiver=True
    )
    db.add(db_message)
    db.commit()
    db.refresh(db_message)
    return db_message


# ------------------ Chat Deletion ------------------
def clear_chat_messages(db: Session, user_id: int, friend_id: int, delete_for_all: bool = False):
    if delete_for_all:
        # Hard delete for both
        db.query(Message).filter(
            ((Message.sender_id == user_id) & (Message.receiver_id == friend_id)) |
            ((Message.sender_id == friend_id) & (Message.receiver_id == user_id))
        ).delete(synchronize_session=False)
    else:
        # Soft delete: hide messages from current user only
        db.query(Message).filter(
            (Message.sender_id == user_id) & (Message.receiver_id == friend_id)
        ).update({Message.visible_to_sender: False}, synchronize_session=False)

        db.query(Message).filter(
            (Message.sender_id == friend_id) & (Message.receiver_id == user_id)
        ).update({Message.visible_to_receiver: False}, synchronize_session=False)

        # Fully delete messages no longer visible to either user
        db.query(Message).filter(
            (Message.visible_to_sender == False) & (Message.visible_to_receiver == False)
        ).delete(synchronize_session=False)

    db.commit()
    return {"detail": "Chat cleared successfully"}


# ------------------ Message Querying ------------------
def get_messages_between_users(db: Session, user_id_1: int, user_id_2: int, skip: int = 0, limit: int = 10):
    return db.query(Message).filter(
        ((Message.sender_id == user_id_1) & (Message.receiver_id == user_id_2) & (Message.visible_to_sender == True)) |
        ((Message.sender_id == user_id_2) & (Message.receiver_id == user_id_1) & (Message.visible_to_receiver == True))
    ).order_by(Message.timestamp.asc()).offset(skip).limit(limit).all()


def get_messages_after(db: Session, user_id_1: int, user_id_2: int, last_ts: datetime):
    return db.query(Message).filter(
        (((Message.sender_id == user_id_1) & (Message.receiver_id == user_id_2) & (Message.visible_to_sender == True)) |
         ((Message.sender_id == user_id_2) & (Message.receiver_id == user_id_1) & (Message.visible_to_receiver == True))) &
        (Message.timestamp > last_ts)
    ).order_by(Message.timestamp.asc()).all()


def get_all_messages_with_friend(db: Session, user_id: int, friend_id: int, skip: int = 0, limit: int = 20):
    """Fetch visible messages only, newest → oldest handled in router if needed"""
    return db.query(Message).filter(
        (
            (Message.sender_id == user_id) &
            (Message.receiver_id == friend_id) &
            (Message.visible_to_sender == True)
        ) |
        (
            (Message.sender_id == friend_id) &
            (Message.receiver_id == user_id) &
            (Message.visible_to_receiver == True)
        )
    ).order_by(Message.timestamp.asc()).offset(skip).limit(limit).all()


def get_all_messages_count_with_friend(db: Session, user_id: int, friend_id: int) -> int:
    return db.query(Message).filter(
        (
            (Message.sender_id == user_id) & (Message.receiver_id == friend_id) & (Message.visible_to_sender == True)
        ) |
        (
            (Message.sender_id == friend_id) & (Message.receiver_id == user_id) & (Message.visible_to_receiver == True)
        )
    ).count()


def get_last_message_with_friend(db: Session, user_id: int, friend_id: int):
    return db.query(Message).filter(
        (
            (Message.sender_id == user_id) & (Message.receiver_id == friend_id) & (Message.visible_to_sender == True)
        ) |
        (
            (Message.sender_id == friend_id) & (Message.receiver_id == user_id) & (Message.visible_to_receiver == True)
        )
    ).order_by(Message.timestamp.desc()).first()


def get_last_message_time_with_friend(db: Session, user_id: int, friend_id: int) -> datetime:
    last_message = get_last_message_with_friend(db, user_id, friend_id)
    return last_message.timestamp if last_message else None


# ------------------ Read/Delivery ------------------
def mark_messages_as_read(db: Session, receiver_id: int, sender_id: int):
    """
    Mark all unread messages from sender to receiver as read.
    Returns list of updated message IDs.
    """
    messages_to_update = db.query(Message).filter(
        Message.receiver_id == receiver_id,
        Message.sender_id == sender_id,
        Message.is_read == False
    )

    updated_ids = [msg.id for msg in messages_to_update.all()]

    if updated_ids:
        messages_to_update.update({
            Message.is_read: True,
            Message.read_at: datetime.now(timezone.utc)
        }, synchronize_session=False)
        db.commit()

    return updated_ids


def mark_messages_as_delivered(db: Session, receiver_id: int, sender_id: int):
    """
    Mark all undelivered messages from sender to receiver as delivered.
    Returns list of updated message IDs.
    """
    messages_to_update = db.query(Message).filter(
        Message.receiver_id == receiver_id,
        Message.sender_id == sender_id,
        Message.delivered == False
    )

    updated_ids = [msg.id for msg in messages_to_update.all()]
    
    if updated_ids:
        messages_to_update.update({Message.delivered: True}, synchronize_session=False)
        db.commit()
    
    return updated_ids

def mark_single_message_as_delivered(db: Session, message_id: int, receiver_id: int):
    """
    Mark a single message as delivered (if current user is receiver)
    Returns the message object.
    """
    msg = db.query(Message).filter(Message.id == message_id).first()
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")
    if msg.receiver_id != receiver_id:
        raise HTTPException(status_code=403, detail="Not authorized")
    
    if not msg.delivered:
        msg.delivered = True
        db.commit()
        db.refresh(msg)
    return msg

# ------------------ Unread Counts ------------------
def get_unread_messages_count_with_friend(db: Session, user_id: int, friend_id: int) -> int:
    return db.query(Message).filter(
        Message.receiver_id == user_id,
        Message.sender_id == friend_id,
        Message.is_read == False
    ).count()


def get_unread_messages_with_friend(db: Session, user_id: int, friend_id: int):
    return db.query(Message).filter(
        Message.receiver_id == user_id,
        Message.sender_id == friend_id,
        Message.is_read == False
    ).all()


# ------------------ Friend Lists ------------------
def get_all_users(db: Session, current_user_id: int):
    return db.query(User).filter(User.id != current_user_id).all()


def get_friends(db: Session, user_id: int):
    return db.query(User).join(Friend, (Friend.user_id == User.id) | (Friend.friend_id == User.id)).filter(
        (Friend.user_id == user_id) | (Friend.friend_id == user_id)
    ).all()


def get_friends_with_unread_counts(db: Session, user_id: int):
    friends = get_all_users(db, user_id)
    friends_with_data = []

    for friend in friends:
        last_message = get_last_message_with_friend(db, user_id, friend.id)
        unread_count = get_unread_messages_count_with_friend(db, user_id, friend.id)

        friends_with_data.append(
            FriendWithUnread(
                id=friend.id,
                username=friend.username,
                is_online=friend.is_online,
                last_timestamp=last_message.timestamp.strftime('%Y-%m-%d %H:%M') if last_message else None,
                last_message=last_message.content if last_message else "",
                unread_count=unread_count,
                last_sender_id=last_message.sender_id if last_message else None,
                last_message_delivered=last_message.delivered if last_message else None,
                last_message_read=last_message.is_read if last_message else None,
                phone=friend.phone,
                avatar_url=friend.avatar_url
            )
        )

    friends_with_data.sort(key=lambda x: x.last_timestamp or "", reverse=True)
    return friends_with_data


# ------------------ Online/Offline ------------------
def get_online_friends(db: Session, user_id: int):
    return db.query(User).filter(User.id != user_id, User.is_online == True).all()


def get_offline_friends(db: Session, user_id: int):
    return db.query(User).filter(User.id != user_id, User.is_online == False).all()


def get_online_friends_count(db: Session, user_id: int) -> int:
    friend_ids = _get_friend_ids(db, user_id)
    return db.query(User).filter(User.id.in_(friend_ids), User.is_online == True).count()


def get_offline_friends_count(db: Session, user_id: int) -> int:
    friend_ids = _get_friend_ids(db, user_id)
    return db.query(User).filter(User.id.in_(friend_ids), User.is_online == False).count()


def _get_friend_ids(db: Session, user_id: int) -> set:
    friend_ids = set()
    for rel in db.query(Friend).filter((Friend.user_id == user_id) | (Friend.friend_id == user_id)).all():
        if rel.user_id != user_id:
            friend_ids.add(rel.user_id)
        if rel.friend_id != user_id:
            friend_ids.add(rel.friend_id)
    return friend_ids


# ------------------ Mute/Block ------------------
def is_user_muted(db: Session, user_id: int, muted_user_id: int) -> bool:
    return db.query(MuteStatus).filter(
        MuteStatus.user_id == user_id,
        MuteStatus.muted_user_id == muted_user_id
    ).first() is not None


def toggle_mute(db: Session, user_id: int, muted_user_id: int) -> bool:
    mute = db.query(MuteStatus).filter(
        MuteStatus.user_id == user_id,
        MuteStatus.muted_user_id == muted_user_id
    ).first()
    if mute:
        db.delete(mute)
        db.commit()
        return False
    else:
        db.add(MuteStatus(user_id=user_id, muted_user_id=muted_user_id))
        db.commit()
        return True


def toggle_block(db: Session, user_id: int, blocked_user_id: int) -> bool:
    block = db.query(BlockStatus).filter(
        BlockStatus.user_id == user_id,
        BlockStatus.blocked_user_id == blocked_user_id
    ).first()
    if block:
        db.delete(block)
        db.commit()
        return False
    else:
        db.add(BlockStatus(user_id=user_id, blocked_user_id=blocked_user_id))
        db.commit()
        return True


def get_blocked_friends(db: Session, user_id: int):
    blocked = db.query(BlockStatus).filter(BlockStatus.user_id == user_id).all()
    return db.query(User).filter(User.id.in_([b.blocked_user_id for b in blocked])).all()
