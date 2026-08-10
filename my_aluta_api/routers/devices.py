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
import push

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


@router.get("/push/health")
def push_health(db: Session = Depends(get_db)):
    """Diagnostic (public, no login) — is push deliverable at all, right now?

    Open https://<host>/push/health in a browser. It reports only booleans +
    counts (no secrets), so it's safe to leave public while debugging.

      * push_configured — the SERVER holds valid Firebase service-account
        credentials (FIREBASE_SERVICE_ACCOUNT_JSON + FIREBASE_PROJECT_ID). If
        false, send_push_to_user() returns immediately and NO push is ever sent,
        so a closed phone never rings. (Integrating Firebase in the *app* does
        NOT set these — the backend needs its own service account.)

      * registered_devices_total — how many phones (across all users) have
        registered an FCM token. If 0, no phone ever told the server where to
        push (notifications denied, app never opened after login, or web-only).

    Both green but calls still don't wake the phone → watch the Railway deploy
    logs while placing a test call: push.py now logs a [push] SEND/DONE line and
    the exact FCM error (e.g. SENDER_ID_MISMATCH = the app's google-services.json
    is from a different Firebase project than this service account).
    """
    try:
        total_tokens = db.query(DeviceToken).count()
    except Exception:  # noqa: BLE001
        total_tokens = -1
    return {
        "push_configured": push.push_available(),
        "project_id": push._project_id(),
        "service_account_present": push._load_credentials() is not None,
        "registered_devices_total": total_tokens,
    }
