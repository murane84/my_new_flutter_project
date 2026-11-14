"""Subscriptions (Admin Phase 4): the plan catalog, who has what, and payments.

Two plans at launch:
  • together   — per person: several Our Spaces, forever history, themes.
  • space_plus — per pair (pair_key "lo:hi"): a bigger Our Space.

A paid stretch is an Entitlement [starts_at, ends_at). Renewing appends a new
row that starts where the last one ends, so paying early never loses days.
A lapse NEVER deletes: every gate simply falls back to the free rules — the
extra Spaces and anything over the free storage stay, read-only, until renewed.

Payments: the person pays the owner's mobile-money number and types the
transaction code in the app → a pending Payment; the owner checks their phone
and confirms it in the admin panel → the entitlement starts / extends.
"""
from __future__ import annotations

import calendar
import os
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import or_
from sqlalchemy.orm import Session, object_session

from models import (BillingPlan, BillingSettings, Entitlement, Payment,
                    PlanLimit, UsageCounter, User)

FREE_SPACE_MB = int(os.environ.get("SPACE_CAP_MB", "150"))

# First-run catalog; prices and the rest are edited in the admin panel.
DEFAULT_PLANS = [
    dict(code="together", name="Aluta Together", scope="person",
         price_tzs=3000, year_months=10, space_mb=None, sort=0),
    dict(code="space_plus", name="Bigger Our Space", scope="pair",
         price_tzs=5000, year_months=10, space_mb=1024, sort=2),
    dict(code="together_plus", name="Together Plus", scope="person",
         price_tzs=7000, year_months=10, space_mb=None, sort=1),
]

# ── Limits: every section is open to everyone, with a light free amount ─────
# Paid levels raise them (one bundle: Together, then Together Plus). Values are
# edited in the admin panel (plan_limits); these fill any gap. -1 = unlimited.
UNLIMITED = -1
HARD_FILE_MB = 200   # what the server can hold per file today
METERS = [
    dict(key="spaces", label="Our Spaces you can pin", unit="bonds"),
    dict(key="room_size", label="People in a Listen Together room",
         unit="people"),
    dict(key="file_mb", label="Largest file or video you send", unit="MB"),
    dict(key="call_minutes", label="Length of a call (1:1 and group)",
         unit="min"),
    dict(key="recognize_day", label="Song recognitions a day", unit="a day"),
]
LEVELS = ["free", "together", "together_plus"]
DEFAULT_LIMITS = {
    "free": {"spaces": 2, "room_size": 5, "file_mb": 50, "call_minutes": 10,
             "recognize_day": 5},
    "together": {"spaces": 8, "room_size": 25, "file_mb": 200,
                 "call_minutes": 60, "recognize_day": 30},
    "together_plus": {"spaces": 20, "room_size": 50, "file_mb": 200,
                      "call_minutes": UNLIMITED, "recognize_day": 100},
}

LEGACY_DAYS = 30  # testers flipped to Together by the old toggle keep it this long
TXN_RE = re.compile(r"^[A-Z0-9]{6,20}$")


def now() -> datetime:
    return datetime.now(timezone.utc)


def aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def iso(dt: Optional[datetime]) -> Optional[str]:
    dt = aware(dt)
    return dt.isoformat() if dt else None


def add_months(dt: datetime, months: int) -> datetime:
    m = dt.month - 1 + months
    y = dt.year + m // 12
    m = m % 12 + 1
    d = min(dt.day, calendar.monthrange(y, m)[1])
    return dt.replace(year=y, month=m, day=d)


# ── Catalog ─────────────────────────────────────────────────────────────────

_seeded = False


def ensure_seed(db: Session) -> None:
    """Create the default plans / settings row once, and carry over people the
    old trial toggle put on Together (a LEGACY_DAYS grace, then the normal
    rules)."""
    global _seeded
    if _seeded:
        return
    have = {p.code for p in db.query(BillingPlan).all()}
    for d in DEFAULT_PLANS:
        if d["code"] not in have:
            db.add(BillingPlan(active=True, **d))
    if db.query(BillingSettings).filter(BillingSettings.id == 1).first() is None:
        db.add(BillingSettings(id=1, pay_network="M-Pesa", sandbox=True))
    db.flush()
    t = now()
    legacy = (db.query(User).filter(User.plan_tier == "together").all())
    for u in legacy:
        any_ent = (db.query(Entitlement.id)
                   .filter(Entitlement.user_id == u.id,
                           Entitlement.plan_code == "together").first())
        if any_ent is None:
            db.add(Entitlement(plan_code="together", user_id=u.id,
                               starts_at=t,
                               ends_at=t + timedelta(days=LEGACY_DAYS),
                               source="legacy",
                               note="Carried over from the trial toggle"))
    db.commit()
    _seeded = True


def plan(db: Session, code: str) -> Optional[BillingPlan]:
    ensure_seed(db)
    return db.query(BillingPlan).filter(BillingPlan.code == code).first()


def price_for(p: BillingPlan, months: int) -> int:
    if months == 12:
        return int(p.price_tzs) * int(p.year_months or 12)
    return int(p.price_tzs) * int(months)


def plan_dict(p: BillingPlan) -> dict:
    return {
        "code": p.code, "name": p.name, "scope": p.scope,
        "price_tzs": int(p.price_tzs), "year_months": int(p.year_months or 12),
        "year_price_tzs": price_for(p, 12), "space_mb": p.space_mb,
        "active": bool(p.active), "sort": int(p.sort or 0),
    }


def settings(db: Session) -> BillingSettings:
    ensure_seed(db)
    return db.query(BillingSettings).filter(BillingSettings.id == 1).first()


def settings_dict(st: BillingSettings) -> dict:
    return {"sandbox": st.sandbox is not False,
            "pay_network": st.pay_network or "M-Pesa",
            "pay_number": st.pay_number or "",
            "pay_name": st.pay_name or "",
            "instructions": st.instructions or ""}


# ── Who has what ────────────────────────────────────────────────────────────

def _live(q, at: Optional[datetime] = None):
    t = at or now()
    return q.filter(Entitlement.revoked_at.is_(None),
                    Entitlement.starts_at <= t,
                    or_(Entitlement.ends_at.is_(None), Entitlement.ends_at > t))


def _target(q, user_id=None, pair_key=None):
    if pair_key is not None:
        return q.filter(Entitlement.pair_key == pair_key)
    return q.filter(Entitlement.user_id == user_id)


def until(db: Session, code: str, *, user_id=None, pair_key=None
          ) -> Optional[datetime]:
    """When this plan runs out for the person / pair, counting renewals that
    are already paid (None = not active now). A never-ending grant returns
    datetime.max."""
    ensure_seed(db)
    if user_id is None and pair_key is None:
        return None
    base = _target(db.query(Entitlement)
                   .filter(Entitlement.plan_code == code,
                           Entitlement.revoked_at.is_(None)),
                   user_id, pair_key)
    if _live(base).first() is None:
        return None
    end = now()
    rows = base.order_by(Entitlement.starts_at).all()
    for e in rows:
        if e.ends_at is None:
            return datetime.max.replace(tzinfo=timezone.utc)
        s, f = aware(e.starts_at), aware(e.ends_at)
        if s <= end + timedelta(minutes=1) and f > end:
            end = f
    return end


def has(db: Session, code: str, *, user_id=None, pair_key=None) -> bool:
    return until(db, code, user_id=user_id, pair_key=pair_key) is not None


def level_of(user: User, db: Optional[Session] = None) -> str:
    """'free' | 'together' | 'together_plus' — which limits apply."""
    db = db or object_session(user)
    if db is None:
        return "together" if (user.plan_tier or "free") == "together" else "free"
    if has(db, "together_plus", user_id=user.id):
        return "together_plus"
    if has(db, "together", user_id=user.id):
        return "together"
    return "free"


def tier_of(user: User, db: Optional[Session] = None) -> str:
    """'together' (Together or Together Plus) | 'free' for the older gates.
    Keeps users.plan_tier in step as a cache."""
    db = db or object_session(user)
    if db is None:
        return getattr(user, "plan_tier", None) or "free"
    t = "free" if level_of(user, db) == "free" else "together"
    if (user.plan_tier or "free") != t:
        user.plan_tier = t
        try:
            db.flush()
        except Exception:
            pass
    return t


def space_cap_bytes(db: Session, pair_key: Optional[str]) -> int:
    base = FREE_SPACE_MB * 1024 * 1024
    if not pair_key or not has(db, "space_plus", pair_key=pair_key):
        return base
    p = plan(db, "space_plus")
    mb = int((p.space_mb if p else None) or FREE_SPACE_MB)
    return max(base, mb * 1024 * 1024)


def extend(db: Session, code: str, months: int, *, user_id=None,
           pair_key=None, source="admin", payment_id=None, granted_by=None,
           note=None) -> Entitlement:
    """Add [months] to the person / pair, starting where their current
    stretch ends (or now)."""
    start = until(db, code, user_id=user_id, pair_key=pair_key) or now()
    if start.year >= 9999:   # a never-ending grant: nothing to add
        start = now()
    e = Entitlement(plan_code=code, user_id=user_id, pair_key=pair_key,
                    starts_at=start, ends_at=add_months(start, int(months)),
                    source=source, payment_id=payment_id,
                    granted_by=granted_by, note=note)
    db.add(e)
    db.flush()
    return e


def revoke(db: Session, code: str, *, user_id=None, pair_key=None) -> int:
    rows = _target(db.query(Entitlement)
                   .filter(Entitlement.plan_code == code,
                           Entitlement.revoked_at.is_(None)),
                   user_id, pair_key).all()
    t = now()
    n = 0
    for e in rows:
        if e.ends_at is None or aware(e.ends_at) > t:
            e.revoked_at = t
            n += 1
    db.flush()
    return n


def norm_txn(code: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "", code or "").upper()


def payment_dict(p: Payment, db: Session) -> dict:
    u = db.query(User).filter(User.id == p.user_id).first()
    partner = (db.query(User).filter(User.id == p.partner_id).first()
               if p.partner_id else None)
    return {
        "id": p.id, "user_id": p.user_id,
        "username": u.username if u else None,
        "plan_code": p.plan_code, "months": p.months,
        "amount_tzs": p.amount_tzs, "network": p.network,
        "txn_code": p.txn_code, "payer_phone": p.payer_phone,
        "pair_key": p.pair_key, "partner_id": p.partner_id,
        "partner_username": partner.username if partner else None,
        "status": p.status, "note": p.note,
        "sandbox": bool(p.sandbox),
        "created_at": iso(p.created_at), "decided_at": iso(p.decided_at),
    }


# ── Limits ──────────────────────────────────────────────────────────────────

def limits_table(db: Session) -> dict:
    """{level: {meter: value}} — defaults overlaid with the admin's edits."""
    out = {lv: dict(DEFAULT_LIMITS[lv]) for lv in LEVELS}
    for r in db.query(PlanLimit).all():
        if r.plan_code in out:
            out[r.plan_code][r.meter] = int(r.value)
    return out


def limit(db: Session, user: User, meter: str) -> int:
    """This person's amount of [meter] (-1 = unlimited)."""
    lv = level_of(user, db)
    v = limits_table(db).get(lv, {}).get(meter)
    if v is None:
        v = DEFAULT_LIMITS["free"].get(meter, 0)
    if meter == "file_mb" and (v == UNLIMITED or v > HARD_FILE_MB):
        v = HARD_FILE_MB
    return int(v)


def my_limits(db: Session, user: User) -> dict:
    return {m["key"]: limit(db, user, m["key"]) for m in METERS}


def set_limit(db: Session, level: str, meter: str, value: int) -> None:
    r = (db.query(PlanLimit)
         .filter(PlanLimit.plan_code == level, PlanLimit.meter == meter).first())
    if r is None:
        db.add(PlanLimit(plan_code=level, meter=meter, value=int(value)))
    else:
        r.value = int(value)
    db.flush()


def use_daily(db: Session, user: User, meter: str) -> tuple:
    """Count one use of a daily meter. Returns (allowed, used, limit) — when
    not allowed nothing is counted."""
    cap = limit(db, user, meter)
    today = now().date()
    row = (db.query(UsageCounter)
           .filter(UsageCounter.user_id == user.id,
                   UsageCounter.meter == meter,
                   UsageCounter.day == today).first())
    used = int(row.count) if row else 0
    if cap != UNLIMITED and used >= cap:
        return False, used, cap
    if row is None:
        db.add(UsageCounter(user_id=user.id, meter=meter, day=today, count=1))
    else:
        row.count = used + 1
    db.commit()
    return True, used + 1, cap


def upgrade_hint(db: Session, user: User) -> str:
    lv = level_of(user, db)
    if lv == "free":
        return "Aluta Together gives you more."
    if lv == "together":
        return "Together Plus gives you more."
    return ""
