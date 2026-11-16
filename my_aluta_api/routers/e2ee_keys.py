"""Aluta Seal key directory (end-to-end encryption, Phase 1b).

The server only ever sees PUBLIC keys. Each app install registers a device:
its identity keys and a signed prekey (signatures are checked here so junk
never reaches a friend), plus a batch of one-time prekeys. A friend's phone
fetches one bundle per device to start a session; each one-time prekey is
handed out once and then deleted.

    PUT    /e2ee/device              register / refresh this device
    POST   /e2ee/prekeys             upload more one-time prekeys
    GET    /e2ee/prekeys/count       how many are left (refill below ~20)
    DELETE /e2ee/device/{device_id}  forget this device (sign-out)
    GET    /e2ee/devices/{user_id}   their devices + identities (no consume)
    GET    /e2ee/bundles/{user_id}   one bundle per device (consumes OPKs)
"""
import base64
from datetime import datetime, timedelta, timezone
from typing import List, Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

import crud
from auth import get_current_user
from database import get_db
from models import E2eeDevice, E2eePreKey, Friend, User

router = APIRouter(prefix="/e2ee", tags=["E2EE"])

SPK_PREFIX = b"AlutaSeal SPK v1"
IKDH_PREFIX = b"AlutaSeal IKDH v1"
MAX_DEVICES = 6          # per person; the stalest one makes room
MAX_PREKEYS = 200        # stored per device
STALE_AFTER = timedelta(days=60)   # not seen this long → left out of bundles


def _b64(v: str, n: int) -> bytes:
    try:
        raw = base64.b64decode(v, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail="Bad key encoding")
    if len(raw) != n:
        raise HTTPException(status_code=400, detail="Bad key length")
    return raw


def _verify(sig_pub: bytes, msg: bytes, sig: bytes) -> None:
    try:
        Ed25519PublicKey.from_public_bytes(sig_pub).verify(sig, msg)
    except (InvalidSignature, ValueError):
        raise HTTPException(status_code=400, detail="Bad key signature")


class DeviceIn(BaseModel):
    device_id: str = Field(min_length=8, max_length=64)
    ik_sig: str
    ik_dh: str
    ik_dh_sig: str
    spk_id: int = Field(ge=0, le=0xFFFFFFFE)
    spk: str
    spk_sig: str
    label: Optional[str] = Field(default=None, max_length=60)
    platform: Optional[str] = Field(default=None, max_length=20)


class PreKeyIn(BaseModel):
    id: int = Field(ge=0, le=0xFFFFFFFE)
    pub: str


class PreKeysIn(BaseModel):
    device_id: str = Field(min_length=8, max_length=64)
    keys: List[PreKeyIn] = Field(max_length=100)


def _mine(db: Session, me: User, device_id: str) -> E2eeDevice:
    d = db.query(E2eeDevice).filter(E2eeDevice.user_id == me.id,
                                    E2eeDevice.device_id == device_id).first()
    if d is None:
        raise HTTPException(status_code=404, detail="Device not registered")
    return d


@router.put("/device")
def put_device(body: DeviceIn, db: Session = Depends(get_db),
               me: User = Depends(get_current_user)):
    ik_sig = _b64(body.ik_sig, 32)
    _verify(ik_sig, IKDH_PREFIX + _b64(body.ik_dh, 32),
            _b64(body.ik_dh_sig, 64))
    _verify(ik_sig, SPK_PREFIX + _b64(body.spk, 32), _b64(body.spk_sig, 64))
    now = datetime.now(timezone.utc)
    d = db.query(E2eeDevice).filter(E2eeDevice.user_id == me.id,
                                    E2eeDevice.device_id == body.device_id
                                    ).first()
    if d is None:
        others = (db.query(E2eeDevice).filter(E2eeDevice.user_id == me.id)
                  .order_by(E2eeDevice.last_seen_at.asc()).all())
        for old in others[:max(0, len(others) - MAX_DEVICES + 1)]:
            db.delete(old)
        d = E2eeDevice(user_id=me.id, device_id=body.device_id)
        db.add(d)
    elif d.ik_sig != body.ik_sig:
        # Same install id, new identity (data cleared / reinstall): its old
        # one-time prekeys belong to the old identity.
        d.identity_changed_at = now
        db.query(E2eePreKey).filter(E2eePreKey.device_pk == d.id).delete(
            synchronize_session=False)
    d.ik_sig, d.ik_dh, d.ik_dh_sig = body.ik_sig, body.ik_dh, body.ik_dh_sig
    d.spk_id, d.spk, d.spk_sig = body.spk_id, body.spk, body.spk_sig
    d.label, d.platform = body.label, body.platform
    d.updated_at = d.last_seen_at = now
    db.commit()
    return {"ok": True}


@router.post("/prekeys")
def post_prekeys(body: PreKeysIn, db: Session = Depends(get_db),
                 me: User = Depends(get_current_user)):
    d = _mine(db, me, body.device_id)
    have = {k for (k,) in db.query(E2eePreKey.key_id)
            .filter(E2eePreKey.device_pk == d.id).all()}
    room = MAX_PREKEYS - len(have)
    added = 0
    for k in body.keys:
        if added >= room:
            break
        _b64(k.pub, 32)
        if k.id in have:
            continue
        db.add(E2eePreKey(device_pk=d.id, key_id=k.id, pub=k.pub))
        have.add(k.id)
        added += 1
    d.last_seen_at = datetime.now(timezone.utc)
    db.commit()
    return {"ok": True, "added": added, "count": len(have)}


@router.get("/prekeys/count")
def prekey_count(device_id: str, db: Session = Depends(get_db),
                 me: User = Depends(get_current_user)):
    d = _mine(db, me, device_id)
    d.last_seen_at = datetime.now(timezone.utc)
    n = db.query(E2eePreKey).filter(E2eePreKey.device_pk == d.id).count()
    db.commit()
    return {"count": n, "spk_id": d.spk_id}


@router.delete("/device/{device_id}")
def delete_device(device_id: str, db: Session = Depends(get_db),
                  me: User = Depends(get_current_user)):
    db.query(E2eeDevice).filter(E2eeDevice.user_id == me.id,
                                E2eeDevice.device_id == device_id).delete(
        synchronize_session=False)
    db.commit()
    return {"ok": True}


def _may_reach(db: Session, me: User, user_id: int) -> bool:
    """Same reach as sending a message: in either one's Circle, and I haven't
    blocked them (their block on me stays invisible, as for messages)."""
    if user_id == me.id:
        return True
    i_blocked, _ = crud.block_state(db, me.id, user_id)
    if i_blocked:
        raise HTTPException(status_code=403,
                            detail="Unblock them to send a message")
    return db.query(Friend.id).filter(
        ((Friend.user_id == me.id) & (Friend.friend_id == user_id))
        | ((Friend.user_id == user_id) & (Friend.friend_id == me.id))
    ).first() is not None


def _live_devices(db: Session, user_id: int):
    since = datetime.now(timezone.utc) - STALE_AFTER
    return (db.query(E2eeDevice)
            .filter(E2eeDevice.user_id == user_id,
                    E2eeDevice.last_seen_at >= since)
            .order_by(E2eeDevice.id.asc()).all())


@router.get("/devices/{user_id}")
def list_devices(user_id: int, db: Session = Depends(get_db),
                 me: User = Depends(get_current_user)):
    if not _may_reach(db, me, user_id):
        raise HTTPException(status_code=403, detail="Not in your Circle")
    return {"devices": [{
        "device_id": d.device_id,
        "ik_sig": d.ik_sig,
        "label": d.label,
        "platform": d.platform,
        "identity_changed_at": (d.identity_changed_at.isoformat()
                                if d.identity_changed_at else None),
    } for d in _live_devices(db, user_id)]}


@router.get("/bundles/{user_id}")
def get_bundles(user_id: int, device_id: Optional[str] = None,
                db: Session = Depends(get_db),
                me: User = Depends(get_current_user)):
    """One bundle per live device of [user_id] (or just [device_id]). Asking
    for your own id gives your OTHER devices' bundles."""
    if not _may_reach(db, me, user_id):
        raise HTTPException(status_code=403, detail="Not in your Circle")
    _, they_blocked = crud.block_state(db, me.id, user_id)
    out = []
    for d in _live_devices(db, user_id):
        if device_id is not None and d.device_id != device_id:
            continue
        b = {
            "user_id": user_id,
            "device_id": d.device_id,
            "ik_sig": d.ik_sig, "ik_dh": d.ik_dh, "ik_dh_sig": d.ik_dh_sig,
            "spk_id": d.spk_id, "spk": d.spk, "spk_sig": d.spk_sig,
            "opk_id": None, "opk": None,
        }
        # A blocked sender's messages are never delivered, so don't spend
        # the person's one-time prekeys on them.
        if not they_blocked:
            q = (db.query(E2eePreKey).filter(E2eePreKey.device_pk == d.id)
                 .order_by(E2eePreKey.id.asc()))
            if db.bind.dialect.name == "postgresql":
                q = q.with_for_update(skip_locked=True)
            k = q.first()
            if k is not None:
                b["opk_id"], b["opk"] = k.key_id, k.pub
                db.delete(k)
        out.append(b)
    db.commit()
    return {"bundles": out}
