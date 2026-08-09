"""Minimal transactional-email helper backed by the ZeptoMail HTTP API (v1.1).

Only used for email-code password recovery. Best-effort: if ZeptoMail isn't
configured (or a send fails) the caller still returns a generic success so the
endpoint never reveals whether an email exists, and users can fall back to the
authenticator-based recovery path.
"""
import json
import requests

from config import (
    ZEPTOMAIL_TOKEN,
    ZEPTOMAIL_FROM,
    ZEPTOMAIL_FROM_NAME,
    ZEPTOMAIL_API_URL,
)


def mail_available() -> bool:
    """True when we have enough config to attempt a send."""
    return bool(ZEPTOMAIL_TOKEN and ZEPTOMAIL_FROM)


def _auth_header_value() -> str:
    """ZeptoMail expects 'Zoho-enczapikey <key>'. Accept either the bare key or
    the already-prefixed value so it doesn't matter which the user pasted."""
    tok = (ZEPTOMAIL_TOKEN or "").strip()
    if tok.lower().startswith("zoho-enczapikey"):
        return tok
    return f"Zoho-enczapikey {tok}"


def send_email(
    to_email: str,
    subject: str,
    html_body: str,
    text_body: str | None = None,
    to_name: str | None = None,
) -> bool:
    """Send one email via ZeptoMail. Returns True on a 2xx response."""
    if not mail_available():
        print("[mailer] ZeptoMail not configured; skipping send")
        return False

    payload = {
        "from": {"address": ZEPTOMAIL_FROM, "name": ZEPTOMAIL_FROM_NAME or "Aluta"},
        "to": [
            {
                "email_address": {
                    "address": to_email,
                    "name": to_name or to_email,
                }
            }
        ],
        "subject": subject,
        "htmlbody": html_body,
    }
    if text_body:
        payload["textbody"] = text_body

    headers = {
        "Authorization": _auth_header_value(),
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    try:
        resp = requests.post(
            ZEPTOMAIL_API_URL,
            headers=headers,
            data=json.dumps(payload),
            timeout=15,
        )
        if 200 <= resp.status_code < 300:
            return True
        print(f"[mailer] send failed {resp.status_code}: {resp.text[:300]}")
        return False
    except Exception as e:  # noqa: BLE001
        print(f"[mailer] exception: {e}")
        return False


def send_password_reset_code(to_email: str, username: str | None, code: str) -> bool:
    """Compose + send the password-reset code email."""
    name = username or "there"
    subject = "Your Aluta password reset code"
    html_body = f"""\
<div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:auto;
            padding:24px;color:#1a1a1a">
  <h2 style="margin:0 0 8px">Reset your Aluta password</h2>
  <p style="color:#555;font-size:14px;margin:0 0 20px">Hi {name}, use the code
     below to reset your password. It expires in 15 minutes.</p>
  <div style="font-size:34px;font-weight:700;letter-spacing:10px;
              background:#f4f4f7;border-radius:12px;padding:18px;text-align:center;
              color:#111">{code}</div>
  <p style="color:#888;font-size:12px;margin:20px 0 0">If you didn't request
     this, you can safely ignore this email — your password won't change.</p>
</div>"""
    text_body = (
        f"Hi {name}, your Aluta password reset code is {code}. "
        "It expires in 15 minutes. If you didn't request this, ignore this email."
    )
    return send_email(
        to_email, subject, html_body, text_body=text_body, to_name=username
    )
