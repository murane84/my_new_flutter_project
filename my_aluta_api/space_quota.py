"""Our Space storage cap — each bond (couple) keeps at most SPACE_CAP_BYTES of
media on the server (moments, dedication voice notes, capsule media).

Why a cap and not a 24 h purge: a keepsake is the one thing people must never
lose, and their phones aren't a safe single copy (lost phone, new phone, web).
So the server keeps one copy per moment — but bounded, so storage can never run
away (the volume once filled with old test APKs). Phones also keep their own
copy; the server's is the safety net.

Counting is set-based on MediaAsset.size (the bytes are never loaded)."""
import os
import re

from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from models import (
    MediaAsset, Message, PinnedMoment, Dedication, LoveCapsule,
)

SPACE_CAP_BYTES = int(os.environ.get("SPACE_CAP_MB", "150")) * 1024 * 1024
FULL_DETAIL = ("Our Space is full — remove a few moments to make room "
               "for new ones.")

_ASSET = re.compile(r"/attachments/([0-9a-fA-F]{32})")


def asset_ids(*refs) -> set:
    """Media asset ids referenced by these strings (urls / refs)."""
    out = set()
    for r in refs:
        if r:
            out.update(m.lower() for m in _ASSET.findall(str(r)))
    return out


def bond_asset_ids(db: Session, space_ids: list, pair_key) -> set:
    """Every asset this bond's Our Space holds."""
    refs = []
    if space_ids:
        refs += [r for (r,) in db.query(PinnedMoment.ref)
                 .filter(PinnedMoment.space_id.in_(space_ids)).all()]
    if pair_key:
        for (v,) in (db.query(Dedication.voice_note_url)
                     .filter(Dedication.pair_key == pair_key).all()):
            refs.append(v)
        for (v,) in (db.query(LoveCapsule.media_url)
                     .filter(LoveCapsule.pair_key == pair_key).all()):
            refs.append(v)
    return asset_ids(*refs)


def _bytes_of(db: Session, ids: set) -> int:
    if not ids:
        return 0
    total = (
        db.query(func.coalesce(func.sum(MediaAsset.size), 0))
        .filter(MediaAsset.id.in_(list(ids)), MediaAsset.data.isnot(None))
        .scalar()
    )
    return int(total or 0)


def usage(db: Session, space_ids: list, pair_key) -> dict:
    used = _bytes_of(db, bond_asset_ids(db, space_ids, pair_key))
    return {"used_bytes": used, "cap_bytes": SPACE_CAP_BYTES}


def check_room(db: Session, space_ids: list, pair_key, uploader_id: int,
               *new_refs) -> None:
    """Raise 413 when adding these refs would pass the cap. The just-uploaded
    asset is then removed (if it's the caller's and nothing else uses it), so a
    refused keepsake doesn't linger on the server."""
    new = asset_ids(*new_refs)
    if not new:
        return
    have = bond_asset_ids(db, space_ids, pair_key)
    fresh = new - have
    if not fresh:
        return
    if _bytes_of(db, have) + _bytes_of(db, fresh) <= SPACE_CAP_BYTES:
        return
    for aid in fresh:
        used_in_chat = (
            db.query(Message.id)
            .filter(Message.media_url.contains(aid, autoescape=True))
            .first()
            is not None
        )
        if not used_in_chat:
            (db.query(MediaAsset)
             .filter(MediaAsset.id == aid,
                     MediaAsset.uploader_id == uploader_id)
             .delete(synchronize_session=False))
    db.commit()
    raise HTTPException(status_code=413, detail=FULL_DETAIL)
