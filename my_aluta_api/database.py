from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from config import DATABASE_URL

# SQLite (local fallback) needs check_same_thread=False for FastAPI's
# threaded request handling. Postgres benefits from pool_pre_ping so
# stale/recycled connections (common on managed hosts) don't error.
if DATABASE_URL.startswith("sqlite"):
    engine = create_engine(
        DATABASE_URL,
        connect_args={"check_same_thread": False},
    )
else:
    engine = create_engine(
        DATABASE_URL,
        pool_pre_ping=True,
    )

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
