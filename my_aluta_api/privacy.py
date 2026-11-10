"""Who may see whose "last seen".

Each user picks, in the app (synced in their app_prefs as
`last_seen_mode`): 'circle' (every friend — the default), 'bonds' (only
their Our Space partners) or 'nobody'. It works both ways, like WhatsApp:
I see a friend's last seen only if THEY allow me AND my own setting would
allow THEM — hide yours and you stop seeing theirs.
"""
import json

from models import UserSetting, BondRequest, Friend

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


def bond_ids(db, uid: int) -> set:
    """Everyone uid shares an accepted bond (Our Space) with."""
    rows = db.query(BondRequest.from_user_id, BondRequest.to_user_id).filter(
        BondRequest.status == "accepted",
        (BondRequest.from_user_id == uid) | (BondRequest.to_user_id == uid),
    ).all()
    return {int(b if int(a) == uid else a) for a, b in rows} - {uid}


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
    bonds = bond_ids(db, int(viewer))
    return {
        o: _allows(modes.get(o, "circle"), True, o in bonds)
        and _allows(mine, True, o in bonds)
        for o in owners
    }


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
