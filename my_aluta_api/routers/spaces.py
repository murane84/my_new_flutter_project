"""'Our Space' — a bond rendered as a place (the relationship profile).

A Space is a *deliberate pin*, not a chat thread and not auto-assigned. It opens
a relationship profile: the story of a connection through Aluta (stats, "your
song", pinned moments). Kept scarce on purpose — the free tier allows a single
Space; the Together plan unlocks several.

Efficiency note (standing mandate): nothing here runs in the background. Stats
are computed on demand when a Space is opened, and the "shared-listen" aggregates
("your song", "days in a song", streak) are returned best-effort — null/0 until a
real shared-listening surface (Listen-Together / Rooms) produces the events to
populate them. We deliberately do NOT stand up an always-on listen-logging
pipeline before a live surface needs it.
"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from typing import Optional
from pydantic import BaseModel

from database import get_db
from models import (
    User, RelationshipSpace, SpaceMember, PinnedMoment, MomentReaction,
    PlaylistTrack,
)
import crud
import schemas
import bonding
from auth import get_current_user
from websocket_manager import safe_notify_user
try:
    from push import send_push_to_user
except Exception:  # pragma: no cover - push optional
    send_push_to_user = None

router = APIRouter(prefix="/spaces", tags=["Our Space"])


class _ReactBody(BaseModel):
    emoji: Optional[str] = None


class _TrackBody(BaseModel):
    title: str
    artist: Optional[str] = None
    ref: Optional[str] = None

# Free tier: one pinned Space. Raised for the Together plan (checked per-user).
# Scarcity is the point (spec §2.1). Free keeps a single hero Space; the Together
# plan unlocks a small, deliberate set. Caps are read per-plan in create_space.
FREE_SPACE_CAP = 1
TOGETHER_SPACE_CAP = 8
_VALID_MOMENT_KINDS = {"dedication", "voice", "photo", "song", "note"}


# ── serialization ────────────────────────────────────────────────────────────
def _member_dicts(db: Session, space: RelationshipSpace) -> list:
    out = []
    for m in space.members:
        u = m.user or db.query(User).filter(User.id == m.user_id).first()
        if not u:
            continue
        out.append({
            "id": u.id,
            "username": u.username,
            "avatar_url": u.avatar_url,
            "is_online": bool(u.is_online),
        })
    return out


def _space_brief(db: Session, space: RelationshipSpace) -> dict:
    """The light shape used in the list / hero card."""
    return {
        "id": space.id,
        "owner_id": space.owner_id,
        "name": space.name,
        "theme": space.theme,
        "is_primary": bool(space.is_primary),
        "plan_tier": space.plan_tier,
        "close_since": space.created_at.isoformat() if space.created_at else None,
        "members": _member_dicts(db, space),
        "moment_count": len(space.moments),
    }


def _partner_id(space: RelationshipSpace, current_user_id: int) -> Optional[int]:
    """The other person in a 1:1 bond, or None if it isn't a clean pair."""
    others = [m.user_id for m in space.members if m.user_id != current_user_id]
    return others[0] if len(others) == 1 else None


def _sibling_space(db: Session, space: RelationshipSpace,
                   current_user_id: int) -> Optional[RelationshipSpace]:
    """The partner's mirror of this 1:1 bond — a Space the OTHER person pinned
    that also contains me. Because a Space is owner-scoped, each partner pins
    their own; unifying the two lets both see ONE shared moments timeline."""
    partner = _partner_id(space, current_user_id)
    if partner is None:
        return None
    candidates = (
        db.query(RelationshipSpace)
        .join(SpaceMember, SpaceMember.space_id == RelationshipSpace.id)
        .filter(RelationshipSpace.owner_id == partner,
                SpaceMember.user_id == current_user_id)
        .all()
    )
    for c in candidates:
        if {m.user_id for m in c.members} == {partner, current_user_id}:
            return c
    return None


def _bond_space_ids(db: Session, space: RelationshipSpace,
                    current_user_id: int) -> list:
    """Both mirror Spaces of this bond (mine + the partner's), so moments and
    reactions are shared across the pair."""
    ids = {space.id}
    sib = _sibling_space(db, space, current_user_id)
    if sib is not None:
        ids.add(sib.id)
    return list(ids)


def _moment_dict(db: Session, m: PinnedMoment, current_user_id: int) -> dict:
    author = m.author or (
        db.query(User).filter(User.id == m.author_id).first() if m.author_id else None
    )
    reactions = db.query(MomentReaction).filter(
        MomentReaction.moment_id == m.id).all()
    mine = next((r.emoji for r in reactions
                 if r.user_id == current_user_id and r.emoji), None)
    return {
        "id": m.id,
        "kind": m.kind,
        "ref": m.ref,
        "caption": m.caption,
        "author_id": m.author_id,
        "author": {
            "id": author.id,
            "username": author.username,
            "avatar_url": author.avatar_url,
        } if author else None,
        "created_at": m.created_at.isoformat() if m.created_at else None,
        "reactions": [
            {"user_id": r.user_id, "emoji": r.emoji}
            for r in reactions if r.emoji
        ],
        "my_reaction": mine,
        "mine": m.author_id == current_user_id,
    }


def _notify_partner_moment(db: Session, space: RelationshipSpace,
                           current_user: User, moment: PinnedMoment) -> None:
    """Tell the partner a new moment landed — the little loop that makes people
    keep sending. Best-effort over the home socket + a push."""
    partner = _partner_id(space, current_user.id)
    if not partner:
        return
    who = current_user.username or "Someone"
    line = (f"{who} dedicated a song to you 💛"
            if moment.kind in ("dedication", "song")
            else f"{who} pinned a moment for you")
    try:
        safe_notify_user(partner, {
            "type": "space_moment",
            "data": {
                "space_id": space.id,
                "moment_id": moment.id,
                "from_id": current_user.id,
                "from_username": who,
                "kind": moment.kind,
                "caption": moment.caption,
                "ref": moment.ref,
                "line": line,
            },
        })
    except Exception:
        pass
    if send_push_to_user is not None:
        try:
            send_push_to_user(partner, {
                "type": "space_moment",
                "title": "Our Space 💛",
                "body": line,
            })
        except Exception:
            pass


def _bond_pair_key(space: RelationshipSpace, current_user_id: int):
    """(pair_key, partner_id) for a clean 1:1 bond, else (None, None). The
    pair_key ('loId:hiId') is what the shared crate + streak series are keyed by,
    so both partners land on one list regardless of who owns which Space."""
    partner = _partner_id(space, current_user_id)
    if partner is None:
        return None, None
    return bonding.pair_key(current_user_id, partner), partner


def _track_dict(db: Session, t: PlaylistTrack, current_user_id: int) -> dict:
    adder = (
        db.query(User).filter(User.id == t.added_by).first()
        if t.added_by else None
    )
    return {
        "id": t.id,
        "title": t.title,
        "artist": t.artist,
        "ref": t.ref,
        "added_by": t.added_by,
        "added_by_username": adder.username if adder else None,
        "mine": t.added_by == current_user_id,
        "created_at": t.created_at.isoformat() if t.created_at else None,
    }


def _playlist_for(db: Session, space: RelationshipSpace,
                  current_user_id: int) -> list:
    pk, _partner = _bond_pair_key(space, current_user_id)
    if pk is None:
        return []
    rows = (
        db.query(PlaylistTrack)
        .filter(PlaylistTrack.pair_key == pk)
        .order_by(PlaylistTrack.id.desc())
        .all()
    )
    return [_track_dict(db, t, current_user_id) for t in rows]


def _notify_partner_playlist(db: Session, space: RelationshipSpace,
                             current_user: User, track: PlaylistTrack) -> None:
    """Tell the partner a song just landed in the shared crate — the little pull
    that says 'come add to this with me'. Best-effort socket + push."""
    partner = _partner_id(space, current_user.id)
    if not partner:
        return
    who = current_user.username or "Someone"
    line = f"{who} added '{track.title}' to your playlist 🎶"
    try:
        safe_notify_user(partner, {
            "type": "space_playlist_add",
            "data": {
                "space_id": space.id,
                "track_id": track.id,
                "from_id": current_user.id,
                "from_username": who,
                "title": track.title,
                "artist": track.artist,
                "line": line,
            },
        })
    except Exception:
        pass
    if send_push_to_user is not None:
        try:
            send_push_to_user(partner, {
                "type": "space_playlist_add",
                "title": "Our Playlist 🎶",
                "body": line,
            })
        except Exception:
            pass


def _space_full(db: Session, space: RelationshipSpace, current_user: User) -> dict:
    data = _space_brief(db, space)
    # Stats: real shared-listening maths for a 1:1 bond (streak, days, your song,
    # milestones); honestly empty for a non-pair Space.
    partner = _partner_id(space, current_user.id)
    close_since_date = space.created_at.date() if space.created_at else None
    if partner is not None:
        st = bonding.bond_stats(db, current_user.id, partner, close_since_date)
    else:
        st = {"days_in_song": 0, "listen_streak": 0, "your_song": None,
              "next_milestone": None, "milestone_reached": None}
    data["stats"] = {"close_since": data["close_since"], **st}
    # Moments are shared across BOTH partners' mirror Spaces, newest first.
    bond_ids = _bond_space_ids(db, space, current_user.id)
    moments = (
        db.query(PinnedMoment)
        .filter(PinnedMoment.space_id.in_(bond_ids))
        .order_by(PinnedMoment.id.desc())
        .all()
    )
    data["moments"] = [_moment_dict(db, m, current_user.id) for m in moments]
    # "Our Playlist" — the shared crate for this bond (both partners' adds).
    data["playlist"] = _playlist_for(db, space, current_user.id)
    return data


# ── helpers ──────────────────────────────────────────────────────────────────
def _owned_space_or_404(db: Session, space_id: int, user_id: int) -> RelationshipSpace:
    space = db.query(RelationshipSpace).filter(
        RelationshipSpace.id == space_id,
        RelationshipSpace.owner_id == user_id,
    ).first()
    if not space:
        raise HTTPException(status_code=404, detail="Space not found")
    return space


# ── endpoints ────────────────────────────────────────────────────────────────
@router.get("")
def list_spaces(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """My pinned Spaces — the hero (primary) first, then the rest by newest."""
    spaces = (
        db.query(RelationshipSpace)
        .filter(RelationshipSpace.owner_id == current_user.id)
        .all()
    )
    spaces.sort(key=lambda s: (0 if s.is_primary else 1, -s.id))
    return {"spaces": [_space_brief(db, s) for s in spaces]}


@router.post("")
def create_space(
    payload: schemas.SpaceCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Pin a bond. Every member must already be a mutual friend. Enforces the
    free-tier cap; the first Space becomes the primary hero automatically."""
    member_ids = [int(x) for x in (payload.member_ids or []) if int(x) != current_user.id]
    member_ids = list(dict.fromkeys(member_ids))  # de-dupe, keep order
    if not member_ids:
        raise HTTPException(status_code=400, detail="Pick at least one friend to pin")

    friend_ids = crud._get_friend_ids(db, current_user.id)
    not_friends = [m for m in member_ids if m not in friend_ids]
    if not_friends:
        raise HTTPException(
            status_code=400,
            detail="You can only pin people already in your circle",
        )

    # No duplicate Spaces: reject if one already pins this exact set of people.
    target_set = set(member_ids)
    owner_spaces = (
        db.query(RelationshipSpace)
        .filter(RelationshipSpace.owner_id == current_user.id)
        .all()
    )
    for existing_space in owner_spaces:
        existing_members = {
            m.user_id for m in existing_space.members
            if m.user_id != current_user.id
        }
        if existing_members == target_set:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="You already have a Space with "
                + ("these people." if len(target_set) > 1 else "this person."),
            )

    existing = len(owner_spaces)
    plan = current_user_plan(current_user)
    cap = TOGETHER_SPACE_CAP if plan == "together" else FREE_SPACE_CAP
    if existing >= cap:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=(
                "The free plan keeps one Our Space. Upgrade to Together to pin "
                "more of the people who matter."
                if plan != "together"
                else "You've reached the maximum number of Spaces."
            ),
        )

    space = RelationshipSpace(
        owner_id=current_user.id,
        name=(payload.name or None),
        theme=(payload.theme or None),
        is_primary=(existing == 0),   # first pin is the hero
        plan_tier=current_user_plan(current_user),
    )
    db.add(space)
    db.flush()  # get space.id

    # Owner is always a member, alongside the pinned friend(s).
    db.add(SpaceMember(space_id=space.id, user_id=current_user.id))
    for mid in member_ids:
        db.add(SpaceMember(space_id=space.id, user_id=mid))
    db.commit()
    db.refresh(space)
    return _space_full(db, space, current_user)


@router.get("/{space_id}")
def get_space(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    space = _owned_space_or_404(db, space_id, current_user.id)
    return _space_full(db, space, current_user)


@router.patch("/{space_id}")
def update_space(
    space_id: int,
    payload: schemas.SpaceUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    space = _owned_space_or_404(db, space_id, current_user.id)
    if payload.name is not None:
        space.name = payload.name or None
    if payload.theme is not None:
        space.theme = payload.theme or None
    if payload.is_primary is True:
        # Exactly one hero: demote the others first.
        db.query(RelationshipSpace).filter(
            RelationshipSpace.owner_id == current_user.id,
            RelationshipSpace.id != space.id,
        ).update({RelationshipSpace.is_primary: False}, synchronize_session=False)
        space.is_primary = True
    elif payload.is_primary is False:
        space.is_primary = False
    db.commit()
    db.refresh(space)
    return _space_full(db, space, current_user)


@router.delete("/{space_id}")
def delete_space(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Unpin a Space (moments + members cascade away)."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    was_primary = space.is_primary
    db.delete(space)
    db.commit()
    # If we removed the hero, promote the newest remaining Space so the friend
    # list is never left with a headless "Your Spaces" row.
    if was_primary:
        nxt = (
            db.query(RelationshipSpace)
            .filter(RelationshipSpace.owner_id == current_user.id)
            .order_by(RelationshipSpace.id.desc())
            .first()
        )
        if nxt:
            nxt.is_primary = True
            db.commit()
    return {"ok": True}


@router.post("/{space_id}/moments")
def add_moment(
    space_id: int,
    payload: schemas.MomentCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    space = _owned_space_or_404(db, space_id, current_user.id)
    kind = (payload.kind or "").strip().lower()
    if kind not in _VALID_MOMENT_KINDS:
        raise HTTPException(status_code=400, detail="Unknown moment kind")
    moment = PinnedMoment(
        space_id=space.id,
        author_id=current_user.id,
        kind=kind,
        ref=(payload.ref or None),
        caption=(payload.caption or None),
    )
    db.add(moment)
    db.commit()
    db.refresh(moment)
    # Reach across to the partner: a dedication that no one hears about is only
    # half a gift.
    _notify_partner_moment(db, space, current_user, moment)
    return _moment_dict(db, moment, current_user.id)


@router.post("/{space_id}/moments/{moment_id}/react")
def react_moment(
    space_id: int,
    moment_id: int,
    payload: _ReactBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """React to a moment (a heart). Authorised by membership of the bond the
    moment belongs to — so the PARTNER can react to what you pinned, not just the
    owner. Sending the same emoji again clears it (toggle)."""
    moment = db.query(PinnedMoment).filter(PinnedMoment.id == moment_id).first()
    if not moment:
        raise HTTPException(status_code=404, detail="Moment not found")
    is_member = db.query(SpaceMember).filter(
        SpaceMember.space_id == moment.space_id,
        SpaceMember.user_id == current_user.id,
    ).first()
    if not is_member:
        raise HTTPException(status_code=403, detail="Not part of this space")

    emoji = (payload.emoji or "").strip()
    existing = db.query(MomentReaction).filter(
        MomentReaction.moment_id == moment_id,
        MomentReaction.user_id == current_user.id,
    ).first()

    # Empty emoji, or the same one again → toggle off.
    if not emoji or (existing and existing.emoji == emoji):
        if existing:
            db.delete(existing)
            db.commit()
        return {"ok": True, "my_reaction": None}

    if existing:
        existing.emoji = emoji
    else:
        db.add(MomentReaction(
            moment_id=moment_id, user_id=current_user.id, emoji=emoji))
    db.commit()

    # Tell the moment's author their partner reacted (unless reacting to my own).
    if moment.author_id and moment.author_id != current_user.id:
        try:
            safe_notify_user(moment.author_id, {
                "type": "space_moment_react",
                "data": {
                    "space_id": space_id,
                    "moment_id": moment_id,
                    "from_id": current_user.id,
                    "from_username": current_user.username,
                    "emoji": emoji,
                },
            })
        except Exception:
            pass
    return {"ok": True, "my_reaction": emoji}


@router.post("/{space_id}/nudge")
def nudge_partner(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """"Thinking of you" — a one-tap tap on the shoulder across the bond. No
    payload and nothing stored: just a warm live ping (home socket + push) to
    the partner. The lightest loop in Our Space — "I'm here, I'm thinking of
    you" — meant to pull them back in for a listen."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    partner = _partner_id(space, current_user.id)
    if not partner:
        raise HTTPException(
            status_code=400, detail="This space has no partner to nudge")
    who = current_user.username or "Someone"
    line = f"{who} is thinking of you 💭"
    try:
        safe_notify_user(partner, {
            "type": "space_nudge",
            "data": {
                "space_id": space.id,
                "from_id": current_user.id,
                "from_username": who,
                "line": line,
            },
        })
    except Exception:
        pass
    if send_push_to_user is not None:
        try:
            send_push_to_user(partner, {
                "type": "space_nudge",
                "title": "Our Space 💭",
                "body": line,
            })
        except Exception:
            pass
    return {"ok": True}


@router.get("/{space_id}/playlist")
def get_playlist(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The shared crate for this bond (both partners' adds), newest first."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    return {"tracks": _playlist_for(db, space, current_user.id)}


@router.post("/{space_id}/playlist")
def add_track(
    space_id: int,
    payload: _TrackBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Add a song to "Our Playlist". Shared across the bond via pair_key, so the
    partner sees it too. Notifies them so the crate feels co-built."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(
            status_code=400,
            detail="This space has no partner to share a playlist with")
    title = (payload.title or "").strip()
    if not title:
        raise HTTPException(status_code=400, detail="A track needs a title")
    artist = (payload.artist or "").strip() or None
    ref = (payload.ref or "").strip() or None
    track = PlaylistTrack(
        pair_key=pk,
        added_by=current_user.id,
        title=title[:200],
        artist=artist[:200] if artist else None,
        ref=ref,
    )
    db.add(track)
    db.commit()
    db.refresh(track)
    _notify_partner_playlist(db, space, current_user, track)
    return _track_dict(db, track, current_user.id)


@router.delete("/{space_id}/playlist/{track_id}")
def remove_track(
    space_id: int,
    track_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove a track from the shared crate. Either partner can prune it — it's a
    communal list, not a personal one. Scoped by pair_key so you can only touch
    your own bond's crate."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Track not found")
    track = db.query(PlaylistTrack).filter(
        PlaylistTrack.id == track_id,
        PlaylistTrack.pair_key == pk,
    ).first()
    if not track:
        raise HTTPException(status_code=404, detail="Track not found")
    db.delete(track)
    db.commit()
    return {"ok": True}


@router.delete("/{space_id}/moments/{moment_id}")
def delete_moment(
    space_id: int,
    moment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    space = _owned_space_or_404(db, space_id, current_user.id)
    db.query(PinnedMoment).filter(
        PinnedMoment.id == moment_id,
        PinnedMoment.space_id == space.id,
    ).delete(synchronize_session=False)
    db.commit()
    return {"ok": True}


def current_user_plan(user: User) -> str:
    """The user's plan tier ('free' | 'together'), read from the entitlement on
    the User row. A dev/trial toggle (routers/plan.py) sets it today; a real
    billing webhook will set the same field later, so this hook never changes."""
    return (getattr(user, "plan_tier", None) or "free")
