"""Aluta Admin (backoffice) API — /admin/api/*.

Security model (see claude/admin-panel-plan.md, "Device authorization"):

* Only accounts listed in ADMIN_OWNER_EMAILS can use the admin panel at all.
* Admin access = the owner's Aluta password + an APPROVED DEVICE. Each admin
  browser creates a non-extractable ECDSA P-256 key (WebCrypto); the server keeps
  only the public half (AdminDevice). A leaked password alone only ever produces
  a *pending* device request — and an alert to the owner.
* A pending device is approved ONLY from an already-trusted device, by typing
  the 6-character pairing code the new device shows + re-entering the password.
  Approved devices are read-only (probation) for 24 h.
* Every admin request is signed by the device key over
  METHOD\\nPATH\\nTS\\nNONCE\\nSHA256(BODY); stale (>60 s) or replayed requests
  are refused, so a stolen admin session token is useless elsewhere.
* Admin sessions are separate from Aluta app logins: 15 min idle, 8 h max.
* 5 wrong passwords → 15 min lock; 3 locks in 24 h → frozen. "Not me — lock
  admin" (from a device or the alert email) freezes admin + ends every session;
  only a NEW Aluta password, signed in from a trusted device, lifts it.
* The very first device enrolls with the one-time ADMIN_BOOTSTRAP_CODE (burned
  on use) and receives 10 recovery codes. A recovery code enrolls a device after
  a 72 h delay, alerting the owner throughout.
* Every step is written to admin_audit_log.

Single-replica by design (in-memory nonce/challenge caches), like the WS
manager. Multi-replica would move those to Redis.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from jose import JWTError, jwt
from pydantic import BaseModel
from sqlalchemy import func as sa_func, text
from sqlalchemy.orm import Session

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from config import SECRET_KEY, ALGORITHM
from database import get_db
from models import (
    AdminAuditLog, AdminDevice, AdminRecoveryCode, AdminSession, AdminState,
    User,
)

router = APIRouter(prefix="/admin/api", tags=["Admin"])

# ── Tunables ────────────────────────────────────────────────────────────────
SIG_WINDOW_S = 60
SESSION_IDLE = timedelta(minutes=15)
SESSION_MAX = timedelta(hours=8)
PAIR_TTL = timedelta(minutes=10)
PAIR_MAX_ATTEMPTS = 3
PROBATION = timedelta(hours=24)
DEVICE_EXPIRY = timedelta(days=30)
RECOVERY_DELAY = timedelta(hours=72)
FAIL_LIMIT = 5
FAIL_WINDOW = timedelta(minutes=15)
LOCK_FOR = timedelta(minutes=15)
LOCKOUTS_TO_FREEZE = 3
LOCKOUT_WINDOW = timedelta(hours=24)
RECOVERY_CODE_COUNT = 10

_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O/1/I/L


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    dt = _aware(dt)
    return dt.isoformat() if dt else None


def _owner_emails() -> set:
    raw = os.getenv("ADMIN_OWNER_EMAILS", "")
    return {e.strip().lower() for e in raw.split(",") if e.strip()}


def _public_base() -> str:
    return os.getenv("PUBLIC_BASE_URL", "https://aluta.ozilane.com").rstrip("/")


def _h(value: str) -> str:
    """Keyed hash for codes/tokens at rest (never stored in clear)."""
    return hmac.new(SECRET_KEY.encode(), value.encode(), hashlib.sha256).hexdigest()


def _norm_code(code: str) -> str:
    return "".join(ch for ch in (code or "").upper() if ch.isalnum())


def _gen_code(n: int) -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(n))


def _pw_fp(user: User) -> str:
    return hashlib.sha256((user.hashed_password or "").encode()).hexdigest()[:24]


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()[:64]
    return (request.client.host if request.client else "")[:64]


def _ua(request: Request) -> str:
    return (request.headers.get("user-agent") or "")[:300]


def _describe_ua(ua: str) -> str:
    """'Chrome on Windows' style label for alerts and the device list."""
    u = ua or ""
    browser = ("Edge" if "Edg/" in u else "Opera" if "OPR/" in u
               else "Chrome" if "Chrome/" in u else "Firefox" if "Firefox/" in u
               else "Safari" if "Safari/" in u else "Browser")
    osname = ("iPhone" if "iPhone" in u else "iPad" if "iPad" in u
              else "Android" if "Android" in u else "Windows" if "Windows" in u
              else "Mac" if "Macintosh" in u else "Linux" if "Linux" in u
              else "unknown OS")
    return f"{browser} on {osname}"


# ── Device keys & signatures ────────────────────────────────────────────────

def _load_key(spki_b64: str):
    try:
        der = base64.b64decode(spki_b64, validate=True)
        key = serialization.load_der_public_key(der)
    except Exception:
        raise HTTPException(400, "Bad device key")
    if not isinstance(key, ec.EllipticCurvePublicKey) or \
            not isinstance(key.curve, ec.SECP256R1):
        raise HTTPException(400, "Device key must be ECDSA P-256")
    return key, der


def _key_id(der: bytes) -> str:
    return hashlib.sha256(der).hexdigest()


def _verify(spki_b64: str, message: str, sig_b64: str) -> bool:
    """WebCrypto ECDSA signatures are raw r||s (64 bytes) — convert to DER."""
    try:
        key, _ = _load_key(spki_b64)
        raw = base64.b64decode(sig_b64, validate=True)
        if len(raw) != 64:
            return False
        r = int.from_bytes(raw[:32], "big")
        s = int.from_bytes(raw[32:], "big")
        key.verify(encode_dss_signature(r, s), message.encode(),
                   ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, HTTPException, ValueError):
        return False
    except Exception:
        return False


# In-memory replay guard + login challenges (single replica).
_lock = threading.Lock()
_seen_nonces: dict = {}      # nonce -> expiry epoch
_challenges: dict = {}       # challenge_id -> (device_id, nonce, expiry)


def _nonce_fresh(nonce: str) -> bool:
    now = time.time()
    with _lock:
        for k in [k for k, exp in _seen_nonces.items() if exp < now]:
            _seen_nonces.pop(k, None)
        if not nonce or len(nonce) > 100 or nonce in _seen_nonces:
            return False
        _seen_nonces[nonce] = now + SIG_WINDOW_S * 3
        return True


def _new_challenge(device_id: int) -> dict:
    cid = secrets.token_urlsafe(16)
    nonce = secrets.token_urlsafe(24)
    now = time.time()
    with _lock:
        for k in [k for k, v in _challenges.items() if v[2] < now]:
            _challenges.pop(k, None)
        _challenges[cid] = (device_id, nonce, now + 120)
    return {"challenge_id": cid, "nonce": nonce}


def _take_challenge(cid: str):
    with _lock:
        v = _challenges.pop(cid or "", None)
    if not v or v[2] < time.time():
        return None
    return v


# ── State, audit, alerts ────────────────────────────────────────────────────

def _state(db: Session, user_id: int) -> AdminState:
    st = db.query(AdminState).filter(AdminState.user_id == user_id).first()
    if not st:
        st = AdminState(user_id=user_id, bootstrap_used=False, fail_count=0,
                        lockouts=0)
        db.add(st)
        db.flush()
    return st


def _audit(db: Session, action: str, *, user_id=None, device_id=None,
           target=None, detail=None, ip=None, ok=True) -> None:
    db.add(AdminAuditLog(
        user_id=user_id, device_id=device_id, action=action,
        target=None if target is None else str(target)[:200],
        detail=None if detail is None else json.dumps(detail, default=str)[:4000],
        ip=ip, ok=ok,
    ))


def _lock_link(user: User) -> str:
    tok = jwt.encode({
        "sub": user.email, "typ": "admin_lock",
        "exp": _now() + timedelta(days=7),
    }, SECRET_KEY, algorithm=ALGORITHM)
    return f"{_public_base()}/admin/api/lock?t={tok}"


def _send_alert(user_id: int, email: str, username: str, lock_url: str,
                title: str, body: str) -> None:
    """Push to the owner's Aluta phones + email with a one-tap lock link.
    Best-effort: never raises (runs as a background task)."""
    try:
        from push import send_push_to_user
        send_push_to_user(user_id, {
            "type": "admin_alert",
            "title": f"🛡️ {title}",
            "body": f"{body} Not you? Use “Lock admin” in the alert email "
                    "or the admin panel.",
        })
    except Exception as e:  # noqa: BLE001
        print(f"[admin] alert push failed: {e}")
    try:
        from mailer import send_email
        html = (
            f"<p>Hi {username or ''},</p>"
            f"<p><b>{title}</b></p><p>{body}</p>"
            f"<p>Time: {_now().strftime('%Y-%m-%d %H:%M UTC')}</p>"
            "<p>If this wasn't you, lock the admin panel right away — it "
            "ends every admin session and blocks admin sign-in until you change "
            "your Aluta password:</p>"
            f'<p><a href="{lock_url}" style="background:#c62828;color:#fff;'
            'padding:10px 16px;border-radius:8px;text-decoration:none">'
            "Not me — lock admin</a></p>"
        )
        send_email(email, f"Aluta Admin: {title}", html,
                   text_body=f"{title}\n{body}\nNot you? Lock admin: {lock_url}",
                   to_name=username)
    except Exception as e:  # noqa: BLE001
        print(f"[admin] alert email failed: {e}")


def _alert(bg: BackgroundTasks, user: User, title: str, body: str) -> None:
    bg.add_task(_send_alert, user.id, user.email, user.username,
                _lock_link(user), title, body)


def _freeze(db: Session, user: User, reason: str, ip: str,
            device_id: Optional[int] = None) -> None:
    st = _state(db, user.id)
    st.frozen_at = _now()
    st.frozen_pw_fp = _pw_fp(user)
    db.query(AdminSession).filter(
        AdminSession.user_id == user.id, AdminSession.revoked.is_(False)
    ).update({"revoked": True}, synchronize_session=False)
    # Anything not fully trusted is shut out too.
    for d in db.query(AdminDevice).filter(AdminDevice.user_id == user.id).all():
        if d.status in ("pending", "recovering"):
            d.status = "denied"
            d.pair_code_hash = None
        elif d.status == "trusted" and d.probation_until and \
                _aware(d.probation_until) > _now():
            d.status = "revoked"
    _audit(db, "admin_frozen", user_id=user.id, device_id=device_id,
           detail={"reason": reason}, ip=ip)


def _is_frozen(st: AdminState) -> bool:
    return st.frozen_at is not None


# ── Login ───────────────────────────────────────────────────────────────────

class LoginIn(BaseModel):
    email: str
    password: str
    public_key: str
    device_name: Optional[str] = None
    bootstrap_code: Optional[str] = None
    recovery_code: Optional[str] = None


class VerifyIn(BaseModel):
    challenge_id: str
    signature: str


class PollIn(BaseModel):
    device_id: int
    ts: int
    signature: str


def _gen_recovery_codes(db: Session, user_id: int) -> list:
    db.query(AdminRecoveryCode).filter(
        AdminRecoveryCode.user_id == user_id,
        AdminRecoveryCode.used_at.is_(None),
    ).delete(synchronize_session=False)
    codes = []
    for _ in range(RECOVERY_CODE_COUNT):
        c = _gen_code(8)
        codes.append(f"{c[:4]}-{c[4:]}")
        db.add(AdminRecoveryCode(user_id=user_id, code_hash=_h(c)))
    return codes


def _device_out(d: AdminDevice, current_id: Optional[int] = None) -> dict:
    now = _now()
    prob = _aware(d.probation_until)
    return {
        "id": d.id,
        "name": d.name or _describe_ua(d.user_agent or ""),
        "browser": _describe_ua(d.user_agent or ""),
        "status": d.status,
        "on_probation": bool(d.status == "trusted" and prob and prob > now),
        "probation_until": _iso(prob),
        "activate_at": _iso(d.activate_at),
        "approved_at": _iso(d.approved_at),
        "approved_by": d.approved_by,
        "created_at": _iso(d.created_at),
        "last_used_at": _iso(d.last_used_at),
        "last_ip": d.last_ip,
        "request_ip": d.request_ip,
        "pair_expires_at": _iso(d.pair_expires_at),
        "is_this_device": current_id is not None and d.id == current_id,
    }


@router.post("/login")
def admin_login(payload: LoginIn, request: Request, bg: BackgroundTasks,
                db: Session = Depends(get_db)):
    ip, ua = _client_ip(request), _ua(request)
    email = (payload.email or "").strip().lower()
    user = db.query(User).filter(sa_func.lower(User.email) == email).first()
    is_owner = bool(user and email in _owner_emails())
    generic = HTTPException(401, "Invalid credentials")

    if not is_owner:
        # Same answer as a wrong password: never reveal who the owner is.
        _audit(db, "login_rejected", target=email, ip=ip, ok=False,
               detail={"why": "not an admin account"})
        db.commit()
        raise generic

    st = _state(db, user.id)
    now = _now()
    if st.locked_until and _aware(st.locked_until) > now:
        db.commit()
        raise HTTPException(
            429, f"Too many wrong passwords. Try again after "
                 f"{_aware(st.locked_until).strftime('%H:%M UTC')}.")

    from auth import verify_password
    if not verify_password(payload.password or "", user.hashed_password):
        if not st.fail_window_start or \
                now - _aware(st.fail_window_start) > FAIL_WINDOW:
            st.fail_window_start, st.fail_count = now, 0
        st.fail_count += 1
        _audit(db, "login_wrong_password", user_id=user.id, ip=ip, ok=False,
               detail={"ua": ua, "count": st.fail_count})
        if st.fail_count >= FAIL_LIMIT:
            st.locked_until = now + LOCK_FOR
            st.fail_count = 0
            if not st.lockout_window_start or \
                    now - _aware(st.lockout_window_start) > LOCKOUT_WINDOW:
                st.lockout_window_start, st.lockouts = now, 0
            st.lockouts += 1
            if st.lockouts >= LOCKOUTS_TO_FREEZE and not _is_frozen(st):
                _freeze(db, user, "repeated wrong passwords", ip)
                _alert(bg, user, "Admin frozen after repeated wrong passwords",
                       f"Admin sign-in was locked {st.lockouts} times in 24 h "
                       f"(last from IP {ip}). Change your Aluta password to "
                       "unlock it.")
            else:
                _alert(bg, user, "Admin sign-in locked for 15 minutes",
                       f"{FAIL_LIMIT} wrong admin passwords from IP {ip} "
                       f"({_describe_ua(ua)}).")
        db.commit()
        raise generic

    key, der = _load_key(payload.public_key)
    kid = _key_id(der)
    dev = db.query(AdminDevice).filter(AdminDevice.key_id == kid).first()
    if dev and dev.user_id != user.id:
        raise HTTPException(400, "This device key belongs to another account")

    if _is_frozen(st):
        changed = st.frozen_pw_fp != _pw_fp(user)
        usable = dev and dev.status == "trusted" and not (
            dev.probation_until and _aware(dev.probation_until) > now)
        if not changed:
            db.commit()
            raise HTTPException(
                423, "Admin is locked. Change your Aluta password in the app, "
                     "then sign in here from a trusted device.")
        if not usable:
            db.commit()
            raise HTTPException(
                423, "Admin is locked. Sign in from one of your trusted "
                     "devices with your new password to unlock it.")
        # New password + trusted device → challenge below; unfreeze on verify.

    st.fail_count = 0
    trusted_count = db.query(AdminDevice).filter(
        AdminDevice.user_id == user.id, AdminDevice.status == "trusted").count()
    name = (payload.device_name or "").strip()[:60] or _describe_ua(ua)

    def _ensure_dev() -> AdminDevice:
        nonlocal dev
        if not dev:
            dev = AdminDevice(user_id=user.id, key_id=kid,
                              public_key=payload.public_key, pair_attempts=0)
            db.add(dev)
        dev.name, dev.user_agent, dev.request_ip = name, ua, ip
        return dev

    # 1) First-ever device: one-time bootstrap code from Railway variables.
    if payload.bootstrap_code:
        env_code = os.getenv("ADMIN_BOOTSTRAP_CODE", "")
        ok = (env_code and not st.bootstrap_used and trusted_count == 0 and
              hmac.compare_digest(_norm_code(payload.bootstrap_code),
                                  _norm_code(env_code)))
        if not ok:
            _audit(db, "bootstrap_rejected", user_id=user.id, ip=ip, ok=False)
            db.commit()
            raise HTTPException(403, "Bootstrap code invalid or already used")
        d = _ensure_dev()
        d.status, d.probation_until = "trusted", None
        d.approved_at, d.pair_code_hash = now, None
        st.bootstrap_used = True
        db.flush()
        codes = _gen_recovery_codes(db, user.id)
        _audit(db, "bootstrap_enrolled", user_id=user.id, device_id=d.id, ip=ip,
               detail={"device": name})
        _alert(bg, user, "First admin device enrolled",
               f"“{name}” was set up as your first admin device (IP {ip}). "
               "Remove ADMIN_BOOTSTRAP_CODE from Railway variables now.")
        db.commit()
        return {"status": "bootstrapped", "device_id": d.id,
                "recovery_codes": codes, **_new_challenge(d.id)}

    # 2) Recovery code: enroll after a 72 h delay, alerting throughout.
    if payload.recovery_code:
        h = _h(_norm_code(payload.recovery_code))
        rc = db.query(AdminRecoveryCode).filter(
            AdminRecoveryCode.user_id == user.id,
            AdminRecoveryCode.used_at.is_(None),
            AdminRecoveryCode.code_hash == h).first()
        if not rc:
            _audit(db, "recovery_rejected", user_id=user.id, ip=ip, ok=False)
            db.commit()
            raise HTTPException(403, "Recovery code invalid or already used")
        rc.used_at = now
        d = _ensure_dev()
        d.status, d.activate_at = "recovering", now + RECOVERY_DELAY
        d.pair_code_hash = None
        db.flush()
        _audit(db, "recovery_started", user_id=user.id, device_id=d.id, ip=ip,
               detail={"device": name, "activate_at": _iso(d.activate_at)})
        _alert(bg, user, "Admin recovery started",
               f"A recovery code was used to enroll “{name}” (IP {ip}). It "
               f"becomes an admin device at {_iso(d.activate_at)} unless you "
               "cancel it from a trusted device or lock admin.")
        db.commit()
        return {"status": "recovering", "device_id": d.id,
                "activate_at": _iso(d.activate_at)}

    # 3) Known device paths.
    if dev and dev.status == "recovering":
        if dev.activate_at and _aware(dev.activate_at) <= now:
            dev.status, dev.approved_at, dev.probation_until = "trusted", now, None
            _audit(db, "recovery_completed", user_id=user.id, device_id=dev.id,
                   ip=ip)
        else:
            db.commit()
            return {"status": "recovering", "device_id": dev.id,
                    "activate_at": _iso(dev.activate_at)}

    if dev and dev.status == "trusted":
        last = _aware(dev.last_used_at) or _aware(dev.approved_at)
        if last and now - last > DEVICE_EXPIRY:
            dev.status = "pending"   # unused 30 days → must be approved again
            _audit(db, "device_expired", user_id=user.id, device_id=dev.id, ip=ip)
        else:
            db.commit()
            return {"status": "challenge", "device_id": dev.id,
                    **_new_challenge(dev.id)}

    # 4) Unknown / pending / revoked / denied → (re)open a pending request.
    open_requests = db.query(AdminDevice).filter(
        AdminDevice.user_id == user.id, AdminDevice.status == "pending",
        AdminDevice.pair_expires_at > now).all()
    still_open = bool(dev and dev in open_requests)
    if not still_open and len(open_requests) >= 3:
        _audit(db, "device_request_throttled", user_id=user.id, ip=ip, ok=False,
               detail={"ua": ua})
        db.commit()
        raise HTTPException(
            429, "Too many devices are waiting for approval. Approve or deny "
                 "them from a trusted device first.")
    d = _ensure_dev()
    code = _gen_code(6)
    d.status = "pending"
    d.pair_code_hash = _h(code)
    d.pair_expires_at = now + PAIR_TTL
    d.pair_attempts = 0
    db.flush()
    _audit(db, "device_requested", user_id=user.id, device_id=d.id, ip=ip,
           detail={"device": name, "ua": ua, "refresh": still_open})
    if not still_open:  # one alert per request, not per retry
        _alert(bg, user, "New device wants admin access",
               f"Someone signed in with your password from “{name}” (IP {ip}). "
               "It can't do anything until you approve it from a trusted "
               "device with the code it shows.")
    db.commit()
    return {"status": "pending", "device_id": d.id, "pair_code": code,
            "expires_at": _iso(d.pair_expires_at),
            "no_trusted_device": trusted_count == 0}


@router.post("/login/verify")
def admin_login_verify(payload: VerifyIn, request: Request,
                       bg: BackgroundTasks, db: Session = Depends(get_db)):
    ip = _client_ip(request)
    ch = _take_challenge(payload.challenge_id)
    if not ch:
        raise HTTPException(401, "Sign-in expired — try again")
    device_id, nonce, _ = ch
    dev = db.query(AdminDevice).filter(AdminDevice.id == device_id).first()
    if not dev or dev.status != "trusted":
        raise HTTPException(401, "Device not approved")
    if not _verify(dev.public_key, f"login\n{nonce}", payload.signature):
        _audit(db, "login_bad_signature", user_id=dev.user_id,
               device_id=dev.id, ip=ip, ok=False)
        db.commit()
        raise HTTPException(401, "Device signature invalid")
    user = db.query(User).filter(User.id == dev.user_id).first()
    if not user:
        raise HTTPException(401, "Invalid credentials")
    st = _state(db, user.id)
    now = _now()
    if _is_frozen(st):
        if st.frozen_pw_fp == _pw_fp(user):
            raise HTTPException(423, "Admin is locked")
        st.frozen_at, st.frozen_pw_fp = None, None
        st.lockouts, st.locked_until = 0, None
        _audit(db, "admin_unfrozen", user_id=user.id, device_id=dev.id, ip=ip)
        _alert(bg, user, "Admin unlocked",
               f"Admin was unlocked from “{dev.name}” after your password "
               "change.")
    new_ip = bool(dev.last_ip and dev.last_ip != ip)
    token = secrets.token_urlsafe(32)
    db.add(AdminSession(token_hash=_h(token), user_id=user.id,
                        device_id=dev.id, last_used_at=now,
                        expires_at=now + SESSION_MAX, revoked=False))
    dev.last_used_at, dev.last_ip = now, ip
    _audit(db, "login", user_id=user.id, device_id=dev.id, ip=ip)
    if new_ip:
        _alert(bg, user, "Admin sign-in from a new network",
               f"“{dev.name}” signed in to admin from IP {ip}.")
    db.commit()
    return {"token": token, "idle_minutes": int(SESSION_IDLE.total_seconds() // 60),
            "device": _device_out(dev, dev.id),
            "owner": {"id": user.id, "username": user.username,
                      "email": user.email}}


@router.post("/device/poll")
def admin_device_poll(payload: PollIn, db: Session = Depends(get_db)):
    """A pending/recovering device asks 'am I approved yet?' — signed by its own
    key so nobody else can probe another device's state."""
    if abs(time.time() * 1000 - payload.ts) > SIG_WINDOW_S * 1000:
        raise HTTPException(401, "Clock out of sync")
    dev = db.query(AdminDevice).filter(AdminDevice.id == payload.device_id).first()
    if not dev or not _verify(dev.public_key,
                              f"poll\n{dev.id}\n{payload.ts}", payload.signature):
        raise HTTPException(401, "Unknown device")
    status = dev.status
    if status == "pending" and dev.pair_expires_at and \
            _aware(dev.pair_expires_at) < _now():
        status = "expired"
    return {"status": status, "activate_at": _iso(dev.activate_at)}


# ── Signed-request dependency ───────────────────────────────────────────────

class AdminCtx:
    def __init__(self, user: User, device: AdminDevice, session: AdminSession,
                 ip: str):
        self.user, self.device, self.session, self.ip = user, device, session, ip

    @property
    def on_probation(self) -> bool:
        p = _aware(self.device.probation_until)
        return bool(p and p > _now())


async def admin_ctx(request: Request, db: Session = Depends(get_db)) -> AdminCtx:
    auth = request.headers.get("authorization") or ""
    if not auth.startswith("Admin "):
        raise HTTPException(401, "Admin session required")
    token = auth[6:].strip()
    ts = request.headers.get("x-admin-ts") or ""
    nonce = request.headers.get("x-admin-nonce") or ""
    sig = request.headers.get("x-admin-sig") or ""
    now = _now()
    sess = db.query(AdminSession).filter(
        AdminSession.token_hash == _h(token)).first()
    if not sess or sess.revoked or _aware(sess.expires_at) < now or \
            now - _aware(sess.last_used_at) > SESSION_IDLE:
        raise HTTPException(401, "Admin session expired")
    dev = db.query(AdminDevice).filter(AdminDevice.id == sess.device_id).first()
    if not dev or dev.status != "trusted":
        sess.revoked = True
        db.commit()
        raise HTTPException(401, "Device no longer approved")
    try:
        ts_ms = int(ts)
    except ValueError:
        raise HTTPException(401, "Bad signature")
    if abs(time.time() * 1000 - ts_ms) > SIG_WINDOW_S * 1000:
        raise HTTPException(401, "Request too old — check the device clock")
    body = await request.body()
    path = request.url.path + (f"?{request.url.query}" if request.url.query else "")
    msg = "\n".join([request.method.upper(), path, ts, nonce,
                     hashlib.sha256(body).hexdigest()])
    if not _verify(dev.public_key, msg, sig):
        raise HTTPException(401, "Bad signature")
    if not _nonce_fresh(nonce):
        raise HTTPException(401, "Replayed request")
    st = _state(db, sess.user_id)
    if _is_frozen(st):
        sess.revoked = True
        db.commit()
        raise HTTPException(423, "Admin is locked")
    user = db.query(User).filter(User.id == sess.user_id).first()
    if not user or (user.email or "").lower() not in _owner_emails():
        raise HTTPException(403, "Not an admin")
    sess.last_used_at = now
    dev.last_used_at = now
    db.commit()
    return AdminCtx(user, dev, sess, _client_ip(request))


def require_full(ctx: AdminCtx) -> None:
    if ctx.on_probation:
        raise HTTPException(
            403, "This device is on probation (read-only) until "
                 f"{_aware(ctx.device.probation_until).strftime('%Y-%m-%d %H:%M UTC')}.")


def _step_up(ctx: AdminCtx, password: Optional[str]) -> None:
    from auth import verify_password
    if not password or not verify_password(password, ctx.user.hashed_password):
        raise HTTPException(403, "Password incorrect")


# ── Session & devices ───────────────────────────────────────────────────────

class PasswordIn(BaseModel):
    password: str


class ApproveIn(BaseModel):
    pair_code: str
    password: str


class RenameIn(BaseModel):
    name: str


@router.get("/me")
def admin_me(ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    pending = db.query(AdminDevice).filter(
        AdminDevice.user_id == ctx.user.id,
        AdminDevice.status.in_(["pending", "recovering"])).count()
    left = db.query(AdminRecoveryCode).filter(
        AdminRecoveryCode.user_id == ctx.user.id,
        AdminRecoveryCode.used_at.is_(None)).count()
    from models import Feedback
    new_fb = db.query(Feedback).filter(Feedback.status == "new").count()
    return {"owner": {"id": ctx.user.id, "username": ctx.user.username,
                      "email": ctx.user.email},
            "device": _device_out(ctx.device, ctx.device.id),
            "pending_requests": pending,
            "recovery_codes_left": left,
            "new_feedback": new_fb}


@router.post("/logout")
def admin_logout(ctx: AdminCtx = Depends(admin_ctx), db: Session = Depends(get_db)):
    ctx.session.revoked = True
    _audit(db, "logout", user_id=ctx.user.id, device_id=ctx.device.id, ip=ctx.ip)
    db.commit()
    return {"ok": True}


@router.get("/devices")
def admin_devices(ctx: AdminCtx = Depends(admin_ctx),
                  db: Session = Depends(get_db)):
    rows = db.query(AdminDevice).filter(
        AdminDevice.user_id == ctx.user.id).order_by(AdminDevice.id.desc()).all()
    return {"devices": [_device_out(d, ctx.device.id) for d in rows]}


def _target(db: Session, ctx: AdminCtx, device_id: int) -> AdminDevice:
    d = db.query(AdminDevice).filter(AdminDevice.id == device_id,
                                     AdminDevice.user_id == ctx.user.id).first()
    if not d:
        raise HTTPException(404, "No such device")
    return d


@router.post("/devices/{device_id}/approve")
def admin_device_approve(device_id: int, payload: ApproveIn,
                         bg: BackgroundTasks,
                         ctx: AdminCtx = Depends(admin_ctx),
                         db: Session = Depends(get_db)):
    require_full(ctx)
    d = _target(db, ctx, device_id)
    if d.status != "pending":
        raise HTTPException(400, "This device isn't waiting for approval")
    if not d.pair_expires_at or _aware(d.pair_expires_at) < _now():
        raise HTTPException(400, "The request expired — sign in again on that device")
    _step_up(ctx, payload.password)
    if not hmac.compare_digest(d.pair_code_hash or "",
                               _h(_norm_code(payload.pair_code))):
        d.pair_attempts = (d.pair_attempts or 0) + 1
        killed = d.pair_attempts >= PAIR_MAX_ATTEMPTS
        if killed:
            d.status, d.pair_code_hash = "denied", None
        _audit(db, "device_approve_wrong_code", user_id=ctx.user.id,
               device_id=ctx.device.id, target=d.id, ip=ctx.ip, ok=False,
               detail={"attempts": d.pair_attempts})
        db.commit()
        raise HTTPException(
            400, "Wrong code — request cancelled" if killed else
            f"Wrong code ({PAIR_MAX_ATTEMPTS - d.pair_attempts} tries left)")
    now = _now()
    d.status, d.pair_code_hash = "trusted", None
    d.approved_by, d.approved_at = ctx.device.id, now
    d.probation_until = now + PROBATION
    _audit(db, "device_approved", user_id=ctx.user.id, device_id=ctx.device.id,
           target=d.id, ip=ctx.ip, detail={"device": d.name})
    _alert(bg, ctx.user, "New admin device approved",
           f"“{d.name}” was approved from “{ctx.device.name}”. It is read-only "
           "for 24 hours.")
    db.commit()
    return {"device": _device_out(d, ctx.device.id)}


@router.post("/devices/{device_id}/deny")
def admin_device_deny(device_id: int, ctx: AdminCtx = Depends(admin_ctx),
                      db: Session = Depends(get_db)):
    d = _target(db, ctx, device_id)
    if d.status not in ("pending", "recovering"):
        raise HTTPException(400, "Nothing to deny")
    d.status, d.pair_code_hash = "denied", None
    _audit(db, "device_denied", user_id=ctx.user.id, device_id=ctx.device.id,
           target=d.id, ip=ctx.ip)
    db.commit()
    return {"device": _device_out(d, ctx.device.id)}


@router.post("/devices/{device_id}/revoke")
def admin_device_revoke(device_id: int, bg: BackgroundTasks,
                        ctx: AdminCtx = Depends(admin_ctx),
                        db: Session = Depends(get_db)):
    d = _target(db, ctx, device_id)
    # A device on probation may only remove itself — never your real ones.
    if ctx.on_probation and d.id != ctx.device.id:
        require_full(ctx)
    d.status = "revoked"
    db.query(AdminSession).filter(AdminSession.device_id == d.id).update(
        {"revoked": True}, synchronize_session=False)
    _audit(db, "device_revoked", user_id=ctx.user.id, device_id=ctx.device.id,
           target=d.id, ip=ctx.ip, detail={"device": d.name})
    if d.id != ctx.device.id:
        _alert(bg, ctx.user, "Admin device removed",
               f"“{d.name}” was removed from “{ctx.device.name}”.")
    db.commit()
    return {"device": _device_out(d, ctx.device.id)}


@router.post("/devices/{device_id}/end-probation")
def admin_device_end_probation(device_id: int, payload: PasswordIn,
                               ctx: AdminCtx = Depends(admin_ctx),
                               db: Session = Depends(get_db)):
    require_full(ctx)
    d = _target(db, ctx, device_id)
    if d.id == ctx.device.id:
        raise HTTPException(400, "Use another trusted device for this")
    _step_up(ctx, payload.password)
    d.probation_until = None
    _audit(db, "device_probation_ended", user_id=ctx.user.id,
           device_id=ctx.device.id, target=d.id, ip=ctx.ip)
    db.commit()
    return {"device": _device_out(d, ctx.device.id)}


@router.post("/devices/{device_id}/rename")
def admin_device_rename(device_id: int, payload: RenameIn,
                        ctx: AdminCtx = Depends(admin_ctx),
                        db: Session = Depends(get_db)):
    d = _target(db, ctx, device_id)
    if ctx.on_probation and d.id != ctx.device.id:
        require_full(ctx)
    d.name = (payload.name or "").strip()[:60] or d.name
    _audit(db, "device_renamed", user_id=ctx.user.id, device_id=ctx.device.id,
           target=d.id, ip=ctx.ip, detail={"name": d.name})
    db.commit()
    return {"device": _device_out(d, ctx.device.id)}


@router.post("/devices/revoke-others")
def admin_revoke_others(payload: PasswordIn, bg: BackgroundTasks,
                        ctx: AdminCtx = Depends(admin_ctx),
                        db: Session = Depends(get_db)):
    require_full(ctx)
    _step_up(ctx, payload.password)
    n = 0
    for d in db.query(AdminDevice).filter(
            AdminDevice.user_id == ctx.user.id,
            AdminDevice.id != ctx.device.id).all():
        if d.status in ("trusted", "pending", "recovering"):
            d.status, d.pair_code_hash = "revoked", None
            n += 1
    db.query(AdminSession).filter(
        AdminSession.user_id == ctx.user.id,
        AdminSession.device_id != ctx.device.id,
    ).update({"revoked": True}, synchronize_session=False)
    _audit(db, "devices_revoked_others", user_id=ctx.user.id,
           device_id=ctx.device.id, ip=ctx.ip, detail={"count": n})
    _alert(bg, ctx.user, "All other admin devices removed",
           f"{n} device(s) were removed from “{ctx.device.name}”.")
    db.commit()
    return {"revoked": n}


@router.post("/recovery-codes/regenerate")
def admin_recovery_regen(payload: PasswordIn, bg: BackgroundTasks,
                         ctx: AdminCtx = Depends(admin_ctx),
                         db: Session = Depends(get_db)):
    require_full(ctx)
    _step_up(ctx, payload.password)
    codes = _gen_recovery_codes(db, ctx.user.id)
    _audit(db, "recovery_codes_regenerated", user_id=ctx.user.id,
           device_id=ctx.device.id, ip=ctx.ip)
    _alert(bg, ctx.user, "New admin recovery codes",
           f"Recovery codes were regenerated from “{ctx.device.name}”. Old "
           "codes no longer work.")
    db.commit()
    return {"recovery_codes": codes}


# ── "Not me — lock admin" ───────────────────────────────────────────────────

@router.post("/lock-now")
def admin_lock_now(bg: BackgroundTasks, ctx: AdminCtx = Depends(admin_ctx),
                   db: Session = Depends(get_db)):
    _freeze(db, ctx.user, "locked from admin panel", ctx.ip, ctx.device.id)
    _alert(bg, ctx.user, "Admin locked",
           f"Admin was locked from “{ctx.device.name}”. Change your Aluta "
           "password, then sign in from a trusted device to unlock.")
    db.commit()
    return {"locked": True}


_LOCK_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aluta Admin</title><style>body{{font-family:system-ui,sans-serif;
background:#0f0f14;color:#eee;display:flex;min-height:100vh;align-items:center;
justify-content:center;margin:0;padding:16px}}.c{{max-width:420px;background:#1b1b24;
border-radius:16px;padding:24px}}h1{{font-size:20px}}button{{background:#c62828;
color:#fff;border:0;border-radius:10px;padding:12px 18px;font-size:16px}}</style>
</head><body><div class="c">{body}</div></body></html>"""


def _lock_user_from(t: str, db: Session) -> Optional[User]:
    try:
        claims = jwt.decode(t or "", SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
    if claims.get("typ") != "admin_lock":
        return None
    email = (claims.get("sub") or "").lower()
    return db.query(User).filter(sa_func.lower(User.email) == email).first()


@router.get("/lock", response_class=HTMLResponse, include_in_schema=False)
def admin_lock_page(t: str = "", db: Session = Depends(get_db)):
    # GET only shows a button (mail scanners pre-fetch links — they must not
    # trigger the lock); the POST below does it.
    if not _lock_user_from(t, db):
        return HTMLResponse(_LOCK_PAGE.format(
            body="<h1>Link expired</h1><p>Open the admin panel on a trusted "
                 "device and use “Lock admin”.</p>"), status_code=400)
    return HTMLResponse(_LOCK_PAGE.format(body=(
        "<h1>Lock Aluta Admin?</h1><p>This ends every admin session and blocks "
        "admin sign-in until you change your Aluta password.</p>"
        f'<form method="post" action="/admin/api/lock?t={t}">'
        '<button type="submit">Lock admin now</button></form>')))


@router.post("/lock", response_class=HTMLResponse, include_in_schema=False)
def admin_lock_post(request: Request, bg: BackgroundTasks, t: str = "",
                    db: Session = Depends(get_db)):
    user = _lock_user_from(t, db)
    if not user:
        return HTMLResponse(_LOCK_PAGE.format(body="<h1>Link expired</h1>"),
                            status_code=400)
    _freeze(db, user, "locked from alert email", _client_ip(request))
    _alert(bg, user, "Admin locked",
           "Admin was locked from the alert email. Change your Aluta password, "
           "then sign in from a trusted device to unlock.")
    db.commit()
    return HTMLResponse(_LOCK_PAGE.format(body=(
        "<h1>Admin locked 🔒</h1><p>All admin sessions are ended. Change your "
        "Aluta password in the app, then sign in to the admin panel from one "
        "of your trusted devices to unlock it.</p>")))


# ── Audit log ───────────────────────────────────────────────────────────────

@router.get("/audit")
def admin_audit(limit: int = 100, before_id: Optional[int] = None,
                ctx: AdminCtx = Depends(admin_ctx),
                db: Session = Depends(get_db)):
    q = db.query(AdminAuditLog).filter(
        (AdminAuditLog.user_id == ctx.user.id) | (AdminAuditLog.user_id.is_(None)))
    if before_id:
        q = q.filter(AdminAuditLog.id < before_id)
    rows = q.order_by(AdminAuditLog.id.desc()).limit(max(1, min(limit, 200))).all()
    names = {d.id: d.name for d in db.query(AdminDevice).filter(
        AdminDevice.user_id == ctx.user.id).all()}
    return {"entries": [{
        "id": r.id, "at": _iso(r.at), "action": r.action, "target": r.target,
        "detail": json.loads(r.detail) if r.detail else None, "ip": r.ip,
        "ok": r.ok, "device": names.get(r.device_id),
    } for r in rows]}


# ── Metrics (Phase 1, read-only) ────────────────────────────────────────────

_TZ = "Africa/Dar_es_Salaam"
_TZ_OFFSET_H = 3


def _is_pg(db: Session) -> bool:
    return db.bind.dialect.name == "postgresql"


def _daily(db: Session, table: str, col: str, days: int,
           where: str = "") -> list:
    since = _now() - timedelta(days=days)
    extra = f" AND {where}" if where else ""
    if _is_pg(db):
        sql = (f"SELECT to_char(({col} AT TIME ZONE '{_TZ}')::date, 'YYYY-MM-DD')"
               f" AS d, COUNT(*) FROM {table} WHERE {col} >= :since{extra}"
               " GROUP BY 1")
    else:
        sql = (f"SELECT date(datetime({col}, '+{_TZ_OFFSET_H} hours')) AS d,"
               f" COUNT(*) FROM {table} WHERE {col} >= :since{extra} GROUP BY 1")
    got = {str(r[0]): int(r[1]) for r in db.execute(text(sql), {"since": since})}
    local_today = (_now() + timedelta(hours=_TZ_OFFSET_H)).date()
    out = []
    for i in range(days - 1, -1, -1):
        d = (local_today - timedelta(days=i)).isoformat()
        out.append({"date": d, "count": got.get(d, 0)})
    return out


@router.get("/metrics/overview")
def metrics_overview(ctx: AdminCtx = Depends(admin_ctx),
                     db: Session = Depends(get_db)):
    import websocket_manager
    now = _now()
    total = db.query(User).count()

    def since(col, delta):
        return db.query(User).filter(col >= now - delta).count()

    local_midnight = (now + timedelta(hours=_TZ_OFFSET_H)).replace(
        hour=0, minute=0, second=0, microsecond=0) - timedelta(hours=_TZ_OFFSET_H)
    online_ids = [uid for uid, socks in websocket_manager.connected_users.items()
                  if socks]
    retention = {}
    for n in (1, 7, 30):
        cutoff = now - timedelta(days=n)
        cohort = db.query(User).filter(User.created_at.isnot(None),
                                       User.created_at <= cutoff).all()
        kept = 0
        for u in cohort:
            ca, ls = _aware(u.created_at), _aware(u.last_seen)
            if ca and ls and ls >= ca + timedelta(days=n):
                kept += 1
        retention[f"d{n}"] = {"cohort": len(cohort), "returned": kept,
                              "pct": round(100 * kept / len(cohort), 1)
                              if cohort else None}
    try:
        from live_session import MANAGER
        live_now = len(MANAGER.sessions)
    except Exception:
        live_now = None
    return {
        "users_total": total,
        "new_today": db.query(User).filter(User.created_at >= local_midnight).count(),
        "new_7d": since(User.created_at, timedelta(days=7)),
        "new_30d": since(User.created_at, timedelta(days=30)),
        "online_now": len(online_ids),
        "active_24h": since(User.last_seen, timedelta(hours=24)),
        "active_7d": since(User.last_seen, timedelta(days=7)),
        "active_30d": since(User.last_seen, timedelta(days=30)),
        "retention": retention,
        "listen_together_now": live_now,
        "generated_at": _iso(now),
        "note": "Join dates before 26 Oct 2026 are estimated from first activity.",
    }


@router.get("/metrics/online")
def metrics_online(ctx: AdminCtx = Depends(admin_ctx),
                   db: Session = Depends(get_db)):
    import websocket_manager
    from models import UserDevice
    ids = [uid for uid, socks in websocket_manager.connected_users.items() if socks]
    users = db.query(User).filter(User.id.in_(ids)).all() if ids else []
    plat = {}
    if ids:
        for d in db.query(UserDevice).filter(UserDevice.user_id.in_(ids)).order_by(
                UserDevice.last_seen.desc()).all():
            plat.setdefault(d.user_id, d.platform)
    return {"online": [{"id": u.id, "username": u.username,
                        "platform": plat.get(u.id),
                        "last_seen": _iso(u.last_seen)} for u in users]}


@router.get("/metrics/signups")
def metrics_signups(days: int = 30, ctx: AdminCtx = Depends(admin_ctx),
                    db: Session = Depends(get_db)):
    days = max(7, min(days, 365))
    return {"days": _daily(db, "users", "created_at", days)}


PLATFORM_LABELS = {
    "android": "Android app", "windows": "Windows app", "ios": "iPhone app",
    "macos": "Mac app", "linux": "Linux app", "web-ios": "Web · iPhone/iPad",
    "web-android": "Web · Android", "web-desktop": "Web · computer",
}


@router.get("/metrics/devices")
def metrics_devices(days: int = 30, ctx: AdminCtx = Depends(admin_ctx),
                    db: Session = Depends(get_db)):
    from models import UserDevice
    days = max(1, min(days, 365))
    rows = db.query(UserDevice).filter(
        UserDevice.last_seen >= _now() - timedelta(days=days)).all()
    by_plat, by_ver = {}, {}
    for r in rows:
        by_plat.setdefault(r.platform, set()).add(r.user_id)
        v = r.app_version or "unknown"
        by_ver.setdefault(v, set()).add(r.user_id)
    users = set(r.user_id for r in rows)
    plats = sorted(({"platform": p, "label": PLATFORM_LABELS.get(p, p),
                     "users": len(s)} for p, s in by_plat.items()),
                   key=lambda x: -x["users"])
    vers = sorted(({"version": v, "users": len(s)} for v, s in by_ver.items()),
                  key=lambda x: -x["users"])[:10]
    return {"window_days": days, "users_reporting": len(users),
            "installs": len(rows), "platforms": plats, "versions": vers,
            "note": "Counts start once people open an app version that "
                    "reports its device (26 Oct 2026 onwards)."}


@router.get("/metrics/storage")
def metrics_storage(ctx: AdminCtx = Depends(admin_ctx),
                    db: Session = Depends(get_db)):
    out: dict = {}
    live = ("data IS NOT NULL AND purged_at IS NULL")
    cat = ("CASE WHEN mime LIKE 'image/%' THEN 'photos' "
           "WHEN mime LIKE 'video/%' THEN 'videos' "
           "WHEN mime LIKE 'audio/%' THEN 'audio' ELSE 'files' END")
    rows = db.execute(text(
        f"SELECT {cat} AS k, COUNT(*), COALESCE(SUM(size),0) FROM media_assets "
        f"WHERE {live} GROUP BY 1")).fetchall()
    out["media_by_kind"] = [{"kind": r[0], "files": int(r[1]),
                             "bytes": int(r[2])} for r in rows]
    out["media_live_bytes"] = sum(x["bytes"] for x in out["media_by_kind"])
    out["media_live_files"] = sum(x["files"] for x in out["media_by_kind"])
    out["media_purged_rows"] = int(db.execute(text(
        "SELECT COUNT(*) FROM media_assets WHERE data IS NULL "
        "OR purged_at IS NOT NULL")).scalar() or 0)
    top = db.execute(text(
        f"SELECT uploader_id, COUNT(*), COALESCE(SUM(size),0) FROM media_assets "
        f"WHERE {live} AND uploader_id IS NOT NULL GROUP BY uploader_id "
        "ORDER BY 3 DESC LIMIT 10")).fetchall()
    names = {u.id: u.username for u in db.query(User).filter(
        User.id.in_([int(r[0]) for r in top])).all()} if top else {}
    out["top_uploaders"] = [{"user_id": int(r[0]),
                             "username": names.get(int(r[0])),
                             "files": int(r[1]), "bytes": int(r[2])} for r in top]
    if _is_pg(db):
        out["database_bytes"] = int(db.execute(text(
            "SELECT pg_database_size(current_database())")).scalar() or 0)
        tables = db.execute(text(
            "SELECT relname, pg_total_relation_size(c.oid) FROM pg_class c "
            "JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE c.relkind = 'r' AND n.nspname = 'public' "
            "ORDER BY 2 DESC LIMIT 8")).fetchall()
        out["largest_tables"] = [{"table": r[0], "bytes": int(r[1])}
                                 for r in tables]
    else:
        out["database_bytes"] = None
        out["largest_tables"] = []
    return out


@router.get("/metrics/activity")
def metrics_activity(days: int = 14, ctx: AdminCtx = Depends(admin_ctx),
                     db: Session = Depends(get_db)):
    days = max(7, min(days, 90))
    return {
        "messages": _daily(db, "messages", "timestamp", days),
        "hearts": _daily(db, "messages", "timestamp", days,
                         "message_type = 'heart'"),
        "voice_notes": _daily(db, "messages", "timestamp", days,
                              "message_type = 'audio'"),
    }


# ── Feedback (from the app's "Send feedback" page) ──────────────────────────

class FeedbackUpdateIn(BaseModel):
    status: Optional[str] = None     # new | seen | planned | done | wontfix
    reply: Optional[str] = None      # shown to the person in the app


_FB_STATUSES = {"new", "seen", "planned", "done", "wontfix"}


@router.get("/feedback")
def admin_feedback(status: Optional[str] = None, kind: Optional[str] = None,
                   limit: int = 50, before_id: Optional[int] = None,
                   ctx: AdminCtx = Depends(admin_ctx),
                   db: Session = Depends(get_db)):
    from models import Feedback, UserDevice
    q = db.query(Feedback)
    if status in _FB_STATUSES:
        q = q.filter(Feedback.status == status)
    if kind:
        q = q.filter(Feedback.kind == kind)
    if before_id:
        q = q.filter(Feedback.id < before_id)
    rows = q.order_by(Feedback.id.desc()).limit(max(1, min(limit, 100))).all()
    uids = {r.user_id for r in rows}
    users = {u.id: u for u in db.query(User).filter(User.id.in_(uids)).all()} \
        if uids else {}
    counts = {s: 0 for s in _FB_STATUSES}
    for st, n in db.query(Feedback.status, sa_func.count(Feedback.id)).group_by(
            Feedback.status).all():
        counts[st] = int(n)
    avg = db.query(sa_func.avg(Feedback.rating)).filter(
        Feedback.rating.isnot(None)).scalar()
    from routers.feedback import out as fb_out
    entries = []
    for r in rows:
        u = users.get(r.user_id)
        e = fb_out(r)
        e.update({
            "user_id": r.user_id,
            "username": u.username if u else None,
            "platform": r.platform,
            "app_version": r.app_version,
        })
        entries.append(e)
    return {"entries": entries, "counts": counts,
            "average_rating": round(float(avg), 2) if avg is not None else None}


@router.post("/feedback/{feedback_id}")
def admin_feedback_update(feedback_id: int, payload: FeedbackUpdateIn,
                          bg: BackgroundTasks,
                          ctx: AdminCtx = Depends(admin_ctx),
                          db: Session = Depends(get_db)):
    require_full(ctx)
    from models import Feedback
    from routers.feedback import out as fb_out
    f = db.query(Feedback).filter(Feedback.id == feedback_id).first()
    if not f:
        raise HTTPException(404, "No such feedback")
    changes = {}
    if payload.status is not None:
        if payload.status not in _FB_STATUSES:
            raise HTTPException(400, "Unknown status")
        changes["status"] = [f.status, payload.status]
        f.status = payload.status
    if payload.reply is not None:
        reply = payload.reply.strip()[:2000]
        changes["reply"] = bool(reply)
        f.admin_note = reply or None
    f.updated_at = _now()
    # Let the person know their voice was heard (a reply, or it's planned/done).
    tell = None
    what = {"idea": "idea", "problem": "problem report", "praise": "note",
            "help": "help request"}.get(f.kind or "", "feedback")
    snippet = ""
    if payload.reply and payload.reply.strip():
        tell = f"💬 The Aluta team replied to your {what}"
        snippet = payload.reply.strip()[:140]
    elif payload.status in ("planned", "done"):
        tell = (f"🛠️ Your {what} is planned" if payload.status == "planned"
                else f"✅ Your {what} is done")
        snippet = (f.message or "")[:100]
    if tell:
        def _push(uid=f.user_id, title=tell, body=snippet, fid=f.id):
            try:
                from push import send_push_to_user
                send_push_to_user(uid, {"type": "feedback_update",
                                        "title": title,
                                        "body": body or "Tap to see it",
                                        "feedback_id": str(fid)})
            except Exception as e:  # noqa: BLE001
                print(f"[feedback] user push failed: {e}")
        bg.add_task(_push)
    _audit(db, "feedback_updated", user_id=ctx.user.id, device_id=ctx.device.id,
           target=f.id, ip=ctx.ip, detail=changes)
    db.commit()
    return fb_out(f)
