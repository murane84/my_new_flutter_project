"""Feedback from people using Aluta — the app's "Send feedback" page.

POST /feedback       send one (idea / problem / praise / other, optional 1-5
                     rating and app area); the owner gets a push.
GET  /feedback/mine  what I've sent, with its status and any reply — so people
                     see their voice was heard.

The owner works through them in the admin panel (/admin/api/feedback).
"""
import os
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func as sa_func
from sqlalchemy.orm import Session

from auth import get_current_user
from database import get_db
from models import Feedback, User

router = APIRouter(tags=["Feedback"])

KINDS = {"idea", "problem", "praise", "other"}
AREAS = {"chat", "music", "spaces", "calls", "stories", "glow", "account",
         "other"}
DAILY_LIMIT = 10
STATUS_LABEL = {
    "new": "Received", "seen": "Read by the team", "planned": "Planned",
    "done": "Done", "wontfix": "Not planned",
}


class FeedbackIn(BaseModel):
    message: str
    kind: str = "idea"
    area: Optional[str] = None
    rating: Optional[int] = None
    platform: Optional[str] = None
    app_version: Optional[str] = None


def out(f: Feedback) -> dict:
    return {
        "id": f.id,
        "kind": f.kind,
        "area": f.area,
        "rating": f.rating,
        "message": f.message,
        "status": f.status,
        "status_label": STATUS_LABEL.get(f.status, f.status),
        "reply": f.admin_note,
        "created_at": f.created_at.isoformat() if f.created_at else None,
        "updated_at": f.updated_at.isoformat() if f.updated_at else None,
    }


def _notify_owner(text: str) -> None:
    try:
        from database import SessionLocal
        from push import send_push_to_user
        emails = {e.strip().lower()
                  for e in os.getenv("ADMIN_OWNER_EMAILS", "").split(",")
                  if e.strip()}
        if not emails:
            return
        db = SessionLocal()
        try:
            ids = [u.id for u in db.query(User).filter(
                sa_func.lower(User.email).in_(emails)).all()]
        finally:
            db.close()
        for uid in ids:
            send_push_to_user(uid, {
                "type": "admin_feedback",
                "title": "💬 New Aluta feedback",
                "body": text,
            })
    except Exception as e:  # noqa: BLE001
        print(f"[feedback] owner push failed: {e}")


@router.post("/feedback")
def send_feedback(payload: FeedbackIn, bg: BackgroundTasks,
                  db: Session = Depends(get_db),
                  current_user: User = Depends(get_current_user)):
    msg = (payload.message or "").strip()
    if len(msg) < 3:
        raise HTTPException(400, "Please write a few words")
    if len(msg) > 4000:
        raise HTTPException(400, "That's a bit long — 4000 characters at most")
    since = datetime.now(timezone.utc) - timedelta(days=1)
    recent = db.query(Feedback).filter(
        Feedback.user_id == current_user.id,
        Feedback.created_at >= since).count()
    if recent >= DAILY_LIMIT:
        raise HTTPException(429, "Thanks! You've sent a lot today — try again tomorrow")
    kind = payload.kind if payload.kind in KINDS else "other"
    area = payload.area if payload.area in AREAS else None
    rating = payload.rating if payload.rating in (1, 2, 3, 4, 5) else None
    f = Feedback(
        user_id=current_user.id, kind=kind, area=area, rating=rating,
        message=msg, platform=(payload.platform or "")[:40] or None,
        app_version=(payload.app_version or "")[:40] or None, status="new")
    db.add(f)
    db.commit()
    db.refresh(f)
    icon = {"idea": "💡", "problem": "🐞", "praise": "💖"}.get(kind, "💬")
    stars = f" {'★' * rating}" if rating else ""
    bg.add_task(_notify_owner,
                f"{icon}{stars} @{current_user.username}: {msg[:90]}")
    return out(f)


@router.get("/feedback/mine")
def my_feedback(db: Session = Depends(get_db),
                current_user: User = Depends(get_current_user)):
    rows = db.query(Feedback).filter(
        Feedback.user_id == current_user.id).order_by(
        Feedback.id.desc()).limit(50).all()
    return {"feedback": [out(f) for f in rows]}
