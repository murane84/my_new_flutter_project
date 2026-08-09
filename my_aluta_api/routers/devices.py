"""Device (FCM) token registration endpoints.

The client registers its Firebase Cloud Messaging token here after login so the
backend can push new-message / incoming-call notifications when the app is
backgrounded or closed. Tokens are unregistered on logout.
"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from database import get_db
from models import User, DeviceToken
from auth import get_current_user
import schemas

router = APIRouter(tags=["Devices"])


@router.post("/devices/token")
def save_device_token(
    payload: schemas.DeviceTokenIn,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Register (or re-home) this device's FCM token to the current user. A
    token is globally unique — if it already exists it's simply pointed at the
    caller (handles a shared device where a new user logs in)."""
    token = (payload.token or "").strip()
    if not token:
        return {"ok": False, "detail": "empty token"}
    now = datetime.now(timezone.utc)
    row = db.query(DeviceToken).filter(DeviceToken.token == token).first()
    if row:
        row.user_id = current_user.id
        row.platform = payload.platform
        row.updated_at = now
    else:
        db.add(DeviceToken(
            user_id=current_user.id,
            token=token,
            platform=payload.platform,
            updated_at=now,
        ))
    db.commit()
    return {"ok": True}


@router.delete("/devices/token")
def delete_device_token(
    payload: schemas.DeviceTokenIn,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Unregister this device's token (e.g. on logout) so it stops receiving
    pushes for the account."""
    token = (payload.token or "").strip()
    if token:
        db.query(DeviceToken).filter(
            DeviceToken.token == token,
            DeviceToken.user_id == current_user.id,
        ).delete(synchronize_session=False)
        db.commit()
    return {"ok": True}
