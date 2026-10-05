import os
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import (
    APIRouter, UploadFile, File, Depends, HTTPException, Response, Request,
)
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from database import get_db
from models import (
    User, MediaAsset, Message, Conversation, ConversationMember,
    PinnedMoment, SpaceMember, Dedication, PlaylistTrack,
)
from .users import get_current_user
from auth import get_current_user_flexible

router = APIRouter(tags=["Attachments"])

# Max attachment size. Media is stored in Postgres, so keep this modest —
# voice notes and compressed images are small; big files should be capped.
MAX_BYTES = 15 * 1024 * 1024  # 15 MB (images / files / voice)
VIDEO_MAX_BYTES = 64 * 1024 * 1024  # 64 MB (video — larger by nature)

# Ephemeral shared songs are purged from the server this long after upload even
# if the recipient never fetched them (the normal case purges on cache-ack, far
# sooner). This is the "leave a reference, don't hoard the bytes" TTL.
EPHEMERAL_TTL = timedelta(days=7)

# Root of on-disk media (legacy /media/audio/* voice notes). Resolved absolute
# so we can reject path-traversal attempts.
_MEDIA_DIR = os.path.abspath("media")


def purge_expired_ephemeral(db: Session) -> int:
    """Null out the bytes of ephemeral assets older than EPHEMERAL_TTL whose
    data hasn't already been purged. Cheap set-based UPDATE, run opportunistically
    on write activity (uploads / cache-acks). Best-effort: never raises into the
    caller. Returns the number of rows purged."""
    try:
        cutoff = datetime.now(timezone.utc) - EPHEMERAL_TTL
        now = datetime.now(timezone.utc)
        n = (
            db.query(MediaAsset)
            .filter(
                MediaAsset.ephemeral.is_(True),
                MediaAsset.data.isnot(None),
                MediaAsset.created_at < cutoff,
            )
            .update(
                {MediaAsset.data: None, MediaAsset.purged_at: now},
                synchronize_session=False,
            )
        )
        db.commit()
        return n or 0
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ purge_expired_ephemeral failed: {e}")
        try:
            db.rollback()
        except Exception:  # noqa: BLE001
            pass
        return 0


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

    # GROUP (and DM) conversation attachments: any MEMBER of the conversation
    # that carries this media may view it. Group messages have receiver_id = NULL
    # (they route by conversation_id), so the sender/receiver check above never
    # covers them — this does, for every member.
    conv_row = (
        db.query(Message.conversation_id)
        .filter(
            Message.media_url.contains(fragment, autoescape=True),
            Message.conversation_id.isnot(None),
        )
        .order_by(Message.id.asc())
        .first()
    )
    if conv_row and conv_row[0]:
        is_member = (
            db.query(ConversationMember.user_id)
            .filter(
                ConversationMember.conversation_id == conv_row[0],
                ConversationMember.user_id == user_id,
            )
            .first()
            is not None
        )
        if is_member:
            return True

    # GROUP AVATAR: the photo lives on the Conversation (not on any User), so the
    # profile-picture branch below never matches it. Members of that group may
    # view its photo.
    grp_avatar = (
        db.query(Conversation.id)
        .filter(Conversation.avatar_url.contains(fragment, autoescape=True))
        .first()
    )
    if grp_avatar and grp_avatar[0]:
        is_member = (
            db.query(ConversationMember.user_id)
            .filter(
                ConversationMember.conversation_id == grp_avatar[0],
                ConversationMember.user_id == user_id,
            )
            .first()
            is not None
        )
        if is_member:
            return True

    # OUR SPACE moments: a member of the space that pinned a moment referencing
    # this asset may view it. A moment can be kept from a chat the viewer was
    # never part of (a friend's DM, a group), so SPACE membership — not chat
    # membership — is the authorization, and it covers both partners (each owns
    # a mirror Space whose members are the two of them).
    mom_space_ids = [
        r[0]
        for r in db.query(PinnedMoment.space_id)
        .filter(PinnedMoment.ref.contains(fragment, autoescape=True))
        .all()
        if r[0] is not None
    ]
    if mom_space_ids:
        in_space = (
            db.query(SpaceMember.user_id)
            .filter(
                SpaceMember.space_id.in_(mom_space_ids),
                SpaceMember.user_id == user_id,
            )
            .first()
            is not None
        )
        if in_space:
            return True

    # Dedications / Our Playlist tracks kept into a bond: a member of the pair
    # may fetch the song/voice/video. These are keyed by pair_key ("lo:hi"), not
    # a space id, so authorize by pair membership.
    bond_pair_keys = set()
    for (pk,) in (
        db.query(Dedication.pair_key)
        .filter(Dedication.track_ref.contains(fragment, autoescape=True))
        .all()
    ):
        if pk:
            bond_pair_keys.add(pk)
    for (pk,) in (
        db.query(PlaylistTrack.pair_key)
        .filter(PlaylistTrack.ref.contains(fragment, autoescape=True))
        .all()
    ):
        if pk:
            bond_pair_keys.add(pk)
    if bond_pair_keys:
        uid_s = str(user_id)
        for pk in bond_pair_keys:
            if uid_s in str(pk).split(":"):
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
    ephemeral: bool = False,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Accept any chat attachment (image / file / voice note), store its bytes
    in the database, and return a relative URL the client can reference.

    When `ephemeral=true` (a shared song), the bytes are marked for early purge:
    the recipient caches the file locally and acks via /attachments/<id>/cached,
    which empties the bytes here; a 7-day TTL is the fallback. This keeps big
    audio files off the server long-term while the message keeps a reference."""
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")
    _mime = (file.content_type or "").lower()
    _is_video = _mime.startswith("video/")
    _cap = VIDEO_MAX_BYTES if _is_video else MAX_BYTES
    if len(data) > _cap:
        _mb = _cap // (1024 * 1024)
        raise HTTPException(
            status_code=413, detail=f"File too large (max {_mb} MB)")

    # Opportunistic housekeeping: every new upload sweeps out expired ephemeral
    # bytes so old shared songs don't accumulate even if no one re-fetched them.
    purge_expired_ephemeral(db)

    asset_id = uuid.uuid4().hex
    mime = file.content_type or "application/octet-stream"
    asset = MediaAsset(
        id=asset_id,
        data=data,
        mime=mime,
        name=file.filename or asset_id,
        size=len(data),
        uploader_id=current_user.id,
        ephemeral=bool(ephemeral),
    )
    db.add(asset)
    db.commit()

    return {
        "url": f"/attachments/{asset_id}",
        "name": file.filename,
        "mime": mime,
        "size": len(data),
        "ephemeral": bool(ephemeral),
    }


@router.get("/attachments/{asset_id}")
def get_attachment(
    asset_id: str,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_flexible),
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
    # Ephemeral song whose bytes were purged after delivery: the row survives as
    # a reference but the file lives only in the participants' local caches now.
    # 410 Gone tells the client to fall back to its cached copy (or show that the
    # song is no longer available if it never cached it).
    if asset.data is None:
        raise HTTPException(status_code=410, detail="Attachment no longer on server")
    headers = {
        "Content-Disposition": f'inline; filename="{asset.name or asset_id}"',
        # Immutable, but PRIVATE now that access is per-user — shared proxies /
        # CDNs must not cache it; the client may.
        "Cache-Control": "private, max-age=31536000, immutable",
    }
    # Serve with HTTP Range support so players (video especially) can start
    # after the first chunk instead of downloading the whole file first, and
    # can seek. Falls back to a full 200 when no Range header is present.
    data = asset.data
    total = len(data)
    media_type = asset.mime or "application/octet-stream"
    range_header = request.headers.get("range") or request.headers.get("Range")
    if range_header and range_header.strip().lower().startswith("bytes="):
        try:
            spec = range_header.split("=", 1)[1].split(",")[0].strip()
            start_s, _, end_s = spec.partition("-")
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else total - 1
            if start < 0:
                start = 0
            if end >= total:
                end = total - 1
            if start > end or start >= total:
                return Response(
                    status_code=416,
                    headers={
                        "Content-Range": f"bytes */{total}",
                        "Accept-Ranges": "bytes",
                    },
                )
            chunk = data[start:end + 1]
            r_headers = dict(headers)
            r_headers.update({
                "Accept-Ranges": "bytes",
                "Content-Range": f"bytes {start}-{end}/{total}",
                "Content-Length": str(len(chunk)),
            })
            return Response(
                content=chunk,
                status_code=206,
                media_type=media_type,
                headers=r_headers,
            )
        except Exception:
            pass
    headers["Accept-Ranges"] = "bytes"
    headers["Content-Length"] = str(total)
    return Response(content=data, media_type=media_type, headers=headers)


@router.post("/attachments/{asset_id}/cached")
def ack_cached(
    asset_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The recipient of an ephemeral shared song acknowledges it's now cached on
    their device. We record the ack and purge the bytes from the server (keeping
    the row as a reference). Idempotent: acking an already-purged asset is a
    no-op success.

    Only the RECIPIENT may trigger the purge — verified by requiring a message
    that carries this asset TO the caller. The sender must not purge (the
    recipient may not have fetched yet); the sender keeps its own local copy from
    send time. `sender_id`/`receiver_id` are server-set, so this can't be forged."""
    asset = db.query(MediaAsset).filter(MediaAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Attachment not found")

    # Non-ephemeral assets are never purged this way — treat as a harmless no-op
    # so an over-eager client can't delete ordinary attachments.
    if not asset.ephemeral:
        return {"ok": True, "purged": False}

    is_recipient = (
        db.query(Message.id)
        .filter(
            Message.media_url.contains(asset_id, autoescape=True),
            Message.receiver_id == current_user.id,
        )
        .first()
        is not None
    )
    if not is_recipient:
        raise HTTPException(status_code=403, detail="Not a recipient of this song")

    # Opportunistic TTL sweep while we're here (recipient activity).
    purge_expired_ephemeral(db)

    now = datetime.now(timezone.utc)
    if asset.cached_at is None:
        asset.cached_at = now
    if asset.data is not None:
        asset.data = None
        asset.purged_at = now
    db.commit()
    return {"ok": True, "purged": True}


@router.get("/media/{file_path:path}")
def get_media_file(
    file_path: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_flexible),
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
