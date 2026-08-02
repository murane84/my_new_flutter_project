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

# Log which database backend is in use (never print credentials).
try:
    _scheme = DATABASE_URL.split("://", 1)[0]
except Exception:
    _scheme = "unknown"
print(f"[config] ENVIRONMENT={ENVIRONMENT} DB_SCHEME={_scheme}")
