#!/usr/bin/env python3
"""Back-office password reset (operator tool).

Resets ONE user's password directly in the database and flags the account so
the app forces them to set their own password at next sign-in. For a locked-out
user with no working recovery path (no 2FA / Ozilane Key, email recovery down).

Run it INSIDE the Aluta service's Railway Console, where DATABASE_URL is the
live one and the app's dependencies are installed:

    python admin_reset_password.py <phone|email|username> [new-password]

With no password given, the default ("Aluta@123") is used. Either way the
account is marked must_change_password, so the app prompts the user to set a new
password right after they sign in. Existing sessions are signed out.

The password is printed here ONCE (Console only, never chat) so you can pass it
to the user over a trusted channel.
"""
import sys

from passlib.context import CryptContext

from database import SessionLocal
from models import User

DEFAULT_PASSWORD = "Aluta@123"

# Same scheme as auth.get_password_hash (bcrypt, 72-byte truncation).
_pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    truncated = password.encode("utf-8")[:72].decode("utf-8", "ignore")
    return _pwd.hash(truncated)


def find_user(db, ident: str):
    ident = (ident or "").strip()
    return (
        db.query(User).filter(User.phone == ident).first()
        or db.query(User).filter(User.email == ident.lower()).first()
        or db.query(User).filter(User.username == ident).first()
    )


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: python admin_reset_password.py "
              "<phone|email|username> [new-password]")
        return 2
    ident = sys.argv[1]
    new_pw = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_PASSWORD
    if len(new_pw) < 6:
        print("New password must be at least 6 characters.")
        return 2

    db = SessionLocal()
    try:
        user = find_user(db, ident)
        if not user:
            print(f"No user found for '{ident}'.")
            return 1
        user.hashed_password = hash_password(new_pw)
        user.must_change_password = True   # force a change at next sign-in
        user.refresh_token = None          # sign out existing sessions
        db.commit()
        print(f"OK — password reset for user #{user.id} "
              f"(username={user.username}, email={user.email}, "
              f"phone={user.phone}).")
        print(f"Temporary password: {new_pw}")
        print("Share it over a trusted channel. The app will require a new "
              "password immediately after they sign in.")
    finally:
        db.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
