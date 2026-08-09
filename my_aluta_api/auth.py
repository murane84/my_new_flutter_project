from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from sqlalchemy.orm import Session
from fastapi.security import OAuth2PasswordBearer
from passlib.context import CryptContext
from jose import JWTError, jwt
import pyotp
import secrets
import hmac
import hashlib
from datetime import datetime, timedelta, timezone
from pydantic import BaseModel, EmailStr
from models import User, PasswordResetCode
from database import get_db
from mailer import send_password_reset_code
from config import SECRET_KEY, ALGORITHM, ACCESS_TOKEN_EXPIRE_MINUTES, INACTIVITY_TIMEOUT_MINUTES

router = APIRouter()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Label shown for the account inside the authenticator app (e.g. "Aluta").
TOTP_ISSUER = "Aluta"

def _digits_only(code: str | None) -> str:
    """Strip spaces/dashes users often paste, keep just the digits."""
    return "".join(ch for ch in (code or "") if ch.isdigit())

# Email-code recovery tuning.
RESET_CODE_TTL_MINUTES = 15
RESET_CODE_MAX_ATTEMPTS = 5

def _hash_code(code: str) -> str:
    """HMAC-SHA256 the reset code with the app secret so the DB never holds the
    plaintext (and a leaked DB can't be reversed to a code)."""
    return hmac.new(
        SECRET_KEY.encode(), _digits_only(code).encode(), hashlib.sha256
    ).hexdigest()

# ------------------------------
# Pydantic Schemas
# ------------------------------

class UserCreate(BaseModel):
    username: str
    email: EmailStr
    password: str
    # Phone is now MANDATORY (like email) and expected in E.164 form
    # (+<country code><number>), so contacts can be matched across countries.
    phone: str

class UserLogin(BaseModel):
    email: EmailStr
    password: str

class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    email: EmailStr
    username: str
    last_login: datetime

# --- Two-factor / password-recovery (TOTP) ---

class TwoFASetupResponse(BaseModel):
    secret: str          # base32 shared secret (also encoded in the QR)
    otpauth_uri: str     # otpauth://... — render as a QR for Google Authenticator

class TwoFAStatus(BaseModel):
    enabled: bool

class TwoFAVerify(BaseModel):
    code: str

class TwoFADisable(BaseModel):
    # Disabling requires proof of ownership: EITHER a current authenticator
    # code OR the account password.
    code: str | None = None
    password: str | None = None

class PasswordReset(BaseModel):
    # Reset a forgotten password by proving a current authenticator code.
    email: EmailStr
    code: str
    new_password: str

# --- Email-code password recovery ---

class EmailOnly(BaseModel):
    email: EmailStr

class EmailCodeReset(BaseModel):
    email: EmailStr
    code: str
    new_password: str

# ------------------------------
# Helper Functions
# ------------------------------

# ------------------------------
# Password Hashing
# ------------------------------

def get_password_hash(password: str) -> str:
    """
    Hashes a password using bcrypt (Passlib) while respecting the 72-byte limit.
    """
    # Encode -> truncate 72 bytes -> decode back to string safely
    truncated = password.encode("utf-8")[:72].decode("utf-8", "ignore")
    return pwd_context.hash(truncated)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    """
    Verifies a password against a hashed value, truncating if needed.
    """
    truncated = plain_password.encode("utf-8")[:72].decode("utf-8", "ignore")
    return pwd_context.verify(truncated, hashed_password)

def create_token(data: dict, expires_delta: timedelta) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + expires_delta
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def create_tokens(email: str):
    access_token = create_token(
        {"sub": email},
        timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    )
    refresh_token = create_token(
        {"sub": email},
        # Long-lived so a user who leaves the app idle/backgrounded for weeks is
        # never forced to re-enter credentials — the app silently refreshes.
        timedelta(days=365)
    )
    return access_token, refresh_token

def update_last_seen(user_id: int, db: Session):
    user = db.query(User).filter(User.id == user_id).first()
    if user:
        user.last_seen = datetime.now(timezone.utc)
        user.is_online = True  # ← ensure online when activity is detected
        db.commit()

def get_user_by_email(db: Session, email: str) -> User:
    return db.query(User).filter(User.email == email).first()

def check_inactivity(last_seen: datetime) -> bool:
    # Ensure last_seen is timezone-aware
    if last_seen.tzinfo is None or last_seen.tzinfo.utcoffset(last_seen) is None:
        last_seen = last_seen.replace(tzinfo=timezone.utc)

    inactivity_period = datetime.now(timezone.utc) - last_seen
    return inactivity_period.total_seconds() > 600  # 10 minutes

def set_user_status_based_on_inactivity(user: User, db: Session):
    """Updates the user's is_online status based on inactivity."""
    if check_inactivity(user.last_seen):
        user.is_online = False  # Set to offline if inactivity exceeds timeout
        user.last_seen = datetime.now(timezone.utc)  # ✅ Update last_seen
    else:
        user.is_online = True  # Set to online if still within inactivity window
    db.commit()

# ------------------------------
# Token Dependencies
# ------------------------------

def get_current_user(db: Session = Depends(get_db), token: str = Depends(oauth2_scheme)) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        raise credentials_exception

    email = payload.get("sub")
    if not isinstance(email, str):
        raise credentials_exception

    user = get_user_by_email(db, email)
    if not user:
        raise credentials_exception

    # A valid token means a valid session. This is a chat app, not a bank —
    # users stay signed in like WhatsApp and are never logged out for being
    # idle. Every authenticated request counts as activity, keeping the user
    # online and reachable in the background so messages still deliver.
    update_last_seen(user.id, db)

    return user

def get_active_user(current_user: User = Depends(get_current_user)):
    if not current_user.is_online:
        raise HTTPException(status_code=403, detail="User is not active")
    return current_user

# ------------------------------
# Routes
# ------------------------------

@router.post("/register/")
def register_user(user: UserCreate, db: Session = Depends(get_db)):
    if get_user_by_email(db, user.email):
        raise HTTPException(status_code=400, detail="Email already registered")

    # Phone is mandatory and must be a valid E.164 number (+<cc><number>,
    # 8–15 digits) so it can be matched against contacts across countries.
    phone = (user.phone or "").strip()
    import re as _re
    if not _re.fullmatch(r"\+\d{8,15}", phone):
        raise HTTPException(
            status_code=400,
            detail="Enter a valid phone number with country code (e.g. +255…).",
        )
    # Block a second account on the same number (numbers are the discovery key).
    existing_phone = db.query(User).filter(User.phone == phone).first()
    if existing_phone:
        raise HTTPException(
            status_code=400, detail="That phone number is already registered.")

    hashed_password = get_password_hash(user.password)
    new_user = User(
        username=user.username,
        email=user.email,
        hashed_password=hashed_password,
        phone=phone,
        is_online=False
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)

    return {
        "message": "User registered successfully",
        "user_id": new_user.id,
        "email": new_user.email
    }

@router.post("/login", response_model=TokenResponse)
def login_user(user: UserLogin, db: Session = Depends(get_db)):
    db_user = get_user_by_email(db, user.email)
    if not db_user or not verify_password(user.password, db_user.hashed_password):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    # Set the user to online and update their last seen timestamp
    db_user.is_online = True
    db_user.last_login = datetime.now(timezone.utc)
    update_last_seen(db_user.id, db)

    access_token, refresh_token = create_tokens(db_user.email)
    db_user.refresh_token = refresh_token
    db.commit()

    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        email=db_user.email,
        username=db_user.username,
        last_login=db_user.last_login
    )

@router.post("/refresh")
def refresh_access_token(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db)
):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    email = payload.get("sub")
    if not isinstance(email, str):
        raise HTTPException(status_code=401, detail="Invalid token")

    user = get_user_by_email(db, email)
    if not user or user.refresh_token != token:
        raise HTTPException(status_code=403, detail="Invalid refresh token")

    new_access_token, _ = create_tokens(user.email)
    return {"access_token": new_access_token, "token_type": "bearer"}

@router.post("/logout")
def logout_user(db: Session = Depends(get_db), current_user: User = Depends(get_active_user)):
    current_user.is_online = False
    current_user.last_seen = datetime.now(timezone.utc)
    current_user.refresh_token = None
    db.commit()
    return {"message": f"{current_user.username} logged out successfully."}


@router.get("/users/{friend_id}/status")
def get_user_status(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_active_user)):
    friend = db.query(User).filter(User.id == friend_id).first()
    if not friend:
        raise HTTPException(status_code=404, detail="User not found")

    return {
        "user_id": friend.id,
        "is_online": friend.is_online,
        "last_seen": str(friend.last_seen) if friend.last_seen else None
    }

@router.get("/users/me")
def get_me(current_user: User = Depends(get_active_user)):
    return {
        "id": current_user.id,
        "username": current_user.username,
        "email": current_user.email,
        "is_online": current_user.is_online
    }


# ---------------------------------------------------------------------------
# Two-factor authentication + password recovery (TOTP / Google Authenticator)
# ---------------------------------------------------------------------------
# Enrolling an authenticator lets a user recover a FORGOTTEN password without
# email: they prove ownership of the account by entering a current 6-digit code
# from their authenticator app. Enrollment is a two-step handshake — /setup
# hands out a secret (shown as a QR), /verify confirms the first code and flips
# the account to enabled. `get_current_user` is used (not `get_active_user`) so
# these work right after login regardless of the online flag.

@router.get("/2fa/status", response_model=TwoFAStatus)
def twofa_status(current_user: User = Depends(get_current_user)):
    return TwoFAStatus(enabled=bool(current_user.totp_enabled))


@router.post("/2fa/setup", response_model=TwoFASetupResponse)
def twofa_setup(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    # Never re-hand-out a secret for an already-protected account — the user
    # must explicitly disable first. This prevents a hijacked session from
    # silently swapping the authenticator.
    if current_user.totp_enabled and current_user.totp_secret:
        raise HTTPException(
            status_code=400,
            detail="Two-factor is already on. Turn it off first to re-enroll.",
        )
    secret = pyotp.random_base32()
    current_user.totp_secret = secret
    current_user.totp_enabled = False  # not active until a code is verified
    db.commit()
    uri = pyotp.TOTP(secret).provisioning_uri(
        name=current_user.email, issuer_name=TOTP_ISSUER
    )
    return TwoFASetupResponse(secret=secret, otpauth_uri=uri)


@router.post("/2fa/verify")
def twofa_verify(
    payload: TwoFAVerify,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    if not current_user.totp_secret:
        raise HTTPException(status_code=400, detail="Start setup first.")
    # valid_window=1 tolerates a ±30s clock skew between phone and server.
    totp = pyotp.TOTP(current_user.totp_secret)
    if not totp.verify(_digits_only(payload.code), valid_window=1):
        raise HTTPException(status_code=400, detail="Invalid or expired code.")
    current_user.totp_enabled = True
    db.commit()
    return {"message": "Two-factor enabled", "enabled": True}


@router.post("/2fa/disable")
def twofa_disable(
    payload: TwoFADisable,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    ok = False
    if payload.code and current_user.totp_secret:
        ok = pyotp.TOTP(current_user.totp_secret).verify(
            _digits_only(payload.code), valid_window=1
        )
    if not ok and payload.password:
        ok = verify_password(payload.password, current_user.hashed_password)
    if not ok:
        raise HTTPException(
            status_code=400,
            detail="Enter a valid authenticator code or your password to turn off 2FA.",
        )
    current_user.totp_secret = None
    current_user.totp_enabled = False
    db.commit()
    return {"message": "Two-factor disabled", "enabled": False}


@router.post("/password-reset")
def password_reset(payload: PasswordReset, db: Session = Depends(get_db)):
    """Reset a forgotten password by proving a current authenticator code.

    Only works for accounts that enrolled an authenticator beforehand. Errors
    are deliberately generic so the endpoint doesn't reveal which emails exist
    or which have 2FA turned on.
    """
    generic = HTTPException(
        status_code=400,
        detail="Couldn't reset. Check the email and the authenticator code, "
               "and make sure two-factor was set up on this account.",
    )
    user = get_user_by_email(db, payload.email)
    if not user or not user.totp_enabled or not user.totp_secret:
        raise generic
    if not pyotp.TOTP(user.totp_secret).verify(
        _digits_only(payload.code), valid_window=1
    ):
        raise generic

    new_pw = payload.new_password or ""
    if len(new_pw) < 6:
        raise HTTPException(
            status_code=400,
            detail="New password must be at least 6 characters.",
        )
    user.hashed_password = get_password_hash(new_pw)
    # Invalidate any lingering session so a thief with the old password is out.
    user.refresh_token = None
    db.commit()
    return {"message": "Password updated. Sign in with your new password."}


# ---------------------------------------------------------------------------
# Email-code password recovery (fallback for users without an authenticator)
# ---------------------------------------------------------------------------
# Two steps: /request emails a short-lived 6-digit code; /confirm verifies it
# and sets the new password. Codes are stored HMAC-hashed, single-use, expiring,
# and attempt-limited. Both endpoints stay deliberately vague about whether an
# email exists.

@router.post("/password-reset/request")
def password_reset_request(
    payload: EmailOnly,
    background: BackgroundTasks,
    db: Session = Depends(get_db),
):
    user = get_user_by_email(db, payload.email)
    if user:
        # Retire any earlier unused codes so only the newest one works.
        db.query(PasswordResetCode).filter(
            PasswordResetCode.user_id == user.id,
            PasswordResetCode.used == False,  # noqa: E712
        ).update({"used": True})
        code = f"{secrets.randbelow(1_000_000):06d}"
        rec = PasswordResetCode(
            user_id=user.id,
            code_hash=_hash_code(code),
            expires_at=datetime.now(timezone.utc)
            + timedelta(minutes=RESET_CODE_TTL_MINUTES),
            used=False,
            attempts=0,
        )
        db.add(rec)
        db.commit()
        # Send off the request thread so the response isn't blocked on SMTP.
        background.add_task(
            send_password_reset_code, user.email, user.username, code
        )
    # Always the same response, whether or not the email is registered.
    return {
        "message": "If that email is registered, a reset code is on its way. "
                   "It expires in 15 minutes.",
    }


@router.post("/password-reset/confirm")
def password_reset_confirm(payload: EmailCodeReset, db: Session = Depends(get_db)):
    generic = HTTPException(status_code=400, detail="Invalid or expired code.")
    user = get_user_by_email(db, payload.email)
    if not user:
        raise generic

    rec = (
        db.query(PasswordResetCode)
        .filter(
            PasswordResetCode.user_id == user.id,
            PasswordResetCode.used == False,  # noqa: E712
        )
        .order_by(PasswordResetCode.id.desc())
        .first()
    )
    if not rec:
        raise generic

    # Expiry (guard against a naive datetime coming back from some drivers).
    exp = rec.expires_at
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=timezone.utc)
    if exp < datetime.now(timezone.utc):
        rec.used = True
        db.commit()
        raise generic

    if rec.attempts >= RESET_CODE_MAX_ATTEMPTS:
        rec.used = True
        db.commit()
        raise generic

    if not hmac.compare_digest(rec.code_hash, _hash_code(payload.code)):
        rec.attempts += 1
        db.commit()
        raise generic

    new_pw = payload.new_password or ""
    if len(new_pw) < 6:
        raise HTTPException(
            status_code=400,
            detail="New password must be at least 6 characters.",
        )

    user.hashed_password = get_password_hash(new_pw)
    user.refresh_token = None
    rec.used = True
    db.commit()
    return {"message": "Password updated. Sign in with your new password."}
