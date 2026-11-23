"""🔒 Our Space and group chat keys (end-to-end encryption, Phase 6 / 8).

Everything a group shares in Our Space is sealed on the devices with one key
per group. The **scope** names the group: its member ids, sorted ("3,7").
The server never sees the key — it keeps one copy per device, wrapped to that
device's identity and signed by the member device that wrapped it (the app
checks the signature against the key directory before trusting it).

    GET  /e2ee/scopes/{scope}?device_id=   my copies + current epoch + which
                                           member devices still need a copy
    POST /e2ee/scopes/{scope}/create       a new key: epoch 1 for a new group,
                                           or current+1 when a member device
                                           has no copy left to write with (a
                                           new phone nobody has served yet) —
                                           the first device to ask wins, the
                                           others get 409 and take that one
    POST /e2ee/scopes/{scope}/wraps        copies of any of its keys for more
                                           devices (only ones that have none
                                           yet — first wins)
"""
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

import crud
from auth import get_current_user
from database import get_db
from models import (E2eeDevice, SealScope, SealScopeEpoch, SealScopeGrant,
                    SealScopeKey, User)
from routers.e2ee_keys import STALE_AFTER, _live_devices

router = APIRouter(prefix="/e2ee/scopes", tags=["E2EE"])

MAX_MEMBERS = 32          # a member-list scope ("3,7,9") holds at most this
MAX_WRAPPED = 400          # base64 of the 158-byte wrapped key
# NAMED scopes — a key that belongs to something rather than to a list of
# ids: "g:<conversation id>" (a group chat of more than 32) and "s:<user id>"
# (that person's Stories). Their members are whoever belongs today (the
# group's members; the author + who may see their status); each epoch
# records who it was made for (SealScopeEpoch) and a new one is due when
# that changes: a group on any join or leave (a newcomer reads only what
# comes after, unless the group shares its history; a leaver nothing more),
# Stories when someone loses access (a new viewer just gets today's key).
MAX_NAMED_MEMBERS = 1024  # a group (= crud_conversations.GROUP_MAX_MEMBERS)
# Who may see someone's Stories: far past any real circle. A status is never
# posted plain for being seen by many — past this the app says so instead.
MAX_STORY_AUDIENCE = 20000
# Key copies per request: a full group with all its members' devices (routers/
# e2ee_keys.MAX_DEVICES = 6 each) fits one; a bigger Stories audience gets
# the rest in further requests (/wraps).
MAX_WRAPS = MAX_NAMED_MEMBERS * 6


def stale_group_key(db: Session, cid: int, *values, pair=None) -> bool:
    """Whether a value written to group [cid] is sealed for anyone but its
    members today — so someone who just left (and still holds the old key)
    can't read it. Sealed with the members' list key: exactly today's
    members ([pair]: exactly those two — a heart for one member); with a big
    group's own key: its current one, made for today's members. Anything
    else sealed (another scope) doesn't belong here either. The writer's
    phone then looks its members / key up afresh and writes again."""
    lead = "🔒s1."
    now = None
    named = f"g:{int(cid)}"
    for v in values:
        if not (isinstance(v, str) and v.startswith(lead)):
            continue
        parts = v[len(lead):].split(".")
        if len(parts) < 3:
            return True
        scope, ep = parts[0], parts[1]
        if now is None:
            now = named_members(db, "g", int(cid))
        if scope == named:
            s = db.query(SealScope).filter(SealScope.scope == named).first()
            if s is None or ep != str(s.epoch):
                return True
            if _epoch_members(db, named, s.epoch) != now:
                return True
            continue
        try:
            ids = {int(x) for x in scope.split(",")}
        except ValueError:
            return True
        if ids != ({int(x) for x in pair} if pair else now):
            return True
    return False


def _named_cap(nk) -> int:
    return MAX_STORY_AUDIENCE if nk[0] == "s" else MAX_NAMED_MEMBERS


def _devices_of(db: Session, uids) -> dict:
    """{user id: their live devices} for many people in a few queries (a
    big group or audience isn't looked up person by person)."""
    from datetime import datetime, timezone
    since = datetime.now(timezone.utc) - STALE_AFTER
    ids = sorted({int(u) for u in uids})
    out = {u: [] for u in ids}
    for i in range(0, len(ids), 500):
        for d in (db.query(E2eeDevice)
                  .filter(E2eeDevice.user_id.in_(ids[i:i + 500]),
                          E2eeDevice.last_seen_at >= since)
                  .order_by(E2eeDevice.id.asc()).all()):
            out[int(d.user_id)].append(d)
    return out


def named_kind(scope: str):
    """("g", conversation id) / ("s", user id) for a named scope, else None."""
    if len(scope) < 3 or scope[1] != ":" or scope[0] not in ("g", "s"):
        return None
    tail = scope[2:]
    if not tail.isdigit() or str(int(tail)) != tail or int(tail) <= 0:
        raise HTTPException(status_code=400, detail="Bad scope")
    return scope[0], int(tail)


def named_members(db: Session, kind: str, n: int) -> set:
    """Who belongs to a named scope today."""
    if kind == "g":
        from models import Conversation, ConversationMember
        conv = db.query(Conversation).filter(Conversation.id == n).first()
        if conv is None or not conv.is_group:
            return set()
        return {int(r[0]) for r in db.query(ConversationMember.user_id).filter(
            ConversationMember.conversation_id == n).all()}
    import privacy
    from routers.stories import _story_circle
    return {n} | {int(x) for x in privacy.status_audience_of(
        db, n, _story_circle(db, n))}


def _epoch_members(db: Session, scope: str, epoch: int) -> set:
    row = db.query(SealScopeEpoch).filter(SealScopeEpoch.scope == scope,
                                         SealScopeEpoch.epoch == epoch).first()
    if row is None:
        return set()
    return {int(x) for x in row.members.split(",") if x}


def _named_targets(db: Session, scope: str, nk, epoch: int, current: int,
                   now_members: set) -> set:
    """Who may hold a named scope's key of [epoch]: those it was made for
    (still here) — plus, for a group that shares its history, every member
    now; for Stories, today's audience gets today's key."""
    out = _epoch_members(db, scope, epoch) & now_members
    if nk[0] == "g":
        from models import Conversation
        conv = db.query(Conversation).filter(Conversation.id == nk[1]).first()
        if conv is not None and getattr(conv, "share_history", False):
            out |= now_members
    elif epoch == current:
        out |= now_members
    return out


def space_groups(db: Session, uid: int) -> List[set]:
    """The member sets (owner + members) of every Space [uid] is in."""
    from models import RelationshipSpace, SpaceMember
    ids = {r[0] for r in db.query(SpaceMember.space_id).filter(
        SpaceMember.user_id == uid).all()}
    ids |= {r[0] for r in db.query(RelationshipSpace.id).filter(
        RelationshipSpace.owner_id == uid).all()}
    out = []
    for sid in ids:
        sp = db.query(RelationshipSpace).filter(
            RelationshipSpace.id == sid).first()
        if sp is None:
            continue
        members = {r[0] for r in db.query(SpaceMember.user_id).filter(
            SpaceMember.space_id == sid).all()}
        members.add(sp.owner_id)
        out.append(members)
    return out


def chat_groups(db: Session, uid: int) -> List[set]:
    """The member sets of every group chat [uid] is in (today's members)."""
    from models import Conversation, ConversationMember
    cids = [r[0] for r in db.query(ConversationMember.conversation_id)
            .join(Conversation, Conversation.id ==
                  ConversationMember.conversation_id)
            .filter(ConversationMember.user_id == uid,
                    Conversation.is_group == True).all()]  # noqa: E712
    out = []
    for cid in cids:
        out.append({r[0] for r in db.query(ConversationMember.user_id).filter(
            ConversationMember.conversation_id == cid).all()})
    return out


def share_a_space(db: Session, a: int, b: int) -> bool:
    return any(b in g for g in space_groups(db, a))


def _members(scope: str, me: User, db: Session,
             making: bool = False) -> List[int]:
    nk = named_kind(scope)
    if nk is not None:
        members = named_members(db, *nk)
        # Too many to make a key for — but reading the keys one already
        # holds never stops working because the audience grew.
        if making and len(members) > _named_cap(nk):
            raise HTTPException(status_code=400, detail="Too many members")
        if me.id in members:
            # Only the author's devices make a key for their Stories.
            if making and nk[0] == "s" and me.id != nk[1]:
                raise HTTPException(status_code=403, detail="Not yours")
            return sorted(members)
        # Someone who left reads their own copies of older keys — nothing
        # more.
        if not making and db.query(SealScopeKey.id).filter(
                SealScopeKey.scope == scope,
                SealScopeKey.user_id == me.id).first() is not None:
            return sorted(members)
        raise HTTPException(status_code=403, detail="Not your space")
    try:
        ids = [int(x) for x in scope.split(",")]
    except ValueError:
        raise HTTPException(status_code=400, detail="Bad scope")
    if (len(ids) < 2 or len(ids) > MAX_MEMBERS
            or ",".join(str(x) for x in sorted(set(ids))) != scope):
        raise HTTPException(status_code=400, detail="Bad scope")
    if me.id not in ids:
        # A newcomer the group shared its earlier messages with may read
        # their own copies of that older key — nothing more.
        if not making and db.query(SealScopeGrant.id).filter(
                SealScopeGrant.scope == scope,
                SealScopeGrant.user_id == me.id).first() is not None:
            return ids
        raise HTTPException(status_code=403, detail="Not your space")
    # Exactly the people of one of my Spaces (a group Space's members need
    # not be each other's contacts) — or, for two people, anyone I can reach.
    if set(ids) in space_groups(db, me.id):
        return ids
    # …or of one of my group chats (its members today).
    if set(ids) in chat_groups(db, me.id):
        return ids
    if len(ids) == 2 and crud.may_reach(db, me.id, [x for x in ids
                                                     if x != me.id][0]):
        return ids
    # A group I was in before its members changed: I may still read my own
    # copies of its keys (and give them to my other devices / members who
    # lack them), never start a new key for it.
    if not making and db.query(SealScopeKey.id).filter(
            SealScopeKey.scope == scope,
            SealScopeKey.user_id == me.id).first() is not None:
        return ids
    raise HTTPException(status_code=403, detail="Not your space")


class WrapIn(BaseModel):
    user_id: int
    device_id: str = Field(min_length=8, max_length=64)
    wrapped: str = Field(min_length=40, max_length=MAX_WRAPPED)


class WrapsIn(BaseModel):
    epoch: int = Field(ge=1)
    from_device: str = Field(min_length=8, max_length=64)
    wraps: List[WrapIn] = Field(max_length=MAX_WRAPS)


def _check_wraps(db: Session, me: User, members, body: WrapsIn):
    mine = db.query(E2eeDevice).filter(E2eeDevice.user_id == me.id,
                                       E2eeDevice.device_id == body.from_device
                                       ).first()
    if mine is None:
        raise HTTPException(status_code=400, detail="Unknown device")
    live = {uid: {d.device_id for d in ds}
            for uid, ds in _devices_of(db, members).items()}
    for w in body.wraps:
        if w.user_id not in live or w.device_id not in live[w.user_id]:
            raise HTTPException(status_code=400, detail="Unknown device")


def _insert(db: Session, scope: str, me: User, body: WrapsIn) -> int:
    have = {(r.user_id, r.device_id) for r in db.query(
        SealScopeKey.user_id, SealScopeKey.device_id).filter(
        SealScopeKey.scope == scope, SealScopeKey.epoch == body.epoch).all()}
    n = 0
    for w in body.wraps:
        if (w.user_id, w.device_id) in have:
            continue  # first copy wins
        db.add(SealScopeKey(scope=scope, epoch=body.epoch, user_id=w.user_id,
                            device_id=w.device_id, wrapped=w.wrapped,
                            from_user=me.id, from_device=body.from_device))
        have.add((w.user_id, w.device_id))
        n += 1
    return n


@router.get("/{scope}")
def get_scope(scope: str, device_id: str, db: Session = Depends(get_db),
              me: User = Depends(get_current_user)):
    members = _members(scope, me, db)
    nk = named_kind(scope)
    s = db.query(SealScope).filter(SealScope.scope == scope).first()
    named = {}
    # Who belongs to a named scope (and their devices) is told only to
    # someone who may make its key: a member of the group today, or the
    # author of the Stories. A viewer of someone's Stories must not learn
    # who else may see them, nor someone who left a group who is in it now;
    # they get only themselves and whoever handed them their copies (enough
    # to check those copies' signatures).
    full = nk is None or (me.id == nk[1] if nk[0] == "s"
                          else me.id in members)
    if nk is not None and not full:
        givers = {int(r[0]) for r in db.query(SealScopeKey.from_user).filter(
            SealScopeKey.scope == scope, SealScopeKey.user_id == me.id).all()}
        members = sorted({me.id} | givers)
        named["members"] = members
    if nk is not None and full:
        # The devices of everyone who belongs (with what their Aluta can
        # open), so a member's device can make the next key and tell
        # whether every device can read it — without asking per person.
        named["members"] = members
        devs = _devices_of(db, members)
        if len(members) > _named_cap(nk):
            # (No new key can be made for this many.)
            named["too_big"] = True
        named["member_devices"] = [] if named.get("too_big") else [
            {"user_id": uid, "device_id": d.device_id, "ik_sig": d.ik_sig,
             "ik_dh": d.ik_dh, "ik_dh_sig": d.ik_dh_sig,
             "caps": getattr(d, "caps", None) or ""}
            for uid in members for d in devs.get(uid, [])]
        if s is not None:
            made_for = _epoch_members(db, scope, s.epoch)
            now = set(members)
            named["rotate"] = (made_for != now if nk[0] == "g"
                               else bool(made_for - now))
    if s is None:
        return {"epoch": None, "keys": [], "missing": [], **named}
    keys = (db.query(SealScopeKey)
            .filter(SealScopeKey.scope == scope,
                    SealScopeKey.user_id == me.id,
                    SealScopeKey.device_id == device_id)
            .order_by(SealScopeKey.epoch).all())
    # Every key of the group a live member device lacks — older ones too,
    # so a device that joined later can open what was written before it.
    have_by = {}
    for e, u, dv in db.query(SealScopeKey.epoch, SealScopeKey.user_id,
                             SealScopeKey.device_id).filter(
            SealScopeKey.scope == scope).all():
        have_by.setdefault(e, set()).add((u, dv))
    missing = []
    # (Only the author's devices hand out a Stories key, and only members
    # today hand out a group's — add_wraps.)
    now_members = set(members) if full else set()
    targets = {e: (_named_targets(db, scope, nk, e, s.epoch, now_members)
                   if nk is not None else now_members)
               for e in range(1, s.epoch + 1)}
    # (only who hands out keys learns who lacks them)
    live_by = _devices_of(db, members) if full else {}
    for uid in members:
        for d in live_by.get(uid, []):
            for e in range(1, s.epoch + 1):
                if uid not in targets[e]:
                    continue
                if (uid, d.device_id) not in have_by.get(e, set()):
                    missing.append({"epoch": e, "user_id": uid,
                                    "device_id": d.device_id,
                                    "ik_sig": d.ik_sig, "ik_dh": d.ik_dh,
                                    "ik_dh_sig": d.ik_dh_sig})
    return {
        "epoch": s.epoch,
        "keys": [{"epoch": k.epoch, "wrapped": k.wrapped,
                  "from_user": k.from_user, "from_device": k.from_device}
                 for k in keys],
        "missing": missing,
        **named,
    }


@router.post("/{scope}/create")
def create_scope(scope: str, body: WrapsIn, db: Session = Depends(get_db),
                 me: User = Depends(get_current_user)):
    members = _members(scope, me, db, making=True)
    _check_wraps(db, me, members, body)
    if not any(w.user_id == me.id and w.device_id == body.from_device
               for w in body.wraps):
        raise HTTPException(status_code=400, detail="Keep a copy for yourself")
    s = db.query(SealScope).filter(SealScope.scope == scope).first()
    if s is None:
        if body.epoch != 1:
            raise HTTPException(status_code=409, detail="Not the next key")
        try:
            db.add(SealScope(scope=scope, epoch=1, created_by=me.id))
            db.flush()
        except IntegrityError:
            db.rollback()
            raise HTTPException(status_code=409, detail="Already has a key")
    else:
        if body.epoch != s.epoch + 1:
            raise HTTPException(status_code=409, detail="Not the next key")
        # Only one device moves the group on (compare-and-set).
        moved = (db.query(SealScope)
                 .filter(SealScope.scope == scope,
                         SealScope.epoch == s.epoch)
                 .update({SealScope.epoch: body.epoch,
                          SealScope.created_by: me.id},
                         synchronize_session=False))
        if moved != 1:
            db.rollback()
            raise HTTPException(status_code=409, detail="Not the next key")
    if named_kind(scope) is not None:
        # Who this key is made for (the next one is due when that changes).
        db.add(SealScopeEpoch(scope=scope, epoch=body.epoch,
                              members=",".join(str(m) for m in members)))
    _insert(db, scope, me, body)
    db.commit()
    return {"ok": True, "epoch": body.epoch}


@router.post("/{scope}/wraps")
def add_wraps(scope: str, body: WrapsIn, db: Session = Depends(get_db),
              me: User = Depends(get_current_user)):
    members = _members(scope, me, db)
    if me.id not in members:
        # (A newcomer given the history only reads; its copies must never
        # take a member device's place — the first copy wins.)
        raise HTTPException(status_code=403, detail="Not your space")
    s = db.query(SealScope).filter(SealScope.scope == scope).first()
    if s is None or not (1 <= body.epoch <= s.epoch):
        raise HTTPException(status_code=409, detail="No such key")
    _check_wraps(db, me, members, body)
    nk = named_kind(scope)
    # Only the author's devices hand out their Stories key: a viewer's phone
    # may not be able to check another viewer's devices (they needn't know
    # each other), and the first copy a device gets is the one it keeps.
    if nk is not None and nk[0] == "s" and me.id != nk[1]:
        raise HTTPException(status_code=403, detail="Not yours")
    if nk is not None:
        allowed = _named_targets(db, scope, nk, body.epoch, s.epoch,
                                 set(members))
        if any(w.user_id not in allowed for w in body.wraps):
            raise HTTPException(status_code=403, detail="Not for this key")
    # Only a device that holds the key can wrap it: it must have its own copy.
    held = db.query(SealScopeKey.id).filter(
        SealScopeKey.scope == scope, SealScopeKey.epoch == body.epoch,
        SealScopeKey.user_id == me.id,
        SealScopeKey.device_id == body.from_device).first()
    if held is None:
        raise HTTPException(status_code=403, detail="This device has no key")
    n = _insert(db, scope, me, body)
    db.commit()
    return {"ok": True, "added": n}


# ── A group's earlier messages for members who joined later ───────────────

def _group_scopes(db: Session, cid: int) -> List[str]:
    """The scopes this group chat's sealed messages were written with."""
    from models import Message
    from e2ee_msgs import SCOPE_PREFIX
    out = set()
    for (c,) in db.query(Message.content).filter(
            Message.conversation_id == cid,
            Message.is_deleted == False,  # noqa: E712
            Message.content.startswith(SCOPE_PREFIX)).all():
        part = (c or "")[len(SCOPE_PREFIX):].split(".", 1)[0]
        if part:
            out.add(part)
    return sorted(out)


def _sharing_group(db: Session, cid: int, me: User):
    from models import Conversation, ConversationMember
    conv = db.query(Conversation).filter(Conversation.id == cid).first()
    if conv is None or not conv.is_group:
        raise HTTPException(status_code=404, detail="No such group")
    members = {r[0] for r in db.query(ConversationMember.user_id).filter(
        ConversationMember.conversation_id == cid).all()}
    if me.id not in members:
        raise HTTPException(status_code=404, detail="No such group")
    if not getattr(conv, "share_history", False):
        raise HTTPException(status_code=403, detail="This group keeps its history")
    return members


@router.get("/history/needs")
def history_needs(conversation_id: int, device_id: str,
                  db: Session = Depends(get_db),
                  me: User = Depends(get_current_user)):
    """For a group that shares its history: the members who joined after some
    of its messages were sealed, per older scope this device holds a key of —
    with their devices, so this device can hand them those keys."""
    members = _sharing_group(db, conversation_id, me)
    out = []
    for scope in _group_scopes(db, conversation_id):
        try:
            ids = {int(x) for x in scope.split(",")}
        except ValueError:
            continue
        if me.id not in ids:
            continue  # only a member of that older group holds its key
        epochs = sorted({r[0] for r in db.query(SealScopeKey.epoch).filter(
            SealScopeKey.scope == scope, SealScopeKey.user_id == me.id,
            SealScopeKey.device_id == device_id).all()})
        if not epochs:
            continue
        for uid in sorted(members - ids):
            devices = []
            for d in _live_devices(db, uid):
                have = {r[0] for r in db.query(SealScopeKey.epoch).filter(
                    SealScopeKey.scope == scope, SealScopeKey.user_id == uid,
                    SealScopeKey.device_id == d.device_id).all()}
                need = [e for e in epochs if e not in have]
                if need and d.ik_dh and d.ik_dh_sig:
                    devices.append({"device_id": d.device_id,
                                    "ik_sig": d.ik_sig, "ik_dh": d.ik_dh,
                                    "ik_dh_sig": d.ik_dh_sig,
                                    "epochs": need})
            if devices:
                out.append({"scope": scope, "user_id": uid,
                            "devices": devices})
    return {"needs": out}


class GrantIn(BaseModel):
    conversation_id: int
    user_id: int
    keys: List[WrapsIn] = Field(max_length=64)


@router.post("/{scope}/grant")
def grant_history(scope: str, body: GrantIn, db: Session = Depends(get_db),
                  me: User = Depends(get_current_user)):
    """Hand an older scope's keys (wrapped on my device) to a member who
    joined the group later — only for a group that shares its history, only
    a scope this group wrote with, only from a device holding those keys."""
    members = _sharing_group(db, body.conversation_id, me)
    if body.user_id not in members or body.user_id == me.id:
        raise HTTPException(status_code=400, detail="Not a member")
    if scope not in _group_scopes(db, body.conversation_id):
        raise HTTPException(status_code=400, detail="Not this group's")
    try:
        ids = [int(x) for x in scope.split(",")]
    except ValueError:
        raise HTTPException(status_code=400, detail="Bad scope")
    if me.id not in ids or body.user_id in ids:
        raise HTTPException(status_code=400, detail="Not for this scope")
    live = {d.device_id for d in _live_devices(db, body.user_id)}
    n = 0
    for k in body.keys:
        held = db.query(SealScopeKey.id).filter(
            SealScopeKey.scope == scope, SealScopeKey.epoch == k.epoch,
            SealScopeKey.user_id == me.id,
            SealScopeKey.device_id == k.from_device).first()
        if held is None:
            raise HTTPException(status_code=403, detail="This device has no key")
        for w in k.wraps:
            if w.user_id != body.user_id or w.device_id not in live:
                raise HTTPException(status_code=400, detail="Unknown device")
        n += _insert(db, scope, me, k)
    if db.query(SealScopeGrant.id).filter(
            SealScopeGrant.scope == scope,
            SealScopeGrant.user_id == body.user_id).first() is None:
        db.add(SealScopeGrant(scope=scope, user_id=body.user_id,
                              conversation_id=body.conversation_id,
                              granted_by=me.id))
    db.commit()
    # Their open chat reloads and reads the earlier messages now.
    try:
        from websocket_manager import safe_notify_user
        safe_notify_user(body.user_id, {"type": "history_shared",
                                        "conversation_id": body.conversation_id})
    except Exception:  # noqa: BLE001
        pass
    return {"ok": True, "added": n}
