"""
WebRTC ICE-server configuration.

The Flutter clients (voice/video calls AND "Listen Together" live sessions) used
to HARD-CODE their STUN/TURN servers. That bit us hard: the free public TURN
they pointed at (openrelay.metered.ca) was decommissioned — its DNS no longer
resolves — so every cross-network call/session silently hung waiting for a relay
that no longer existed, and the only "fix" was rebuilding + reshipping the app.

This endpoint moves that config to the SERVER, so swapping or renewing a TURN
provider is a Railway env-var change that takes effect instantly for every
client, with no app rebuild. It's provider-agnostic — set whichever block of
env vars matches what you're using:

  • Metered (hosted, easiest):
        METERED_TURN_SUBDOMAIN = your-app        # -> your-app.metered.live
        METERED_TURN_API_KEY   = <api key>
    We fetch fresh (ephemeral) credentials from Metered and hand them to the
    client. Cached briefly so we don't hammer their API.

  • coturn / TURN REST secret (self-hosted, most control + privacy):
        TURN_SHARED_SECRET = <the coturn static-auth-secret>
        TURN_URLS          = turn:turn.example.com:3478,turns:turn.example.com:5349?transport=tcp
    We mint time-limited HMAC credentials (the standard TURN REST API scheme
    coturn's `use-auth-secret` expects) — nothing long-lived leaves the server.

  • Static credentials (any provider that gives you a fixed user/pass):
        TURN_STATIC_URLS       = turn:turn.example.com:3478
        TURN_STATIC_USERNAME   = <username>
        TURN_STATIC_CREDENTIAL = <credential>

If NONE are set, the endpoint returns STUN-only — same-network sessions still
work; cross-network ones need one of the blocks above. The client falls back to
STUN-only on its own if this endpoint is ever unreachable, so calls never get
WORSE than "no relay", they just can't relay until TURN is configured.
"""
import base64
import hashlib
import hmac
import os
import time
from typing import List, Optional

from fastapi import APIRouter, Depends

from auth import get_current_user
from models import User

try:
    import requests  # already a dependency (used by push.py)
except Exception:  # pragma: no cover
    requests = None

router = APIRouter(prefix="/webrtc", tags=["WebRTC"])

# Public STUN — always included. Cheap, credential-free, and enough for
# same-network / friendly-NAT peers to connect directly.
_STUN: List[dict] = [
    {"urls": "stun:stun.l.google.com:19302"},
    {"urls": "stun:stun1.l.google.com:19302"},
]

# Default lifetime for minted (coturn HMAC) credentials.
_TURN_TTL_SECONDS = 12 * 60 * 60

# Tiny in-process cache for the Metered fetch so a burst of joins doesn't hammer
# their API. (value, expires_at)
_metered_cache: Optional[tuple] = None
_METERED_CACHE_TTL = 10 * 60


def _split_urls(raw: str) -> List[str]:
    return [u.strip() for u in raw.split(",") if u.strip()]


def _coturn_credentials(secret: str, urls: List[str],
                        ttl: int = _TURN_TTL_SECONDS) -> Optional[dict]:
    """Mint a time-limited credential per the TURN REST API (coturn
    `use-auth-secret`): username = "<expiry-unix-ts>", credential =
    base64(HMAC-SHA1(secret, username))."""
    if not secret or not urls:
        return None
    username = str(int(time.time()) + ttl)
    digest = hmac.new(secret.encode("utf-8"), username.encode("utf-8"),
                      hashlib.sha1).digest()
    credential = base64.b64encode(digest).decode("utf-8")
    return {"urls": urls, "username": username, "credential": credential}


def _metered_servers() -> Optional[List[dict]]:
    """Fetch a fresh iceServers list from Metered (STUN+TURN), cached briefly."""
    global _metered_cache
    subdomain = os.getenv("METERED_TURN_SUBDOMAIN")
    api_key = os.getenv("METERED_TURN_API_KEY")
    if not subdomain or not api_key or requests is None:
        return None
    now = time.time()
    if _metered_cache is not None and _metered_cache[1] > now:
        return _metered_cache[0]
    try:
        resp = requests.get(
            f"https://{subdomain}.metered.live/api/v1/turn/credentials",
            params={"apiKey": api_key},
            timeout=5,
        )
        if resp.status_code == 200:
            data = resp.json()
            if isinstance(data, list) and data:
                _metered_cache = (data, now + _METERED_CACHE_TTL)
                return data
    except Exception:
        pass
    return None


def build_ice_servers() -> List[dict]:
    """Assemble the ICE server list from whatever env config is present.

    Never raises — worst case returns STUN-only.
    """
    # Metered returns its own complete list (STUN + TURN); use it as-is when set.
    metered = _metered_servers()
    if metered:
        return metered

    servers: List[dict] = list(_STUN)

    secret = os.getenv("TURN_SHARED_SECRET")
    turn_urls = os.getenv("TURN_URLS")
    if secret and turn_urls:
        minted = _coturn_credentials(secret, _split_urls(turn_urls))
        if minted:
            servers.append(minted)
            return servers

    static_urls = os.getenv("TURN_STATIC_URLS")
    static_user = os.getenv("TURN_STATIC_USERNAME")
    static_cred = os.getenv("TURN_STATIC_CREDENTIAL")
    if static_urls and static_user and static_cred:
        servers.append({
            "urls": _split_urls(static_urls),
            "username": static_user,
            "credential": static_cred,
        })

    return servers


@router.get("/ice")
def ice_servers(current_user: User = Depends(get_current_user)):
    """Return the ICE (STUN/TURN) servers the client should use for calls and
    Listen Together. Authenticated so credentials aren't handed to the world."""
    return {"iceServers": build_ice_servers()}
