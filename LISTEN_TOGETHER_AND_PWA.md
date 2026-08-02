# Aluta — Listen Together + Web/PWA (integration guide)

This covers two things added to your project:

1. The **"listen together" live session** feature (backend done & tested; Flutter client added).
2. Serving your app as an **installable PWA** on `aluta.ozilane.com` (backend ready; the Flutter side needs a web-compatibility pass — see the honest note at the end).

---

## 1. Listen Together — how it works

- The song **never leaves memory**. The host streams the raw audio bytes over a WebSocket; the server forwards them **in memory** and never writes to disk or the database; the listener plays them from an in-memory `BytesAudioSource`. When the session ends, everything is dropped.
- **Sharer = DJ**: the host controls play/pause/seek; the listener mirrors it.
- **Scope: 1:1 DM** for now (the backend already supports multiple invitees, so groups are a small extension later).

### Backend endpoints (already live on `https://aluta.ozilane.com`)

| Method | Path | Purpose |
|---|---|---|
| POST | `/live/sessions` | Host creates a session `{receiver_id, track:{title,artist,duration_ms,mime}}` → returns `{session_id}`. Also pushes a `live_invite` to the receiver's notification socket. |
| POST | `/live/sessions/{id}/end` | Host ends the session (403 for non-hosts). |
| WS | `/live/ws/{session_id}?token=<jwt>&user_id=<id>` | Host + listener exchange control JSON and binary audio. |

Control messages (JSON text frames): `meta`, `play`, `pause`, `seek`, `position`, `eos`, `end`, `peer_joined`, `peer_left`, `session_state`.

### Flutter client: `lib/services/live_session_service.dart`

A self-contained `LiveSessionController`. It's platform-agnostic (no `dart:io`) so it also works on web. You supply the audio **bytes** (mobile: read the picked file; web: use the bytes `file_picker` already gives you).

**Host side** — when the user taps "Listen together" in a DM and picks a song:

```dart
final controller = LiveSessionController(
  onEvent: (e) => debugPrint('live event: $e'),
  onEnded: (reason) => Navigator.pop(context),
  onError: (err) => showError(err),
);

// bytes: from on_audio_query/file_picker path -> File(path).readAsBytes(),
//        or file_picker's result.files.single.bytes on web.
await controller.startHost(
  receiverId: friendId,
  myUserId: myId,          // your logged-in user id (from /users/me)
  token: myAccessToken,    // however you store it (secure storage / prefs)
  audioBytes: bytes,
  title: song.title,
  artist: song.artist,
  durationMs: song.durationMs,
  mime: 'audio/mpeg',
);
// Bind your seekbar/controls to controller.player (a just_audio AudioPlayer).
// To stop for everyone: await controller.endSession(myAccessToken);
```

**Listener side** — you already receive notifications on the `/ws/{user_id}` socket. When a `{"type":"live_invite", "data":{session_id, host_username, track}}` arrives, show an "X wants to listen together — Join?" prompt. On accept:

```dart
final controller = LiveSessionController(onEnded: (_) => Navigator.pop(context));
await controller.joinAsListener(
  sessionId: invite['session_id'],
  myUserId: myId,
  token: myAccessToken,
);
// Playback starts automatically once the stream finishes buffering (a second or
// two for a typical song). controller.player drives your now-playing UI.
```

**Where to wire the UI:** add a "Listen together" action in your DM app bar / attachment menu in `lib/screens/chat_page.dart`, and handle the `live_invite` event wherever you already parse notification-socket messages (`lib/screens/websocket_manager.dart`). I intentionally did **not** edit those large files blindly — drop the two snippets above in and we can refine together.

> v1 buffers the whole song before the listener starts (reliable, in-memory, ~1–2s for a normal track). We can upgrade to true progressive playback later if you want instant start.

---

## 2. Web / PWA on aluta.ozilane.com

The backend now serves a Flutter web build if one is present:

- Put your build output in **`my_aluta_api/webapp/`** (i.e. copy the contents of `build/web/` there).
- `main.py` serves it at `/` with all API routes (`/auth`, `/users`, `/messages`, `/live`, `/ws`, `/media`, `/health`, `/api`) still taking precedence.
- The API "welcome" JSON moved from `/` to **`/api`**.
- Flutter's web build already includes `manifest.json` + a service worker, so it's installable as a PWA out of the box.

**Steps once the web build compiles:**
```
flutter build web --release --dart-define=PROD_URL=https://aluta.ozilane.com
# copy build/web/* into my_aluta_api/webapp/
git add my_aluta_api/webapp
git commit -m "Add Flutter web build (PWA)"
git push
```
Railway redeploys and `https://aluta.ozilane.com` shows the installable app.

### ⚠️ Honest caveat: the app won't `flutter build web` as-is yet

This app was built for mobile/desktop and currently uses APIs that **don't compile or work on web**:

- **`dart:io`** is imported in `lib/utils/app_config.dart` (`NetworkInterface`, `Platform`) — this fails to compile for web. It needs a conditional import / `kIsWeb` guard so web just uses the production URL.
- **`on_audio_query`** (scanning the device music library) has **no web support** — browsers can't read your phone's music library. On web you'd share songs via `file_picker` (which works) instead of browsing the library.
- A few others degrade on web (`permission_handler`, `flutter_local_notifications`, `path_provider`).

So a true "full-functioning PWA" needs a **web-compatibility pass**: guard the `dart:io` usage, make `app_config` web-safe, and provide graceful fallbacks for the web-only-incompatible plugins (especially replacing the library browser with a file picker on web). The chat, auth, and the new listen-together feature will work on web; the "browse my device's music" screen is the main thing that needs a web fallback.

I can do that web-compat pass as the next step and verify the build — just say the word.
