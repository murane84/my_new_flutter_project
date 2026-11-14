"""Admin Phase 4 — subscription control (under /admin/api/billing).

Same protection as every admin command (admin_panel.admin_ctx): a trusted,
signed device. Reading is open to any trusted device; anything that changes
money or plans needs a device past probation + the owner password, and is
written to the audit log.
"""
from datetime import timedelta
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func, or_
from sqlalchemy.orm import Session

import billing
from admin_panel import AdminCtx, _audit, _step_up, admin_ctx, require_full
from database import get_db
from models import BillingPlan, Entitlement, Payment, User

router = APIRouter(prefix="/admin/api/billing", tags=["Admin billing"])


def _guard(ctx: AdminCtx, password: Optional[str]) -> None:
    require_full(ctx)
    _step_up(ctx, password)


def _tell_user(user_id: int, title: str, body: str) -> None:
    """Push + live event so the app refreshes its plan at once."""
    try:
        from push import send_push_to_user
        send_push_to_user(user_id, {"type": "plan_updated",
                                    "title": title, "body": body})
    except Exception:
        pass
    try:
        from websocket_manager import safe_notify_user
        safe_notify_user(user_id, {"type": "plan_updated"})
    except Exception:
        pass


def _uname(db: Session, uid: Optional[int]) -> Optional[str]:
    if not uid:
        return None
    u = db.query(User).filter(User.id == uid).first()
    return u.username if u else None


def _pair_names(db: Session, pair_key: Optional[str]) -> Optional[str]:
    if not pair_key:
        return None
    try:
        a, b = (int(x) for x in pair_key.split(":"))
    except ValueError:
        return pair_key
    return f"{_uname(db, a) or a} & {_uname(db, b) or b}"


def _pair_users(pair_key: Optional[str]) -> list:
    try:
        return [int(x) for x in (pair_key or "").split(":") if x]
    except ValueError:
        return []


def _ent_dict(db: Session, e: Entitlement) -> dict:
    t = billing.now()
    end = billing.aware(e.ends_at)
    live = (e.revoked_at is None and billing.aware(e.starts_at) <= t
            and (end is None or end > t))
    return {
        "id": e.id, "plan_code": e.plan_code,
        "user_id": e.user_id, "username": _uname(db, e.user_id),
        "pair_key": e.pair_key, "pair": _pair_names(db, e.pair_key),
        "starts_at": billing.iso(e.starts_at), "ends_at": billing.iso(e.ends_at),
        "source": e.source, "note": e.note,
        "revoked": e.revoked_at is not None,
        "live": live,
        "upcoming": e.revoked_at is None and billing.aware(e.starts_at) > t,
    }


# ── Overview ────────────────────────────────────────────────────────────────

@router.get("/overview")
def overview(ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    billing.ensure_seed(db)
    t = billing.now()
    month0 = t.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    def revenue(since=None) -> int:
        q = db.query(func.coalesce(func.sum(Payment.amount_tzs), 0)).filter(
            Payment.status == "confirmed")
        if since is not None:
            q = q.filter(Payment.decided_at >= since)
        return int(q.scalar() or 0)

    live = (db.query(Entitlement)
            .filter(Entitlement.revoked_at.is_(None),
                    Entitlement.starts_at <= t,
                    or_(Entitlement.ends_at.is_(None),
                        Entitlement.ends_at > t)).all())
    together = {e.user_id for e in live if e.plan_code == "together"}
    space = {e.pair_key for e in live if e.plan_code == "space_plus"}
    soon = []
    for e in live:
        if e.ends_at is None:
            continue
        who = {"user_id": e.user_id} if e.user_id else {"pair_key": e.pair_key}
        end = billing.until(db, e.plan_code, **who)
        if end and end.year < 9999 and end <= t + timedelta(days=7):
            soon.append({**_ent_dict(db, e), "ends_at": billing.iso(end)})
    seen = set()
    expiring = []
    for x in sorted(soon, key=lambda x: x["ends_at"] or ""):
        k = (x["plan_code"], x["user_id"], x["pair_key"])
        if k not in seen:
            seen.add(k)
            expiring.append(x)
    pending = db.query(Payment).filter(Payment.status == "pending").count()
    return {
        "revenue_month_tzs": revenue(month0),
        "revenue_30d_tzs": revenue(t - timedelta(days=30)),
        "revenue_total_tzs": revenue(),
        "active_together": len(together),
        "active_space_plus": len(space),
        "pending_payments": pending,
        "expiring": expiring[:30],
        "settings": billing.settings_dict(billing.settings(db)),
    }


# ── Payments ────────────────────────────────────────────────────────────────

@router.get("/payments")
def payments(status: str = "pending", limit: int = 100,
             ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    q = db.query(Payment)
    if status != "all":
        q = q.filter(Payment.status == status)
    rows = q.order_by(Payment.created_at.desc()).limit(max(1, min(limit, 300)))
    return {"payments": [billing.payment_dict(p, db) for p in rows]}


class DecideIn(BaseModel):
    password: str
    reason: Optional[str] = None


def _pending(db: Session, pid: int) -> Payment:
    p = db.query(Payment).filter(Payment.id == pid).first()
    if not p:
        raise HTTPException(404, "No such payment")
    if p.status != "pending":
        raise HTTPException(409, f"Already {p.status}")
    return p


@router.post("/payments/{pid}/confirm")
def confirm(pid: int, payload: DecideIn, bg: BackgroundTasks,
            ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    _guard(ctx, payload.password)
    p = _pending(db, pid)
    plan = billing.plan(db, p.plan_code)
    name = plan.name if plan else p.plan_code
    who = ({"pair_key": p.pair_key} if p.pair_key else {"user_id": p.user_id})
    e = billing.extend(db, p.plan_code, p.months, source="payment",
                       payment_id=p.id, granted_by=ctx.user.id, **who)
    p.status = "confirmed"
    p.decided_at = billing.now()
    p.decided_by = ctx.user.id
    if p.plan_code == "together":
        u = db.query(User).filter(User.id == p.user_id).first()
        if u is not None and u.together_since is None:
            u.together_since = billing.now()
    _audit(db, "payment_confirmed", user_id=ctx.user.id,
           device_id=ctx.device.id, target=f"payment:{p.id}", ip=ctx.ip,
           detail={"amount_tzs": p.amount_tzs, "plan": p.plan_code,
                   "months": p.months, "txn": p.txn_code})
    db.commit()
    end = billing.until(db, p.plan_code, **who)
    until_txt = end.strftime("%d %b %Y") if end and end.year < 9999 else ""
    for uid in ({p.user_id, *_pair_users(p.pair_key)}):
        bg.add_task(_tell_user, uid, f"{name} is on 💛",
                    f"Thank you! Active until {until_txt}." if until_txt
                    else "Thank you!")
    return {"ok": True, "payment": billing.payment_dict(p, db),
            "entitlement": _ent_dict(db, e)}


@router.post("/payments/{pid}/reject")
def reject(pid: int, payload: DecideIn, bg: BackgroundTasks,
           ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    _guard(ctx, payload.password)
    p = _pending(db, pid)
    p.status = "rejected"
    p.note = (payload.reason or "").strip()[:200] or None
    p.decided_at = billing.now()
    p.decided_by = ctx.user.id
    _audit(db, "payment_rejected", user_id=ctx.user.id,
           device_id=ctx.device.id, target=f"payment:{p.id}", ip=ctx.ip,
           detail={"reason": p.note, "txn": p.txn_code})
    db.commit()
    bg.add_task(_tell_user, p.user_id, "We couldn't confirm your payment",
                p.note or f"Code {p.txn_code} didn't match a payment — "
                          "check it and send it again.")
    return {"ok": True, "payment": billing.payment_dict(p, db)}


# ── Subscribers: grant / extend / revoke ────────────────────────────────────

@router.get("/subscribers")
def subscribers(q: str = "", show: str = "live",
                ctx: AdminCtx = Depends(admin_ctx),
                db: Session = Depends(get_db)):
    billing.ensure_seed(db)
    t = billing.now()
    query = db.query(Entitlement)
    if show == "live":
        query = query.filter(Entitlement.revoked_at.is_(None),
                             or_(Entitlement.ends_at.is_(None),
                                 Entitlement.ends_at > t))
    rows = query.order_by(Entitlement.created_at.desc()).limit(400).all()
    out = [_ent_dict(db, e) for e in rows]
    qq = q.strip().lower()
    if qq:
        out = [x for x in out
               if qq in (x["username"] or "").lower()
               or qq in (x["pair"] or "").lower()]
    return {"entitlements": out}


@router.get("/users/{user_id}/bonds")
def user_bonds(user_id: int, ctx: AdminCtx = Depends(admin_ctx),
               db: Session = Depends(get_db)):
    """The person's 1:1 Our Space partners — the pairs a pair plan can go to."""
    from bonding import pair_key
    from models import RelationshipSpace
    out, seen = [], set()
    for sp in (db.query(RelationshipSpace)
               .filter(RelationshipSpace.owner_id == user_id).all()):
        others = [m.user_id for m in sp.members if m.user_id != user_id]
        if len(others) != 1 or others[0] in seen:
            continue
        seen.add(others[0])
        pk = pair_key(user_id, others[0])
        end = billing.until(db, "space_plus", pair_key=pk)
        out.append({"partner_id": others[0],
                    "partner": _uname(db, others[0]),
                    "pair_key": pk,
                    "space_plus_until": None if end is None
                    else billing.iso(end)})
    return {"bonds": out}


class GrantIn(BaseModel):
    password: str
    plan_code: str
    months: int = 1
    user_id: int
    partner_id: Optional[int] = None   # pair plans
    note: Optional[str] = None


@router.post("/grant")
def grant(payload: GrantIn, bg: BackgroundTasks,
          ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    """Give (or add to) a plan for free — a gift, a refund, a tester."""
    _guard(ctx, payload.password)
    plan = billing.plan(db, payload.plan_code)
    if plan is None:
        raise HTTPException(404, "No such plan")
    if not db.query(User.id).filter(User.id == payload.user_id).first():
        raise HTTPException(404, "No such user")
    months = max(1, min(int(payload.months), 24))
    if plan.scope == "pair":
        if not payload.partner_id:
            raise HTTPException(400, "Choose the pair (their partner)")
        from bonding import pair_key
        who = {"pair_key": pair_key(payload.user_id, payload.partner_id)}
    else:
        who = {"user_id": payload.user_id}
    e = billing.extend(db, plan.code, months, source="admin",
                       granted_by=ctx.user.id,
                       note=(payload.note or "").strip()[:200] or None, **who)
    _audit(db, "plan_granted", user_id=ctx.user.id, device_id=ctx.device.id,
           target=f"user:{payload.user_id}", ip=ctx.ip,
           detail={"plan": plan.code, "months": months, **who,
                   "note": e.note})
    db.commit()
    targets = ([payload.user_id] if plan.scope == "person"
               else _pair_users(who["pair_key"]))
    for uid in targets:
        bg.add_task(_tell_user, uid, f"{plan.name} is on 💛",
                    "A gift from Aluta — enjoy!")
    return {"ok": True, "entitlement": _ent_dict(db, e)}


class EntActIn(BaseModel):
    password: str
    months: int = 1


def _ent(db: Session, eid: int) -> Entitlement:
    e = db.query(Entitlement).filter(Entitlement.id == eid).first()
    if not e:
        raise HTTPException(404, "No such plan record")
    return e


@router.post("/entitlements/{eid}/extend")
def extend_ent(eid: int, payload: EntActIn, bg: BackgroundTasks,
               ctx: AdminCtx = Depends(admin_ctx),
               db: Session = Depends(get_db)):
    _guard(ctx, payload.password)
    old = _ent(db, eid)
    months = max(1, min(int(payload.months), 24))
    who = ({"pair_key": old.pair_key} if old.pair_key
           else {"user_id": old.user_id})
    e = billing.extend(db, old.plan_code, months, source="admin",
                       granted_by=ctx.user.id, note="extended", **who)
    _audit(db, "plan_extended", user_id=ctx.user.id, device_id=ctx.device.id,
           target=f"entitlement:{eid}", ip=ctx.ip,
           detail={"months": months, **who})
    db.commit()
    for uid in ([old.user_id] if old.user_id else _pair_users(old.pair_key)):
        bg.add_task(_tell_user, uid, "Your plan was extended 💛", "")
    return {"ok": True, "entitlement": _ent_dict(db, e)}


@router.post("/entitlements/{eid}/revoke")
def revoke_ent(eid: int, payload: EntActIn, bg: BackgroundTasks,
               ctx: AdminCtx = Depends(admin_ctx),
               db: Session = Depends(get_db)):
    """End the plan now (this and any paid-ahead stretch). Nothing the
    person made is deleted — they're simply on the free rules again."""
    _guard(ctx, payload.password)
    old = _ent(db, eid)
    who = ({"pair_key": old.pair_key} if old.pair_key
           else {"user_id": old.user_id})
    n = billing.revoke(db, old.plan_code, **who)
    _audit(db, "plan_revoked", user_id=ctx.user.id, device_id=ctx.device.id,
           target=f"entitlement:{eid}", ip=ctx.ip,
           detail={"rows": n, **who})
    db.commit()
    for uid in ([old.user_id] if old.user_id else _pair_users(old.pair_key)):
        bg.add_task(_tell_user, uid, "Your plan has ended",
                    "Everything you made is safe.")
    return {"ok": True, "revoked": n}


# ── Catalog & where to pay ──────────────────────────────────────────────────

@router.get("/plans")
def plans(ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    billing.ensure_seed(db)
    rows = db.query(BillingPlan).order_by(BillingPlan.sort).all()
    return {"plans": [billing.plan_dict(p) for p in rows],
            "settings": billing.settings_dict(billing.settings(db))}


class PlanIn(BaseModel):
    password: str
    name: Optional[str] = None
    price_tzs: Optional[int] = None
    year_months: Optional[int] = None
    space_mb: Optional[int] = None
    active: Optional[bool] = None


@router.post("/plans/{code}")
def edit_plan(code: str, payload: PlanIn, ctx: AdminCtx = Depends(admin_ctx),
              db: Session = Depends(get_db)):
    """Change a plan's price / length deal / storage. Only new payments use
    the new price; anyone already paid keeps what they paid for."""
    _guard(ctx, payload.password)
    p = billing.plan(db, code)
    if p is None:
        raise HTTPException(404, "No such plan")
    before = billing.plan_dict(p)
    if payload.name is not None and payload.name.strip():
        p.name = payload.name.strip()[:60]
    if payload.price_tzs is not None:
        if not 0 <= payload.price_tzs <= 10_000_000:
            raise HTTPException(400, "Price looks wrong")
        p.price_tzs = int(payload.price_tzs)
    if payload.year_months is not None:
        if not 1 <= payload.year_months <= 12:
            raise HTTPException(400, "12 months must cost 1–12 months' price")
        p.year_months = int(payload.year_months)
    if payload.space_mb is not None and p.code == "space_plus":
        if not billing.FREE_SPACE_MB < payload.space_mb <= 100_000:
            raise HTTPException(400, "Storage must be above the free "
                                     f"{billing.FREE_SPACE_MB} MB")
        p.space_mb = int(payload.space_mb)
    if payload.active is not None:
        p.active = bool(payload.active)
    _audit(db, "plan_edited", user_id=ctx.user.id, device_id=ctx.device.id,
           target=f"plan:{code}", ip=ctx.ip,
           detail={"before": before, "after": billing.plan_dict(p)})
    db.commit()
    return {"ok": True, "plan": billing.plan_dict(p)}


class SettingsIn(BaseModel):
    password: str
    pay_network: Optional[str] = None
    pay_number: Optional[str] = None
    pay_name: Optional[str] = None
    instructions: Optional[str] = None


@router.post("/settings")
def edit_settings(payload: SettingsIn, ctx: AdminCtx = Depends(admin_ctx),
                  db: Session = Depends(get_db)):
    _guard(ctx, payload.password)
    st = billing.settings(db)
    for f in ("pay_network", "pay_number", "pay_name", "instructions"):
        v = getattr(payload, f)
        if v is not None:
            setattr(st, f, v.strip()[:500] or None)
    _audit(db, "pay_settings_edited", user_id=ctx.user.id,
           device_id=ctx.device.id, target="billing_settings", ip=ctx.ip,
           detail=billing.settings_dict(st))
    db.commit()
    return {"ok": True, "settings": billing.settings_dict(st)}
