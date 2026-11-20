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
from models import E2eeDevice, SealScope, SealScopeKey, User
from routers.e2ee_keys import _live_devices

router = APIRouter(prefix="/e2ee/scopes", tags=["E2EE"])

MAX_MEMBERS = 32          # a group bigger than this stays unsealed
MAX_WRAPPED = 400          # base64 of the 158-byte wrapped key


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
    try:
        ids = [int(x) for x in scope.split(",")]
    except ValueError:
        raise HTTPException(status_code=400, detail="Bad scope")
    if (len(ids) < 2 or len(ids) > MAX_MEMBERS
            or ",".join(str(x) for x in sorted(set(ids))) != scope):
        raise HTTPException(status_code=400, detail="Bad scope")
    if me.id not in ids:
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
    wraps: List[WrapIn] = Field(max_length=MAX_MEMBERS * 6)


def _check_wraps(db: Session, me: User, members, body: WrapsIn):
    mine = db.query(E2eeDevice).filter(E2eeDevice.user_id == me.id,
                                       E2eeDevice.device_id == body.from_device
                                       ).first()
    if mine is None:
        raise HTTPException(status_code=400, detail="Unknown device")
    live = {}
    for uid in members:
        live[uid] = {d.device_id for d in _live_devices(db, uid)}
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
    s = db.query(SealScope).filter(SealScope.scope == scope).first()
    if s is None:
        return {"epoch": None, "keys": [], "missing": []}
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
    for uid in members:
        for d in _live_devices(db, uid):
            for e in range(1, s.epoch + 1):
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
    _insert(db, scope, me, body)
    db.commit()
    return {"ok": True, "epoch": body.epoch}


@router.post("/{scope}/wraps")
def add_wraps(scope: str, body: WrapsIn, db: Session = Depends(get_db),
              me: User = Depends(get_current_user)):
    members = _members(scope, me, db)
    s = db.query(SealScope).filter(SealScope.scope == scope).first()
    if s is None or not (1 <= body.epoch <= s.epoch):
        raise HTTPException(status_code=409, detail="No such key")
    _check_wraps(db, me, members, body)
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
