"""🔒 Encrypted backup kept on the server (end-to-end, recovery key).

The app builds the same backup as the file (chats, Our Space, and the keys
to the encrypted chats), locks it on the phone with a key derived from a
random 256-bit RECOVERY KEY the person keeps (shown once in the app), and
uploads only the locked bytes. The server never sees the recovery key, so
it can't open the backup — and with 256 bits there is nothing to guess.

    GET    /e2ee/backup/info   {exists, size, updated_at}
    GET    /e2ee/backup        the locked backup (base64)
    PUT    /e2ee/backup        replace it ({"blob": base64})
    DELETE /e2ee/backup        remove it
"""
import base64
import binascii

from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy.orm import Session

from auth import get_current_user
from database import get_db
from models import CloudBackup, User

router = APIRouter(prefix="/e2ee/backup", tags=["E2EE"])

MAX_BYTES = 25 * 1024 * 1024      # locked backup (chats are text; media aren't in it)
MAGIC = b"ACB1"                   # the app's locked-backup header


@router.get("/info")
def backup_info(db: Session = Depends(get_db),
                me: User = Depends(get_current_user)):
    b = db.query(CloudBackup).filter(CloudBackup.user_id == me.id).first()
    if b is None:
        return {"exists": False}
    return {"exists": True, "size": b.size,
            "updated_at": b.updated_at.isoformat() if b.updated_at else None}


@router.get("")
def get_backup(db: Session = Depends(get_db),
               me: User = Depends(get_current_user)):
    b = db.query(CloudBackup).filter(CloudBackup.user_id == me.id).first()
    if b is None:
        raise HTTPException(status_code=404, detail="No backup")
    return {"blob": base64.b64encode(b.blob).decode(),
            "updated_at": b.updated_at.isoformat() if b.updated_at else None}


@router.put("")
def put_backup(body: dict = Body(...), db: Session = Depends(get_db),
               me: User = Depends(get_current_user)):
    raw = body.get("blob")
    if not isinstance(raw, str) or len(raw) > MAX_BYTES * 4 // 3 + 8:
        raise HTTPException(status_code=413, detail="Backup too large")
    try:
        blob = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=400, detail="Bad backup")
    # Only ever locked bytes: the app's header, then nonce + ciphertext.
    if not blob.startswith(MAGIC) or len(blob) < len(MAGIC) + 12 + 16:
        raise HTTPException(status_code=400, detail="Not a locked backup")
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    b = db.query(CloudBackup).filter(CloudBackup.user_id == me.id).first()
    if b is None:
        b = CloudBackup(user_id=me.id)
        db.add(b)
    b.blob, b.size, b.updated_at = blob, len(blob), now
    db.commit()
    return {"ok": True, "size": len(blob), "updated_at": now.isoformat()}


@router.delete("")
def delete_backup(db: Session = Depends(get_db),
                  me: User = Depends(get_current_user)):
    db.query(CloudBackup).filter(CloudBackup.user_id == me.id).delete(
        synchronize_session=False)
    db.commit()
    return {"ok": True}
