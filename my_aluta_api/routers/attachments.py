from fastapi import APIRouter, UploadFile, File, Depends, HTTPException, Response
from sqlalchemy.orm import Session
import uuid

from database import get_db
from models import User, MediaAsset
from .users import get_current_user

router = APIRouter(tags=["Attachments"])

# Max attachment size. Media is stored in Postgres, so keep this modest —
# voice notes and compressed images are small; big files should be capped.
MAX_BYTES = 15 * 1024 * 1024  # 15 MB


@router.post("/upload/media")
async def upload_media(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Accept any chat attachment (image / file / voice note), store its bytes
    in the database, and return a relative URL the client can reference."""
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")
    if len(data) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="File too large (max 15 MB)")

    asset_id = uuid.uuid4().hex
    mime = file.content_type or "application/octet-stream"
    asset = MediaAsset(
        id=asset_id,
        data=data,
        mime=mime,
        name=file.filename or asset_id,
        size=len(data),
    )
    db.add(asset)
    db.commit()

    return {
        "url": f"/attachments/{asset_id}",
        "name": file.filename,
        "mime": mime,
        "size": len(data),
    }


@router.get("/attachments/{asset_id}")
def get_attachment(asset_id: str, db: Session = Depends(get_db)):
    """Stream an attachment back by id. Intentionally unauthenticated so image
    widgets can load it directly by URL; the random uuid acts as the capability
    token (unguessable), matching how most chat CDNs serve media."""
    asset = db.query(MediaAsset).filter(MediaAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Attachment not found")
    headers = {
        "Content-Disposition": f'inline; filename="{asset.name or asset_id}"',
        # Attachments are immutable (uuid-addressed), so cache hard.
        "Cache-Control": "public, max-age=31536000, immutable",
    }
    return Response(
        content=asset.data,
        media_type=asset.mime or "application/octet-stream",
        headers=headers,
    )
