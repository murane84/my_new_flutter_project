"""Ozilane Auth (auth.ozilane.com) — platform client for Aluta.

A small Python port of sdk/ozilane-auth.ts. Aluta is a *client platform* of the
shared passwordless identity service: it links a user's Ozilane Key phone and
uses phone approvals / offline codes / backup codes for password recovery,
passwordless sign-in and step-up auth. No email or SMS, so it is immune to a
mail-provider outage.

Server-side only — the client secret (OZILANE_AUTH_CLIENT) must never reach the
app. Identity rule (docs/DESIGN.md): `subject` is an opaque per-user id we keep;
Aluta uses "aluta-<user id>". Names, emails and phone numbers are refused by the
service, so never send them as subject or label.
"""
from __future__ import annotations

from typing import Any, Optional
from urllib.parse import quote

import requests

from config import OZILANE_AUTH_URL, OZILANE_AUTH_CLIENT

TIMEOUT = 10


class OzAuthError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def available() -> bool:
    """True when a client credential is configured on this server."""
    return bool(OZILANE_AUTH_CLIENT)


def _call(method: str, path: str, body: Optional[dict] = None) -> dict:
    if not OZILANE_AUTH_CLIENT:
        raise OzAuthError(503, "not_configured",
                          "Ozilane Auth is not configured on the server.")
    url = f"{OZILANE_AUTH_URL}/v1{path}"
    headers = {
        "Authorization": f"Bearer {OZILANE_AUTH_CLIENT}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    try:
        resp = requests.request(
            method, url, headers=headers,
            json=body if body is not None else None,
            timeout=TIMEOUT,
        )
    except requests.RequestException as e:  # noqa: BLE001
        raise OzAuthError(502, "unreachable",
                          f"Could not reach Ozilane Auth: {e}")
    try:
        data = resp.json()
    except ValueError:
        data = {}
    if not (200 <= resp.status_code < 300):
        raise OzAuthError(
            resp.status_code,
            str(data.get("error", "error")),
            str(data.get("message", f"Ozilane Auth answered {resp.status_code}")),
        )
    return data if isinstance(data, dict) else {"data": data}


# ── Enrollment (link a phone) ──────────────────────────────────────────────
def start_enrollment(subject: str, label: str,
                     authorization: Optional[dict] = None) -> dict:
    body: dict[str, Any] = {"subject": subject, "label": label}
    if authorization:
        body["authorization"] = authorization
    return _call("POST", "/enrollments", body)


def enrollment_status(enrollment_id: str) -> dict:
    return _call("GET", f"/enrollments/{quote(enrollment_id, safe='')}")


def subject_info(subject: str) -> dict:
    return _call("GET", f"/subjects/{quote(subject, safe='')}")


def revoke(subject: str) -> dict:
    return _call("DELETE", f"/subjects/{quote(subject, safe='')}")


# ── Challenges (approve on phone) ──────────────────────────────────────────
def start_challenge(subject: str, context: Optional[dict] = None,
                    purpose: str = "PASSWORD_RESET") -> dict:
    return _call("POST", "/challenges",
                 {"subject": subject, "purpose": purpose,
                  "context": context or {}})


def challenge_status(challenge_id: str) -> dict:
    return _call("GET", f"/challenges/{quote(challenge_id, safe='')}")


def consume(challenge_id: str) -> dict:
    return _call("POST", f"/challenges/{quote(challenge_id, safe='')}/consume")


def cancel(challenge_id: str) -> dict:
    return _call("POST", f"/challenges/{quote(challenge_id, safe='')}/cancel")


# ── Phone-less fallbacks ───────────────────────────────────────────────────
def verify_code(subject: str, code: str) -> dict:
    """Offline 6-digit code (TOTP, RFC 6238) shown by Ozilane Key."""
    return _call("POST", "/totp/verify", {"subject": subject, "code": code})


def verify_backup_code(subject: str, code: str) -> dict:
    """One of the user's paper backup codes."""
    return _call("POST", "/backup-codes/verify",
                 {"subject": subject, "code": code})
