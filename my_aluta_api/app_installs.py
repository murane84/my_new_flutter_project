"""Which Aluta build each person runs, and the partner "bring them along"
update invites that ride on it.

The app reports {version, build, slot} on every socket connect. That lets an
accepted, mutual bond partner see "they're still on 1.0.5" and send ONE
personal invite per version — a second path to the newest build beside the
server's own prompt/push. When the invited person turns up on that version,
the inviter hears "they're here ✨"."""
import re
from datetime import datetime, timezone

import crud
from database import SessionLocal
from models import AppInstall, UpdateNudge

SLOTS = {"android", "android-universal", "windows", "web"}
_VER = re.compile(r"^\d{1,4}(\.\d{1,4}){0,3}$")


def vtuple(v) -> tuple:
    """'1.0.7' → (1, 0, 7); anything odd → () (sorts lowest)."""
    try:
        return tuple(int(x) for x in str(v or "").split("."))
    except Exception:
        return ()


def clean(version, build, slot):
    """Validated (version, build, slot) or None — never trust the socket."""
    v = str(version or "").strip()
    s = str(slot or "").strip()
    try:
        b = int(build)
    except Exception:
        return None
    if not _VER.match(v) or s not in SLOTS or not (0 <= b <= 10_000_000):
        return None
    return v, b, s


def record(uid: int, version, build, slot) -> list:
    """Store what this person runs. Returns the user ids who invited them to
    this version (or an older one) and haven't heard they arrived yet —
    marked arrived here, so each inviter is told once."""
    got = clean(version, build, slot)
    if got is None:
        return []
    v, b, s = got
    db = SessionLocal()
    try:
        now = datetime.now(timezone.utc)
        row = db.get(AppInstall, int(uid))
        if row is None:
            row = AppInstall(user_id=int(uid))
            db.add(row)
        changed = (row.version, row.build, row.slot) != (v, b, s)
        row.version, row.build, row.slot = v, b, s
        if changed or row.updated_at is None:
            row.updated_at = now
        arrived = []
        mine = vtuple(v)
        for n in (db.query(UpdateNudge)
                  .filter(UpdateNudge.to_user_id == int(uid),
                          UpdateNudge.arrived_at.is_(None))
                  .all()):
            if vtuple(n.version) <= mine:
                n.arrived_at = now
                # A block since the invite: it's done, but nobody is told.
                if not crud.blocked_either(db, int(uid), int(n.from_user_id)):
                    arrived.append(int(n.from_user_id))
        db.commit()
        return sorted(set(arrived))
    except Exception:
        db.rollback()
        return []
    finally:
        db.close()
