"""Grey double ticks for messages that reached someone while they were away.

A DM is "delivered" when the receiver's Aluta gets it. With the app open
that's the socket (the client marks it). With the app closed, the push lands
on the phone (the client marks it from the push too) — and as a safety net,
the moment the receiver's app connects again, everything still waiting for
them is marked delivered here and each sender's tick turns grey-double.

Held messages (not yet visible to the receiver) are never marked."""
from database import SessionLocal


def deliver_pending(uid: int) -> None:
    import schemas
    from models import Message
    from websocket_manager import safe_notify_user
    from routers.messages import serialize_message

    db = SessionLocal()
    try:
        msgs = (
            db.query(Message)
            .filter(Message.receiver_id == int(uid),
                    Message.delivered == False,  # noqa: E712
                    Message.visible_to_receiver.isnot(False))
            .order_by(Message.id.desc())
            .limit(300)
            .all()
        )
        if not msgs:
            return
        for m in msgs:
            m.delivered = True
        db.commit()
        for m in msgs:
            try:
                safe_notify_user(m.sender_id, {
                    "type": "message_delivered",
                    "data": serialize_message(
                        schemas.MessageWithSender.model_validate(m)),
                })
            except Exception:
                pass
    except Exception:
        db.rollback()
    finally:
        db.close()
