from sqlalchemy import (
    Column, DateTime, Integer, String, Text, TIMESTAMP, ForeignKey, Boolean,
    UniqueConstraint, LargeBinary
)
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from datetime import datetime, timezone

Base = declarative_base()

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    email = Column(String, unique=True, index=True, nullable=False)
    hashed_password = Column(String, nullable=False)

    is_online = Column(Boolean, default=False, nullable=False)
    last_seen = Column(TIMESTAMP, nullable=True)
    last_login = Column(DateTime, nullable=True)
    refresh_token = Column(String, nullable=True)
    # Optional phone number, used for one-tap direct calls between friends.
    phone = Column(String, nullable=True)
    # Optional profile picture, stored as an attachment ref (/attachments/<id>).
    avatar_url = Column(String, nullable=True)

    # Two-factor / account recovery (TOTP, e.g. Google Authenticator).
    # `totp_secret` is the base32 shared secret; `totp_enabled` flips true only
    # after the user confirms a first valid code. A user can reset a forgotten
    # password by proving a current TOTP code (see auth.py password-reset).
    totp_secret = Column(String, nullable=True)
    totp_enabled = Column(Boolean, default=False, nullable=False)

    sent_messages = relationship(
        "Message",
        foreign_keys="[Message.sender_id]",
        back_populates="sender",
        cascade="all, delete-orphan",
        passive_deletes=True
    )
    received_messages = relationship(
        "Message",
        foreign_keys="[Message.receiver_id]",
        back_populates="receiver",
        cascade="all, delete-orphan",
        passive_deletes=True
    )

    def __repr__(self):
        return f"<User(id={self.id}, username='{self.username}')>"


class Message(Base):
    __tablename__ = "messages"

    id = Column(Integer, primary_key=True, index=True)
    sender_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    receiver_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    # Nullable now: media messages may carry an empty (or caption) content.
    content = Column(Text, nullable=True, default="")
    timestamp = Column(DateTime(timezone=True), default=func.now())
    is_read = Column(Boolean, default=False)
    read_at = Column(DateTime(timezone=True), nullable=True)
    delivered = Column(Boolean, default=False)

    # ── Media attachment (image / file / audio voice note) ──────────────────
    # message_type: "text" | "image" | "file" | "audio"
    message_type = Column(String, default="text", nullable=True)
    media_url = Column(String, nullable=True)      # e.g. /attachments/<id>
    media_name = Column(String, nullable=True)     # original filename
    media_mime = Column(String, nullable=True)     # content type
    media_size = Column(Integer, nullable=True)    # bytes
    media_duration = Column(Integer, nullable=True)  # audio length in ms

    # ── Conversation features ───────────────────────────────────────────────
    # reactions: JSON object mapping a reactor's user id -> emoji, e.g.
    #   {"3": "❤️", "7": "👍"}  (one reaction per user, WhatsApp-style)
    reactions = Column(Text, nullable=True)
    edited = Column(Boolean, default=False)      # set once content is edited
    is_deleted = Column(Boolean, default=False)  # tombstone: delete-for-everyone
    # When set to a future time, this message is "pinned" in the conversation
    # until that moment; the client shows it in a banner and auto-hides it once
    # the time passes. NULL = not pinned.
    pinned_until = Column(DateTime(timezone=True), nullable=True)

    # New fields for visibility
    visible_to_sender = Column(Boolean, default=True)
    visible_to_receiver = Column(Boolean, default=True)

    sender = relationship("User", foreign_keys=[sender_id], back_populates="sent_messages")
    receiver = relationship("User", foreign_keys=[receiver_id], back_populates="received_messages")

    def __repr__(self):
        return (
            f"<Message(id={self.id}, sender_id={self.sender_id}, "
            f"receiver_id={self.receiver_id}, visible_to_sender={self.visible_to_sender}, "
            f"visible_to_receiver={self.visible_to_receiver})>"
        )


class MuteStatus(Base):
    __tablename__ = "mute_status"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    muted_user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)
    muted_user = relationship("User", foreign_keys=[muted_user_id], passive_deletes=True)

    __table_args__ = (UniqueConstraint('user_id', 'muted_user_id', name='_user_muted_user_uc'),)

    def __repr__(self):
        return f"<MuteStatus(user_id={self.user_id}, muted_user_id={self.muted_user_id})>"


class BlockStatus(Base):
    __tablename__ = "block_status"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    blocked_user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)
    blocked_user = relationship("User", foreign_keys=[blocked_user_id], passive_deletes=True)

    __table_args__ = (UniqueConstraint('user_id', 'blocked_user_id', name='_user_blocked_user_uc'),)

    def __repr__(self):
        return f"<BlockStatus(user_id={self.user_id}, blocked_user_id={self.blocked_user_id})>"


class Friend(Base):
    __tablename__ = "friends"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    friend_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)
    friend = relationship("User", foreign_keys=[friend_id], passive_deletes=True)

    __table_args__ = (UniqueConstraint('user_id', 'friend_id', name='_user_friend_uc'),)

    def __repr__(self):
        return f"<Friend(user_id={self.user_id}, friend_id={self.friend_id})>"


class MediaAsset(Base):
    """A chat attachment stored directly in Postgres (survives Railway
    redeploys, no external storage needed). Referenced by Message.media_url as
    /attachments/<id> and streamed back by the attachments router."""
    __tablename__ = "media_assets"

    id = Column(String, primary_key=True, index=True)   # uuid hex
    # Nullable: for EPHEMERAL assets (shared songs) the bytes are purged from
    # the server once the recipient has cached them locally (or after the TTL),
    # leaving this row as a lightweight reference. Non-ephemeral assets keep
    # their bytes for the life of the row.
    data = Column(LargeBinary, nullable=True)           # raw bytes (None once purged)
    mime = Column(String, nullable=True)
    name = Column(String, nullable=True)
    size = Column(Integer, nullable=True)
    # Who uploaded this asset. Lets the uploader always fetch their own file
    # (e.g. previewing before the message is sent), and is the fast-path owner
    # check for the authenticated attachment endpoint. Nullable for pre-existing
    # rows uploaded before this column existed.
    uploader_id = Column(Integer, index=True, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    # ── Ephemeral songs (server-storage minimisation) ───────────────────────
    # An ephemeral asset is a shared song whose bytes should NOT live on the
    # server long-term. The recipient downloads + caches it locally, then acks
    # (POST /attachments/<id>/cached), which purges the bytes here. A 7-day TTL
    # is the fallback purge for songs the recipient never fetched. The row stays
    # so the chat message keeps a valid reference; playback then uses the local
    # cache on both ends.
    ephemeral = Column(Boolean, default=False, nullable=False)
    cached_at = Column(DateTime(timezone=True), nullable=True)   # recipient acked
    purged_at = Column(DateTime(timezone=True), nullable=True)   # bytes nulled

    def __repr__(self):
        return f"<MediaAsset(id={self.id}, mime='{self.mime}', size={self.size})>"


class DeviceToken(Base):
    """A Firebase Cloud Messaging (FCM) registration token for one of a user's
    devices. Used to push new-message / incoming-call notifications when the app
    is backgrounded or closed (the WebSocket is dead then). One row per device
    token; a token is unique and re-homed to whoever last registered it (tokens
    can migrate between users on a shared device after logout/login)."""
    __tablename__ = "device_tokens"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    token = Column(String, unique=True, index=True, nullable=False)
    platform = Column(String, nullable=True)   # "android" | "ios" | "web"
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)

    def __repr__(self):
        return f"<DeviceToken(user_id={self.user_id}, platform='{self.platform}')>"


class PasswordResetCode(Base):
    """A short-lived email-delivered code for resetting a forgotten password.

    The plaintext code is never stored — only an HMAC of it (see auth.py). Codes
    expire after a few minutes, are single-use (`used`), and lock after too many
    wrong `attempts` to blunt brute force. This is the email-based recovery path;
    the authenticator (TOTP) path is separate and needs no stored code.
    """
    __tablename__ = "password_reset_codes"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    code_hash = Column(String, nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    used = Column(Boolean, default=False, nullable=False)
    attempts = Column(Integer, default=0, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)

    def __repr__(self):
        return f"<PasswordResetCode(user_id={self.user_id}, used={self.used})>"
