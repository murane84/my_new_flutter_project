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

import hashlib
import hmac
import html
import json
import os
import tempfile
from datetime import datetime, timezone

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse

router = APIRouter(tags=["Releases"])

PLATFORMS = {
    "android": "aluta.apk",
    "windows": "aluta-windows.zip",
}
_MIME = {
    "android": "application/vnd.android.package-archive",
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


@router.get("/download", response_class=HTMLResponse, include_in_schema=False)
@router.get("/download/", response_class=HTMLResponse, include_in_schema=False)
def download_page():
    a = _meta("android")
    w = _meta("windows")
    e = html.escape
    if a:
        notes = "".join(
            f"<li>{e(line.lstrip('-• ').strip())}</li>"
            for line in (a.get("notes") or "").splitlines() if line.strip())
        card = f"""
      <div class="card">
        <div class="app">
          <img src="/icons/Icon-192.png" alt="" onerror="this.style.display='none'">
          <div><h2>Aluta</h2><p>Chat, music and love — together</p></div>
        </div>
        <div class="grid">
          <div><span>Version</span><b>{e(str(a.get('version', '—')))}</b></div>
          <div><span>Size</span><b>{_mb(a.get('size'))}</b></div>
          <div><span>Android</span><b>7.0 and above</b></div>
          <div><span>Updated</span><b>{_when(a.get('updated_at'))}</b></div>
        </div>
        <a class="btn" href="/download/aluta.apk">Download for Android</a>
        {f'<div class="new"><h3>What’s new</h3><ul>{notes}</ul></div>' if notes else ''}
      </div>"""
    else:
        card = '<div class="card"><h2>Coming soon</h2><p>The Android app will be here shortly.</p></div>'
    win = ('<a class="alt" href="/download/aluta-windows.zip">Windows app (.zip)</a>'
           if w else "")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Download Aluta</title>
<meta name="description" content="Download Aluta for Android — chat, listen together and keep your moments.">
<meta name="theme-color" content="#1a1014">
<style>
:root{{--bg:#140d10;--card:#ffffff;--ink:#1d1215;--muted:#7a6a6e;--accent:#e0103a;--line:#eadfe2}}
*{{box-sizing:border-box}}
body{{margin:0;background:radial-gradient(1200px 500px at 70% -10%,#4a0f22 0,transparent 60%),var(--bg);
color:#f6eef0;font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}}
.wrap{{max-width:560px;margin:0 auto;padding:28px 16px 40px}}
.pill{{display:inline-block;border:1px solid #ff5a7a66;color:#ff8aa0;background:#ff2d5512;
border-radius:999px;padding:4px 12px;font-size:12px;font-weight:800;letter-spacing:.08em}}
h1{{font-size:34px;line-height:1.1;margin:14px 0 10px}}
.lead{{color:#d9c7cc;margin:0 0 22px}}
.card{{background:var(--card);color:var(--ink);border-radius:22px;padding:22px;box-shadow:0 18px 50px #0007}}
.app{{display:flex;gap:14px;align-items:center}}
.app img{{width:64px;height:64px;border-radius:16px}}
.app h2{{margin:0;font-size:22px}} .app p{{margin:2px 0 0;color:var(--muted)}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin:20px 0}}
.grid span{{display:block;font-size:11px;font-weight:800;letter-spacing:.08em;color:var(--muted);text-transform:uppercase}}
.grid b{{font-size:17px}}
.btn{{display:block;text-align:center;background:linear-gradient(#ff3a60,var(--accent) 55%,#a00024);
color:#fff;text-decoration:none;font-weight:800;padding:15px;border-radius:16px;box-shadow:0 8px 22px #e0103a55}}
.new h3{{margin:20px 0 6px;font-size:15px}} .new ul{{margin:0;padding-left:20px;color:#4b3c40}}
.alt{{display:block;text-align:center;color:#ff9fb1;margin-top:16px}}
.how{{margin-top:26px;color:#d9c7cc;font-size:14px}}
.how h3{{color:#fff;font-size:16px;margin:0 0 8px}} .how li{{margin:4px 0}}
</style></head><body><div class="wrap">
<span class="pill">LATEST VERSION — FREE</span>
<h1>Download Aluta</h1>
<p class="lead">Chat with your people, listen together in sync, and keep your moments in Our Space.</p>
{card}
{win}
<div class="how"><h3>How to install</h3><ol>
<li>Tap <b>Download for Android</b> and open the file when it finishes.</li>
<li>If Android asks, allow your browser to <b>install unknown apps</b>.</li>
<li>Play Protect may say it doesn’t know the app — tap <b>More details → Install anyway</b>. Aluta isn’t on the Play Store yet.</li>
<li>Already have Aluta? Installing updates it — your chats stay.</li>
</ol><p>After this, Aluta tells you when a new version is ready.</p></div>
</div></body></html>"""


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
<label>Platform</label><select name="platform"><option>android</option><option>windows</option></select>
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
    return {"ok": True, "on_volume": _on_volume(), **meta}
