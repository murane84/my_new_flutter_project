from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from fastapi.security import OAuth2PasswordBearer
from passlib.context import CryptContext
from jose import JWTError, jwt
from datetime import datetime, timedelta, timezone
from pydantic import BaseModel, EmailStr
from models import User
from database import get_db
from config import SECRET_KEY, ALGORITHM, ACCESS_TOKEN_EXPIRE_MINUTES, INACTIVITY_TIMEOUT_MINUTES

router = APIRouter()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# ------------------------------
# Pydantic Schemas
# ------------------------------

class UserCreate(BaseModel):
    username: str
    email: EmailStr
    password: str

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
        timedelta(days=7)
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

    # Check for inactivity timeout and update user status
    set_user_status_based_on_inactivity(user, db)

    # If the user is inactive, raise session expired
    if not user.is_online:
        raise HTTPException(status_code=401, detail="Session expired due to inactivity")

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
    
    hashed_password = get_password_hash(user.password)
    new_user = User(
        username=user.username,
        email=user.email,
        hashed_password=hashed_password,
        phone=user.phone,
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
