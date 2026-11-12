"""App releases outside the Play Store: the download page, the "is there a
newer build?" check the Android app makes, and the uploader I publish with.

Files live on the Railway VOLUME (RAILWAY_VOLUME_MOUNT_PATH, e.g. /data),
never in Postgres (47 test APKs in media_assets once crashed it — see
storage-policy). One file per platform; a new upload replaces the old one,
so storage stays flat and the download links never change.

  GET  /download                  public page (phone-friendly)
  GET  /download/aluta.apk        the APK (also /downloads/aluta.apk)
  GET  /app/latest?platform=…     {"version","build","notes","size",…}
  GET  /admin/release             uploader page (needs RELEASE_KEY)
  POST /admin/release             multipart: key, platform, version, build,
                                  notes, min_build, file
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import html
import json
import os
import tempfile
import threading
from datetime import datetime, timezone

from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse

router = APIRouter(tags=["Releases"])

# One file per slot; publishing replaces it, so the volume never piles up.
#   android            arm64 APK (--split-per-abi) — almost every phone
#   android-universal  universal APK — older / 32-bit phones
#   windows            the Windows app, zipped
PLATFORMS = {
    "android": "aluta.apk",
    "android-universal": "aluta-universal.apk",
    "windows": "aluta-windows.zip",
}
_MIME = {
    "android": "application/vnd.android.package-archive",
    "android-universal": "application/vnd.android.package-archive",
    "windows": "application/zip",
}
MAX_BYTES = 200 * 1024 * 1024  # 200 MB — an arm64 APK is ~30 MB


def _dir() -> str:
    base = os.getenv("RAILWAY_VOLUME_MOUNT_PATH") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "_releases_local")
    d = os.path.join(base, "releases")
    os.makedirs(d, exist_ok=True)
    return d


def _on_volume() -> bool:
    return bool(os.getenv("RAILWAY_VOLUME_MOUNT_PATH"))


def _meta_path(platform: str) -> str:
    return os.path.join(_dir(), f"{platform}.json")


def _meta(platform: str) -> dict | None:
    try:
        with open(_meta_path(platform), encoding="utf-8") as f:
            data = json.load(f)
        if os.path.isfile(os.path.join(_dir(), PLATFORMS[platform])):
            return data
    except Exception:
        pass
    return None


def _key_ok(key: str) -> bool:
    want = os.getenv("RELEASE_KEY") or os.getenv("UPLOAD_KEY") or ""
    return bool(want) and hmac.compare_digest(key.encode(), want.encode())


# ── Public ────────────────────────────────────────────────────────────────────

@router.get("/app/latest")
def latest(platform: str = "android"):
    """What the app compares its own build number with."""
    if platform not in PLATFORMS:
        raise HTTPException(status_code=404, detail="Unknown platform")
    m = _meta(platform)
    if m is None:
        raise HTTPException(status_code=404, detail="No release yet")
    return {**m, "url": f"/download/{PLATFORMS[platform]}"}


def _serve(platform: str):
    path = os.path.join(_dir(), PLATFORMS[platform])
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Not published yet")
    m = _meta(platform) or {}
    v = m.get("version")
    # A versioned file name in the browser's download list.
    stem, ext = os.path.splitext(PLATFORMS[platform])
    name = f"{stem}-{v}{ext}" if v else PLATFORMS[platform]
    resp = FileResponse(path, media_type=_MIME[platform], filename=name)
    resp.headers["Cache-Control"] = "no-cache"
    return resp


@router.get("/download/aluta.apk", include_in_schema=False)
@router.get("/downloads/aluta.apk", include_in_schema=False)  # old links
def download_apk():
    return _serve("android")


@router.get("/download/aluta-universal.apk", include_in_schema=False)
def download_universal():
    return _serve("android-universal")


@router.get("/download/aluta-windows.zip", include_in_schema=False)
@router.get("/downloads/aluta-windows.zip", include_in_schema=False)
def download_windows():
    return _serve("windows")


def _mb(n) -> str:
    try:
        return f"{int(n) / 1048576:.0f} MB"
    except Exception:
        return "—"


def _when(iso) -> str:
    try:
        return datetime.fromisoformat(iso).strftime("%d %b %Y")
    except Exception:
        return "—"


_ANDROID_SVG = ('<svg viewBox="0 0 24 24"><path d="M17.6 9.48l1.84-3.18a.38.38 0 0 0-.66-.38l-1.86 3.22a11.4 '
                '11.4 0 0 0-9.84 0L5.22 5.92a.38.38 0 0 0-.66.38L6.4 9.48A10.8 10.8 0 0 0 1 18h22a10.8 10.8 0 '
                '0 0-5.4-8.52zM7 15.25a1.25 1.25 0 1 1 0-2.5 1.25 1.25 0 0 1 0 2.5zm10 0a1.25 1.25 0 1 1 0-2.5 '
                '1.25 1.25 0 0 1 0 2.5z"/></svg>')
_WINDOWS_SVG = ('<svg viewBox="0 0 24 24"><path d="M3 5.5l7.5-1v7H3zm8.5-1.2L21 3v8.5h-9.5zM3 12.5h7.5v7L3 18.5z'
                'm8.5 0H21V21l-9.5-1.3z"/></svg>')
_PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "download_page.html")


def _history() -> list:
    """Android releases, newest first (kept on publish; the page's
    "Earlier versions")."""
    try:
        with open(os.path.join(_dir(), "history.json"), encoding="utf-8") as f:
            h = json.load(f)
        return h if isinstance(h, list) else []
    except Exception:
        return []


def _remember(meta: dict) -> None:
    h = [x for x in _history() if x.get("build") != meta["build"]]
    h.insert(0, {k: meta.get(k) for k in ("version", "build", "notes",
                                           "updated_at", "size")})
    try:
        with open(os.path.join(_dir(), "history.json"), "w",
                  encoding="utf-8") as f:
            json.dump(h[:12], f)
    except Exception as e:  # noqa: BLE001
        print(f"[release] history not saved: {e}")


_qr_memo: dict[str, str] = {}


def _qr(url: str) -> str:
    """Inline SVG QR for [url] ("" if segno isn't installed)."""
    if url not in _qr_memo:
        # A handful of hosts at most (the domain, the railway.app name);
        # never let made-up Host headers grow this.
        if len(_qr_memo) >= 8:
            _qr_memo.clear()
        try:
            import segno
            _qr_memo[url] = segno.make(url, error="m").svg_inline(
                scale=4, border=2, dark="#1d1215", light="#ffffff")
        except Exception:
            _qr_memo[url] = ""
    return _qr_memo[url]


def _notes_li(notes: str) -> str:
    return "".join(
        f"<li>{html.escape(line.lstrip('-•* ').strip())}</li>"
        for line in (notes or "").splitlines() if line.strip())


def _trust(m: dict) -> str:
    sha = html.escape(str(m.get("sha256") or ""))
    if len(sha) < 16:
        return ""
    return (f'<div class="trust"><span data-i18n="trust">Published by Ozilane</span>'
            f' · SHA-256 <code title="{sha}">{sha[:8]}…{sha[-6:]}</code>'
            f'<button type="button" class="copy" data-copy="{sha}" data-i18n="copy">Copy</button></div>')


def _facts(m: dict, os_label: str, os_key: str, os_value: str) -> str:
    e = html.escape
    return f"""<div class="facts">
      <div><span data-i18n="f_version">Version</span><b>{e(str(m.get('version', '—')))}</b></div>
      <div><span data-i18n="f_size">Size</span><b>{_mb(m.get('size'))}</b></div>
      <div><span>{os_label}</span><b data-i18n="{os_key}">{os_value}</b></div>
      <div><span data-i18n="f_updated">Updated</span><b>{_when(m.get('updated_at'))}</b></div>
    </div>"""


@router.get("/download", response_class=HTMLResponse, include_in_schema=False)
@router.get("/download/", response_class=HTMLResponse, include_in_schema=False)
def download_page(request: Request):
    a = _meta("android")
    u = _meta("android-universal")
    w = _meta("windows")
    e = html.escape
    # Behind Railway's proxy: the public host + https come in headers
    # (a proxy chain can send "https,http" — the first is the visitor's).
    host = (request.headers.get("x-forwarded-host") or request.url.netloc
            ).split(",")[0].strip()
    scheme = (request.headers.get("x-forwarded-proto") or request.url.scheme
              ).split(",")[0].strip()
    if scheme not in ("http", "https"):
        scheme = "https"
    page_url = f"{scheme}://{host}/download"

    if a:
        notes = _notes_li(a.get("notes"))
        uni = (f'<a class="sub" href="/download/aluta-universal.apk"><span data-i18n="uni">Older or '
               f'32-bit phone? Get the universal APK</span> ({_mb(u.get("size"))})</a>' if u else "")
        new = (f'<div class="new"><h3 data-i18n="new">What’s new</h3><ul>{notes}</ul></div>'
               if notes else "")
        and_card = f"""<div class="card" id="c-and">
    <div class="app"><img src="/icons/Icon-192.png" alt="">
      <div><h2>Aluta for Android</h2><p data-i18n="free">Free · no ads in the way</p></div></div>
    {_facts(a, 'Android', 'f_and_min', '7.0 and above')}
    <a class="btn" data-get="android" href="/download/aluta.apk">{_ANDROID_SVG}<span data-i18n="btn_and">Download for Android</span></a>
    {uni}{new}{_trust(a)}
  </div>"""
        and_tile = f"""<a class="tile t-and" data-get="android" href="/download/aluta.apk">
    <span class="ic">{_ANDROID_SVG}</span>
    <span><b>Aluta for Android</b><small><span data-i18n="f_version">Version</span> {e(str(a.get('version', '')))} · {_mb(a.get('size'))}</small></span>
    <span class="go" data-i18n="nav_dl">Download</span></a>"""
        bar = (f'<div class="sbar" id="sbar"><span><b>Aluta {e(str(a.get("version", "")))}</b>'
               f'<small>{_mb(a.get("size"))} · Android</small></span>'
               f'<a class="chip" data-get="android" href="/download/aluta.apk" data-i18n="nav_dl">Download</a></div>')
    else:
        and_card = ('<div class="card" id="c-and"><h2 data-i18n="soon">Coming soon</h2>'
                    '<p data-i18n="soon_s">The Android app will be here shortly.</p></div>')
        and_tile = bar = ""

    if w:
        wn = _notes_li(w.get("notes"))
        win_new = (f'<div class="new"><h3 data-i18n="new">What’s new</h3><ul>{wn}</ul></div>'
                   if wn else "")
        win_card = f"""<div class="card" id="c-win">
    <div class="app"><span class="winic">{_WINDOWS_SVG}</span>
      <div><h2>Aluta for Windows</h2><p data-i18n="free">Free · no ads in the way</p></div></div>
    {_facts(w, 'Windows', 'f_win_min', '10 and 11')}
    <a class="btn" data-get="windows" href="/download/aluta-windows.zip">{_WINDOWS_SVG}<span data-i18n="btn_win">Download for Windows</span></a>
    <p class="sub" data-i18n="win_how">Unzip it and open Aluta.exe. To update, unzip over your old Aluta folder.</p>
    {win_new}{_trust(w)}
  </div>"""
        win_tile = f"""<a class="tile t-win" data-get="windows" href="/download/aluta-windows.zip">
    <span class="ic">{_WINDOWS_SVG}</span>
    <span><b>Aluta for Windows</b><small><span data-i18n="f_version">Version</span> {e(str(w.get('version', '')))} · {_mb(w.get('size'))} · <span data-i18n="win_short">unzip and open Aluta</span></small></span>
    <span class="go" data-i18n="nav_dl">Download</span></a>"""
    else:
        win_card = win_tile = ""

    qr = _qr(page_url) if a else ""
    qr_box = (f"""<div class="qr"><div class="code">{qr}</div><div>
    <b data-i18n="qr_t">Get it on your phone</b>
    <span data-i18n="qr_s">Point your phone’s camera here — this page opens there, ready to download.</span></div></div>"""
              if qr else "")

    cur = a.get("build") if a else None
    older = [h for h in _history() if h.get("build") != cur]
    if older:
        items = "".join(
            f"<li><b>{e(str(h.get('version', '')))}</b><small>{_when(h.get('updated_at'))}</small>"
            f"<ul>{_notes_li(h.get('notes'))}</ul></li>" for h in older)
        history = (f'<details class="hist"><summary data-i18n="hist">Earlier versions</summary>'
                   f'<ol>{items}</ol></details>')
    else:
        history = ""

    with open(_PAGE, encoding="utf-8") as f:
        page = f.read()
    for k, v in {
        "{{AND_CARD}}": and_card, "{{WIN_CARD}}": win_card, "{{QR}}": qr_box,
        "{{WIN_TILE}}": win_tile, "{{AND_TILE}}": and_tile,
        "{{HISTORY}}": history, "{{BAR}}": bar,
    }.items():
        page = page.replace(k, v)
    return page


# ── Publishing ───────────────────────────────────────────────────────────────

@router.get("/admin/release", response_class=HTMLResponse, include_in_schema=False)
def uploader_page():
    vol = "" if _on_volume() else (
        "<p style='color:#c00'><b>No Railway volume is attached</b> — files would "
        "vanish on the next deploy. Add a volume to this service first.</p>")
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Publish a release</title>
<meta name="robots" content="noindex">
<style>body{{font:15px system-ui,sans-serif;max-width:520px;margin:30px auto;padding:0 16px}}
label{{display:block;margin:12px 0 4px;font-weight:700}} input,select,textarea{{width:100%;padding:9px;font:inherit}}
button{{margin-top:16px;padding:12px 18px;font:inherit;font-weight:800;background:#e0103a;color:#fff;border:0;border-radius:10px}}
progress{{width:100%;margin-top:12px}}</style></head><body>
<h2>Publish an Aluta release</h2>{vol}
<form id="f">
<label>Release key</label><input name="key" type="password" required>
<label>Platform</label><select name="platform">
<option value="android">android — arm64 APK (app-arm64-v8a-release.apk)</option>
<option value="android-universal">android-universal — universal APK (app-release.apk)</option>
<option value="windows">windows — zipped Release folder</option></select>
<label>Version (e.g. 1.0.3)</label><input name="version" required>
<label>Build number (the +N in pubspec, e.g. 4)</label><input name="build" type="number" min="1" required>
<label>Lowest build that may keep working (optional — older ones must update)</label><input name="min_build" type="number" min="0">
<label>What's new (one per line)</label><textarea name="notes" rows="5"></textarea>
<label>File (.apk / .zip)</label><input name="file" type="file" required>
<button>Publish</button></form><progress id="p" value="0" max="1" hidden></progress><pre id="o"></pre>
<script>
f.onsubmit=e=>{{e.preventDefault();const x=new XMLHttpRequest();p.hidden=false;
x.upload.onprogress=v=>{{if(v.lengthComputable)p.value=v.loaded/v.total}};
x.onload=()=>{{o.textContent=x.status+' '+x.responseText}};
x.onerror=()=>{{o.textContent='Upload failed'}};
x.open('POST','/admin/release');x.send(new FormData(f));}};
</script></body></html>"""


@router.post("/admin/release", include_in_schema=False)
async def publish(
    key: str = Form(...),
    platform: str = Form("android"),
    version: str = Form(...),
    build: int = Form(...),
    notes: str = Form(""),
    min_build: int | None = Form(None),
    announce: bool = Form(True),
    file: UploadFile = File(...),
):
    if not _key_ok(key):
        raise HTTPException(status_code=403, detail="Wrong key")
    if platform not in PLATFORMS:
        raise HTTPException(status_code=400, detail="Unknown platform")
    version = version.strip()[:32]
    if not version or build < 1:
        raise HTTPException(status_code=400, detail="Version and build needed")
    d = _dir()
    # Stream to a temp file beside the target (never the whole file in RAM),
    # then swap it in atomically — a half upload never replaces a good one.
    sha = hashlib.sha256()
    size = 0
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_BYTES:
                    raise HTTPException(status_code=413, detail="File too large")
                sha.update(chunk)
                out.write(chunk)
        if size < 1024:
            raise HTTPException(status_code=400, detail="Empty file")
        os.replace(tmp, os.path.join(d, PLATFORMS[platform]))
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    meta = {
        "platform": platform,
        "version": version,
        "build": int(build),
        "min_build": int(min_build) if min_build else 0,
        "notes": notes.strip()[:2000],
        "size": size,
        "sha256": sha.hexdigest(),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    with open(_meta_path(platform), "w", encoding="utf-8") as f:
        json.dump(meta, f)
    if platform == "android":
        _remember(meta)
    announced = _announce(meta) if announce else 0
    return {"ok": True, "on_volume": _on_volume(), "announced": announced,
            **meta}


# The universal APK is the same build as the arm64 one — announcing both
# would ping every phone twice. Windows apps hear it over their socket.
_ANNOUNCE = ("android", "windows")
_tasks: set = set()  # keep the socket fan-out task alive until it's done


def _announce(meta: dict) -> int:
    """Tell people a new build is out, so nobody sits on an old one.
    Open apps get an `app_update` socket event (they check and show a toast);
    closed Android apps get a data push that shows one quiet notification.
    Each app compares the build with its own and ignores what it has.
    Returns how many sockets were told."""
    if meta["platform"] not in _ANNOUNCE:
        return 0
    evt = {
        "type": "app_update",
        "platform": meta["platform"],
        "version": meta["version"],
        "build": meta["build"],
    }
    told = 0
    try:
        from websocket_manager import broadcast_event, connected_users
        uids = list(connected_users.keys())
        told = len(uids)
        t = asyncio.get_running_loop().create_task(broadcast_event(uids, evt))
        _tasks.add(t)
        t.add_done_callback(_tasks.discard)
    except Exception as e:  # noqa: BLE001
        print(f"[release] socket announce failed: {e}")
    if meta["platform"] == "android":
        first = next((l.strip(" -•*\t") for l in meta["notes"].splitlines()
                      if l.strip(" -•*\t")), "")
        threading.Thread(target=_push_android, daemon=True, args=(
            {**evt, "note": first[:120]},)).start()
    return told


def _push_android(data: dict) -> None:
    """One data push per Android user (background thread — FCM is slow)."""
    try:
        from database import SessionLocal
        from models import DeviceToken
        from push import push_available, send_push_to_user
        if not push_available():
            return
        db = SessionLocal()
        try:
            uids = [r[0] for r in db.query(DeviceToken.user_id).filter(
                DeviceToken.platform == "android").distinct().all()]
        finally:
            db.close()
        for uid in uids:
            send_push_to_user(uid, data, platform="android")
        print(f"[release] pushed build {data['build']} to {len(uids)} user(s)")
    except Exception as e:  # noqa: BLE001
        print(f"[release] push announce failed: {e}")
