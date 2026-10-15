"""Shared Ozilane Key identity helpers.

Used by BOTH auth.py (the two-step sign-in gate) and routers/ozilane.py. It
lives in its own module so neither of those has to import the other (which would
be a circular import).
"""
from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import HTTPException
from sqlalchemy.orm import Session

from models import User, OzkeyTrustedDevice
import ozilane_auth as oz

TRUST_DAYS = 30


def subject_for(db: Session, user: User) -> str:
    """The opaque per-user id sent to auth.ozilane.com — a random uuid created
    once and stored, so names/emails never leave Aluta."""
    if not user.ozkey_subject:
        user.ozkey_subject = f"aluta-{uuid.uuid4().hex}"
        db.commit()
    return user.ozkey_subject


def sync_linked(db: Session, user: User, enrolled: bool) -> None:
    """Keep the local linked-at cache in step with the service. Losing the link
    also turns off two-step (a phone that's gone can't approve)."""
    changed = False
    if enrolled and user.ozkey_linked_at is None:
        user.ozkey_linked_at = datetime.now(timezone.utc)
        changed = True
    elif not enrolled and user.ozkey_linked_at is not None:
        user.ozkey_linked_at = None
        user.ozkey_2fa_enabled = False
        changed = True
    if changed:
        db.commit()


def issue_trust(db: Session, user: User, label: Optional[str] = None) -> str:
    """Mint a 30-day trust token for this device; store only its hash."""
    raw = secrets.token_urlsafe(32)
    db.add(OzkeyTrustedDevice(
        user_id=user.id,
        token_hash=hashlib.sha256(raw.encode()).hexdigest(),
        label=label,
        expires_at=datetime.now(timezone.utc) + timedelta(days=TRUST_DAYS),
    ))
    db.commit()
    return raw


def is_trusted(db: Session, user: User, token: Optional[str]) -> bool:
    if not token:
        return False
    h = hashlib.sha256(token.encode()).hexdigest()
    rec = (
        db.query(OzkeyTrustedDevice)
        .filter(OzkeyTrustedDevice.user_id == user.id,
                OzkeyTrustedDevice.token_hash == h)
        .first()
    )
    if not rec:
        return False
    exp = rec.expires_at
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=timezone.utc)
    return exp > datetime.now(timezone.utc)


def maybe_two_step(db: Session, user: User, context: dict,
                   trust_token: Optional[str]) -> Optional[dict]:
    """After a correct password, decide whether a phone approval is required.
    Returns the challenge to relay to the app, or None to sign in now (two-step
    off, no phone linked, trusted device, service not configured, or the phone
    was unlinked on its side)."""
    if not (user.ozkey_2fa_enabled and user.ozkey_linked_at):
        return None
    if is_trusted(db, user, trust_token):
        return None
    if not oz.available():
        return None  # service not configured — never lock anyone out
    try:
        ch = oz.start_challenge(subject_for(db, user), context, "SIGN_IN")
    except oz.OzAuthError as e:
        if e.code in ("not_enrolled", "not_found", "no_phone"):
            sync_linked(db, user, False)  # phone gone — fall back to password
            return None
        if e.code in ("too_many", "rate_limited"):
            raise HTTPException(
                status_code=429,
                detail="Too many sign-in requests for this account. "
                       "Try again later.")
        raise HTTPException(
            status_code=503,
            detail="Your phone couldn't be asked to approve the sign-in. "
                   "Try again in a moment.")
    return {
        "challenge_id": ch.get("challengeId"),
        "match_number": ch.get("matchNumber"),
        "expires_at": ch.get("expiresAt"),
    }
