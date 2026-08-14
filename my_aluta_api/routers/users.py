from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from typing import List
from datetime import datetime, timezone
import re
import json
from models import BlockStatus
from database import get_db
from models import User, MuteStatus, Friend, UserContactBook, UserTrackOverrides
import crud, schemas
from schemas import UserOut  # Ensure this contains fields like id, email, username, is_online
from auth import get_current_user, get_password_hash, verify_password

router = APIRouter()


def _phone_keys(p: str) -> set:
    """Match keys for a phone number. Prefers the FULL E.164 digits (country
    code + national number) — the modern, cross-country-correct key — and also
    includes the last 9 digits as a fallback so numbers stored before the E.164
    switch (no country code) still match."""
    digits = re.sub(r"\D", "", p or "")
    keys = set()
    if len(digits) >= 8:
        keys.add(digits)          # full E.164 (e.g. 255765123456)
    if len(digits) >= 9:
        keys.add(digits[-9:])     # legacy fallback (national tail)
    return keys


@router.post("/users/contacts/sync", tags=["Users"])
def sync_contacts(
    payload: schemas.ContactsSync,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Match phone-book numbers against registered users and auto-add the ones
    found as friends. Returns the matched users + how many were newly added, so
    a user only ever discovers people already in their own contacts — never the
    whole registered-user table."""
    contact_keys = set()
    for p in payload.phones:
        contact_keys |= _phone_keys(p)
    if not contact_keys:
        return {"matched": [], "added": 0}
    candidates = (
        db.query(User)
        .filter(User.phone.isnot(None), User.id != current_user.id)
        .all()
    )
    matched = [u for u in candidates if _phone_keys(u.phone) & contact_keys]
    added = 0
    for u in matched:
        exists = (
            db.query(Friend)
            .filter(
                ((Friend.user_id == current_user.id) & (Friend.friend_id == u.id))
                | ((Friend.user_id == u.id) & (Friend.friend_id == current_user.id))
            )
            .first()
        )
        if not exists:
            db.add(Friend(user_id=current_user.id, friend_id=u.id))
            added += 1
    if added:
        db.commit()
    return {
        "matched": [UserOut.model_validate(u) for u in matched],
        "added": added,
    }

@router.post("/users/contacts/names", tags=["Users"])
def upload_contact_names(
    payload: schemas.ContactNamesUpload,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The phone uploads its number→saved-name map (already normalised keys) so
    the DESKTOP app can show the user's own saved contact names. Private to the
    user — one row per user, replaced on each sync."""
    names = payload.names or {}
    data = json.dumps({str(k): str(v) for k, v in names.items()})
    row = (
        db.query(UserContactBook)
        .filter(UserContactBook.user_id == current_user.id)
        .first()
    )
    if row:
        row.data = data
    else:
        db.add(UserContactBook(user_id=current_user.id, data=data))
    db.commit()
    return {"ok": True, "count": len(names)}


@router.get(
    "/users/contacts/names",
    response_model=schemas.ContactNamesOut,
    tags=["Users"],
)
def get_contact_names(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The desktop app downloads the user's saved-name map after QR login."""
    row = (
        db.query(UserContactBook)
        .filter(UserContactBook.user_id == current_user.id)
        .first()
    )
    names = {}
    if row and row.data:
        try:
            parsed = json.loads(row.data)
            if isinstance(parsed, dict):
                names = {str(k): str(v) for k, v in parsed.items()}
        except Exception:
            names = {}
    return schemas.ContactNamesOut(names=names)


@router.post("/users/track-overrides", tags=["Users"])
def upload_track_overrides(
    payload: schemas.TrackOverridesUpload,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The app backs up the user's edited song details (custom title/artist/…)
    so they survive a reinstall/update or a new device on the same account.
    Private to the user — one row per user, replaced on each sync. The client
    only pushes AFTER it has pulled and merged the server copy, so a full
    replace here never loses server-side edits."""
    overrides = payload.overrides or {}
    # Store verbatim (values are the client's compact {t,a,al,g,y} maps).
    data = json.dumps({str(k): v for k, v in overrides.items() if isinstance(v, dict)})
    row = (
        db.query(UserTrackOverrides)
        .filter(UserTrackOverrides.user_id == current_user.id)
        .first()
    )
    if row:
        row.data = data
    else:
        db.add(UserTrackOverrides(user_id=current_user.id, data=data))
    db.commit()
    return {"ok": True, "count": len(overrides)}


@router.get(
    "/users/track-overrides",
    response_model=schemas.TrackOverridesOut,
    tags=["Users"],
)
def get_track_overrides(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The app pulls the user's backed-up song-detail edits after login and
    merges them into local storage (local edits win on conflict)."""
    row = (
        db.query(UserTrackOverrides)
        .filter(UserTrackOverrides.user_id == current_user.id)
        .first()
    )
    overrides = {}
    if row and row.data:
        try:
            parsed = json.loads(row.data)
            if isinstance(parsed, dict):
                overrides = {
                    str(k): v for k, v in parsed.items() if isinstance(v, dict)
                }
        except Exception:
            overrides = {}
    return schemas.TrackOverridesOut(overrides=overrides)


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
        new_phone = payload.phone.strip()
        if new_phone:
            # Must be valid E.164 and unique (it's the contact-discovery key).
            if not re.fullmatch(r"\+\d{8,15}", new_phone):
                raise HTTPException(
                    status_code=400,
                    detail="Enter a valid phone number with country code (e.g. +255…).",
                )
            clash = (
                db.query(User)
                .filter(User.phone == new_phone, User.id != current_user.id)
                .first()
            )
            if clash:
                raise HTTPException(
                    status_code=400,
                    detail="That phone number is already registered.",
                )
            current_user.phone = new_phone
        else:
            current_user.phone = None

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


def _is_friend(db: Session, a: int, b: int) -> bool:
    return db.query(Friend).filter(
        ((Friend.user_id == a) & (Friend.friend_id == b))
        | ((Friend.user_id == b) & (Friend.friend_id == a))
    ).first() is not None


@router.get("/users/lookup", tags=["Users"])
def lookup_user(
    q: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Find ONE user to add as a friend, by EXACT @username or full phone number
    (no partial/browse search — strangers stay undiscoverable). Used by the
    desktop/web 'Add friend' flow where there's no phone-book to scan."""
    query = (q or "").strip()
    if not query:
        raise HTTPException(status_code=400, detail="Enter a username or phone number")
    user = None
    # Treat it as a phone number when it looks like one; else an exact username.
    digits = re.sub(r"\D", "", query)
    if query.startswith("+") or len(digits) >= 8:
        keys = _phone_keys(query)
        if keys:
            candidates = (
                db.query(User)
                .filter(User.phone.isnot(None), User.id != current_user.id)
                .all()
            )
            for u in candidates:
                if _phone_keys(u.phone) & keys:
                    user = u
                    break
    if user is None:
        # Exact, case-insensitive username match (ilike with no wildcards).
        user = (
            db.query(User)
            .filter(User.username.ilike(query), User.id != current_user.id)
            .first()
        )
    if user is None:
        raise HTTPException(status_code=404, detail="No Aluta user with that username or number")
    return {
        "user": UserOut.model_validate(user),
        "is_friend": _is_friend(db, current_user.id, user.id),
    }


@router.get("/users/friends/listening", tags=["Users"])
def friends_listening(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Friends who are playing music RIGHT NOW — the snapshot that seeds the
    'Listening now' zone on load (live updates then arrive over the WebSocket as
    'friend_now_playing'). Returns [{user_id, username, avatar_url, track}]."""
    from websocket_manager import get_now_playing
    out = []
    for fid in crud._get_friend_ids(db, current_user.id):
        track = get_now_playing(int(fid))
        if not track:
            continue
        u = db.query(User).filter(User.id == fid).first()
        if not u:
            continue
        out.append({
            "user_id": int(fid),
            "username": u.username,
            "avatar_url": u.avatar_url,
            "track": track,
        })
    return {"listening": out}


@router.post("/users/friends/add", tags=["Users"])
def add_friend(
    payload: schemas.FriendAdd,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Add a friend instantly (mutual — both can chat). Idempotent."""
    target_id = payload.user_id
    if target_id == current_user.id:
        raise HTTPException(status_code=400, detail="You can't add yourself")
    target = db.query(User).filter(User.id == target_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    if not _is_friend(db, current_user.id, target_id):
        db.add(Friend(user_id=current_user.id, friend_id=target_id))
        db.commit()
    return {"ok": True, "user": UserOut.model_validate(target)}


@router.delete("/users/friends/{friend_id}", tags=["Users"])
def remove_friend(
    friend_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove someone from your circle (drops the friendship for both sides)."""
    db.query(Friend).filter(
        ((Friend.user_id == current_user.id) & (Friend.friend_id == friend_id))
        | ((Friend.user_id == friend_id) & (Friend.friend_id == current_user.id))
    ).delete(synchronize_session=False)
    db.commit()
    return {"ok": True}

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

