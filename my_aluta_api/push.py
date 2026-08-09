"""Firebase Cloud Messaging (HTTP v1) push helper.

Best-effort push to a user's registered devices so new messages / incoming
calls wake the phone when the app is backgrounded or closed (the WebSocket is
dead then). Everything here is guarded — if Firebase isn't configured or a send
fails, the app keeps working over the WebSocket and nothing raises.

Configure via env (see config.py):
  FIREBASE_PROJECT_ID              - the Firebase project id
  FIREBASE_SERVICE_ACCOUNT_JSON    - the service account JSON (raw string), OR
  FIREBASE_SERVICE_ACCOUNT_FILE    - a path to the service account JSON file
"""
import json
import threading
from typing import Optional

import requests

from database import SessionLocal
from models import DeviceToken
import config

_FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_lock = threading.Lock()
_credentials = None  # cached google.oauth2.service_account.Credentials


def _load_credentials():
    """Build + cache service-account credentials from env. None if Firebase
    isn't configured or google-auth isn't installed."""
    global _credentials
    if _credentials is not None:
        return _credentials
    with _lock:
        if _credentials is not None:
            return _credentials
        try:
            from google.oauth2 import service_account
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ push: google-auth not installed: {e}")
            return None
        info = None
        if config.FIREBASE_SERVICE_ACCOUNT_JSON:
            try:
                info = json.loads(config.FIREBASE_SERVICE_ACCOUNT_JSON)
            except Exception as e:  # noqa: BLE001
                print(f"⚠️ push: FIREBASE_SERVICE_ACCOUNT_JSON invalid: {e}")
                return None
        elif config.FIREBASE_SERVICE_ACCOUNT_FILE:
            try:
                with open(config.FIREBASE_SERVICE_ACCOUNT_FILE) as f:
                    info = json.load(f)
            except Exception as e:  # noqa: BLE001
                print(f"⚠️ push: cannot read service account file: {e}")
                return None
        if not info:
            return None
        try:
            _credentials = service_account.Credentials.from_service_account_info(
                info, scopes=[_FCM_SCOPE])
            return _credentials
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ push: bad service account: {e}")
            return None


def _access_token() -> Optional[str]:
    creds = _load_credentials()
    if creds is None:
        return None
    try:
        from google.auth.transport.requests import Request as GoogleRequest
        if not creds.valid:
            creds.refresh(GoogleRequest())
        return creds.token
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ push: token refresh failed: {e}")
        return None


def _project_id() -> Optional[str]:
    if config.FIREBASE_PROJECT_ID:
        return config.FIREBASE_PROJECT_ID
    creds = _load_credentials()
    return getattr(creds, "project_id", None) if creds else None


def push_available() -> bool:
    return _load_credentials() is not None and _project_id() is not None


def _tokens_for(user_id: int) -> list[str]:
    db = SessionLocal()
    try:
        rows = db.query(DeviceToken).filter(
            DeviceToken.user_id == user_id).all()
        return [r.token for r in rows]
    except Exception:  # noqa: BLE001
        return []
    finally:
        db.close()


def _delete_token(token: str) -> None:
    db = SessionLocal()
    try:
        db.query(DeviceToken).filter(DeviceToken.token == token).delete(
            synchronize_session=False)
        db.commit()
    except Exception:  # noqa: BLE001
        db.rollback()
    finally:
        db.close()


def send_push_to_user(
    user_id: int,
    data: dict,
    notification: Optional[dict] = None,
) -> None:
    """Best-effort FCM data push to every registered device of {user_id}. Never
    raises. Data values are coerced to strings (FCM v1 requirement). Tokens FCM
    reports as unregistered are pruned so we stop pushing to dead devices."""
    try:
        if not push_available():
            return
        tokens = _tokens_for(user_id)
        if not tokens:
            return
        access = _access_token()
        pid = _project_id()
        if not access or not pid:
            return
        url = f"https://fcm.googleapis.com/v1/projects/{pid}/messages:send"
        headers = {
            "Authorization": f"Bearer {access}",
            "Content-Type": "application/json; UTF-8",
        }
        str_data = {str(k): str(v) for k, v in (data or {}).items()}
        for token in tokens:
            body = {
                "message": {
                    "token": token,
                    "data": str_data,
                    # High priority so a data-only message wakes a dozing app.
                    "android": {"priority": "high"},
                }
            }
            if notification:
                body["message"]["notification"] = notification
            try:
                resp = requests.post(
                    url, headers=headers, data=json.dumps(body), timeout=10)
                if resp.status_code == 200:
                    continue
                text = resp.text or ""
                if resp.status_code in (400, 403, 404) and (
                    "UNREGISTERED" in text
                    or "NOT_FOUND" in text
                    or "InvalidRegistration" in text
                    or "registration-token-not-registered" in text
                ):
                    _delete_token(token)
                else:
                    print(f"⚠️ push: FCM {resp.status_code}: {text[:200]}")
            except Exception as e:  # noqa: BLE001
                print(f"⚠️ push: send failed: {e}")
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ push: unexpected: {e}")
