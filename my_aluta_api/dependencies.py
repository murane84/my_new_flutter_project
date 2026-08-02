import email
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from config import SECRET_KEY, ALGORITHM
from schemas import TokenData
from models import User
from sqlalchemy.orm import Session
from database import get_db
from crud import update_last_seen  # Import the update_last_seen function

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db)
) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        email = payload.get("sub")

        if not isinstance(email, str):
            raise credentials_exception

        token_data = TokenData(email=email)

    except JWTError:
        raise credentials_exception

    user = db.query(User).filter(User.email == token_data.email).first()
    if user is None:
        raise credentials_exception

    # Update last_seen for the authenticated user
    update_last_seen(db, user.id)

    return user
def get_current_active_user(
    current_user: User = Depends(get_current_user),
) -> User:
    if not current_user.is_active:
        raise HTTPException(status_code=400, detail="Inactive user")
    return current_user 


