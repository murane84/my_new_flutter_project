"""Legal-consent (Privacy Policy + Terms of Use) endpoints.

The app checks ``GET /policy`` after sign-in; if ``needs_acceptance`` is true it
shows a blocking "read & agree" gate linking to the hosted docs, and calls
``POST /policy/accept`` once the user ticks and confirms. Consent is versioned
(see legal.py): bumping ``CURRENT_POLICY_VERSION`` re-prompts everyone on their
next launch.
"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from database import get_db
from models import User
from auth import get_current_user
import legal
import schemas

router = APIRouter(tags=["Policy"])


def _status(user: User) -> dict:
    accepted = int(getattr(user, "policy_version", 0) or 0)
    current = legal.CURRENT_POLICY_VERSION
    needs = accepted < current
    return {
        "current_version": current,
        "accepted_version": accepted,
        "needs_acceptance": needs,
        # An "update" (vs a first-time accept) is when they've accepted a prior
        # version — the client tailors the copy ("We've updated…" vs "Before you
        # continue…").
        "is_update": needs and accepted > 0,
        "effective_date": legal.POLICY_EFFECTIVE_DATE,
        "privacy_url": legal.PRIVACY_PATH,
        "terms_url": legal.TERMS_PATH,
        "summary": legal.summary_for(current) if needs else "",
    }


@router.get("/policy", response_model=schemas.PolicyStatusOut)
def get_policy(current_user: User = Depends(get_current_user)):
    """Whether the signed-in user must (re-)accept the current Privacy Policy +
    Terms, plus the doc URLs and a short 'what changed' summary."""
    return _status(current_user)


@router.post("/policy/accept", response_model=schemas.PolicyStatusOut)
def accept_policy(
    payload: schemas.PolicyAccept,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Record that the user has read and agreed to the CURRENT documents. The
    server always stamps its own CURRENT_POLICY_VERSION (never a client-supplied
    value) so a stale/forged version can't slip past a newer prompt."""
    current_user.policy_version = legal.CURRENT_POLICY_VERSION
    current_user.policy_accepted_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(current_user)
    return _status(current_user)
