"""Aluta Seal message envelopes (end-to-end encryption, Phase 2: 1:1 text).

An encrypted DM arrives with EMPTY `content`, `e2ee` = the Seal version, and
`envelopes` = JSON {"<user id>:<device id>": "<base64 SealEnvelope>"} — one per
device of the receiver, plus the sender's other devices and a note-to-self
copy for the sending device itself. The server stores and
forwards them unread. Every viewer gets all of a message's envelopes (ciphertext
only, harmless to share) and each device opens its own.

An edit replaces the envelopes and bumps `e2ee_rev`, so devices know to open
the new text instead of reusing the copy they unlocked before.
"""
import base64
import binascii
import json

from fastapi import HTTPException

VERSION = 1
MAX_DEVICES = 16                # envelopes per message (2 people × 6 + slack)
MAX_ENVELOPE = 96 * 1024        # base64 characters per envelope
PUSH_BUDGET = 2800              # envelope JSON that rides in a push (FCM ≤ 4 KB)
# Sealed media (seal_media.dart): the bytes are locked on the phone; the
# message keeps its kind, the rest is inside the sealed copy.
MEDIA_KINDS = ("image", "video", "audio", "file")
# Shared cards whose JSON lives in `content` (sealed like text).
CARD_KINDS = ("location", "contact")
SEALED_MEDIA_MIME = "application/x-aluta-sealed"
# A group chat message sealed with its members' shared key (seal_scope.dart):
# the content itself is the sealed string.
SCOPE_PREFIX = "🔒s1."


def scope_sealed(msg) -> bool:
    c = getattr(msg, "content", None) or ""
    return c.startswith(SCOPE_PREFIX)


LOCKED_PREVIEW = "🔒 Message"   # what lists / pushes show for an encrypted text


def _bad(detail: str):
    raise HTTPException(status_code=400, detail=detail)


def clean(raw, allowed_uids, receiver_uid: int) -> str:
    """Validate client envelopes; returns compact JSON to store."""
    try:
        d = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        _bad("Bad envelopes")
    if not isinstance(d, dict) or not d or len(d) > MAX_DEVICES:
        _bad("Bad envelopes")
    allowed = {int(u) for u in allowed_uids}
    out = {}
    for k, v in d.items():
        uid_s, sep, dev = str(k).partition(":")
        try:
            uid = int(uid_s)
        except ValueError:
            _bad("Bad envelope key")
        if not sep or uid not in allowed or not (8 <= len(dev) <= 64):
            _bad("Bad envelope key")
        if not isinstance(v, str) or len(v) > MAX_ENVELOPE:
            _bad("Bad envelope")
        try:
            b = base64.b64decode(v, validate=True)
        except (binascii.Error, ValueError):
            _bad("Bad envelope")
        # Shortest: a device's note-to-self copy (version, type, nonce, tag).
        if len(b) < 2 + 12 + 16 or b[0] != VERSION:
            _bad("Bad envelope")
        out[f"{uid}:{dev}"] = v
    if not any(k.startswith(f"{int(receiver_uid)}:") for k in out):
        _bad("No envelope for the receiver")
    return json.dumps(out, separators=(",", ":"))


def for_user(envelopes_json, uid: int) -> dict:
    """{device id: envelope} of one person."""
    try:
        d = json.loads(envelopes_json or "{}")
    except ValueError:
        return {}
    pre = f"{int(uid)}:"
    return {k[len(pre):]: v for k, v in d.items() if k.startswith(pre)}


def push_fields(msg, uid: int) -> dict:
    """Extra push data so the phone can show the text without the server
    reading it: its own envelopes when they fit in a push."""
    if not getattr(msg, "e2ee", None):
        return {}
    out = {"e2ee": str(msg.e2ee), "e2ee_rev": str(msg.e2ee_rev or 0)}
    mine = for_user(msg.envelopes, uid)   # none while a timed heart waits
    env = json.dumps(mine, separators=(",", ":"))
    if mine and len(env) <= PUSH_BUDGET:
        out["env"] = env
    if mine:
        # push.py gives each phone its OWN copy (by its token's device), so
        # a person with many devices still gets a readable banner.
        out[ENV_BY_DEVICE] = mine
    return out


ENV_BY_DEVICE = "__env_by_device"


def sealed_preview(msg, uid: int):
    """The last message as the app needs it to open a list preview itself:
    only [uid]'s own sealed copies. None for anything that isn't a sealed,
    live 1:1 text or sealed media (a heart never previews its note)."""
    kind = getattr(msg, "message_type", None) or "text"
    if (msg is None or not getattr(msg, "e2ee", None)
            or getattr(msg, "is_deleted", False)
            or (kind != "text" and kind not in MEDIA_KINDS)):
        return None
    mine = for_user(msg.envelopes, uid)
    if not mine:
        return None
    return json.dumps({
        "id": msg.id,
        "sender_id": msg.sender_id,
        "receiver_id": msg.receiver_id,
        "e2ee": msg.e2ee,
        "e2ee_rev": msg.e2ee_rev or 0,
        "message_type": kind,
        "media_url": getattr(msg, "media_url", None),
        "meta": getattr(msg, "meta", None),
        "envelopes": json.dumps({f"{int(uid)}:{d}": e for d, e in mine.items()},
                                separators=(",", ":")),
    }, separators=(",", ":"))
