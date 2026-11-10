"""One-time-per-deploy conversion to directional friendships.

Before the mutual rule, ONE Friend row meant "friends both ways" — contact
sync added a row for whoever synced first and skipped the other side. Now a
row is one direction and features need both. So, for every pair that has
only one row, add the missing side when there's real evidence the other
person knows them too:
  • the other person has this number saved in their phone book (their
    uploaded contact map), or
  • both have messaged each other at least once, or
  • they share an accepted Our Space bond.
Pairs with no such evidence stay one-sided (they can still message; the
other person becomes a full friend by saving / adding them back).
Idempotent and cheap; never raises.
"""
import json
import re

from database import SessionLocal
from models import Friend, User, Message, BondRequest, UserContactBook


def _keys(p: str) -> set:
    d = re.sub(r"\D", "", p or "")
    out = set()
    if len(d) >= 8:
        out.add(d)
    if len(d) >= 9:
        out.add(d[-9:])
    return out


def backfill_mutual_once() -> int:
    db = SessionLocal()
    added = 0
    try:
        rows = db.query(Friend.user_id, Friend.friend_id).all()
        have = {(int(a), int(b)) for a, b in rows}
        missing = [(b, a) for (a, b) in have if (b, a) not in have and a != b]
        if not missing:
            return 0
        books: dict = {}
        phones: dict = {}

        def book(uid):
            if uid not in books:
                r = db.query(UserContactBook).filter(
                    UserContactBook.user_id == uid).first()
                keys = set()
                if r is not None:
                    try:
                        for k in (json.loads(r.data or "{}") or {}).keys():
                            keys |= _keys(str(k))
                    except Exception:
                        pass
                books[uid] = keys
            return books[uid]

        def phone(uid):
            if uid not in phones:
                u = db.query(User.phone).filter(User.id == uid).first()
                phones[uid] = _keys(u[0] if u else "")
            return phones[uid]

        for (x, y) in missing:  # should x have a row x → y ?
            ok = bool(phone(y) and (book(x) & phone(y)))
            if not ok:
                ok = (db.query(Message.id).filter(
                    Message.sender_id == x, Message.receiver_id == y).first()
                    is not None
                    and db.query(Message.id).filter(
                        Message.sender_id == y, Message.receiver_id == x)
                    .first() is not None)
            if not ok:
                ok = db.query(BondRequest.id).filter(
                    BondRequest.status == "accepted",
                    ((BondRequest.from_user_id == x)
                     & (BondRequest.to_user_id == y))
                    | ((BondRequest.from_user_id == y)
                       & (BondRequest.to_user_id == x)),
                ).first() is not None
            if ok:
                db.add(Friend(user_id=x, friend_id=y))
                added += 1
        if added:
            db.commit()
        print(f"[mutual] backfill added {added} reverse friend rows")
        return added
    except Exception as e:  # noqa: BLE001
        print(f"[mutual] backfill failed: {e}")
        try:
            db.rollback()
        except Exception:
            pass
        return added
    finally:
        db.close()
