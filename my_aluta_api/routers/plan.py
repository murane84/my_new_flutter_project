"""Plans for the signed-in person: what they have, the catalog, and paying.

Paying: the person sends the money to the owner's mobile-money number, then
reports the transaction code here (POST /plan/pay). It waits as a pending
payment until the owner confirms it in the admin panel, which starts / extends
the plan (billing.extend) and tells the person.

The old trial toggle (POST /plan/together, /plan/free) is gone unless
ALLOW_PLAN_TOGGLE=1 is set (local testing only).
"""
import os
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

import billing
from auth import get_current_user
from database import get_db
from models import Payment, RelationshipSpace, User

router = APIRouter(prefix="/plan", tags=["Plan"])

FREE_SPACE_CAP = 1
TOGETHER_SPACE_CAP = 8


def _pair_of(db: Session, user: User, space_id: Optional[int]):
    """(pair_key, partner_id) for one of my 1:1 Spaces, else (None, None)."""
    if not space_id:
        return None, None
    sp = (db.query(RelationshipSpace)
          .filter(RelationshipSpace.id == space_id,
                  RelationshipSpace.owner_id == user.id).first())
    if sp is None:
        return None, None
    others = [m.user_id for m in sp.members if m.user_id != user.id]
    if len(others) != 1:
        return None, None
    from bonding import pair_key
    return pair_key(user.id, others[0]), others[0]


def _iso_until(u):
    return None if u is None or u.year >= 9999 else billing.iso(u)


def _payload(db: Session, user: User) -> dict:
    billing.ensure_seed(db)
    tier = billing.tier_of(user, db)
    together = tier == "together"
    t_until = billing.until(db, "together", user_id=user.id)
    pending = (db.query(Payment)
               .filter(Payment.user_id == user.id)
               .order_by(Payment.created_at.desc()).limit(10).all())
    from models import BillingPlan
    plans = (db.query(BillingPlan).filter(BillingPlan.active.is_(True))
             .order_by(BillingPlan.sort).all())
    out = {
        "tier": tier,
        "is_together": together,
        "together_since": user.together_since.isoformat()
        if user.together_since else None,
        "together_until": None if t_until is None or t_until.year >= 9999
        else billing.iso(t_until),
        "together_forever": bool(t_until and t_until.year >= 9999),
        "level": billing.level_of(user, db),
        "plus_until": _iso_until(billing.until(db, "together_plus",
                                               user_id=user.id)),
        "space_cap": billing.limit(db, user, "spaces"),
        # Every section is open; these are my amounts (-1 = unlimited), and
        # what each level gives, for the plans page.
        "limits": billing.my_limits(db, user),
        "limits_table": billing.limits_table(db),
        "meters": billing.METERS,
        "benefits": {
            "multiple_spaces": together,
            "forever_history": together,
            "custom_themes": together,
        },
        "plans": [billing.plan_dict(p) for p in plans],
        "pay": billing.settings_dict(billing.settings(db)),
        "payments": [
            {k: v for k, v in billing.payment_dict(p, db).items()
             if k not in ("user_id", "username")}
            for p in pending
        ],
    }
    db.commit()
    return out


@router.get("")
def get_plan(db: Session = Depends(get_db),
             current_user: User = Depends(get_current_user)):
    return _payload(db, current_user)


@router.get("/space/{space_id}")
def space_plan(space_id: int, db: Session = Depends(get_db),
               current_user: User = Depends(get_current_user)):
    """Bigger Our Space for this bond: active until when, and the cap."""
    pk, partner = _pair_of(db, current_user, space_id)
    if pk is None:
        raise HTTPException(404, "Space not found")
    u = billing.until(db, "space_plus", pair_key=pk)
    return {
        "active": u is not None,
        "until": None if u is None or u.year >= 9999 else billing.iso(u),
        "cap_bytes": billing.space_cap_bytes(db, pk),
        "free_cap_bytes": billing.FREE_SPACE_MB * 1024 * 1024,
    }


@router.get("/harmony")
def shared_harmony(ids: str = "", db: Session = Depends(get_db),
                   current_user: User = Depends(get_current_user)):
    """Shared Harmony: which of these people's plans include the Harmony font
    (Our Space partner, Listen Together host, the caller / call starter).
    Only answered for people I share something with — my friends or members
    of a conversation I'm in — so it never tells strangers anyone's plan."""
    import crud
    from models import ConversationMember
    want = []
    for x in ids.split(",")[:20]:
        try:
            want.append(int(x))
        except ValueError:
            pass
    if not want:
        return {}
    ok = set(crud._get_friend_ids(db, current_user.id))
    mine = [c.conversation_id for c in db.query(ConversationMember)
            .filter(ConversationMember.user_id == current_user.id).all()]
    if mine:
        ok |= {m.user_id for m in db.query(ConversationMember)
               .filter(ConversationMember.conversation_id.in_(mine),
                       ConversationMember.user_id.in_(want)).all()}
    out = {}
    for uid in want:
        if uid != current_user.id and uid not in ok:
            continue
        u = db.query(User).filter(User.id == uid).first()
        if u is None:
            continue
        out[str(uid)] = billing.limit(db, u, "harmony_font") != 0
    return out


class PayIn(BaseModel):
    plan_code: str
    months: int = 1
    txn_code: str
    payer_phone: Optional[str] = None
    space_id: Optional[int] = None   # pair plans: which bond


def _tell_owners(amount: int, txn: str, username: str) -> None:
    """Push the owner(s): a payment is waiting for them to check."""
    try:
        from admin_panel import _owner_emails
        from database import SessionLocal
        from push import send_push_to_user
        emails = list(_owner_emails())
        if not emails:
            return
        db = SessionLocal()
        try:
            ids = [o.id for o in
                   db.query(User).filter(User.email.in_(emails)).all()]
        finally:
            db.close()
        for oid in ids:
            send_push_to_user(oid, {
                "type": "admin_payment",
                "title": "💳 New payment to confirm",
                "body": f"{username} · TZS {amount:,} · {txn}",
            })
    except Exception:
        pass


@router.post("/pay")
def report_payment(payload: PayIn, bg: BackgroundTasks,
                   db: Session = Depends(get_db),
                   current_user: User = Depends(get_current_user)):
    p = billing.plan(db, payload.plan_code)
    if p is None or not p.active:
        raise HTTPException(404, "That plan isn't available")
    months = 12 if payload.months == 12 else max(1, min(int(payload.months), 6))
    code = billing.norm_txn(payload.txn_code)
    if not billing.TXN_RE.match(code):
        raise HTTPException(400, "Check the transaction code from your "
                                 "payment message (letters and numbers)")
    if db.query(Payment.id).filter(Payment.txn_code == code).first():
        raise HTTPException(409, "This transaction code was already sent")
    waiting = (db.query(Payment)
               .filter(Payment.user_id == current_user.id,
                       Payment.status == "pending").count())
    if waiting >= 3:
        raise HTTPException(429, "You have payments waiting to be confirmed "
                                 "— give us a little time")
    pk = partner = None
    if p.scope == "pair":
        pk, partner = _pair_of(db, current_user, payload.space_id)
        if pk is None:
            raise HTTPException(400, "Choose the Our Space this is for")
    pay = Payment(
        user_id=current_user.id, plan_code=p.code, months=months,
        amount_tzs=billing.price_for(p, months),
        network=(billing.settings(db).pay_network or "M-Pesa"),
        sandbox=billing.settings(db).sandbox is not False,
        txn_code=code,
        payer_phone=(payload.payer_phone or "").strip()[:20] or None,
        pair_key=pk, partner_id=partner, status="pending",
    )
    db.add(pay)
    db.commit()
    db.refresh(pay)
    bg.add_task(_tell_owners, int(pay.amount_tzs), pay.txn_code,
                current_user.username or "Someone")
    return {"ok": True, "payment": billing.payment_dict(pay, db)}


# ── Local testing only ──────────────────────────────────────────────────────
if os.environ.get("ALLOW_PLAN_TOGGLE") == "1":
    @router.post("/together")
    def start_together(db: Session = Depends(get_db),
                       current_user: User = Depends(get_current_user)):
        billing.extend(db, "together", 1, user_id=current_user.id,
                       source="admin", note="dev toggle")
        db.commit()
        return _payload(db, current_user)

    @router.post("/free")
    def end_together(db: Session = Depends(get_db),
                     current_user: User = Depends(get_current_user)):
        billing.revoke(db, "together", user_id=current_user.id)
        db.commit()
        return _payload(db, current_user)
