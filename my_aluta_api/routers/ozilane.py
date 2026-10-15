"""Ozilane Key (auth.ozilane.com) integration for Aluta.

A user links their Ozilane Key phone (once), then can recover a forgotten
password OR sign in with no password at all by approving on the phone — the
"type the match number" flow — with the phone's offline TOTP code and paper
backup codes as the no-signal fallbacks. No email or SMS is involved, so this
path keeps working even when the mail provider is down or out of credit.

Aluta is a *client platform*: every call is server-to-server to
auth.ozilane.com with the Bearer client credential. The user is represented
there only by an opaque subject, "aluta-<id>".
"""
from __future__ import annotations

import re
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.orm import Session

from database import get_db
from models import User
from auth import (
    get_current_user,
    get_password_hash,
    create_tokens,
    get_user_by_email,
)
import ozilane_auth as oz

router = APIRouter(prefix="/auth/ozilane", tags=["Ozilane"])

_GENERIC_START = (
    "Couldn't start a phone approval. Check the details and make sure "
    "Ozilane Key is linked to this account."
)


def _subject(user: User) -> str:
    return f"aluta-{user.id}"


def _user_from_subject(db: Session, subject: str) -> User | None:
    if not subject or not subject.startswith("aluta-"):
        return None
    try:
        uid = int(subject.split("-", 1)[1])
    except (ValueError, IndexError):
        return None
    return db.query(User).filter(User.id == uid).first()


def _label(user: User) -> str:
    # A short, non-PII tag. The service refuses anything that looks like an
    # email or phone number, so sanitise the username to a safe handle.
    raw = (user.username or "").strip()
    safe = re.sub(r"[^A-Za-z0-9._:-]", "", raw)[:24]
    if not safe or "@" in raw or re.search(r"\d{6,}", safe):
        safe = f"aluta-{user.id}"
    return safe


def _resolve(db: Session, identifier: str) -> User | None:
    ident = (identifier or "").strip()
    if not ident:
        return None
    u = get_user_by_email(db, ident)
    if u:
        return u
    u = db.query(User).filter(User.username == ident).first()
    if u:
        return u
    return db.query(User).filter(User.phone == ident).first()


def _context(request: Request) -> dict:
    ctx: dict = {}
    ip = request.client.host if request.client else None
    ua = request.headers.get("user-agent")
    if ip:
        ctx["ip"] = ip
    if ua:
        ctx["userAgent"] = ua[:200]
    return ctx


def _set_password(db: Session, user: User, new_password: str) -> None:
    if len(new_password or "") < 6:
        raise HTTPException(status_code=400,
                            detail="New password must be at least 6 characters.")
    user.hashed_password = get_password_hash(new_password)
    user.refresh_token = None  # kick any lingering sessions
    db.commit()


def _start(db: Session, identifier: str, request: Request, purpose: str) -> dict:
    user = _resolve(db, identifier)
    if not user:
        raise HTTPException(status_code=400, detail=_GENERIC_START)
    try:
        ch = oz.start_challenge(_subject(user), _context(request), purpose)
    except oz.OzAuthError as e:
        if e.code in ("not_enrolled", "not_found", "no_phone"):
            raise HTTPException(status_code=400, detail=_GENERIC_START)
        raise HTTPException(status_code=502, detail=e.message)
    return {
        "challenge_id": ch.get("challengeId"),
        "match_number": ch.get("matchNumber"),
        "expires_at": ch.get("expiresAt"),
    }


# ── request bodies ─────────────────────────────────────────────────────────
class LinkStart(BaseModel):
    # A backup code proves ownership when re-linking an account that had a phone.
    backup_code: str | None = None


class Identifier(BaseModel):
    identifier: str


class ApprovalConfirm(BaseModel):
    challenge_id: str
    new_password: str


class CodeReset(BaseModel):
    identifier: str
    code: str
    new_password: str


class ChallengeOnly(BaseModel):
    challenge_id: str


# ── availability (public — lets the sign-in/recovery screens show the UI) ──
@router.get("/available")
def ozilane_available():
    return {"available": oz.available()}


# ── link management (signed-in user) ───────────────────────────────────────
@router.get("/status")
def ozilane_status(current_user: User = Depends(get_current_user)):
    if not oz.available():
        return {"configured": False, "enrolled": False}
    try:
        info = oz.subject_info(_subject(current_user))
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)
    info["configured"] = True
    return info


@router.post("/link/start")
def ozilane_link_start(payload: LinkStart,
                       current_user: User = Depends(get_current_user)):
    authorization = (
        {"backupCode": payload.backup_code.strip()}
        if payload.backup_code and payload.backup_code.strip()
        else None
    )
    try:
        return oz.start_enrollment(_subject(current_user),
                                   _label(current_user), authorization)
    except oz.OzAuthError as e:
        if e.code == "proof_required":
            raise HTTPException(
                status_code=409,
                detail="This account already had a phone. Enter a backup code, "
                       "or use account recovery to link a new phone.",
            )
        raise HTTPException(status_code=502, detail=e.message)


@router.get("/link/status")
def ozilane_link_status(enrollment_id: str = Query(...),
                        current_user: User = Depends(get_current_user)):
    try:
        return oz.enrollment_status(enrollment_id)
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)


@router.delete("/link")
def ozilane_unlink(current_user: User = Depends(get_current_user)):
    try:
        return oz.revoke(_subject(current_user))
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)


# ── password recovery via phone approval ───────────────────────────────────
@router.post("/recover/start")
def oz_recover_start(payload: Identifier, request: Request,
                     db: Session = Depends(get_db)):
    return _start(db, payload.identifier, request, "PASSWORD_RESET")


@router.get("/recover/status")
def oz_recover_status(challenge_id: str = Query(...)):
    try:
        st = oz.challenge_status(challenge_id)
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)
    return {"status": st.get("status"), "deny_reason": st.get("denyReason")}


@router.post("/recover/confirm")
def oz_recover_confirm(payload: ApprovalConfirm,
                       db: Session = Depends(get_db)):
    try:
        res = oz.consume(payload.challenge_id)
    except oz.OzAuthError:
        raise HTTPException(
            status_code=400,
            detail="This approval can't be used. Approve again on your phone "
                   "and retry.",
        )
    if res.get("purpose") != "PASSWORD_RESET":
        raise HTTPException(status_code=400,
                            detail="This approval wasn't for a password reset.")
    user = _user_from_subject(db, str(res.get("subject", "")))
    if not user:
        raise HTTPException(status_code=400,
                            detail="Account not found for this approval.")
    _set_password(db, user, payload.new_password)
    return {"message": "Password updated. Sign in with your new password.",
            "email": user.email}


# ── phone-less fallbacks ───────────────────────────────────────────────────
@router.post("/recover/totp")
def oz_recover_totp(payload: CodeReset, db: Session = Depends(get_db)):
    user = _resolve(db, payload.identifier)
    generic = HTTPException(status_code=400, detail="Invalid or expired code.")
    if not user:
        raise generic
    try:
        res = oz.verify_code(_subject(user), payload.code.strip())
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)
    if not res.get("ok"):
        locked = res.get("lockedMinutes")
        if locked:
            raise HTTPException(status_code=429,
                                detail=f"Too many tries. Locked for {locked} "
                                       f"minutes.")
        raise generic
    _set_password(db, user, payload.new_password)
    return {"message": "Password updated. Sign in with your new password.",
            "email": user.email}


@router.post("/recover/backup")
def oz_recover_backup(payload: CodeReset, db: Session = Depends(get_db)):
    user = _resolve(db, payload.identifier)
    generic = HTTPException(status_code=400, detail="Invalid backup code.")
    if not user:
        raise generic
    try:
        res = oz.verify_backup_code(_subject(user), payload.code.strip())
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)
    if not res.get("ok"):
        raise generic
    _set_password(db, user, payload.new_password)
    return {"message": "Password updated. Sign in with your new password.",
            "email": user.email, "backup_codes_left": res.get("remaining")}


# ── passwordless sign-in (approve on phone → tokens) ───────────────────────
@router.post("/signin/start")
def oz_signin_start(payload: Identifier, request: Request,
                    db: Session = Depends(get_db)):
    return _start(db, payload.identifier, request, "SIGN_IN")


@router.get("/signin/status")
def oz_signin_status(challenge_id: str = Query(...)):
    try:
        st = oz.challenge_status(challenge_id)
    except oz.OzAuthError as e:
        raise HTTPException(status_code=502, detail=e.message)
    return {"status": st.get("status"), "deny_reason": st.get("denyReason")}


@router.post("/signin/complete")
def oz_signin_complete(payload: ChallengeOnly, db: Session = Depends(get_db)):
    try:
        res = oz.consume(payload.challenge_id)
    except oz.OzAuthError:
        raise HTTPException(
            status_code=400,
            detail="This approval can't be used. Approve again on your phone "
                   "and retry.",
        )
    if res.get("purpose") != "SIGN_IN":
        raise HTTPException(status_code=400,
                            detail="This approval wasn't for sign-in.")
    user = _user_from_subject(db, str(res.get("subject", "")))
    if not user:
        raise HTTPException(status_code=400,
                            detail="Account not found for this approval.")
    user.is_online = True
    user.last_login = datetime.now(timezone.utc)
    access_token, refresh_token = create_tokens(user.email)
    user.refresh_token = refresh_token
    db.commit()
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer",
        "email": user.email,
        "username": user.username,
        "last_login": user.last_login.isoformat(),
    }
