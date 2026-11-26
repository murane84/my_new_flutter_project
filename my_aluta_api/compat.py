"""Older Aluta versions: what each build can handle, and how to tell.

Every feature that changes what the server sends (a new format, a sealed
field…) names the first build that understands it here. Before sending it,
ask whether this reader's Aluta does — and if not, send the older form or a
clear note ("update Aluta to …"), never something it would show as junk.

How the server knows a reader's build:
  * a live socket: the app's `client_info` on connect (every Aluta since
    1.0.19) — kept per socket in `socket_builds`;
  * a request: the `X-Aluta-Build` header (sent by every Aluta since 1.0.24).
When neither says, a feature falls back to what the person's devices
registered (e.g. e2ee caps).
"""
import weakref
from typing import Optional

# First build (pubspec build number) that understands each feature.
FEATURE_BUILD = {
    # 1.0.20 (build 21): group messages sealed with the members' key.
    "sealed_groups": 21,
    # 1.0.26 (build 27): opens sealed reactions in a status's "Viewed by".
    "sealed_story_reactions": 27,
}

BUILD_HEADER = "x-aluta-build"

# Live socket → the build it said it is (client_info).
socket_builds: "weakref.WeakKeyDictionary" = weakref.WeakKeyDictionary()


def note_socket_build(ws, build) -> None:
    try:
        b = int(build)
    except (TypeError, ValueError):
        return
    if b > 0:
        socket_builds[ws] = b


def request_build(request) -> Optional[int]:
    try:
        b = int((request.headers.get(BUILD_HEADER) or "").strip())
        return b if b > 0 else None
    except Exception:  # noqa: BLE001
        return None


def build_supports(build: Optional[int], feature: str) -> Optional[bool]:
    """True / False when the build is known; None when it isn't."""
    if build is None:
        return None
    return build >= FEATURE_BUILD[feature]


def socket_supports(ws, feature: str) -> Optional[bool]:
    return build_supports(socket_builds.get(ws), feature)
