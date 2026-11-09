"""'Tell me when they're online' — one-shot watches.

A watcher asks to be told the next time a friend comes online. When that
friend's first socket connects, every watcher gets one WS event + one push,
and the watch ends (deleted). Watches older than WATCH_TTL are dropped.
"""
from datetime import datetime, timedelta, timezone

from database import SessionLocal
from models import OnlineWatch, User, BlockStatus, ListenIntent

WATCH_TTL = timedelta(days=7)


def _blocked(db, a: int, b: int) -> bool:
    try:
        return db.query(BlockStatus).filter(
            ((BlockStatus.user_id == a) & (BlockStatus.blocked_user_id == b))
            | ((BlockStatus.user_id == b) & (BlockStatus.blocked_user_id == a))
        ).first() is not None
    except Exception:
        return False


def fire_online_watches(target_id: int) -> None:
    """Run (in a worker thread) when {target_id} comes online. Never raises."""
    from websocket_manager import safe_notify_user
    from push import send_push_to_user
    db = SessionLocal()
    try:
        rows = db.query(OnlineWatch).filter(
            OnlineWatch.target_id == target_id).all()
        if not rows:
            return
        target = db.query(User).filter(User.id == target_id).first()
        name = (target.username if target else None) or "Your friend"
        cutoff = datetime.now(timezone.utc) - WATCH_TTL
        fire = []
        for r in rows:
            created = r.created_at
            if created is not None and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            if (created is None or created >= cutoff) and not _blocked(
                    db, r.watcher_id, target_id):
                fire.append(int(r.watcher_id))
            db.delete(r)
        # Watchers who were waiting to LISTEN TOGETHER (then cleared).
        intents = db.query(ListenIntent).filter(
            ListenIntent.target_id == target_id).all()
        listen = {int(i.watcher_id) for i in intents}
        for i in intents:
            db.delete(i)
        db.commit()
    except Exception as e:  # noqa: BLE001
        print(f"[online_watch] fire failed for {target_id}: {e}")
        db.rollback()
        return
    finally:
        db.close()
    for w in fire:
        try:
            for_listen = w in listen
            safe_notify_user(w, {
                "type": "friend_came_online",
                "data": {"user_id": target_id, "username": name,
                         "purpose": "listen" if for_listen else None},
            })
            # Data-only (the app draws it, in the watcher's own name for
            # them; no duplicate system banner).
            send_push_to_user(
                w,
                {"type": "friend_online", "friend_id": target_id,
                 "friend_name": name,
                 "purpose": "listen" if for_listen else "",
                 # from_id → push.py adds their phone so the app shows MY
                 # saved name for them.
                 "from_id": target_id, "from_name": name},
            )
        except Exception as e:  # noqa: BLE001
            print(f"[online_watch] notify {w} failed: {e}")


# Targets with at least one play watch — so a track change by everyone else
# never touches the database. Filled at first use, kept in step by the
# endpoints (note_play_watch) and by firing.
_play_targets: set | None = None


def _load_play_targets() -> set:
    global _play_targets
    if _play_targets is None:
        from models import PlayWatch
        db = SessionLocal()
        try:
            _play_targets = {int(r[0]) for r in
                             db.query(PlayWatch.target_id).distinct().all()}
        except Exception:  # noqa: BLE001
            _play_targets = set()
        finally:
            db.close()
    return _play_targets


def note_play_watch(target_id: int) -> None:
    _load_play_targets().add(int(target_id))


def fire_play_watches(target_id: int, track: dict, audience=None) -> None:
    """Run (in a worker thread) when {target_id} plays a song. Each watcher
    allowed to see it (their audience setting) gets one heads-up, then the
    watch ends. Watchers outside the audience keep waiting. Never raises."""
    if int(target_id) not in _load_play_targets():
        return
    from models import PlayWatch
    from websocket_manager import safe_notify_user
    from push import send_push_to_user
    allowed = None if audience is None else {int(x) for x in audience}
    db = SessionLocal()
    try:
        rows = db.query(PlayWatch).filter(
            PlayWatch.target_id == target_id).all()
        target = db.query(User).filter(User.id == target_id).first()
        name = (target.username if target else None) or "Your friend"
        cutoff = datetime.now(timezone.utc) - WATCH_TTL
        fire, left = [], 0
        for r in rows:
            created = r.created_at
            if created is not None and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            stale = created is not None and created < cutoff
            w = int(r.watcher_id)
            if stale or _blocked(db, w, target_id):
                db.delete(r)
            elif allowed is None or w in allowed:
                fire.append(w)
                db.delete(r)
            else:
                left += 1
        db.commit()
        if left == 0:
            _load_play_targets().discard(int(target_id))
    except Exception as e:  # noqa: BLE001
        print(f"[play_watch] fire failed for {target_id}: {e}")
        db.rollback()
        return
    finally:
        db.close()
    title = str((track or {}).get("title") or "")[:120]
    artist = str((track or {}).get("artist") or "")[:80]
    for w in fire:
        try:
            safe_notify_user(w, {
                "type": "friend_started_playing",
                "data": {"user_id": target_id, "username": name,
                         "title": title, "artist": artist},
            })
            send_push_to_user(w, {
                "type": "friend_playing", "friend_id": str(target_id),
                "friend_name": name, "title": title, "artist": artist,
                "from_id": str(target_id), "from_name": name,
            })
        except Exception as e:  # noqa: BLE001
            print(f"[play_watch] notify {w} failed: {e}")
