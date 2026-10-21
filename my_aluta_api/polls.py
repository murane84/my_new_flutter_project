"""Group polls — a message with message_type 'poll'.

The poll lives in `Message.poll` as JSON:
    {"q": "Where tonight?", "options": ["Pizza", "Sushi"], "multi": false,
     "votes": {"<user id>": [0]}}
`content` carries the question too, so previews / search read naturally.
"""
import json

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
    return {
        "q": q[:MAX_QUESTION_LEN],
        "options": opts,
        "multi": bool(data.get("multi")),
        "votes": {},
    }


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
