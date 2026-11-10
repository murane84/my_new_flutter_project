"""Who may see whose "last seen".

Each user picks, in the app (synced in their app_prefs as
`last_seen_mode`): 'circle' (every friend — the default), 'bonds' (only
their Our Space partners) or 'nobody'. It works both ways, like WhatsApp:
I see a friend's last seen only if THEY allow me AND my own setting would
allow THEM — hide yours and you stop seeing theirs.
"""
import json

from models import (UserSetting, BondRequest, Friend, RelationshipSpace,
                    SpaceMember)

MODES = ("circle", "bonds", "nobody")


def _mode_from(data) -> str:
    try:
        d = json.loads(data or "{}") or {}
    except Exception:
        return "circle"
    box = d.get("last_seen_mode")
    v = box.get("v") if isinstance(box, dict) else None
    return v if v in MODES else "circle"


def modes_for(db, ids) -> dict:
    """{user_id: mode} for many users in one query."""
    ids = {int(i) for i in ids}
    out = {i: "circle" for i in ids}
    if not ids:
        return out
    rows = db.query(UserSetting.user_id, UserSetting.data).filter(
        UserSetting.user_id.in_(ids), UserSetting.key == "app_prefs").all()
    for uid, data in rows:
        out[int(uid)] = _mode_from(data)
    return out


def _accepted(db, uid: int) -> set:
    rows = db.query(BondRequest.from_user_id, BondRequest.to_user_id).filter(
        BondRequest.status == "accepted",
        (BondRequest.from_user_id == uid) | (BondRequest.to_user_id == uid),
    ).all()
    return {int(b if int(a) == uid else a) for a, b in rows} - {uid}


def _i_keep(db, uid: int) -> set:
    rows = db.query(SpaceMember.user_id).join(
        RelationshipSpace, RelationshipSpace.id == SpaceMember.space_id,
    ).filter(RelationshipSpace.owner_id == uid,
             SpaceMember.user_id != uid).all()
    return {int(r[0]) for r in rows}


def _keep_me(db, uid: int) -> set:
    rows = db.query(RelationshipSpace.owner_id).join(
        SpaceMember, SpaceMember.space_id == RelationshipSpace.id,
    ).filter(SpaceMember.user_id == uid,
             RelationshipSpace.owner_id != uid).all()
    return {int(r[0]) for r in rows}


def bond_ids(db, uid: int) -> set:
    """uid's live bonds: an accepted bond whose Our Space BOTH still keep.
    If either un-pins it, it's over for both — the same rule the app uses
    (status 'partner_left' / no Space) and spaces._active_partner."""
    return _accepted(db, uid) & _i_keep(db, uid) & _keep_me(db, uid)


def bonded_to(db, uid: int) -> set:
    """Same set seen from the other side (kept for callers' readability)."""
    return bond_ids(db, uid)


def _allows(mode: str, is_friend: bool, is_bond: bool) -> bool:
    if mode == "nobody":
        return False
    if mode == "bonds":
        return is_bond
    return is_friend


def visible_to(db, viewer: int, owners) -> dict:
    """{owner_id: may `viewer` see owner's last seen} — batched. `owners`
    are assumed to be the viewer's friends (the friend list)."""
    owners = [int(o) for o in owners]
    modes = modes_for(db, owners + [viewer])
    mine = modes.get(int(viewer), "circle")
    my_bonds = bond_ids(db, int(viewer))       # whom I still keep a Space with
    keeps_me = bonded_to(db, int(viewer))      # who still keeps one with me
    return {
        # They allow me (I'm in THEIR bonds) and I'd allow them (mine).
        o: _allows(modes.get(o, "circle"), True, o in keeps_me)
        and _allows(mine, True, o in my_bonds)
        for o in owners
    }


# ── Who can see my status ────────────────────────────────────────────────────
# Each user picks (synced in app_prefs): `status_audience_mode` 'circle' (every
# friend — default) or 'bonds' (only Our Space partners), plus
# `status_hidden_ids` — friends hidden from my status either way.

def _status_prefs_from(data):
    try:
        d = json.loads(data or "{}") or {}
    except Exception:
        return "circle", set()

    def val(k, default):
        box = d.get(k)
        return box.get("v", default) if isinstance(box, dict) else default

    mode = val("status_audience_mode", "circle")
    if mode not in ("circle", "bonds"):
        mode = "circle"
    hidden = set()
    for x in (val("status_hidden_ids", []) or []):
        try:
            hidden.add(int(x))
        except (TypeError, ValueError):
            pass
    return mode, hidden


def status_prefs_for(db, ids) -> dict:
    ids = {int(i) for i in ids}
    out = {i: ("circle", set()) for i in ids}
    if not ids:
        return out
    rows = db.query(UserSetting.user_id, UserSetting.data).filter(
        UserSetting.user_id.in_(ids), UserSetting.key == "app_prefs").all()
    for uid, data in rows:
        out[int(uid)] = _status_prefs_from(data)
    return out


def status_authors_visible_to(db, viewer: int, authors) -> set:
    """Of these [authors] (the viewer's friends), whose status may [viewer]
    see? Their audience choice decides: hidden from them → no; 'bonds' →
    only if they still keep an accepted Our Space with the viewer."""
    authors = {int(a) for a in authors}
    prefs = status_prefs_for(db, authors)
    keeps_me = bonded_to(db, int(viewer))
    out = set()
    for a in authors:
        mode, hidden = prefs.get(a, ("circle", set()))
        if int(viewer) in hidden:
            continue
        if mode == "bonds" and a not in keeps_me:
            continue
        out.add(a)
    return out


def status_audience_of(db, author: int, candidates) -> set:
    """Of these [candidates] (the author's friends), who may see [author]'s
    status — for the live "posted" nudge."""
    mode, hidden = status_prefs_for(db, [author]).get(
        int(author), ("circle", set()))
    cands = {int(c) for c in candidates} - hidden
    if mode == "bonds":
        cands &= bond_ids(db, int(author))
    return cands


def last_seen_visible(db, owner: int, viewer: int) -> bool:
    if int(owner) == int(viewer):
        return True
    is_friend = db.query(Friend).filter(
        ((Friend.user_id == owner) & (Friend.friend_id == viewer))
        | ((Friend.user_id == viewer) & (Friend.friend_id == owner))
    ).first() is not None
    if not is_friend:
        return False
    return visible_to(db, int(viewer), [int(owner)]).get(int(owner), False)
