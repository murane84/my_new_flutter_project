"""🔒 History hand-over when a computer is linked by QR (end-to-end encryption).

A newly linked computer can't open sealed messages sent before it existed —
the server only ever held copies sealed for the devices of that moment. So
the phone that scans the QR sends the texts it has unlocked, sealed to a
one-time key the computer made for this link:

  1. The computer shows the QR: its code ends with a fingerprint of its
     one-time X25519 public key (`seal_pub`, given to /auth/link/new).
  2. The phone approves (`handover: true`), gets `seal_pub` back, checks it
     against the fingerprint in the QR it scanned, seals its package to it
     and uploads it here (POST /e2ee/handover).
  3. The computer, now signed in with that link's session, collects the
     package ONCE (GET /e2ee/handover) and opens it locally.

The server stores ciphertext only, deletes it when collected, and forgets it
after WAIT either way. A typed pair code (nothing to check the key against)
or an older phone links as before, without history.
"""
import base64
import binascii
import hashlib
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Body, Depends, HTTPException
from jose import JWTError, jwt
from sqlalchemy.orm import Session

from auth import get_current_user, oauth2_scheme
from config import ALGORITHM, SECRET_KEY
from database import get_db
from models import LoginLink, User

router = APIRouter(prefix="/e2ee", tags=["E2EE"])

WAIT = timedelta(minutes=15)       # how long a package may wait
MAX_PACKAGE = 24 * 1024 * 1024     # base64 characters


def clean_pub(v):
    """A 32-byte X25519 public key in base64, else None."""
    if not v or not isinstance(v, str) or len(v) > 64:
        return None
    try:
        raw = base64.b64decode(v, validate=True)
    except (binascii.Error, ValueError):
        return None
    return v if len(raw) == 32 else None


def fingerprint(pub_b64: str) -> str:
    """First 16 bytes of SHA-256(public key), base64url without padding."""
    d = hashlib.sha256(base64.b64decode(pub_b64)).digest()[:16]
    return base64.urlsafe_b64encode(d).decode().rstrip("=")


def _now():
    return datetime.now(timezone.utc)


def _aware(dt):
    return dt.replace(tzinfo=timezone.utc) if dt and dt.tzinfo is None else dt


@router.post("/handover")
def put_handover(body: dict = Body(...), db: Session = Depends(get_db),
                 me: User = Depends(get_current_user)):
    """The phone that approved a QR link uploads its sealed package."""
    code = str((body or {}).get("code") or "")
    pkg = (body or {}).get("package")
    link = db.query(LoginLink).filter(LoginLink.code == code).first()
    if (link is None or link.user_id != me.id
            or link.handover_state != "wait"
            or _aware(link.expires_at) < _now()):
        raise HTTPException(status_code=404, detail="Nothing waiting")
    if pkg is None:
        # The phone had nothing to send (or gave up): stop the wait.
        link.handover_state = "none"
        db.commit()
        return {"ok": True}
    if not isinstance(pkg, str) or len(pkg) > MAX_PACKAGE:
        raise HTTPException(status_code=413, detail="Package too large")
    try:
        raw = base64.b64decode(pkg, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=400, detail="Bad package")
    if len(raw) < 2 + 32 + 12 + 16 or raw[0] != 1:
        raise HTTPException(status_code=400, detail="Bad package")
    link.handover = pkg
    link.handover_state = "ready"
    db.commit()
    return {"ok": True}


@router.get("/handover")
def get_handover(code: str, db: Session = Depends(get_db),
                 me: User = Depends(get_current_user),
                 token: str = Depends(oauth2_scheme)):
    """The linked computer collects its package, once."""
    link = db.query(LoginLink).filter(LoginLink.code == code).first()
    try:
        sid = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM]).get("sid")
    except JWTError:
        sid = None
    if link is None or link.user_id != me.id or not sid or link.sid != sid:
        return {"status": "none"}
    if link.handover_state == "ready":
        pkg = link.handover
        link.handover = None
        link.handover_state = "none"
        db.commit()
        return {"status": "ready", "package": pkg}
    if link.handover_state == "wait" and _aware(link.expires_at) >= _now():
        return {"status": "wait"}
    return {"status": "none"}
