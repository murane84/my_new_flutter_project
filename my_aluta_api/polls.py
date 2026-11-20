"""Group polls — a message with message_type 'poll'.

The poll lives in `Message.poll` as JSON:
    {"q": "Where tonight?", "options": ["Pizza", "Sushi"], "multi": false,
     "votes": {"<user id>": [0]}}
`content` carries the question too, so previews / search read naturally.

🔒 A sealed group's poll keeps its words end-to-end encrypted: the app sends
    {"sealed": "🔒s1.…", "n": 3, "multi": false, …}
— the question and options live only inside `sealed` (the group's key), the
server counts votes by option NUMBER (0 … n-1) and runs a jam's clock, and
`content` is the sealed question.
"""
import json
import time

MAX_OPTIONS = 12
MAX_OPTION_LEN = 100
MAX_QUESTION_LEN = 300
MAX_SEALED_LEN = 16000
SCOPE_PREFIX = "🔒s1."


def option_count(poll: dict) -> int:
    """How many options a poll has (a sealed one says so: )."""
    if poll.get("sealed"):
        try:
            return int(poll.get("n") or 0)
        except (TypeError, ValueError):
            return 0
    return len(poll.get("options") or [])


def _clean_sealed(data: dict) -> dict:
    s = str(data.get("sealed") or "")
    if not s.startswith(SCOPE_PREFIX) or len(s) > MAX_SEALED_LEN:
        raise ValueError("Poll is not valid")
    try:
        n = int(data.get("n") or 0)
    except (TypeError, ValueError):
        n = 0
    if n < 2:
        raise ValueError("Poll needs at least two different options")
    if n > MAX_OPTIONS:
        raise ValueError(f"A poll can have at most {MAX_OPTIONS} options")
    return {"sealed": s, "n": n}


def clean_poll(raw) -> dict:
    """Validate a client poll spec → normalised dict (votes empty).
    Raises ValueError with a human message."""
    try:
        data = json.loads(raw) if isinstance(raw, str) else dict(raw or {})
    except Exception:
        raise ValueError("Poll is not valid JSON")
    seen = set()
    if data.get("sealed"):
        out = _clean_sealed(data)
        out["multi"] = bool(data.get("multi"))
        out["votes"] = {}
    else:
        q = str(data.get("q") or "").strip()
        if not q:
            raise ValueError("Poll needs a question")
        opts = []
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
        # A sudden-death decider between tied songs; `rest` keeps the other
        # songs of the original jam so the vote after it can carry on.
        if data.get("decider"):
            out["decider"] = True
            rest = []
            # (a sealed decider's other songs are inside )
            for o in data.get("rest") or []:
                t = str(o or "").strip()[:MAX_OPTION_LEN]
                if t and t.lower() not in seen and t not in rest:
                    rest.append(t)
            if rest:
                out["rest"] = rest[:MAX_OPTIONS]
        # When the jam is decided without a clock: more than half ('half',
        # default) or only once EVERY member has voted ('all').
        if data.get("until") == "all":
            out["until"] = "all"
    return out


def start_countdown(msg, minutes: int) -> str:
    """The jam's starter sets (or resets) its countdown from NOW."""
    poll = load(msg)
    if poll.get("kind") != "jam":
        raise ValueError("Only a jam has a countdown")
    ca = poll.get("closes_at")
    if ca and int(time.time()) > int(ca):
        raise ValueError("This jam has already closed")
    m = max(1, min(int(minutes), 60))
    poll["closes_at"] = int(time.time()) + m * 60
    msg.poll = json.dumps(poll, separators=(",", ":"))
    return msg.poll


def load(msg) -> dict:
    try:
        return json.loads(msg.poll or "{}") or {}
    except Exception:
        return {}


def apply_vote(msg, user_id: int, options) -> str:
    """Record (or retract, with []) user_id's choice; returns the new JSON."""
    poll = load(msg)
    n = option_count(poll)
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
