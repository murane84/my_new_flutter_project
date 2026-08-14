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

from database import get_db
from models import User, RelationshipSpace, SpaceMember, PinnedMoment
import crud
import schemas
from auth import get_current_user

router = APIRouter(prefix="/spaces", tags=["Our Space"])

# Free tier: one pinned Space. Raised for the Together plan (checked per-user).
FREE_SPACE_CAP = 1
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


def _moment_dict(m: PinnedMoment) -> dict:
    return {
        "id": m.id,
        "kind": m.kind,
        "ref": m.ref,
        "caption": m.caption,
        "author_id": m.author_id,
        "created_at": m.created_at.isoformat() if m.created_at else None,
    }


def _space_full(db: Session, space: RelationshipSpace) -> dict:
    data = _space_brief(db, space)
    # Stats: real where we have data, honestly empty where we don't (yet).
    data["stats"] = {
        "close_since": data["close_since"],
        # Populated once a shared-listening surface exists; empty is truthful now.
        "your_song": None,          # {title, artist, count} when known
        "days_in_song": 0,          # accumulated shared-listen days
        "listen_streak": 0,         # consecutive-day streak
        "next_milestone": None,     # {label, date} when computed
    }
    data["moments"] = [_moment_dict(m) for m in
                       sorted(space.moments, key=lambda x: x.id, reverse=True)]
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

    existing = (
        db.query(RelationshipSpace)
        .filter(RelationshipSpace.owner_id == current_user.id)
        .count()
    )
    if current_user_plan(current_user) == "free" and existing >= FREE_SPACE_CAP:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=(
                "The free plan keeps one Our Space. Upgrade to Together to pin "
                "more of the people who matter."
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
    return _space_full(db, space)


@router.get("/{space_id}")
def get_space(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    space = _owned_space_or_404(db, space_id, current_user.id)
    return _space_full(db, space)


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
    return _space_full(db, space)


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
    return _moment_dict(moment)


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
    """The user's plan tier. Billing isn't wired yet, so everyone is 'free' for
    now — this single hook is where the Together entitlement will read from once
    subscriptions land, so the cap logic above needs no further change."""
    return "free"
