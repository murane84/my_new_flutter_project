import os
from dotenv import load_dotenv

# Load environment variables for local development.
# On Railway (and other hosts) real environment variables are injected
# directly, so these files simply won't exist — load_dotenv() no-ops then.
load_dotenv(dotenv_path=".env.txt")
load_dotenv()  # also honour a standard .env if present

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
DATABASE_URL = os.getenv("DATABASE_URL")

# Railway / Heroku style URLs sometimes start with "postgres://", but
# SQLAlchemy 1.4+ requires the "postgresql://" scheme.
if DATABASE_URL and DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)

if not DATABASE_URL:
    # Safe local fallback so the app can still boot for quick tests.
    DATABASE_URL = "sqlite:///./local_dev.db"

# ---------------------------------------------------------------------------
# Auth / JWT
# ---------------------------------------------------------------------------
SECRET_KEY = os.getenv("SECRET_KEY", "CHANGE_ME_IN_PRODUCTION")
ALGORITHM = os.getenv("ALGORITHM", "HS256")
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", 30))
INACTIVITY_TIMEOUT_MINUTES = int(os.getenv("INACTIVITY_TIMEOUT_MINUTES", 60))

ENVIRONMENT = os.getenv("ENVIRONMENT", "development")

# ---------------------------------------------------------------------------
# Firebase Cloud Messaging (push notifications)
# ---------------------------------------------------------------------------
# The FCM HTTP v1 API needs (1) the Firebase project id and (2) a service
# account to mint OAuth2 access tokens. Provide the service account EITHER as a
# raw JSON string in FIREBASE_SERVICE_ACCOUNT_JSON (recommended on Railway — set
# it as a variable, never commit the file) OR as a path in
# FIREBASE_SERVICE_ACCOUNT_FILE. If neither is set, push is disabled and the app
# still works (WebSocket delivery only) — pushes are best-effort.
FIREBASE_PROJECT_ID = os.getenv("FIREBASE_PROJECT_ID")
FIREBASE_SERVICE_ACCOUNT_JSON = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
FIREBASE_SERVICE_ACCOUNT_FILE = os.getenv("FIREBASE_SERVICE_ACCOUNT_FILE")

# ---------------------------------------------------------------------------
# Transactional email (ZeptoMail) — used for email-code password recovery.
# ---------------------------------------------------------------------------
# ZEPTOMAIL_TOKEN: the agent's "Send Mail" token. Paste either the bare key or
#   the full "Zoho-enczapikey <key>" value — the mailer normalises it.
# ZEPTOMAIL_FROM: a verified sender on your domain (e.g. noreply@ozilane.com).
# ZEPTOMAIL_FROM_NAME: display name shown to recipients.
# ZEPTOMAIL_API_URL: region endpoint — default .com; use the .eu host if your
#   ZeptoMail account is in the EU data centre.
# If the token/from are unset, email sending is skipped (the app still works;
# users can recover via authenticator instead).
ZEPTOMAIL_TOKEN = os.getenv("ZEPTOMAIL_TOKEN")
ZEPTOMAIL_FROM = os.getenv("ZEPTOMAIL_FROM")
ZEPTOMAIL_FROM_NAME = os.getenv("ZEPTOMAIL_FROM_NAME", "Aluta")
ZEPTOMAIL_API_URL = os.getenv(
    "ZEPTOMAIL_API_URL", "https://api.zeptomail.com/v1.1/email"
)

# Log which database backend is in use (never print credentials).
try:
    _scheme = DATABASE_URL.split("://", 1)[0]
except Exception:
    _scheme = "unknown"
print(f"[config] ENVIRONMENT={ENVIRONMENT} DB_SCHEME={_scheme}")
