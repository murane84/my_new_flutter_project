import os
import uuid

from fastapi import APIRouter, UploadFile, File, Depends, HTTPException, Response
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from database import get_db
from models import User, MediaAsset, Message
from .users import get_current_user

router = APIRouter(tags=["Attachments"])

# Max attachment size. Media is stored in Postgres, so keep this modest —
# voice notes and compressed images are small; big files should be capped.
MAX_BYTES = 15 * 1024 * 1024  # 15 MB

# Root of on-disk media (legacy /media/audio/* voice notes). Resolved absolute
# so we can reject path-traversal attempts.
_MEDIA_DIR = os.path.abspath("media")


def _owner_of(db: Session, fragment: str, uploader_id):
    """The user who legitimately owns the media referenced by `fragment`.

    For DB attachments we trust `uploader_id` (set server-side at upload time).
    For disk files / legacy rows with no recorded uploader, we fall back to the
    sender of the EARLIEST message that references it: a forged self-message is
    always newer than the real one, so an attacker can't hijack ownership of
    media someone else already sent. Returns None if ownership can't be
    established (e.g. an orphan file no message references).
    """
    if uploader_id is not None:
        return uploader_id
    first_ref = (
        db.query(Message.sender_id)
        .filter(Message.media_url.contains(fragment, autoescape=True))
        .order_by(Message.timestamp.asc(), Message.id.asc())
        .first()
    )
    return first_ref[0] if first_ref else None


def _can_access(
    db: Session, user_id: int, fragment: str, uploader_id, allow_avatar: bool
) -> bool:
    """Whether `user_id` may view the media whose URL contains `fragment`.

    Access is granted when the requester is:
      1. the owner (uploader, or earliest-message sender for ownerless files);
      2. someone the *owner* sent it to in a message — the `sender_id == owner`
         clause is the crux: sender_id is server-set, so an attacker can't forge
         a message "from" the owner and self-authorize; or
      3. (only when `allow_avatar`) viewing a profile picture.

    `allow_avatar` is True only for the /attachments route — profile pictures
    are always DB attachments. The /media disk route passes False, so voice
    notes NEVER consult the avatar table (they are never avatars, and the
    avatar_url column is client-writable — see below).

    For an asset with a known uploader the avatar check is PINNED to that
    uploader's own avatar, so a user can't point their avatar at someone else's
    private asset to unlock it. For a LEGACY attachment with no uploader we fall
    back to the historical "is it anyone's avatar" check so existing profile
    pictures keep loading. That fallback trusts the client-writable avatar_url,
    but a legacy NULL-uploader asset was world-readable via the old public mount
    before this change, so it exposes nothing that wasn't already public — the
    graceful-migration tail. Every NEW asset gets an uploader_id at upload time
    and so is covered by the pinned branch, never the fallback.

    `autoescape=True` escapes LIKE wildcards (% and _) that can appear in disk
    filenames, so the substring match can't be widened. Both the asset uuid and
    the disk file path are unique, so `contains` can't collide across files.
    """
    owner_id = _owner_of(db, fragment, uploader_id)

    if owner_id is not None:
        if owner_id == user_id:
            return True
        owner_sent_to_me = (
            db.query(Message.id)
            .filter(
                Message.media_url.contains(fragment, autoescape=True),
                Message.sender_id == owner_id,
                Message.receiver_id == user_id,
            )
            .first()
            is not None
        )
        if owner_sent_to_me:
            return True

    if not allow_avatar:
        return False

    # Profile pictures are visible to any signed-in user (in Aluta anyone can DM
    # anyone). New/known-uploader avatars are pinned to their uploader; legacy
    # NULL-uploader avatars (already public pre-change) use the historical check.
    if uploader_id is not None:
        return (
            db.query(User.id)
            .filter(
                User.id == uploader_id,
                User.avatar_url.contains(fragment, autoescape=True),
            )
            .first()
            is not None
        )
    return (
        db.query(User.id)
        .filter(User.avatar_url.contains(fragment, autoescape=True))
        .first()
        is not None
    )


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
        uploader_id=current_user.id,
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
def get_attachment(
    asset_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Stream a DB attachment ONLY to someone entitled to it: the uploader, a
    participant the uploader sent it to, or — for profile pictures — any signed-
    in user. Requires a valid JWT, so media is no longer world-readable."""
    asset = db.query(MediaAsset).filter(MediaAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Attachment not found")
    if not _can_access(
        db, current_user.id, asset_id, asset.uploader_id, allow_avatar=True
    ):
        raise HTTPException(status_code=403, detail="Not authorized to view this file")
    headers = {
        "Content-Disposition": f'inline; filename="{asset.name or asset_id}"',
        # Immutable, but PRIVATE now that access is per-user — shared proxies /
        # CDNs must not cache it; the client may.
        "Cache-Control": "private, max-age=31536000, immutable",
    }
    return Response(
        content=asset.data,
        media_type=asset.mime or "application/octet-stream",
        headers=headers,
    )


@router.get("/media/{file_path:path}")
def get_media_file(
    file_path: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Authenticated replacement for the old public /media static mount. Serves a
    disk file (voice notes at /media/audio/*) only to a participant of the
    conversation it belongs to. Path-traversal safe."""
    candidate = os.path.abspath(os.path.join(_MEDIA_DIR, file_path))
    if candidate != _MEDIA_DIR and not candidate.startswith(_MEDIA_DIR + os.sep):
        raise HTTPException(status_code=404, detail="Not found")
    if not os.path.isfile(candidate):
        raise HTTPException(status_code=404, detail="Not found")
    # Disk files have no MediaAsset row (no uploader) and are never avatars, so
    # the avatar table is never consulted for them.
    if not _can_access(db, current_user.id, file_path, None, allow_avatar=False):
        raise HTTPException(status_code=403, detail="Not authorized to view this file")
    return FileResponse(
        candidate,
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )
