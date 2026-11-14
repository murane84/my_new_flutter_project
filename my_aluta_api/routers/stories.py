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
from models import User, MediaAsset, Story, StoryView, StoryReaction
import privacy
from crud import _get_friend_ids
from .users import get_current_user
from auth import get_current_user_flexible
from websocket_manager import safe_notify_user

router = APIRouter(prefix="/stories", tags=["Stories"])

# A story lives for 24 hours from posting.
STORY_TTL = timedelta(hours=24)

VALID_KINDS = {"photo", "video", "music", "text", "sticker"}


def _story_circle(db: Session, user_id: int) -> set:
    """Who shares stories with [user_id]: their friends, minus anyone either
    of them has blocked — a block hides stories both ways (feed, media,
    views, the live "posted" nudge), not just chats."""
    from models import BlockStatus
    ids = set(_get_friend_ids(db, user_id))
    if not ids:
        return ids
    rows = db.query(BlockStatus.user_id, BlockStatus.blocked_user_id).filter(
        ((BlockStatus.user_id == user_id)
         & BlockStatus.blocked_user_id.in_(ids))
        | ((BlockStatus.blocked_user_id == user_id)
           & BlockStatus.user_id.in_(ids))
    ).all()
    blocked = {int(b if int(a) == user_id else a) for a, b in rows}
    return ids - blocked


def _may_see(db: Session, viewer: int, author: int) -> bool:
    """[viewer] may see [author]'s stories: the author themself, or a friend
    in the shared story circle (no block) whom the author's "Who can see my
    status" choice includes."""
    if viewer == author:
        return True
    if viewer not in _story_circle(db, author):
        return False
    return author in privacy.status_authors_visible_to(db, viewer, [author])


def _may_see_story(db: Session, viewer: int, story: Story) -> bool:
    """[viewer] may see this story: via its author, or — a duo — its
    co-author."""
    if _may_see(db, viewer, story.author_id):
        return True
    co = getattr(story, "co_author_id", None)
    return co is not None and _may_see(db, viewer, int(co))


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
        background=story.background,
        thumb=getattr(story, "thumb", None),
        song_url=(f"/stories/media/{story.song_asset_id}"
                  if getattr(story, "song_asset_id", None) else None),
        song_title=getattr(story, "song_title", None),
        song_start_ms=getattr(story, "song_start_ms", None),
        co_author_id=getattr(story, "co_author_id", None),
        created_at=story.created_at,
        expires_at=story.expires_at,
        viewed=viewed,
        view_count=view_count,
    )



def _clean_thumb(raw):
    """A small JPEG/PNG/WebP data URI, or None (anything else is dropped)."""
    t = (raw or "").strip()
    if not t or len(t) > 40000:
        return None
    if not t.startswith(("data:image/jpeg;base64,", "data:image/png;base64,",
                         "data:image/webp;base64,")):
        return None
    return t

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
        # The asset must exist and be the poster's OWN upload. (A legacy
        # asset with no recorded uploader used to pass — anyone's old photo
        # could be lifted into a status, i.e. shown to a whole circle.)
        if not asset or asset.uploader_id != current_user.id:
            raise HTTPException(status_code=400, detail="Unknown media for story")
    elif kind == "text":
        if not (payload.caption and payload.caption.strip()):
            raise HTTPException(status_code=400, detail="Nothing to post")
    elif kind == "sticker":
        # A sticker/GIF story carries its image URL in music_art_url.
        if not (payload.music_art_url and payload.music_art_url.strip()):
            raise HTTPException(status_code=400, detail="Nothing to post")

    else:  # music
        if not (payload.music_title or payload.caption):
            raise HTTPException(status_code=400, detail="Nothing to post")

    # A song moment: the clip must be my own upload; under a photo / text /
    # sticker status, or a music status (the song itself, heard).
    song_id = (payload.song_asset_id or "").strip() or None
    if song_id:
        if kind not in ("photo", "text", "sticker", "music"):
            song_id = None
        else:
            sa = db.query(MediaAsset).filter(MediaAsset.id == song_id).first()
            if not sa or sa.uploader_id != current_user.id:
                raise HTTPException(status_code=400, detail="Unknown song")
    # A duo: only with a mutual friend (my bonded partner, in practice).
    co = payload.co_author_id
    if co is not None:
        if int(co) == current_user.id or \
                int(co) not in set(_get_friend_ids(db, current_user.id)):
            co = None

    # Sane sizes for what every viewer downloads and renders.
    if len(payload.caption or "") > 2000 or \
            len(payload.music_title or "") > 300 or \
            len(payload.music_artist or "") > 300 or \
            len(payload.background or "") > 64:
        raise HTTPException(status_code=400, detail="Too long")

    # Any picture URL (sticker / GIF, a song's art) is loaded by every
    # viewer's phone, so only our GIF provider or our own attachments —
    # never an arbitrary site that would learn who in my circle opened it.
    if payload.music_art_url and payload.music_art_url.strip():
        from urllib.parse import urlparse
        u = payload.music_art_url.strip()
        host = (urlparse(u).hostname or "").lower()
        if not (u.startswith("/attachments/") or (
                u.startswith("https://") and
                (host == "giphy.com" or host.endswith(".giphy.com")))):
            raise HTTPException(status_code=400, detail="Unsupported picture")

    # Housekeeping: clear out anyone's expired stories on this write.
    purge_expired_stories(db)

    # "Now playing" is a LIVE state, not a feed: a user only ever has one active
    # music story. Posting a new one supersedes the previous, so a friend never
    # appears to be "playing" two songs at once. (photo/video/text still append,
    # each living its own 24h.) StoryView rows cascade-delete with the old story.
    if kind == "music":
        db.query(Story).filter(
            Story.author_id == current_user.id,
            Story.kind == "music",
        ).delete(synchronize_session=False)
        db.flush()

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
        background=(payload.background or None),
        thumb=_clean_thumb(getattr(payload, "thumb", None)) if kind == "video" else None,
        song_asset_id=song_id,
        song_title=((payload.song_title or "").strip()[:200] or None) if song_id else None,
        song_start_ms=max(0, int(payload.song_start_ms or 0)) if song_id else None,
        co_author_id=co,
        created_at=now,
        expires_at=now + STORY_TTL,
    )
    db.add(story)
    db.commit()
    db.refresh(story)

    # Live-nudge friends' clients so the new status appears on their tray/tiles
    # without a manual refresh. The event carries no story data — clients fetch
    # the feed themselves on this signal (keeps access control server-side).
    try:
        for fid in privacy.status_audience_of(
                db, current_user.id, _story_circle(db, current_user.id)):
            safe_notify_user(int(fid),
                             {"type": "story_posted", "author_id": current_user.id})
    except Exception:  # noqa: BLE001
        pass

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

    # Friends (no block either way) whose status audience includes me.
    author_ids = privacy.status_authors_visible_to(
        db, me, _story_circle(db, me))
    author_ids.add(me)

    from sqlalchemy import or_
    stories = (
        db.query(Story)
        .filter(or_(Story.author_id.in_(author_ids),
                    Story.co_author_id.in_(author_ids)),
                Story.expires_at > now)
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
    my_story_ids = [s.id for s in stories
                    if s.author_id == me or getattr(s, "co_author_id", None) == me]
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

    # A duo status shows under BOTH people (each whose circle includes me).
    grouped: dict[int, list[Story]] = {}
    for s in stories:
        if s.author_id in author_ids:
            grouped.setdefault(s.author_id, []).append(s)
        co = getattr(s, "co_author_id", None)
        if co is not None and co in author_ids and co != s.author_id:
            grouped.setdefault(co, []).append(s)

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
    from sqlalchemy import or_
    story = (
        db.query(Story)
        .filter(or_(Story.media_asset_id == asset_id,
                    Story.song_asset_id == asset_id),
                Story.expires_at > now)
        .first()
    )
    if not story:
        # Either no such story, or it has expired.
        raise HTTPException(status_code=404, detail="Story not found")
    if not _may_see_story(db, current_user.id, story):
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
    if not _may_see_story(db, me, story):
        raise HTTPException(status_code=403, detail="Not authorized to view this story")
    if story.author_id == me or getattr(story, "co_author_id", None) == me:
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
    if current_user.id not in (story.author_id,
                               getattr(story, "co_author_id", None)):
        raise HTTPException(status_code=403, detail="Only the author can see viewers")

    rows = (
        db.query(StoryView, User)
        .join(User, User.id == StoryView.viewer_id)
        .filter(StoryView.story_id == story_id)
        .order_by(StoryView.viewed_at.desc())
        .all()
    )
    # WHEN someone watched is activity, so it follows their last-seen choice
    # (privacy.py, both ways): hidden → they're listed, without a time.
    seen_ok = privacy.visible_to(db, current_user.id, [u.id for _, u in rows])
    # visible_to assumes friends: someone who has since unfriended / blocked
    # keeps their time hidden, like their last seen.
    mutual = _story_circle(db, current_user.id)
    reacts = {
        int(r.user_id): r.emoji
        for r in db.query(StoryReaction).filter(
            StoryReaction.story_id == story_id).all()
    }
    return [
        schemas.StoryViewerOut(
            user_id=u.id,
            username=u.username,
            avatar_url=u.avatar_url,
            phone=u.phone,
            viewed_at=(v.viewed_at
                       if (u.id in mutual and seen_ok.get(u.id, False))
                       else None),
            reaction=reacts.get(int(u.id)),
        )
        for v, u in rows
    ]


@router.post("/{story_id}/react")
def react_to_story(
    story_id: str,
    payload: schemas.StoryReactIn,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Note my quick reaction on a story (latest wins) so the author's
    "Viewed by" shows it. The app also sends it to their DM."""
    emoji = (payload.emoji or "").strip()[:16]
    if not emoji:
        raise HTTPException(status_code=400, detail="Pick a reaction")
    story = db.query(Story).filter(Story.id == story_id).first()
    if not story or story.expires_at <= _now():
        raise HTTPException(status_code=404, detail="Story not found")
    if story.author_id == current_user.id or not _may_see_story(
            db, current_user.id, story):
        raise HTTPException(status_code=403, detail="Not your story to react to")
    row = db.query(StoryReaction).filter(
        StoryReaction.story_id == story_id,
        StoryReaction.user_id == current_user.id).first()
    if row is None:
        db.add(StoryReaction(story_id=story_id, user_id=current_user.id,
                             emoji=emoji))
    else:
        row.emoji = emoji
    try:
        db.commit()
    except Exception:  # noqa: BLE001
        db.rollback()
    return {"ok": True, "emoji": emoji}


@router.post("/{story_id}/keep")
def keep_story_in_space(
    story_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Keep a bonded partner's status in OUR Space before it expires: it
    becomes a pinned moment (photo / video / song / note / GIF) in my Space
    with them — so a lovely status turns into a lasting memory. Accepted
    bonds only."""
    import json as _json
    from models import PinnedMoment, RelationshipSpace, SpaceMember
    from . import spaces as sp
    story = db.query(Story).filter(Story.id == story_id).first()
    if not story or story.expires_at <= _now():
        raise HTTPException(status_code=404, detail="This status has expired")
    author = int(story.author_id)
    me = current_user.id
    if author == me or not _may_see(db, me, author):
        raise HTTPException(status_code=403, detail="Not available")
    # My Space with them, and only an accepted bond.
    space = (
        db.query(RelationshipSpace)
        .join(SpaceMember, SpaceMember.space_id == RelationshipSpace.id)
        .filter(RelationshipSpace.owner_id == me,
                SpaceMember.user_id == author)
        .first()
    )
    if space is None or sp._active_partner(db, space, me) != author:
        raise HTTPException(status_code=409,
                            detail="Keep works with your bonded partner")
    kind, ref, caption = None, None, (story.caption or None)
    if story.kind in ("photo", "video") and story.media_asset_id:
        kind = story.kind
        ref = f"/attachments/{story.media_asset_id}"
    elif story.kind == "music":
        kind = "song"
        ref = _json.dumps({"title": story.music_title or "",
                           "artist": story.music_artist or ""})
    elif story.kind == "sticker" and story.music_art_url:
        kind, ref = "gif", story.music_art_url
    elif story.kind == "text" and (story.caption or "").strip():
        kind = "note"
    if kind is None:
        raise HTTPException(status_code=400, detail="This status can't be kept")
    # Already kept → don't pin it twice.
    dup = db.query(PinnedMoment).filter(
        PinnedMoment.space_id == space.id, PinnedMoment.kind == kind,
        PinnedMoment.ref == ref, PinnedMoment.caption == caption).first()
    if dup is not None:
        return {"ok": True, "moment_id": dup.id, "already": True}
    moment = PinnedMoment(space_id=space.id, author_id=me, kind=kind,
                          ref=ref, caption=caption)
    db.add(moment)
    db.commit()
    db.refresh(moment)
    try:
        sp._notify_partner_moment(db, space, current_user, moment)
    except Exception:  # noqa: BLE001
        pass
    return {"ok": True, "moment_id": moment.id, "space_id": space.id}


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
