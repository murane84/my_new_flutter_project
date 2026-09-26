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
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_
from typing import Optional
from pydantic import BaseModel

from database import get_db
from models import (
    User, RelationshipSpace, SpaceMember, PinnedMoment, MomentReaction,
    PlaylistTrack, BondRequest, DiaryEntry, DiaryReaction, DiaryComment,
)
from datetime import date as _date
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


class _DiaryBody(BaseModel):
    # A shared diary entry. `kind`: 'memory' (past) | 'plan' (future).
    kind: Optional[str] = "memory"
    title: Optional[str] = None
    body: str
    # 'YYYY-MM-DD' for a plan; ignored for a memory.
    plan_date: Optional[str] = None
    pinned: Optional[bool] = False


class _DiaryEditBody(BaseModel):
    # All optional — only provided fields change. `plan_date` may be cleared by
    # sending an empty string.
    kind: Optional[str] = None
    title: Optional[str] = None
    body: Optional[str] = None
    plan_date: Optional[str] = None
    pinned: Optional[bool] = None


class _DiaryReactBody(BaseModel):
    emoji: str


class _DiaryCommentBody(BaseModel):
    body: str

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


def _space_brief(db: Session, space: RelationshipSpace,
                 current_user_id: Optional[int] = None) -> dict:
    """The light shape used in the list / hero card."""
    data = {
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
    if current_user_id is not None:
        data["status"] = _space_status(db, space, current_user_id)
    return data


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


# ── bond handshake (request → approve → both Spaces created) ──────────────────
def _pair_pending_or_accepted(db: Session, a: int, b: int):
    """Any pending/accepted BondRequest between a and b (either direction)."""
    return (
        db.query(BondRequest)
        .filter(
            BondRequest.status.in_(("pending", "accepted")),
            or_(
                and_(BondRequest.from_user_id == a, BondRequest.to_user_id == b),
                and_(BondRequest.from_user_id == b, BondRequest.to_user_id == a),
            ),
        )
        .first()
    )


def _space_status(db: Session, space: RelationshipSpace,
                  current_user_id: int) -> str:
    """A bond is 'active' when both partners hold a Space for it (mutual) or an
    accepted request exists; 'pending_partner' when only I've pinned and the
    friend hasn't joined yet. Group Spaces are always 'active'. Status is DERIVED
    (no column on RelationshipSpace), so legacy one-sided pins convert for free."""
    partner = _partner_id(space, current_user_id)
    if partner is None:
        return "active"
    if _sibling_space(db, space, current_user_id) is not None:
        return "active"
    acc = (
        db.query(BondRequest)
        .filter(
            BondRequest.status == "accepted",
            or_(
                and_(BondRequest.from_user_id == current_user_id,
                     BondRequest.to_user_id == partner),
                and_(BondRequest.from_user_id == partner,
                     BondRequest.to_user_id == current_user_id),
            ),
        )
        .first()
    )
    return "active" if acc is not None else "pending_partner"


def _space_owned_with(db: Session, owner_id: int, partner_id: int):
    """The Space `owner_id` pinned whose member set is exactly {owner, partner}."""
    candidates = (
        db.query(RelationshipSpace)
        .join(SpaceMember, SpaceMember.space_id == RelationshipSpace.id)
        .filter(RelationshipSpace.owner_id == owner_id,
                SpaceMember.user_id == partner_id)
        .all()
    )
    for c in candidates:
        if {m.user_id for m in c.members} == {owner_id, partner_id}:
            return c
    return None


def _has_space_room(db: Session, user: User) -> bool:
    count = (
        db.query(RelationshipSpace)
        .filter(RelationshipSpace.owner_id == user.id)
        .count()
    )
    plan = current_user_plan(user)
    cap = TOGETHER_SPACE_CAP if plan == "together" else FREE_SPACE_CAP
    return count < cap


def _create_bond_space(db: Session, owner_id: int, partner_id: int,
                       name: Optional[str] = None) -> RelationshipSpace:
    """Create one owner-scoped mirror Space for a bond (default theme; the owner
    edits their own colour later). First Space becomes that owner's hero."""
    owner = db.query(User).filter(User.id == owner_id).first()
    existing = (
        db.query(RelationshipSpace)
        .filter(RelationshipSpace.owner_id == owner_id)
        .count()
    )
    space = RelationshipSpace(
        owner_id=owner_id,
        name=(name or None),
        theme=None,
        is_primary=(existing == 0),
        plan_tier=current_user_plan(owner) if owner else "free",
    )
    db.add(space)
    db.flush()
    db.add(SpaceMember(space_id=space.id, user_id=owner_id))
    db.add(SpaceMember(space_id=space.id, user_id=partner_id))
    db.commit()
    db.refresh(space)
    return space


def _user_brief(db: Session, uid: int) -> Optional[dict]:
    u = db.query(User).filter(User.id == uid).first()
    if not u:
        return None
    return {"id": u.id, "username": u.username, "avatar_url": u.avatar_url}


def _request_dict(db: Session, req: BondRequest) -> dict:
    return {
        "id": req.id,
        "from_user_id": req.from_user_id,
        "to_user_id": req.to_user_id,
        "status": req.status,
        "name": req.name,
        "from_user": _user_brief(db, req.from_user_id),
        "to_user": _user_brief(db, req.to_user_id),
        "created_at": req.created_at.isoformat() if req.created_at else None,
    }


def _push(uid: int, title: str, body: str, kind: str) -> None:
    if send_push_to_user is None:
        return
    try:
        send_push_to_user(uid, {"type": kind, "title": title, "body": body})
    except Exception:
        pass


def _notify_bond_request(db: Session, req: BondRequest, from_user: User) -> None:
    who = from_user.username or "Someone"
    line = f"{who} wants to pin a bond with you 💞"
    try:
        safe_notify_user(req.to_user_id, {
            "type": "bond_request",
            "data": {
                "request_id": req.id,
                "from_id": from_user.id,
                "from_username": who,
                "line": line,
            },
        })
    except Exception:
        pass
    _push(req.to_user_id, "Our Space 💞", line, "bond_request")


def _notify_bond_accepted(db: Session, req: BondRequest, accepter: User) -> None:
    who = accepter.username or "Someone"
    line = f"{who} accepted — your Space is live 🎉"
    try:
        safe_notify_user(req.from_user_id, {
            "type": "bond_request_accepted",
            "data": {
                "request_id": req.id,
                "from_id": accepter.id,
                "from_username": who,
                "line": line,
            },
        })
    except Exception:
        pass
    _push(req.from_user_id, "Our Space 🎉", line, "bond_request_accepted")


def _notify_bond_resolved(req: BondRequest, kind: str, target_id: int) -> None:
    """A soft, socket-only nudge so a stale request clears on the other side
    (a decline or a withdrawal). No push — a 'no' shouldn't buzz a phone."""
    try:
        safe_notify_user(target_id, {
            "type": kind,
            "data": {"request_id": req.id},
        })
    except Exception:
        pass


def _maybe_backfill_bond_request(db: Session, space: RelationshipSpace,
                                 current_user: User) -> None:
    """Convert a legacy one-sided pin into the handshake model: if I hold a 1:1
    Space with no partner mirror and no request has ever passed between us, send
    the partner a pending request so they can join. Runs once per bond."""
    partner = _partner_id(space, current_user.id)
    if partner is None:
        return
    if _sibling_space(db, space, current_user.id) is not None:
        return
    already = (
        db.query(BondRequest)
        .filter(
            or_(
                and_(BondRequest.from_user_id == current_user.id,
                     BondRequest.to_user_id == partner),
                and_(BondRequest.from_user_id == partner,
                     BondRequest.to_user_id == current_user.id),
            ),
        )
        .first()
    )
    if already is not None:
        return
    req = BondRequest(
        from_user_id=current_user.id,
        to_user_id=partner,
        name=space.name,
        status="pending",
    )
    db.add(req)
    db.commit()
    db.refresh(req)
    _notify_bond_request(db, req, current_user)


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


_VALID_DIARY_KINDS = {"memory", "plan"}


def _parse_plan_date(raw):
    """Parse 'YYYY-MM-DD' → date (best-effort). Empty/None/garbage → None, so a
    plan without a set day, or a cleared one, is simply undated."""
    if not raw:
        return None
    try:
        return _date.fromisoformat(str(raw)[:10])
    except Exception:
        return None


def _comment_dict(db: Session, c: DiaryComment, current_user_id: int) -> dict:
    author = c.author or (
        db.query(User).filter(User.id == c.author_id).first()
        if c.author_id else None
    )
    return {
        "id": c.id,
        "body": c.body,
        "author_id": c.author_id,
        "author": {
            "id": author.id,
            "username": author.username,
            "avatar_url": author.avatar_url,
        } if author else None,
        "mine": c.author_id == current_user_id,
        "created_at": c.created_at.isoformat() if c.created_at else None,
    }


def _diary_dict(db: Session, e: DiaryEntry, current_user_id: int) -> dict:
    author = e.author or (
        db.query(User).filter(User.id == e.author_id).first()
        if e.author_id else None
    )
    reacts = (
        db.query(DiaryReaction)
        .filter(DiaryReaction.entry_id == e.id)
        .all()
    )
    # Per-emoji counts + which emojis THIS user has added (for highlight/toggle).
    counts: dict = {}
    mine: list = []
    for r in reacts:
        counts[r.emoji] = counts.get(r.emoji, 0) + 1
        if r.user_id == current_user_id and r.emoji not in mine:
            mine.append(r.emoji)
    comments = (
        db.query(DiaryComment)
        .filter(DiaryComment.entry_id == e.id)
        .order_by(DiaryComment.id.asc())
        .all()
    )
    return {
        "id": e.id,
        "kind": e.kind,
        "title": e.title,
        "body": e.body,
        "plan_date": e.plan_date.isoformat() if e.plan_date else None,
        "pinned": bool(e.pinned),
        "author_id": e.author_id,
        "author": {
            "id": author.id,
            "username": author.username,
            "avatar_url": author.avatar_url,
        } if author else None,
        "mine": e.author_id == current_user_id,
        "created_at": e.created_at.isoformat() if e.created_at else None,
        "updated_at": e.updated_at.isoformat() if e.updated_at else None,
        # Reactions: a list of {emoji, count}, plus the caller's own emojis.
        "reactions": [{"emoji": k, "count": v} for k, v in counts.items()],
        "my_reactions": mine,
        "comment_count": len(comments),
        "comments": [_comment_dict(db, c, current_user_id) for c in comments],
    }


def _diary_for(db: Session, space: RelationshipSpace,
               current_user_id: int) -> list:
    """The shared diary for this bond (both partners' entries). Plans first,
    ordered by their date (soonest upcoming first), then memories newest-first —
    so what's ahead sits at the top and the history reads back in time."""
    pk, _partner = _bond_pair_key(space, current_user_id)
    if pk is None:
        return []
    rows = (
        db.query(DiaryEntry)
        .filter(DiaryEntry.pair_key == pk)
        .all()
    )
    plans = [r for r in rows if r.kind == "plan"]
    memories = [r for r in rows if r.kind != "plan"]
    # Plans: dated ones by date ascending (soonest first), undated ones last.
    plans.sort(key=lambda r: (r.plan_date is None,
                              r.plan_date or _date.max, -r.id))
    memories.sort(key=lambda r: -r.id)
    return [_diary_dict(db, r, current_user_id) for r in plans + memories]


def _notify_partner_diary(db: Session, space: RelationshipSpace,
                          current_user: User, entry: DiaryEntry) -> None:
    """Tell the partner the diary just grew — a shared notebook only feels shared
    if the other person knows it changed. Best-effort socket + push."""
    partner = _partner_id(space, current_user.id)
    if not partner:
        return
    who = current_user.username or "Someone"
    if entry.kind == "plan":
        line = f"{who} added a plan to your diary 🗓️"
    else:
        line = f"{who} wrote a memory in your diary 📖"
    try:
        safe_notify_user(partner, {
            "type": "space_diary",
            "data": {
                "space_id": space.id,
                "entry_id": entry.id,
                "from_id": current_user.id,
                "from_username": who,
                "kind": entry.kind,
                "title": entry.title,
                "plan_date": entry.plan_date.isoformat()
                if entry.plan_date else None,
                "pinned": bool(entry.pinned),
                "line": line,
            },
        })
    except Exception:
        pass
    if send_push_to_user is not None:
        try:
            send_push_to_user(partner, {
                "type": "space_diary",
                "title": "Our Diary 📖",
                "body": line,
            })
        except Exception:
            pass


def _space_full(db: Session, space: RelationshipSpace, current_user: User) -> dict:
    data = _space_brief(db, space, current_user.id)
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
    # "Our Diary" — the shared notebook (memories + upcoming plans) for the bond.
    data["diary"] = _diary_for(db, space, current_user.id)
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
    # Convert any legacy one-sided pins into the handshake model (best-effort,
    # once per bond) so the partner gets a chance to join and go two-way.
    for s in spaces:
        try:
            _maybe_backfill_bond_request(db, s, current_user)
        except Exception:
            db.rollback()
    spaces.sort(key=lambda s: (0 if s.is_primary else 1, -s.id))
    return {"spaces": [_space_brief(db, s, current_user.id) for s in spaces]}


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


# ── bond requests (must be declared BEFORE "/{space_id}" so the literal paths
#    win over the int path-param) ───────────────────────────────────────────────
@router.post("/request")
def request_bond(
    payload: schemas.BondRequestCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Ask a friend to pin a bond. Nothing is created yet — the Space is born for
    BOTH of you only when they accept. They get a live banner + push."""
    partner = int(payload.member_id)
    if partner == current_user.id:
        raise HTTPException(status_code=400,
                            detail="You can't pin a bond with yourself")
    friend_ids = crud._get_friend_ids(db, current_user.id)
    if partner not in friend_ids:
        raise HTTPException(
            status_code=400,
            detail="You can only pin people already in your circle")
    # Already sharing an active bond?
    mine = _space_owned_with(db, current_user.id, partner)
    if mine is not None and _space_status(db, mine, current_user.id) == "active":
        raise HTTPException(status_code=409, detail="You already share a Space")
    # A pending request already in flight?
    pending = _pair_pending_or_accepted(db, current_user.id, partner)
    if pending is not None and pending.status == "pending":
        if pending.to_user_id == current_user.id:
            raise HTTPException(
                status_code=409,
                detail="They already invited you — accept their request instead")
        raise HTTPException(
            status_code=409, detail="You already have a pending request")
    if not _has_space_room(db, current_user):
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=("The free plan keeps one Our Space. Upgrade to Together to "
                    "pin more of the people who matter."))
    req = BondRequest(
        from_user_id=current_user.id,
        to_user_id=partner,
        name=(payload.name or None),
        status="pending",
    )
    db.add(req)
    db.commit()
    db.refresh(req)
    _notify_bond_request(db, req, current_user)
    return _request_dict(db, req)


@router.get("/requests")
def list_requests(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Pending bond requests: `incoming` awaiting my yes/no, `outgoing` awaiting
    theirs."""
    incoming = (
        db.query(BondRequest)
        .filter(BondRequest.to_user_id == current_user.id,
                BondRequest.status == "pending")
        .order_by(BondRequest.id.desc())
        .all()
    )
    outgoing = (
        db.query(BondRequest)
        .filter(BondRequest.from_user_id == current_user.id,
                BondRequest.status == "pending")
        .order_by(BondRequest.id.desc())
        .all()
    )
    return {
        "incoming": [_request_dict(db, r) for r in incoming],
        "outgoing": [_request_dict(db, r) for r in outgoing],
    }


@router.post("/requests/{request_id}/accept")
def accept_bond(
    request_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Accept a bond: officially create the Space for BOTH partners (each owns
    their own mirror with their own colour) and tell the requester it's live."""
    req = db.query(BondRequest).filter(BondRequest.id == request_id).first()
    if not req or req.to_user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Request not found")
    if req.status != "pending":
        raise HTTPException(status_code=409,
                            detail="This request was already handled")
    requester = req.from_user_id
    # My (accepter's) mirror.
    my_space = _space_owned_with(db, current_user.id, requester)
    if my_space is None:
        if not _has_space_room(db, current_user):
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail=("You've reached your Space limit. Free up one or upgrade "
                        "to Together to accept this bond."))
        my_space = _create_bond_space(db, current_user.id, requester)
    # The requester's mirror (best-effort — if they're now at their cap we still
    # keep mine; their side forms when they have room / re-open).
    their_space = _space_owned_with(db, requester, current_user.id)
    if their_space is None:
        requester_user = db.query(User).filter(User.id == requester).first()
        if requester_user is not None and _has_space_room(db, requester_user):
            _create_bond_space(db, requester, current_user.id, name=req.name)
    req.status = "accepted"
    req.responded_at = datetime.now(timezone.utc)
    db.commit()
    _notify_bond_accepted(db, req, current_user)
    db.refresh(my_space)
    return _space_full(db, my_space, current_user)


@router.post("/requests/{request_id}/decline")
def decline_bond(
    request_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    req = db.query(BondRequest).filter(BondRequest.id == request_id).first()
    if not req or req.to_user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Request not found")
    if req.status != "pending":
        raise HTTPException(status_code=409,
                            detail="This request was already handled")
    req.status = "declined"
    req.responded_at = datetime.now(timezone.utc)
    db.commit()
    _notify_bond_resolved(req, "bond_request_declined", req.from_user_id)
    return {"ok": True}


@router.post("/requests/{request_id}/cancel")
def cancel_bond(
    request_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    req = db.query(BondRequest).filter(BondRequest.id == request_id).first()
    if not req or req.from_user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Request not found")
    if req.status != "pending":
        raise HTTPException(status_code=409,
                            detail="This request was already handled")
    req.status = "cancelled"
    req.responded_at = datetime.now(timezone.utc)
    db.commit()
    _notify_bond_resolved(req, "bond_request_cancelled", req.to_user_id)
    return {"ok": True}


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


@router.get("/{space_id}/diary")
def get_diary(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The shared diary for this bond — both partners' entries (memories + plans),
    plans-first ordered soonest-upcoming."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    return {"entries": _diary_for(db, space, current_user.id)}


@router.post("/{space_id}/diary")
def add_diary_entry(
    space_id: int,
    payload: _DiaryBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Write a diary entry. Shared across the bond via pair_key so the partner
    sees it too, and notifies them so the notebook feels co-authored."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(
            status_code=400,
            detail="This space has no partner to share a diary with")
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="A diary entry needs some text")
    kind = (payload.kind or "memory").strip().lower()
    if kind not in _VALID_DIARY_KINDS:
        kind = "memory"
    title = (payload.title or "").strip() or None
    plan_date = _parse_plan_date(payload.plan_date) if kind == "plan" else None
    pinned = bool(payload.pinned) and kind == "plan"
    entry = DiaryEntry(
        pair_key=pk,
        author_id=current_user.id,
        kind=kind,
        title=title[:200] if title else None,
        body=body[:4000],
        plan_date=plan_date,
        pinned=pinned,
    )
    db.add(entry)
    db.commit()
    db.refresh(entry)
    _notify_partner_diary(db, space, current_user, entry)
    return _diary_dict(db, entry, current_user.id)


@router.patch("/{space_id}/diary/{entry_id}")
def edit_diary_entry(
    space_id: int,
    entry_id: int,
    payload: _DiaryEditBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Edit a diary entry. Either partner may refine the shared notebook (it's
    communal, like the playlist). Only provided fields change; `plan_date` may be
    cleared with an empty string, and `pinned`/`plan_date` only apply to plans."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    entry = db.query(DiaryEntry).filter(
        DiaryEntry.id == entry_id,
        DiaryEntry.pair_key == pk,
    ).first()
    if not entry:
        raise HTTPException(status_code=404, detail="Entry not found")
    if payload.kind is not None:
        k = payload.kind.strip().lower()
        if k in _VALID_DIARY_KINDS:
            entry.kind = k
    if payload.title is not None:
        t = payload.title.strip()
        entry.title = t[:200] if t else None
    if payload.body is not None:
        b = payload.body.strip()
        if b:
            entry.body = b[:4000]
    if payload.plan_date is not None:
        entry.plan_date = _parse_plan_date(payload.plan_date)
    if payload.pinned is not None:
        entry.pinned = bool(payload.pinned)
    # A memory can't carry a plan date or a pin.
    if entry.kind != "plan":
        entry.plan_date = None
        entry.pinned = False
    entry.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(entry)
    return _diary_dict(db, entry, current_user.id)


@router.delete("/{space_id}/diary/{entry_id}")
def delete_diary_entry(
    space_id: int,
    entry_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove a diary entry. Either partner can prune the shared notebook. Scoped
    by pair_key so you can only touch your own bond's diary."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    deleted = db.query(DiaryEntry).filter(
        DiaryEntry.id == entry_id,
        DiaryEntry.pair_key == pk,
    ).delete(synchronize_session=False)
    db.commit()
    if not deleted:
        raise HTTPException(status_code=404, detail="Entry not found")
    return {"ok": True}


def _diary_entry_or_404(db: Session, pk: str, entry_id: int) -> DiaryEntry:
    entry = db.query(DiaryEntry).filter(
        DiaryEntry.id == entry_id,
        DiaryEntry.pair_key == pk,
    ).first()
    if not entry:
        raise HTTPException(status_code=404, detail="Entry not found")
    return entry


@router.post("/{space_id}/diary/{entry_id}/react")
def react_diary_entry(
    space_id: int,
    entry_id: int,
    payload: _DiaryReactBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Toggle an emoji reaction on a diary entry for the current user. Adding the
    same emoji again removes it; a user may hold several distinct emojis. Either
    partner can react, author or not. Returns the refreshed entry."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    entry = _diary_entry_or_404(db, pk, entry_id)
    emoji = (payload.emoji or "").strip()
    if not emoji or len(emoji) > 16:
        raise HTTPException(status_code=400, detail="A reaction needs an emoji")
    existing = db.query(DiaryReaction).filter(
        DiaryReaction.entry_id == entry.id,
        DiaryReaction.user_id == current_user.id,
        DiaryReaction.emoji == emoji,
    ).first()
    if existing:
        db.delete(existing)
    else:
        db.add(DiaryReaction(
            entry_id=entry.id, user_id=current_user.id, emoji=emoji))
    db.commit()
    return _diary_dict(db, entry, current_user.id)


@router.get("/{space_id}/diary/{entry_id}/comments")
def get_diary_comments(
    space_id: int,
    entry_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """The comment thread under one diary entry, oldest-first."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    entry = _diary_entry_or_404(db, pk, entry_id)
    rows = (
        db.query(DiaryComment)
        .filter(DiaryComment.entry_id == entry.id)
        .order_by(DiaryComment.id.asc())
        .all()
    )
    return {"comments": [_comment_dict(db, c, current_user.id) for c in rows]}


@router.post("/{space_id}/diary/{entry_id}/comments")
def add_diary_comment(
    space_id: int,
    entry_id: int,
    payload: _DiaryCommentBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Add a comment to a diary entry's thread. Shared across the bond; notifies
    the partner so the conversation feels live."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    entry = _diary_entry_or_404(db, pk, entry_id)
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="A comment needs some text")
    comment = DiaryComment(
        entry_id=entry.id, author_id=current_user.id, body=body[:2000])
    db.add(comment)
    db.commit()
    db.refresh(comment)
    # Best-effort ping to the partner.
    if partner:
        who = current_user.username or "Someone"
        title = (entry.title or "").strip()
        line = (f"{who} commented on “{title}”"
                if title else f"{who} commented in your diary")
        try:
            safe_notify_user(partner, {
                "type": "space_diary_comment",
                "data": {
                    "space_id": space.id,
                    "entry_id": entry.id,
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
                    "type": "space_diary_comment",
                    "title": "Our Diary 💬",
                    "body": line,
                })
            except Exception:
                pass
    return _comment_dict(db, comment, current_user.id)


@router.delete("/{space_id}/diary/{entry_id}/comments/{comment_id}")
def delete_diary_comment(
    space_id: int,
    entry_id: int,
    comment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Delete a comment. Only its own author may remove it."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Comment not found")
    entry = _diary_entry_or_404(db, pk, entry_id)
    comment = db.query(DiaryComment).filter(
        DiaryComment.id == comment_id,
        DiaryComment.entry_id == entry.id,
    ).first()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found")
    if comment.author_id != current_user.id:
        raise HTTPException(
            status_code=403, detail="You can only delete your own comment")
    db.delete(comment)
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
