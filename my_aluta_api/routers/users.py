from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from typing import List
from datetime import datetime, timezone
from models import BlockStatus
from database import get_db
from models import User, MuteStatus
import crud, schemas
from schemas import UserOut  # Ensure this contains fields like id, email, username, is_online
from auth import get_current_user, get_password_hash, verify_password

router = APIRouter()

# ---------------------------
# Routes
# ---------------------------

@router.get("/users/me", response_model=UserOut, tags=["Users"])
def read_users_me(current_user: User = Depends(get_current_user)):
    return current_user


# Update own profile: username / phone / password. Email is immutable.
@router.patch("/users/me/update", response_model=UserOut, tags=["Users"])
def update_profile(
    payload: schemas.UserUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    if payload.username is not None:
        new_username = payload.username.strip()
        if new_username and new_username != current_user.username:
            clash = (
                db.query(User)
                .filter(User.username == new_username, User.id != current_user.id)
                .first()
            )
            if clash:
                raise HTTPException(status_code=400, detail="Username already taken")
            current_user.username = new_username

    if payload.phone is not None:
        current_user.phone = payload.phone.strip() or None

    if payload.avatar_url is not None:
        current_user.avatar_url = payload.avatar_url.strip() or None

    if payload.new_password:
        if not payload.current_password or not verify_password(
            payload.current_password, current_user.hashed_password
        ):
            raise HTTPException(status_code=400, detail="Current password is incorrect")
        current_user.hashed_password = get_password_hash(payload.new_password)

    db.commit()
    db.refresh(current_user)
    return current_user


# Permanently delete the account and wipe the user's data from the server.
@router.delete("/users/me", tags=["Users"])
def delete_account(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    from models import Message, MediaAsset

    user = db.query(User).filter(User.id == current_user.id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Wipe attachment blobs referenced by this user's messages.
    msgs = (
        db.query(Message)
        .filter((Message.sender_id == user.id) | (Message.receiver_id == user.id))
        .all()
    )
    asset_ids = [
        m.media_url.rsplit("/", 1)[-1]
        for m in msgs
        if m.media_url and m.media_url.startswith("/attachments/")
    ]
    if asset_ids:
        db.query(MediaAsset).filter(MediaAsset.id.in_(asset_ids)).delete(
            synchronize_session=False
        )

    # Deleting the user cascades their messages (ORM relationship) and their
    # friend / mute / block rows (FK ON DELETE CASCADE).
    db.delete(user)
    db.commit()
    return {"detail": "Account deleted"}

@router.get("/users/", response_model=List[UserOut], tags=["Users"])
def get_all_users_except_current(current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    users = db.query(User).filter(User.id != current_user.id).all()
    return users

@router.post("/users/me/online", tags=["Users"])
def set_user_online_status(is_online: bool, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    current_user.is_online = is_online
    if not is_online:
        current_user.last_seen = datetime.now(timezone.utc)
    db.commit()
    return {"message": f"User '{current_user.username}' online status updated to {is_online}"}

@router.get("/users/{user_id}/status", tags=["Users"])
def get_user_status(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return {"user_id": user.id, "is_online": user.is_online and crud.is_recently_active(user.last_seen), "last_seen": user.last_seen.isoformat() if user.last_seen else None, "phone": user.phone, "avatar_url": user.avatar_url}

@router.get("/users/friends/unread_counts", response_model=List[schemas.FriendWithUnread], tags=["Users"])
def get_friends_with_unread_counts(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return crud.get_friends_with_unread_counts(db, current_user.id)

@router.post("/users/{friend_id}/mute", tags=["Users"])
def toggle_mute(friend_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    mute = db.query(MuteStatus).filter_by(user_id=current_user.id, muted_user_id=friend_id).first()

    if mute:
        db.delete(mute)  # Unmute
        db.commit()
        return {"muted": False}
    else:
        new_mute = MuteStatus(user_id=current_user.id, muted_user_id=friend_id)
        db.add(new_mute)
        db.commit()
        return {"muted": True}
    
@router.post("/block/{blocked_user_id}", response_model=bool)
def toggle_block_user(
    blocked_user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    block = db.query(BlockStatus).filter_by(
        user_id=current_user.id,
        blocked_user_id=blocked_user_id
    ).first()

    if block:
        db.delete(block)
        db.commit()
        return False  # Unblocked
    else:
        new_block = BlockStatus(user_id=current_user.id, blocked_user_id=blocked_user_id)
        db.add(new_block)
        db.commit()
        return True  # Blocked


@router.get("/users/{user_id}/muted", tags=["Users"])
def is_user_muted(user_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    if user_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot check mute status for self")

    mute = db.query(MuteStatus).filter_by(user_id=current_user.id, muted_user_id=user_id).first()
    return {"muted": mute is not None}

@router.get("/users/{user_id}/friends", response_model=List[UserOut], tags=["Users"])
def get_friends(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view friends of another user")

    friends = crud.get_friends(db, user_id)
    return friends  

@router.get("/users/{user_id}/friends/online", response_model=List[UserOut], tags=["Users"])
def get_online_friends(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view online friends of another user")

    online_friends = crud.get_online_friends(db, user_id)
    return online_friends       

@router.get("/users/{user_id}/friends/offline", response_model=List[UserOut], tags=["Users"])
def get_offline_friends(    
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view offline friends of another user")

    offline_friends = crud.get_offline_friends(db, user_id)
    return offline_friends  

@router.get("/users/{user_id}/friends/muted", response_model=List[UserOut], tags=["Users"])
def get_muted_friends(                                  
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view muted friends of another user")

    muted_friends = crud.get_muted_friends(db, user_id)
    return muted_friends    

@router.get("/users/{user_id}/friends/online_count", tags=["Users"])
def get_online_friends_count(               
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view online friends count of another user")

    online_count = crud.get_online_friends_count(db, user_id)
    return {"online_friends_count": online_count}   

@router.get("/users/{user_id}/friends/offline_count", tags=["Users"])
def get_offline_friends_count(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view offline friends count of another user")

    offline_count = crud.get_offline_friends_count(db, user_id)
    return {"offline_friends_count": offline_count}     

@router.get("/users/{user_id}/friends/muted_count", tags=["Users"])
def get_muted_friends_count(            
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view muted friends count of another user")

    muted_count = crud.get_muted_friends_count(db, user_id)
    return {"muted_friends_count": muted_count} 

@router.get("/users/{user_id}/friends/last_seen_count", tags=["Users"])
def get_friends_last_seen_count(                
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view last seen count of another user's friends")

    last_seen_count = crud.get_friends_last_seen_count(db, user_id)
    return {"friends_last_seen_count": last_seen_count} 

@router.get("/users/{user_id}/friends/online_status", tags=["Users"])
def get_friends_online_status(      
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view online status of another user's friends")

    online_status = crud.get_friends_online_status(db, user_id)
    return online_status    

@router.get("/users/{user_id}/friends/offline_status", tags=["Users"])
def get_friends_offline_status(             
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view offline status of another user's friends")

    offline_status = crud.get_friends_offline_status(db, user_id)
    return offline_status   


@router.get("/users/{user_id}/friends/blocked", response_model=List[UserOut], tags=["Users"])
def get_blocked_friends(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view blocked friends of another user")

    blocked_friends = crud.get_blocked_friends(db, user_id)
    return blocked_friends  

@router.get("/users/{user_id}/friends/blocked_count", tags=["Users"])
def get_blocked_friends_count(  
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view blocked friends count of another user")

    blocked_count = crud.get_blocked_friends_count(db, user_id)
    return {"blocked_friends_count": blocked_count} 

@router.get("/users/{user_id}/friends/blocked_status", tags=["Users"])
def get_blocked_friends_status( 
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    if user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view blocked status of another user's friends")

    blocked_status = crud.get_blocked_friends_status(db, user_id)
    return blocked_status   

