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
from fastapi import APIRouter, Depends, HTTPException, status, UploadFile, File
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_
from typing import Optional
from pydantic import BaseModel

from database import get_db
from models import (
    User, RelationshipSpace, SpaceMember, PinnedMoment, MomentReaction,
    PlaylistTrack, BondRequest, DiaryEntry, DiaryReaction, DiaryComment,
    MediaAsset, DailyPrompt, DailyPromptAnswer, Dedication,
)
import uuid as _uuid
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
    memo: Optional[str] = None
    source: Optional[str] = None


class _MemoBody(BaseModel):
    memo: Optional[str] = None


class _DiaryBody(BaseModel):
    # A shared diary entry. `kind`: 'memory' (past) | 'plan' (future).
    kind: Optional[str] = "memory"
    title: Optional[str] = None
    body: str
    # 'YYYY-MM-DD' for a plan; ignored for a memory.
    plan_date: Optional[str] = None
    pinned: Optional[bool] = False
    # The author's chosen typeface for this memory (client font key).
    font: Optional[str] = None


class _DiaryEditBody(BaseModel):
    # All optional — only provided fields change. `plan_date` may be cleared by
    # sending an empty string.
    kind: Optional[str] = None
    title: Optional[str] = None
    body: Optional[str] = None
    plan_date: Optional[str] = None
    pinned: Optional[bool] = None
    font: Optional[str] = None


class _DiaryReactBody(BaseModel):
    emoji: str


class _DiaryCommentBody(BaseModel):
    body: str

# Free tier: one pinned Space. Raised for the Together plan (checked per-user).
# Scarcity is the point (spec §2.1). Free keeps a single hero Space; the Together
# plan unlocks a small, deliberate set. Caps are read per-plan in create_space.
FREE_SPACE_CAP = 1
TOGETHER_SPACE_CAP = 8
_VALID_MOMENT_KINDS = {"dedication", "voice", "photo", "song", "note", "video"}


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
                 current_user_id: Optional[int] = None,
                 include_stats: bool = False) -> dict:
    """The light shape used in the list / hero card.

    When [include_stats] is set (the spaces LIST), it also carries the bond's
    stats + the playlist/diary counts, so opening the Space page paints fully on
    the first frame — the badges and streak don't have to wait on a second
    round-trip (which was visibly laggy on the slower web fetch). `_space_full`
    leaves it off and computes its own stats."""
    data = {
        "id": space.id,
        "owner_id": space.owner_id,
        "name": space.name,
        "theme": space.theme,
        "background_url": space.background_url,
        "is_primary": bool(space.is_primary),
        "plan_tier": space.plan_tier,
        "close_since": space.created_at.isoformat() if space.created_at else None,
        "members": _member_dicts(db, space),
        "moment_count": len(space.moments),
    }
    if current_user_id is not None:
        data["status"] = _space_status(db, space, current_user_id)
        # Bond-scoped moment count (both partners' mirror Spaces), so the badge
        # matches the full page's moments list instead of shifting after load.
        try:
            bond_ids = _bond_space_ids(db, space, current_user_id)
            data["moment_count"] = (
                db.query(PinnedMoment)
                .filter(PinnedMoment.space_id.in_(bond_ids)).count()
            )
        except Exception:
            pass
        # Cheap per-bond counts for the tile badges (0 for a non-pair Space).
        pk, partner = _bond_pair_key(space, current_user_id)
        if pk is not None:
            data["playlist_count"] = (
                db.query(PlaylistTrack)
                .filter(PlaylistTrack.pair_key == pk).count()
            )
            data["diary_count"] = (
                db.query(DiaryEntry)
                .filter(DiaryEntry.pair_key == pk).count()
            )
        else:
            data["playlist_count"] = 0
            data["diary_count"] = 0
        if include_stats and partner is not None:
            close_since_date = (
                space.created_at.date() if space.created_at else None)
            st = bonding.bond_stats(
                db, current_user_id, partner, close_since_date)
            data["stats"] = {"close_since": data["close_since"], **st}
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
        "source": (t.source or "manual"),
        "memo": t.memo,
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
                "memo": track.memo,
                "source": track.source,
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
        "font": e.font,
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
                          current_user: User, entry: DiaryEntry,
                          action: str = "added") -> None:
    """Tell the partner the diary changed — a shared notebook only feels shared
    if the other person's open page updates the moment it changes. Best-effort
    socket + push.

    [action] is "added", "updated" (e.g. the author reworded a memory or changed
    its font) or "removed". Only "added" is worth a toast + push; "updated" and
    "removed" ship the socket event SILENTLY so the partner's page reloads
    live without a noisy banner for every small edit."""
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
                "action": action,
                # Toast copy only for a brand-new entry; edits/removes are silent.
                "line": line if action == "added" else None,
            },
        })
    except Exception:
        pass
    # Never push-notify an edit or a delete — that would ping the partner's phone
    # every time the author tweaks a word or a font. Only a NEW entry pushes.
    if action == "added" and send_push_to_user is not None:
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
    # Today's "Us" question, so the hub card paints on open (bond spaces only).
    try:
        data["question"] = _question_state(db, space, current_user)
    except Exception:
        data["question"] = None
    try:
        _deds = _dedications_for(db, space, current_user.id)
        data["dedications"] = _deds
        data["dedication_unopened"] = sum(
            1 for x in _deds if not x["mine"] and not x["opened"])
    except Exception:
        data["dedications"] = []
        data["dedication_unopened"] = 0
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
    return {
        "spaces": [
            _space_brief(db, s, current_user.id, include_stats=True)
            for s in spaces
        ]
    }


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
    if payload.background_url is not None:
        # Only a preset ("/wallpapers/<id>") or a clear ("") is allowed here.
        # Uploaded photos go through POST /{id}/background; refusing arbitrary
        # values stops a client aiming a Space at someone else's attachment.
        bg = payload.background_url.strip()
        if bg == "":
            space.background_url = None
        elif bg.startswith("/wallpapers/"):
            space.background_url = bg
        else:
            raise HTTPException(
                status_code=400,
                detail="background_url must be a preset (/wallpapers/<id>) or empty",
            )
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


_VALID_TRACK_SOURCES = {"manual", "share", "listen_together",
                        "question", "dedication"}


def _upsert_soundtrack_track(db: Session, pk: str, user_id: int, title: str,
                             artist=None, ref=None, source="manual",
                             memo=None):
    """Add a track to the bond's soundtrack, de-duping on title+artist. Thin
    wrapper over bonding.record_soundtrack_track so every feed (manual, share,
    listen-together, question, dedication) goes through one place."""
    src = source if source in _VALID_TRACK_SOURCES else "manual"
    return bonding.record_soundtrack_track(
        db, pk, user_id, title, artist, ref, src, memo)

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
    track, created = _upsert_soundtrack_track(
        db, pk, current_user.id, payload.title, payload.artist, payload.ref,
        source=(payload.source or "manual"), memo=payload.memo,
    )
    if track is None:
        raise HTTPException(status_code=400, detail="A track needs a title")
    # Only ping the partner for a genuinely new add, not a silent de-dupe.
    if created:
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


@router.patch("/{space_id}/playlist/{track_id}")
def annotate_track(
    space_id: int,
    track_id: int,
    payload: _MemoBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Attach / edit the one-line memory on a soundtrack track. Either partner
    may annotate — it's a shared memory, not a personal note."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, _partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Track not found")
    track = db.query(PlaylistTrack).filter(
        PlaylistTrack.id == track_id,
        PlaylistTrack.pair_key == pk,
    ).first()
    if not track:
        raise HTTPException(status_code=404, detail="Track not found")
    memo = (payload.memo or "").strip()
    track.memo = memo[:500] if memo else None
    db.commit()
    db.refresh(track)
    return _track_dict(db, track, current_user.id)


# ── Daily "Us" question ──────────────────────────────────────────────────────
# One curated prompt per calendar day, the same for every couple. 'text' prompts
# invite a few words; 'music' prompts ask for a song (both picks drop into the
# soundtrack). Answers reveal to both partners only once BOTH have answered —
# the simultaneous-reveal ritual.
_DAILY_PROMPTS = [
    ("text", "What made you smile today?"),
    ("music", "Pick a song for how you feel about us today."),
    ("text", "What do you miss about them right now?"),
    ("text", "What is one small thing they did that you loved?"),
    ("music", "A song that sounds like your week together."),
    ("text", "What are you most grateful for about them today?"),
    ("text", "Where do you wish you two were right now?"),
    ("music", "Pick a song you want to dance to with them."),
    ("text", "What are you looking forward to together?"),
    ("text", "What is a tiny moment with them you keep replaying?"),
    ("music", "A song that would cheer them up today."),
    ("text", "What did they teach you this week?"),
    ("text", "If today had a title, what would it be?"),
    ("music", "Pick the song for your next slow evening in."),
    ("text", "What is one thing you want to tell them tonight?"),
    ("text", "What made you feel close to them lately?"),
    ("music", "A song that reminds you of how you met."),
    ("text", "What is your favourite thing about them this month?"),
    ("text", "What would make tomorrow better for both of you?"),
    ("music", "Pick a song to wake up to together."),
    ("text", "What small adventure would you take them on?"),
    ("text", "When did you last laugh together, and at what?"),
    ("music", "A song for a long drive, just the two of you."),
    ("text", "What do you love that only the two of you share?"),
]


def _prompt_for_day(db: Session, day: _date) -> DailyPrompt:
    """Resolve (or create) the single prompt for `day`, chosen deterministically
    so it's the same for everyone and stays stable in the archive."""
    p = db.query(DailyPrompt).filter(DailyPrompt.day == day).first()
    if p is not None:
        return p
    kind, body = _DAILY_PROMPTS[day.toordinal() % len(_DAILY_PROMPTS)]
    p = DailyPrompt(day=day, kind=kind, body=body)
    db.add(p)
    try:
        db.commit()
        db.refresh(p)
    except Exception:
        db.rollback()  # another request created it first
        p = db.query(DailyPrompt).filter(DailyPrompt.day == day).first()
    return p


def _answer_payload(a) -> Optional[dict]:
    if a is None:
        return None
    return {
        "user_id": a.user_id,
        "answer_text": a.answer_text,
        "track_title": a.track_title,
        "track_artist": a.track_artist,
        "created_at": a.created_at.isoformat() if a.created_at else None,
    }


def _question_state(db: Session, space: RelationshipSpace,
                    current_user: User) -> dict:
    pk, partner = _bond_pair_key(space, current_user.id)
    today = _date.today()
    prompt = _prompt_for_day(db, today)
    mine = partner_ans = None
    if pk is not None:
        rows = db.query(DailyPromptAnswer).filter(
            DailyPromptAnswer.pair_key == pk,
            DailyPromptAnswer.day == today,
        ).all()
        for r in rows:
            if r.user_id == current_user.id:
                mine = r
            else:
                partner_ans = r
    revealed = (mine is not None and partner_ans is not None)
    partner_user = (
        db.query(User).filter(User.id == partner).first() if partner else None
    )
    return {
        "day": today.isoformat(),
        "prompt": {"kind": prompt.kind, "body": prompt.body},
        "answered": mine is not None,
        "my_answer": _answer_payload(mine),
        "partner_answered": partner_ans is not None,
        "revealed": revealed,
        "partner_answer": _answer_payload(partner_ans) if revealed else None,
        "partner_name": (partner_user.username if partner_user else None),
    }


def _notify_prompt(space: RelationshipSpace, from_user: User,
                   partner_id: Optional[int], event: str,
                   prompt: DailyPrompt, reveal: bool) -> None:
    """Socket + a single gentle push. On reveal, both partners hear; otherwise
    only the partner gets the 'your turn' nudge (never the person who answered)."""
    if not partner_id:
        return
    who = from_user.username or "Someone"
    if reveal:
        title = "Your answers are in 💞"
        body = "You both answered today's question — tap to see."
    else:
        title = "Today's question"
        body = f"{who} answered — your turn 💬"
    data = {
        "space_id": space.id,
        "day": _date.today().isoformat(),
        "prompt": prompt.body,
        "kind": prompt.kind,
    }
    targets = [partner_id, from_user.id] if reveal else [partner_id]
    for uid in targets:
        try:
            safe_notify_user(uid, {"type": event, "data": data})
        except Exception:
            pass
    try:
        _push(partner_id, title, body, event)
    except Exception:
        pass
    if reveal:
        try:
            _push(from_user.id, title, body, event)
        except Exception:
            pass


class _AnswerBody(BaseModel):
    answer_text: Optional[str] = None
    track_title: Optional[str] = None
    track_artist: Optional[str] = None
    track_ref: Optional[str] = None


@router.get("/{space_id}/question")
def get_question(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Today's 'Us' question for this bond, plus my answer and — once both have
    answered — the partner's, revealed together."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    return _question_state(db, space, current_user)


@router.post("/{space_id}/question")
def answer_question(
    space_id: int,
    payload: _AnswerBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Answer today's question (text or a song). One answer per partner per day;
    re-posting updates it until the reveal. When both have answered, both are
    notified and a music prompt's two picks flow into the soundtrack."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(
            status_code=400, detail="This space has no partner yet")
    today = _date.today()
    prompt = _prompt_for_day(db, today)
    text_ans = (payload.answer_text or "").strip() or None
    title = (payload.track_title or "").strip() or None
    artist = (payload.track_artist or "").strip() or None
    ref = (payload.track_ref or "").strip() or None
    if prompt.kind == "music" and not title:
        raise HTTPException(status_code=400, detail="Pick a song to answer")
    if prompt.kind == "text" and not text_ans:
        raise HTTPException(status_code=400, detail="Write a short answer")

    mine = db.query(DailyPromptAnswer).filter(
        DailyPromptAnswer.pair_key == pk,
        DailyPromptAnswer.day == today,
        DailyPromptAnswer.user_id == current_user.id,
    ).first()
    if mine is None:
        mine = DailyPromptAnswer(
            pair_key=pk, day=today, user_id=current_user.id)
        db.add(mine)
    mine.answer_text = text_ans
    mine.track_title = title[:200] if title else None
    mine.track_artist = artist[:200] if artist else None
    mine.track_ref = ref
    db.commit()
    db.refresh(mine)

    partner_ans = db.query(DailyPromptAnswer).filter(
        DailyPromptAnswer.pair_key == pk,
        DailyPromptAnswer.day == today,
        DailyPromptAnswer.user_id == partner,
    ).first() if partner else None
    both = partner_ans is not None

    if both and prompt.kind == "music":
        for ans in (mine, partner_ans):
            if ans.track_title:
                _upsert_soundtrack_track(
                    db, pk, ans.user_id, ans.track_title, ans.track_artist,
                    ans.track_ref, source="question", memo=prompt.body)

    _notify_prompt(space, current_user, partner,
                   "prompt_revealed" if both else "prompt_answered",
                   prompt, reveal=both)
    return _question_state(db, space, current_user)


@router.get("/{space_id}/question/archive")
def question_archive(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Past questions this bond BOTH answered, newest first."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        return {"items": []}
    rows = db.query(DailyPromptAnswer).filter(
        DailyPromptAnswer.pair_key == pk,
    ).order_by(DailyPromptAnswer.day.desc()).all()
    by_day: dict = {}
    for r in rows:
        by_day.setdefault(r.day, []).append(r)
    today = _date.today()
    items = []
    for day in sorted(by_day.keys(), reverse=True):
        answers = by_day[day]
        users = {a.user_id for a in answers}
        # Only fully-answered PAST days belong in the archive.
        if len(users) < 2 or day == today:
            continue
        prompt = _prompt_for_day(db, day)
        mine = next((a for a in answers if a.user_id == current_user.id), None)
        theirs = next((a for a in answers if a.user_id != current_user.id), None)
        items.append({
            "day": day.isoformat(),
            "prompt": {"kind": prompt.kind, "body": prompt.body},
            "my_answer": _answer_payload(mine),
            "partner_answer": _answer_payload(theirs),
        })
        if len(items) >= 30:
            break
    return {"items": items}



# ── Dedications — a song sent as a feeling ───────────────────────────────────
class _DedicationBody(BaseModel):
    track_title: str
    track_artist: Optional[str] = None
    track_ref: Optional[str] = None
    mood: Optional[str] = None
    note: Optional[str] = None
    voice_note_url: Optional[str] = None


def _dedication_dict(db: Session, d: Dedication, current_user_id: int) -> dict:
    sender = db.query(User).filter(User.id == d.from_user_id).first()
    return {
        "id": d.id,
        "from_id": d.from_user_id,
        "from_username": sender.username if sender else None,
        "mine": d.from_user_id == current_user_id,
        "track_title": d.track_title,
        "track_artist": d.track_artist,
        "track_ref": d.track_ref,
        "mood": d.mood,
        "note": d.note,
        "voice_note_url": d.voice_note_url,
        "opened": d.opened_at is not None,
        "opened_at": d.opened_at.isoformat() if d.opened_at else None,
        "created_at": d.created_at.isoformat() if d.created_at else None,
    }


def _dedications_for(db: Session, space: RelationshipSpace,
                     current_user_id: int) -> list:
    pk, _partner = _bond_pair_key(space, current_user_id)
    if pk is None:
        return []
    rows = (
        db.query(Dedication)
        .filter(Dedication.pair_key == pk)
        .order_by(Dedication.id.desc())
        .all()
    )
    return [_dedication_dict(db, d, current_user_id) for d in rows]


def _notify_dedication(space: RelationshipSpace, from_user: User,
                       partner_id: Optional[int], d: Dedication) -> None:
    if not partner_id:
        return
    who = from_user.username or "Someone"
    mood = (d.mood or "").strip()
    line = (f"{who} dedicated '{d.track_title}' to you"
            + (f" · {mood}" if mood else "") + " 💝")
    try:
        safe_notify_user(partner_id, {
            "type": "dedication_received",
            "data": {
                "space_id": space.id,
                "dedication_id": d.id,
                "from_id": from_user.id,
                "from_username": who,
                "track_title": d.track_title,
                "mood": d.mood,
                "line": line,
            },
        })
    except Exception:
        pass
    try:
        _push(partner_id, "A dedication 💝", line, "dedication_received")
    except Exception:
        pass


@router.get("/{space_id}/dedications")
def list_dedications(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Every dedication in this bond (sent + received), newest first."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    return {"dedications": _dedications_for(db, space, current_user.id)}


@router.post("/{space_id}/dedications")
def create_dedication(
    space_id: int,
    payload: _DedicationBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Dedicate a song to the partner — a mood + a line + (optionally) a voice
    note. Delivered as an event (one nudge) and auto-added to the soundtrack."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(
            status_code=400, detail="This space has no partner yet")
    title = (payload.track_title or "").strip()
    if not title:
        raise HTTPException(
            status_code=400, detail="A dedication needs a song")
    artist = (payload.track_artist or "").strip() or None
    d = Dedication(
        pair_key=pk,
        from_user_id=current_user.id,
        track_title=title[:200],
        track_artist=(artist[:200] if artist else None),
        track_ref=((payload.track_ref or "").strip() or None),
        mood=(((payload.mood or "").strip())[:60] or None),
        note=(((payload.note or "").strip())[:500] or None),
        voice_note_url=((payload.voice_note_url or "").strip() or None),
    )
    db.add(d)
    db.commit()
    db.refresh(d)
    # The dedicated song lands in the soundtrack, memo'd with the note/mood.
    memo = d.note or (f"{d.mood} 💝" if d.mood else "A dedication 💝")
    _upsert_soundtrack_track(
        db, pk, current_user.id, d.track_title, d.track_artist, d.track_ref,
        source="dedication", memo=memo)
    _notify_dedication(space, current_user, partner, d)
    return _dedication_dict(db, d, current_user.id)


@router.post("/{space_id}/dedications/{dedication_id}/open")
def open_dedication(
    space_id: int,
    dedication_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Mark a received dedication as opened (first open only)."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    pk, _partner = _bond_pair_key(space, current_user.id)
    if pk is None:
        raise HTTPException(status_code=404, detail="Dedication not found")
    d = db.query(Dedication).filter(
        Dedication.id == dedication_id,
        Dedication.pair_key == pk,
    ).first()
    if not d:
        raise HTTPException(status_code=404, detail="Dedication not found")
    if d.from_user_id != current_user.id and d.opened_at is None:
        d.opened_at = datetime.now(timezone.utc)
        db.commit()
        db.refresh(d)
    return _dedication_dict(db, d, current_user.id)


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
        font=((payload.font or "").strip().lower()[:24] or None),
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
    """Edit a diary entry. A MEMORY carries its author's unique touch, so only
    its author may edit it — the partner can react and comment, but not rewrite
    someone else's memory. PLANS stay jointly editable (a plan involves both).
    Only provided fields change; `plan_date` may be cleared with an empty
    string, and `pinned`/`plan_date` only apply to plans."""
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
    # Only the author may edit their own memory (plans are jointly editable).
    if entry.kind == "memory" and entry.author_id and \
            entry.author_id != current_user.id:
        raise HTTPException(
            status_code=403,
            detail="Only the author can edit their memory")
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
    if payload.font is not None:
        entry.font = (payload.font.strip().lower()[:24] or None)
    # A memory can't carry a plan date or a pin.
    if entry.kind != "plan":
        entry.plan_date = None
        entry.pinned = False
    entry.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(entry)
    # Push the change to the partner's open page so an edit (reworded text, a new
    # font…) shows up instantly, without them having to pull-to-refresh. Silent.
    _notify_partner_diary(db, space, current_user, entry, action="updated")
    return _diary_dict(db, entry, current_user.id)


@router.delete("/{space_id}/diary/{entry_id}")
def delete_diary_entry(
    space_id: int,
    entry_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove a diary entry. Only the author may delete their own MEMORY (you
    can't erase your partner's memory); PLANS remain jointly removable. Scoped
    by pair_key so you can only touch your own bond's diary."""
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
    if entry.kind == "memory" and entry.author_id and \
            entry.author_id != current_user.id:
        raise HTTPException(
            status_code=403,
            detail="Only the author can delete their memory")
    # Snapshot the fields the notifier needs into a DETACHED stand-in BEFORE the
    # row is deleted — the real instance is expired after delete/commit.
    _removed = DiaryEntry(
        id=entry.id,
        kind=entry.kind,
        title=entry.title,
        plan_date=entry.plan_date,
        pinned=entry.pinned,
    )
    db.delete(entry)
    db.commit()
    # Tell the partner's open page it's gone so it disappears live (silent).
    _notify_partner_diary(db, space, current_user, _removed, action="removed")
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
    # Live-nudge the partner so an open Our Space page / memory updates without
    # a manual refresh (no push — reactions are lightweight).
    if partner:
        try:
            safe_notify_user(partner, {
                "type": "space_diary_react",
                "data": {
                    "space_id": space.id,
                    "entry_id": entry.id,
                    "from_id": current_user.id,
                    "emoji": emoji,
                },
            })
        except Exception:
            pass
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


@router.patch("/{space_id}/diary/{entry_id}/comments/{comment_id}")
def edit_diary_comment(
    space_id: int,
    entry_id: int,
    comment_id: int,
    payload: _DiaryCommentBody,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Edit a comment. Only its own author may change it."""
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
            status_code=403, detail="You can only edit your own comment")
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="A comment needs some text")
    comment.body = body[:2000]
    db.commit()
    db.refresh(comment)
    return _comment_dict(db, comment, current_user.id)


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


# ── Keep a chat moment into Our Space (resolve the bond by partner) ───────────
# The chat screen knows the partner's user id but not the Space id, so these two
# endpoints resolve the caller's owned bond Space with that partner. They let a
# message be "kept" as a PinnedMoment straight from a chat bubble without the
# client having to load the Space first.
@router.get("/with/{partner_id}")
def bond_with(
    partner_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Is the caller bonded (Our Space) with `partner_id`? Returns the caller's
    own Space id for that bond so the chat can deep-link and keep moments."""
    space = _space_owned_with(db, current_user.id, partner_id)
    return {
        "bonded": space is not None,
        "space_id": space.id if space else None,
        "space_name": space.name if space else None,
    }


@router.post("/with/{partner_id}/moments")
def add_moment_with(
    partner_id: int,
    payload: schemas.MomentCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Keep a chat message as a PinnedMoment in the caller's bond Space with
    `partner_id`. 409 when the two aren't bonded yet (nothing to keep it in)."""
    space = _space_owned_with(db, current_user.id, partner_id)
    if space is None:
        raise HTTPException(
            status_code=409,
            detail="Bond in Our Space first to keep moments together.",
        )
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
    _notify_partner_moment(db, space, current_user, moment)
    out = _moment_dict(db, moment, current_user.id)
    out["space_id"] = space.id
    return out


def current_user_plan(user: User) -> str:
    """The user's plan tier ('free' | 'together'), read from the entitlement on
    the User row. A dev/trial toggle (routers/plan.py) sets it today; a real
    billing webhook will set the same field later, so this hook never changes."""
    return (getattr(user, "plan_tier", None) or "free")


# ── Custom photo background (per-user) ────────────────────────────────────────
@router.post("/{space_id}/background")
async def set_space_background(
    space_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Set (or replace) the caller's custom photo background for their Our Space
    view. Per-user: changes only the requester's own Space row. The image is
    stored as a MediaAsset and background_url points at it."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty image")
    if len(data) > 12 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Image too large (max 12 MB)")
    mime = file.content_type or "image/jpeg"
    if not mime.startswith("image/"):
        raise HTTPException(status_code=400, detail="Not an image")
    old = space.background_url
    asset_id = _uuid.uuid4().hex
    db.add(MediaAsset(
        id=asset_id, data=data, mime=mime,
        name=file.filename or asset_id, size=len(data),
        uploader_id=current_user.id,
    ))
    space.background_url = f"/attachments/{asset_id}"
    db.commit()
    if old:
        frag = old.rsplit("/", 1)[-1]
        if frag:
            db.query(MediaAsset).filter(MediaAsset.id == frag).update(
                {MediaAsset.data: None}, synchronize_session=False)
            db.commit()
    db.refresh(space)
    return _space_full(db, space, current_user)


@router.delete("/{space_id}/background")
def clear_space_background(
    space_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove the caller's custom background → back to the default motif theme."""
    space = _owned_space_or_404(db, space_id, current_user.id)
    old = space.background_url
    space.background_url = None
    db.commit()
    if old:
        frag = old.rsplit("/", 1)[-1]
        if frag:
            db.query(MediaAsset).filter(MediaAsset.id == frag).update(
                {MediaAsset.data: None}, synchronize_session=False)
            db.commit()
    db.refresh(space)
    return _space_full(db, space, current_user)
