# Aluta

**Messaging, music and relationships in one app.** Chat with friends, listen to the same song at the same moment, and keep a shared space ("Our Space") for a partner or close friends.

- Live at **https://aluta.ozilane.com** (web / installable PWA)
- Android, Windows and Web builds from one Flutter codebase
- Backend: FastAPI + PostgreSQL on Railway

Aluta owns no music. Members stream songs from their own devices; a Listen Together stream passes through the server in memory and is never saved.

---

## Repository layout

| Path | What it is |
|---|---|
| `lib/` | Flutter app (Dart). `screens/` UI, `services/` calls, audio, push, live sessions; `state/` Riverpod state; `utils/app_config.dart` server address |
| `my_aluta_api/` | Backend (Python 3.11, FastAPI). `main.py` app + startup, `routers/` HTTP/WebSocket endpoints, `models.py` database tables |
| `my_aluta_api/webapp/` | The built Flutter **web** app that the backend serves at the site root. Do not edit by hand; `deploy_web.bat` replaces it |
| `android/`, `windows/`, `web/`, `ios/`, `macos/`, `linux/` | Platform projects |
| `assets/` | Images, sounds, fonts used by the app |
| `test/` | Flutter tests |
| `Aluta Project Audit Report/` | Audit, roadmap, design specs and product plans |

Main features and where they live:

- **Chat** (text, images with annotation, voice notes, files, GIFs, reactions, replies, read receipts): `lib/screens/chat/`, `routers/messages.py`, `routers/conversations.py`, `routers/attachments.py`
- **Listen Together** live rooms: `lib/services/live_session_service.dart`, `routers/live.py` (see `LISTEN_TOGETHER_AND_PWA.md`)
- **Voice and group calls** (WebRTC, relayed by Ozilane Turn when phones can't connect directly): `lib/services/call_service.dart`, `group_call_service.dart`, `ice_config.dart`, `routers/webrtc.py`
- **Our Space / relationships**: `lib/screens/relationship_space_page.dart`, `routers/spaces.py`, `bonding.py`
- **Stories**: `lib/screens/stories/`, `routers/stories.py`
- **Push notifications** (FCM): `lib/services/fcm_service.dart`, `my_aluta_api/push.py` (setup in `FIREBASE_FCM_SETUP.md`)

---

## Run it locally

### Backend

```bash
cd my_aluta_api
python -m venv venv
venv\Scripts\activate            # Windows  (macOS/Linux: source venv/bin/activate)
pip install -r requirements.txt
copy .env.example .env.txt       # then fill in the values (see "Settings" below)
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

You need a PostgreSQL database; put its address in `DATABASE_URL`. Tables are created automatically on start-up.

### Flutter app

```bash
flutter pub get
flutter run                                   # pick a device: Android, Windows or Chrome
```

By default the app talks to **https://aluta.ozilane.com**. To use your local backend instead:

```bash
flutter run --dart-define=SERVER_IP=192.168.x.x   # your PC's address on the Wi-Fi
```

Other build-time options (all optional): `PROD_URL` (backend address), `SENTRY_DSN` (crash reporting), `GIPHY_API_KEY` (GIF search).

---

## Deploying

**Backend.** Railway deploys `my_aluta_api/` automatically on every push to `main` (`railway.json`, start command `uvicorn main:app`). Set the settings below as Railway service variables.

**Web app.** Run `deploy_web.bat` from the project folder. It builds the web release, replaces `my_aluta_api/webapp/` with the fresh build, commits and pushes, so Railway serves the new version. (Running only `flutter build web` is not enough: the site serves `webapp/`, not `build/web/`.)

**Android.**

```bash
flutter build apk --release
```

Package name: `com.example.new_flutter_project_fixed`. It must match the Firebase app registration, or push notifications will not arrive.

---

## Settings (environment variables)

Never commit real values. Locally they go in `my_aluta_api/.env.txt` (git-ignored); in production, in Railway's Variables tab.

| Variable | Needed for |
|---|---|
| `DATABASE_URL` | PostgreSQL connection (Railway provides it) |
| `SECRET_KEY`, `ALGORITHM`, `ACCESS_TOKEN_EXPIRE_MINUTES`, `INACTIVITY_TIMEOUT_MINUTES` | Sign-in tokens |
| `ENVIRONMENT` | `production` or `development` |
| `FIREBASE_PROJECT_ID`, `FIREBASE_SERVICE_ACCOUNT_JSON` (or `_FILE`) | Push notifications |
| `TURN_URLS`, `TURN_SHARED_SECRET` (or `TURN_STATIC_*`, `METERED_TURN_*`) | Call relay (Ozilane Turn) |
| `ZEPTOMAIL_TOKEN`, `ZEPTOMAIL_FROM`, `ZEPTOMAIL_FROM_NAME` | Sending email |
| `AUDD_API_TOKEN`, `AUDD_API_URL`, `ACOUSTID_API_KEY`, `ACOUSTID_API_URL` | Song recognition |

---

## Database changes

Tables are created by `Base.metadata.create_all()` in `main.py`. New columns on existing tables are added by the `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` list right below it in `main.py`. Add new columns there as well as in `models.py`. The `alembic/` folder holds early migrations and is no longer the source of truth.

---

## More documentation

- `LISTEN_TOGETHER_AND_PWA.md`: how Listen Together works, and serving the app as a PWA
- `FIREBASE_FCM_SETUP.md`: step-by-step push notification setup
- `ALUTA_THIRD_PARTY_LICENSES.md`: licences of the packages Aluta uses
- `Aluta Project Audit Report/`: technical audit, roadmap, Harmony / Our Space plans and designs
