# Aluta — Firebase Cloud Messaging (FCM) setup

The code is done. These are the **manual steps only you can do** in the Firebase
console + Railway. Do them in order. Nothing here touches code you didn't ask
for; the app already builds and runs *without* Firebase (push just stays off
until this is finished).

Two facts to know up front:
- Your Android **package name** is `com.example.new_flutter_project_fixed`. It
  must match EXACTLY when you register the app in Firebase, or pushes silently
  never arrive.
- FCM now uses the **HTTP v1 API** (the old "server key" is dead). That's why
  the backend needs a **service account key**, not a server key.

---

## Part A — Firebase console (create the project + Android app)

1. Go to <https://console.firebase.google.com> and sign in with a Google account.
2. Click **Add project** (or **Create a project**).
   - Name it e.g. `Aluta`. Continue.
   - Google Analytics: **not required** — you can toggle it OFF. Continue → **Create project** → wait → **Continue**.
3. On the project dashboard, click the **Android** icon (“Add app” → Android).
4. Register the app:
   - **Android package name**: `com.example.new_flutter_project_fixed`  ← must be exact.
   - **App nickname**: `Aluta` (optional).
   - **Debug signing certificate SHA-1**: **leave blank** — FCM does not need it. (It's only for Google Sign-In / Dynamic Links, which you're not using.)
   - Click **Register app**.
5. **Download `google-services.json`** when prompted.
   - Put it here on your PC: `D:\new_flutter_project_fixed\android\app\google-services.json`
   - (Exactly in the `android\app\` folder — next to `build.gradle.kts`.)
6. The console then shows "Add Firebase SDK" Gradle snippets — **skip all of that**, it's already done in the code. Click **Next → Continue to console**.

> `google-services.json` is client config, not a secret — it's fine to commit it
> or to leave it out of git; your call. The **service account key** in Part B is
> the real secret.

---

## Part B — Service account key (lets the backend send pushes)

1. In the Firebase console, click the **gear icon** (top-left, next to “Project Overview”) → **Project settings**.
2. Open the **Service accounts** tab.
3. Click **Generate new private key** → confirm **Generate key**. A `.json` file downloads. **Keep it secret** — anyone with it can send pushes as you.
4. Also note your **Project ID** — it's on the **General** tab of Project settings (e.g. `aluta-1a2b3`).

---

## Part C — Railway (give the backend the key)

1. Open your Aluta service on <https://railway.app> → **Variables**.
2. Add these two variables:
   - `FIREBASE_PROJECT_ID` = your project id (e.g. `aluta-1a2b3`).
   - `FIREBASE_SERVICE_ACCOUNT_JSON` = the **entire contents** of the service
     account `.json` file from Part B. Open it in a text editor, select all,
     copy, and paste it as the value (it's a big JSON blob starting with
     `{"type": "service_account", ...}` — that's correct).
3. Redeploy the service (Railway usually redeploys automatically when you push
   the new `requirements.txt`; if not, trigger a redeploy). The new backend adds
   `google-auth` + `requests` for the push helper.

> If these two variables are absent, the backend simply skips push (logs
> `push: ...`) and the app keeps working over WebSocket — so nothing breaks
> while you're mid-setup.

---

## Part D — Build & test

On your PC, in `D:\new_flutter_project_fixed`:

```
flutter pub get
flutter analyze
```

(`pub get` fetches `firebase_core` + `firebase_messaging`. `analyze` should be
clean — it doesn't need `google-services.json`.)

Then build/run on a **real Android phone** (emulators can receive FCM but a real
device is the honest test):

```
flutter run           # or: flutter build apk --release
```

> The Android build will FAIL with *"File google-services.json is missing"* if
> you skipped step A5. That file must be in `android\app\` before you build.

**Test it:**
1. Sign in on the phone (this registers its FCM token — you'll see a
   `/devices/token` call succeed).
2. Background or fully close the app on the phone.
3. From another account (e.g. the desktop app), send that phone a message → the
   phone should get a **"New message"** notification.
4. Start a voice **call** to the phone → it should get an **"Incoming call"**
   notification (full-screen, rings on the calls channel). Tapping it opens the
   app so you can answer.

---

## What the code already does (for reference)

- **Client**: `firebase_core` + `firebase_messaging` added; `Firebase.initializeApp()`
  + background handler wired in `main.dart` (Android/iOS only — a no-op on
  web/Windows so those builds are unaffected). `lib/services/fcm_service.dart`
  requests permission, registers the token on login (and on token refresh), and
  turns foreground/background/terminated **data** pushes into local
  notifications. Incoming calls use a dedicated max-importance channel
  (`aluta_calls`) with a full-screen intent.
- **Backend**: `device_tokens` table (auto-created on boot), `POST/DELETE
  /devices/token`, an FCM v1 push helper (`push.py`), and best-effort pushes
  fired on `new_message` (in `routers/messages.py`) and on `call_offer` (in
  `websocket_routes.py`). Pushes are **data-only**, so the client always
  controls how they're shown.
- **Android**: google-services Gradle plugin applied, `USE_FULL_SCREEN_INTENT`
  permission, and the default FCM notification channel meta-data
  (`aluta_messages`).

## iOS note
This wiring is Android + iOS-capable, but iOS also needs an APNs key uploaded to
Firebase (Project settings → Cloud Messaging → Apple app config) and push
capabilities in Xcode. Since you're on Android, that's out of scope here — ask
me when you want the iOS half.
