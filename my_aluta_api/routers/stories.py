"""Ephemeral 24-hour Stories.

A user posts a photo, a short video clip, or a "now playing" music moment; it
is visible to their friends for 24 hours and then expires. There is no
scheduler — a story is "active" while ``expires_at > now`` and expired rows are
swept opportunistically on write, mirroring the ephemeral-media purge pattern
in ``routers/attachments.py``.

Media bytes are reused from the existing MediaAsset store: the client uploads
the photo/clip via ``/upload/media`` (ephemeral=true) and passes the returned
asset id here. Those bytes are served back FRIEND-SCOPED at
``/stories/media/<asset_id>`` so they never leak through the chat-media gate.
"""

import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import func
from sqlalchemy.orm import Session

import schemas
from database import get_db
from models import User, MediaAsset, Story, StoryView
from crud import _get_friend_ids
from .users import get_current_user
from auth import get_current_user_flexible

router = APIRouter(prefix="/stories", tags=["Stories"])

# A story lives for 24 hours from posting.
STORY_TTL = timedelta(hours=24)

VALID_KINDS = {"photo", "video", "music"}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def purge_expired_stories(db: Session) -> int:
    """Delete stories whose 24h window has closed (their StoryView rows cascade
    away with them). Cheap set-based delete run opportunistically on write.
    Best-effort: never raises into the caller. Returns rows deleted."""
    try:
        n = (
            db.query(Story)
            .filter(Story.expires_at < _now())
            .delete(synchronize_session=False)
        )
        db.commit()
        return n or 0
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ purge_expired_stories failed: {e}")
        try:
            db.rollback()
        except Exception:  # noqa: BLE001
            pass
        return 0


def _media_url(story: Story) -> str | None:
    if story.media_asset_id:
        return f"/stories/media/{story.media_asset_id}"
    return None


def _story_out(story: Story, *, viewed: bool, view_count: int = 0) -> schemas.StoryOut:
    return schemas.StoryOut(
        id=story.id,
        author_id=story.author_id,
        kind=story.kind,
        media_url=_media_url(story),
        media_mime=story.media_mime,
        caption=story.caption,
        music_title=story.music_title,
        music_artist=story.music_artist,
        music_art_url=story.music_art_url,
        created_at=story.created_at,
        expires_at=story.expires_at,
        viewed=viewed,
        view_count=view_count,
    )


@router.post("", response_model=schemas.StoryOut)
def create_story(
    payload: schemas.StoryCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Post a new story (expires in 24h). photo/video need a media_asset_id from
    a prior /upload/media; music needs at least a track title."""
    kind = (payload.kind or "photo").strip().lower()
    if kind not in VALID_KINDS:
        raise HTTPException(status_code=400, detail="Invalid story kind")

    if kind in ("photo", "video"):
        if not payload.media_asset_id:
            raise HTTPException(status_code=400, detail="Missing media for story")
        asset = (
            db.query(MediaAsset)
            .filter(MediaAsset.id == payload.media_asset_id)
            .first()
        )
        # The asset must exist and belong to the poster (they just uploaded it).
        if not asset or (
            asset.uploader_id is not None and asset.uploader_id != current_user.id
        ):
            raise HTTPException(status_code=400, detail="Unknown media for story")
    else:  # music
        if not (payload.music_title or payload.caption):
            raise HTTPException(status_code=400, detail="Nothing to post")

    # Housekeeping: clear out anyone's expired stories on this write.
    purge_expired_stories(db)

    now = _now()
    story = Story(
        id=uuid.uuid4().hex,
        author_id=current_user.id,
        kind=kind,
        media_asset_id=payload.media_asset_id if kind in ("photo", "video") else None,
        media_mime=payload.media_mime,
        caption=(payload.caption or None),
        music_title=(payload.music_title or None),
        music_artist=(payload.music_artist or None),
        music_art_url=(payload.music_art_url or None),
        created_at=now,
        expires_at=now + STORY_TTL,
    )
    db.add(story)
    db.commit()
    db.refresh(story)
    # The author has implicitly "seen" their own post.
    return _story_out(story, viewed=True, view_count=0)


@router.get("/feed", response_model=schemas.StoryFeedOut)
def stories_feed(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Active stories from me + my friends, grouped by author. My group first,
    then friends ordered by most-recent story. Each group flags whether I still
    have anything unseen in it (drives the tray's coloured ring)."""
    me = current_user.id
    now = _now()
    purge_expired_stories(db)

    author_ids = set(_get_friend_ids(db, me))
    author_ids.add(me)

    stories = (
        db.query(Story)
        .filter(Story.author_id.in_(author_ids), Story.expires_at > now)
        .order_by(Story.created_at.asc())
        .all()
    )
    if not stories:
        return schemas.StoryFeedOut(groups=[])

    story_ids = [s.id for s in stories]

    # Which of these have I already viewed?
    viewed_ids = {
        row[0]
        for row in db.query(StoryView.story_id)
        .filter(StoryView.viewer_id == me, StoryView.story_id.in_(story_ids))
        .all()
    }

    # View counts for MY own stories only (others don't get to see counts).
    my_story_ids = [s.id for s in stories if s.author_id == me]
    counts: dict[str, int] = {}
    if my_story_ids:
        for sid, c in (
            db.query(StoryView.story_id, func.count(StoryView.id))
            .filter(StoryView.story_id.in_(my_story_ids))
            .group_by(StoryView.story_id)
            .all()
        ):
            counts[sid] = c

    authors = {
        u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()
    }

    grouped: dict[int, list[Story]] = {}
    for s in stories:
        grouped.setdefault(s.author_id, []).append(s)

    def group_out(aid: int) -> schemas.StoryGroupOut:
        u = authors.get(aid)
        is_me = aid == me
        out_stories = []
        unseen = False
        for s in grouped[aid]:
            seen = is_me or (s.id in viewed_ids)
            if not seen:
                unseen = True
            out_stories.append(
                _story_out(
                    s,
                    viewed=seen,
                    view_count=counts.get(s.id, 0) if is_me else 0,
                )
            )
        return schemas.StoryGroupOut(
            author_id=aid,
            username=(u.username if u else ""),
            avatar_url=(u.avatar_url if u else None),
            phone=(u.phone if u else None),
            is_me=is_me,
            has_unseen=(False if is_me else unseen),
            stories=out_stories,
        )

    def latest_ts(aid: int) -> float:
        return max(s.created_at for s in grouped[aid]).timestamp()

    # Me first, then friends by most-recent story descending.
    ordered = sorted(
        grouped.keys(), key=lambda aid: (0 if aid == me else 1, -latest_ts(aid))
    )
    return schemas.StoryFeedOut(groups=[group_out(aid) for aid in ordered])


@router.get("/media/{asset_id}")
def get_story_media(
    asset_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_flexible),
):
    """Stream a story's photo/video bytes — only to the author or one of their
    friends, and only while the story is still active. Flexible auth so the web
    <img>/<video> can pass the token as a ?token= query param."""
    now = _now()
    story = (
        db.query(Story)
        .filter(Story.media_asset_id == asset_id, Story.expires_at > now)
        .first()
    )
    if not story:
        # Either no such story, or it has expired.
        raise HTTPException(status_code=404, detail="Story not found")
    if story.author_id != current_user.id and current_user.id not in _get_friend_ids(
        db, story.author_id
    ):
        raise HTTPException(status_code=403, detail="Not authorized to view this story")

    asset = db.query(MediaAsset).filter(MediaAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Media not found")
    if asset.data is None:
        raise HTTPException(status_code=410, detail="Media no longer on server")

    return Response(
        content=asset.data,
        media_type=asset.mime or "application/octet-stream",
        headers={"Cache-Control": "private, max-age=86400, immutable"},
    )


@router.post("/{story_id}/view")
def mark_viewed(
    story_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Record that I watched a story (idempotent). No-op for my own stories."""
    me = current_user.id
    now = _now()
    story = db.query(Story).filter(Story.id == story_id).first()
    if not story or story.expires_at <= now:
        raise HTTPException(status_code=404, detail="Story not found")
    if story.author_id != me and me not in _get_friend_ids(db, story.author_id):
        raise HTTPException(status_code=403, detail="Not authorized to view this story")
    if story.author_id == me:
        return {"ok": True}  # don't record self-views

    exists = (
        db.query(StoryView)
        .filter(StoryView.story_id == story_id, StoryView.viewer_id == me)
        .first()
    )
    if not exists:
        db.add(StoryView(story_id=story_id, viewer_id=me))
        try:
            db.commit()
        except Exception:  # noqa: BLE001 — unique-race: someone else committed first
            db.rollback()
    return {"ok": True}


@router.get("/{story_id}/viewers", response_model=list[schemas.StoryViewerOut])
def story_viewers(
    story_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Who viewed my story (author only), most-recent first."""
    story = db.query(Story).filter(Story.id == story_id).first()
    if not story:
        raise HTTPException(status_code=404, detail="Story not found")
    if story.author_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the author can see viewers")

    rows = (
        db.query(StoryView, User)
        .join(User, User.id == StoryView.viewer_id)
        .filter(StoryView.story_id == story_id)
        .order_by(StoryView.viewed_at.desc())
        .all()
    )
    return [
        schemas.StoryViewerOut(
            user_id=u.id,
            username=u.username,
            avatar_url=u.avatar_url,
            phone=u.phone,
            viewed_at=v.viewed_at,
        )
        for v, u in rows
    ]


@router.delete("/{story_id}")
def delete_story(
    story_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Delete my own story (its view rows cascade away)."""
    story = db.query(Story).filter(Story.id == story_id).first()
    if not story:
        raise HTTPException(status_code=404, detail="Story not found")
    if story.author_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the author can delete")
    db.delete(story)
    db.commit()
    return {"ok": True}
