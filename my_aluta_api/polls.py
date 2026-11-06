"""Group polls — a message with message_type 'poll'.

The poll lives in `Message.poll` as JSON:
    {"q": "Where tonight?", "options": ["Pizza", "Sushi"], "multi": false,
     "votes": {"<user id>": [0]}}
`content` carries the question too, so previews / search read naturally.
"""
import json
import time

MAX_OPTIONS = 12
MAX_OPTION_LEN = 100
MAX_QUESTION_LEN = 300


def clean_poll(raw) -> dict:
    """Validate a client poll spec → normalised dict (votes empty).
    Raises ValueError with a human message."""
    try:
        data = json.loads(raw) if isinstance(raw, str) else dict(raw or {})
    except Exception:
        raise ValueError("Poll is not valid JSON")
    q = str(data.get("q") or "").strip()
    if not q:
        raise ValueError("Poll needs a question")
    opts = []
    seen = set()
    for o in data.get("options") or []:
        t = str(o or "").strip()[:MAX_OPTION_LEN]
        if t and t.lower() not in seen:
            seen.add(t.lower())
            opts.append(t)
    if len(opts) < 2:
        raise ValueError("Poll needs at least two different options")
    if len(opts) > MAX_OPTIONS:
        raise ValueError(f"A poll can have at most {MAX_OPTIONS} options")
    out = {
        "q": q[:MAX_QUESTION_LEN],
        "options": opts,
        "multi": bool(data.get("multi")),
        "votes": {},
    }
    # A "jam": the options are songs — the group votes what plays next.
    # Always ONE vote each (a jam must name a single winner).
    if data.get("kind") == "jam":
        out["kind"] = "jam"
        out["multi"] = False
        # Optional countdown: voting closes at this unix time (≤ 1 hour out).
        try:
            ca = int(data.get("closes_at") or 0)
        except (TypeError, ValueError):
            ca = 0
        now = int(time.time())
        if ca > now:
            out["closes_at"] = min(ca, now + 3600)
        # A sudden-death decider between tied songs.
        if data.get("decider"):
            out["decider"] = True
    return out


def load(msg) -> dict:
    try:
        return json.loads(msg.poll or "{}") or {}
    except Exception:
        return {}


def apply_vote(msg, user_id: int, options) -> str:
    """Record (or retract, with []) user_id's choice; returns the new JSON."""
    poll = load(msg)
    n = len(poll.get("options") or [])
    if n == 0:
        raise ValueError("Not a poll")
    ca = poll.get("closes_at")
    if ca and int(time.time()) > int(ca) + 2:  # tiny grace for clock skew
        raise ValueError("Voting has closed")
    picks = []
    for i in options or []:
        try:
            i = int(i)
        except (TypeError, ValueError):
            continue
        if 0 <= i < n and i not in picks:
            picks.append(i)
    if not poll.get("multi") and len(picks) > 1:
        picks = picks[:1]
    votes = poll.get("votes") or {}
    if picks:
        votes[str(int(user_id))] = sorted(picks)
    else:
        votes.pop(str(int(user_id)), None)
    poll["votes"] = votes
    msg.poll = json.dumps(poll, separators=(",", ":"))
    return msg.poll
