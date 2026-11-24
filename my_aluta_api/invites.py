"""💌 Invitations, the Founding Circle and the waiting list (brand strategy:
being invited is the status, not paying).

* Every member can hold up to INVITES_OPEN unused personal invite codes; a
  friend joins with one and both see who brought whom.
* The Founding Circle: the first FOUNDING_CIRCLE accounts, by their real
  order of joining (member number = their place in that order) — never an
  invented number.
* ALUTA_INVITE_ONLY (env, off by default): when on, registering needs an
  invite code; everyone else can join the waiting list.
"""
import os
import re
import secrets
from datetime import datetime, timezone

import time

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from auth import get_current_user
from database import get_db
from models import Invite, User, WaitlistEntry

router = APIRouter(tags=["Invites"])

# People each member can bring in while Aluta opens in waves (only enforced
# when ALUTA_INVITE_ONLY is on — otherwise invites are unlimited).
INVITES_PER_MEMBER = 5
FOUNDING_CIRCLE = 1000
_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"  # no look-alikes (l/1, o/0)


# Public endpoints (no account): a few tries per address, so codes can't be
# swept for names and the waiting list can't be flooded.
_hits: dict = {}


def _slow_down(request: Request, kind: str, per_ip: int, window: float,
               overall: int | None = None) -> None:
    xff = request.headers.get("x-forwarded-for", "")
    ip = (xff.split(",")[-1].strip() if xff else
          (request.client.host if request.client else "?"))
    now = time.time()
    for key, cap in (((kind, ip), per_ip), ((kind, "*"), overall)):
        if cap is None:
            continue
        seen = [x for x in _hits.get(key, []) if now - x < window]
        if len(seen) >= cap:
            _hits[key] = seen
            raise HTTPException(status_code=429,
                                detail="Too many tries — try again later")
        seen.append(now)
        _hits[key] = seen


def invite_only() -> bool:
    return os.getenv("ALUTA_INVITE_ONLY", "").strip().lower() in (
        "1", "true", "yes", "on")


def _clean_code(code) -> str:
    return re.sub(r"[^a-z0-9]", "", str(code or "").lower())[:24]


def find_open_invite(db: Session, code) -> Invite | None:
    c = _clean_code(code)
    if not c:
        return None
    return db.query(Invite).filter(Invite.code == c,
                                   Invite.used_by.is_(None)).first()


def use_invite(db: Session, invite: Invite, new_user: User) -> None:
    """At registration: the friend joined with this code (caller commits)."""
    if invite.inviter_id == new_user.id:
        return
    invite.used_by = new_user.id
    invite.used_at = datetime.now(timezone.utc)
    new_user.invited_by = invite.inviter_id


def leave_waitlist(db: Session, email, phone) -> None:
    """A waiting-list entry goes once its person has joined."""
    keys = {str(x).strip().lower() for x in (email, phone) if x}
    if not keys:
        return
    try:
        db.query(WaitlistEntry).filter(WaitlistEntry.contact.in_(keys)).delete(
            synchronize_session=False)
        db.commit()
    except Exception:  # noqa: BLE001
        db.rollback()


def number_members(db: Session) -> int:
    """Give every account without a member number one, in the true order of
    joining, after the highest already given. Run at start-up (existing
    accounts) and at registration (the new one). Returns how many."""
    from sqlalchemy import func
    top = db.query(func.max(User.member_no)).scalar() or 0
    rows = (db.query(User).filter(User.member_no.is_(None))
            .order_by(User.id.asc()).all())
    for u in rows:
        top += 1
        u.member_no = top
    if rows:
        db.commit()
    return len(rows)


def member_number(db: Session, user: User) -> int:
    """Their place in the order of joining (1 = the first account) — worked
    out once, then kept: a permanent mark never shifts when an earlier
    account is deleted."""
    n = getattr(user, "member_no", None)
    if n:
        return int(n)
    from sqlalchemy import func
    n = db.query(User.id).filter(User.id <= user.id).count()
    # (never a number an earlier member already holds)
    top = db.query(func.max(User.member_no)).filter(User.id < user.id).scalar()
    if top and n <= int(top):
        n = int(top) + 1
    try:
        user.member_no = n
        db.commit()
    except Exception:  # noqa: BLE001
        db.rollback()
    return n


def _used(db: Session, uid: int) -> int:
    return db.query(Invite.id).filter(Invite.inviter_id == uid,
                                      Invite.used_by.isnot(None)).count()


def _open_codes(db: Session, uid: int) -> list:
    return (db.query(Invite)
            .filter(Invite.inviter_id == uid, Invite.used_by.is_(None))
            .order_by(Invite.id.asc()).all())


@router.get("/users/me/membership")
def my_membership(db: Session = Depends(get_db),
                  me: User = Depends(get_current_user)):
    n = member_number(db, me)
    inviter = (db.query(User).filter(User.id == me.invited_by).first()
               if getattr(me, "invited_by", None) else None)
    brought = db.query(User.id).filter(User.invited_by == me.id).count()
    return {
        "member_no": n,
        "founding": n <= FOUNDING_CIRCLE,
        "invited_by_id": inviter.id if inviter else None,
        "invited_by_name": inviter.username if inviter else None,
        # Their face in the new member's welcome ("Asha brought you here").
        "invited_by_avatar": inviter.avatar_url if inviter else None,
        "brought": brought,
        "invites_left": (max(0, INVITES_PER_MEMBER - _used(db, me.id))
                         if invite_only() else None),
        "invite_only": invite_only(),
    }


@router.post("/users/me/invites")
def new_invite(db: Session = Depends(get_db),
               me: User = Depends(get_current_user)):
    """My invite code to share: one open code at a time (reused until
    someone joins with it); while Aluta is invite-only, each member brings
    up to INVITES_PER_MEMBER people."""
    open_ = _open_codes(db, me.id)
    if open_:
        return {"code": open_[0].code}
    if invite_only() and _used(db, me.id) >= INVITES_PER_MEMBER:
        raise HTTPException(status_code=429,
                            detail="You've brought all the people you can "
                                   "for now — more open with the next wave")
    for _ in range(5):
        code = "".join(secrets.choice(_ALPHABET) for _ in range(8))
        if db.query(Invite.id).filter(Invite.code == code).first() is None:
            db.add(Invite(code=code, inviter_id=me.id))
            db.commit()
            return {"code": code}
    raise HTTPException(status_code=503, detail="Try again")


@router.get("/invites/{code}")
def invite_info(code: str, request: Request, db: Session = Depends(get_db)):
    """Public: who invited (first name only) — for the join page and the
    registration screen. Nothing else about them."""
    _slow_down(request, "invite", per_ip=20, window=600)
    inv = find_open_invite(db, code)
    if inv is None:
        raise HTTPException(status_code=404, detail="That invite isn't open")
    u = db.query(User).filter(User.id == inv.inviter_id).first()
    name = (u.username if u else "").strip()
    return {"from": name.split()[0] if name else "A friend"}


class WaitlistIn(BaseModel):
    contact: str = Field(min_length=5, max_length=160)
    name: str | None = Field(default=None, max_length=80)


@router.post("/waitlist")
def join_waitlist(body: WaitlistIn, request: Request,
                  db: Session = Depends(get_db)):
    """Public: an email or phone number waiting for a wave to open."""
    _slow_down(request, "waitlist", per_ip=5, window=3600, overall=500)
    c = body.contact.strip().lower()
    if not (re.fullmatch(r"[^@\s]+@[^@\s]+\.[a-z]{2,}", c)
            or re.fullmatch(r"\+\d{8,15}", c)):
        raise HTTPException(status_code=400,
                            detail="Enter an email or a phone number with +code")
    if db.query(WaitlistEntry.id).filter(WaitlistEntry.contact == c).first():
        return {"ok": True, "already": True}
    db.add(WaitlistEntry(contact=c, name=(body.name or "").strip() or None))
    db.commit()
    return {"ok": True}
