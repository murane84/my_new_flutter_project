"""Admin account controls, checked on every authenticated request.

Kept in a small in-process cache (rows are few: only accounts an admin has
touched), loaded once and updated whenever an admin acts, so the per-request
check costs a dict lookup, not a query.

* paused (disabled) or waiting for deletion → every token refused, sign-in
  refused with a plain reason;
* "sign out everywhere" → tokens issued before that moment stop working.
"""
import threading
from datetime import datetime, timezone
from typing import Optional

from database import SessionLocal
from models import AccountControl

_lock = threading.Lock()
_cache: dict = {}        # user_id → (blocked: bool, why: str, signed_out_ts)
_loaded = False


def _load() -> None:
    global _loaded
    if _loaded:
        return
    db = SessionLocal()
    try:
        rows = db.query(AccountControl).all()
        with _lock:
            for r in rows:
                _cache[int(r.user_id)] = _entry(r)
            _loaded = True
    except Exception:
        pass
    finally:
        db.close()


def _entry(r: AccountControl):
    so = r.signed_out_at
    if so is not None and so.tzinfo is None:
        so = so.replace(tzinfo=timezone.utc)
    why = ""
    if r.delete_after is not None:
        why = "This account is being deleted."
    elif r.disabled:
        why = "This account is paused. Contact support@ozilane.com."
    return (bool(why), why, so.timestamp() if so else None)


def refresh(r: Optional[AccountControl], user_id: int) -> None:
    """Call after an admin changes a row (or removes it: r=None)."""
    with _lock:
        if r is None:
            _cache.pop(int(user_id), None)
        else:
            _cache[int(user_id)] = _entry(r)


def check(user_id: int, iat: Optional[float]) -> Optional[str]:
    """None = fine; else the reason this token/sign-in is refused."""
    _load()
    with _lock:
        e = _cache.get(int(user_id))
    if not e:
        return None
    blocked, why, so = e
    if blocked:
        return why
    # iat is whole seconds: compare against the whole second of the sign-out
    # so a fresh sign-in in that same second isn't refused.
    if so is not None and (iat is None or iat < int(so)):
        return "Signed out — please sign in again."
    return None


def purge_due() -> int:
    """Hard-delete accounts whose 7-day freeze has ended. Returns how many."""
    from models import User
    from routers.users import hard_delete_user
    db = SessionLocal()
    n = 0
    try:
        now = datetime.now(timezone.utc)
        for r in db.query(AccountControl).filter(
                AccountControl.delete_after.isnot(None)).all():
            due = r.delete_after
            if due.tzinfo is None:
                due = due.replace(tzinfo=timezone.utc)
            if due > now:
                continue
            uid = int(r.user_id)
            user = db.query(User).filter(User.id == uid).first()
            if user is not None:
                hard_delete_user(db, user)
                n += 1
            else:
                db.delete(r)
                db.commit()
            refresh(None, uid)
    except Exception:
        db.rollback()
    finally:
        db.close()
    return n
