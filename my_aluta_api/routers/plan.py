"""Monetization entitlement — the 'Aluta Together' plan.

Together unlocks multiple Our Spaces, forever history, and custom Space themes.
Real billing (Play Billing / Stripe) is NOT wired yet: the /plan/together toggle
is a dev/trial stand-in that a verified-purchase webhook will replace later. Every
gate in the app reads the plan_tier entitlement on the User row, so swapping in
real billing changes only how this field gets set — never the gating logic.
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from datetime import datetime, timezone

from database import get_db
from models import User
from auth import get_current_user

router = APIRouter(prefix="/plan", tags=["Plan"])

FREE_SPACE_CAP = 1
TOGETHER_SPACE_CAP = 8


def _payload(user: User) -> dict:
    tier = (user.plan_tier or "free")
    together = tier == "together"
    return {
        "tier": tier,
        "is_together": together,
        "together_since": user.together_since.isoformat()
        if user.together_since else None,
        "space_cap": TOGETHER_SPACE_CAP if together else FREE_SPACE_CAP,
        "benefits": {
            "multiple_spaces": together,
            "forever_history": together,
            "custom_themes": together,
        },
    }


@router.get("")
def get_plan(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return _payload(current_user)


@router.post("/together")
def start_together(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """DEV/TRIAL: flip the account to Together. Replaced by a verified purchase
    webhook once real billing lands."""
    current_user.plan_tier = "together"
    if current_user.together_since is None:
        current_user.together_since = datetime.now(timezone.utc)
    db.commit()
    db.refresh(current_user)
    return _payload(current_user)


@router.post("/free")
def end_together(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Revert to the free plan (for testing the gates)."""
    current_user.plan_tier = "free"
    db.commit()
    db.refresh(current_user)
    return _payload(current_user)
