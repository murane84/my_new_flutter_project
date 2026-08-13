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

    # Legal consent: the highest Privacy Policy / Terms version this user has
    # accepted (see legal.py). 0 means "never accepted"; whenever the server's
    # CURRENT_POLICY_VERSION is higher than this, the app re-prompts the user to
    # read and agree before they can continue. `policy_accepted_at` records when.
    policy_version = Column(Integer, default=0, nullable=False, server_default="0")
    policy_accepted_at = Column(DateTime(timezone=True), nullable=True)

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
    # receiver_id is the OTHER party in a 1:1 DM. It is NULL for group messages
    # (which fan out to a conversation's members instead). DMs still set it so
    # all the existing 1:1 endpoints/logic keep working unchanged.
    receiver_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=True)
    # The conversation this message belongs to. Backfilled for existing DMs and
    # set on every new message (DM or group). DMs also keep receiver_id set.
    conversation_id = Column(
        Integer, ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=True, index=True,
    )
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


class Conversation(Base):
    """A chat thread. `is_group=False` is a 1:1 DM (exactly two members, no
    title/avatar); `is_group=True` is a named group with any number of members.
    Existing 1:1 message history is migrated into DM conversations on boot."""
    __tablename__ = "conversations"

    id = Column(Integer, primary_key=True, index=True)
    is_group = Column(Boolean, default=False, nullable=False)
    title = Column(String, nullable=True)       # group name (NULL for DMs)
    avatar_url = Column(String, nullable=True)  # group photo (NULL for DMs)
    created_by = Column(
        Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now())

    members = relationship(
        "ConversationMember",
        back_populates="conversation",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )

    def __repr__(self):
        return f"<Conversation(id={self.id}, is_group={self.is_group})>"


class ConversationMember(Base):
    """A user's membership in a conversation, plus WhatsApp-style per-member
    delivery/read POINTERS (the highest message id delivered to / read by this
    member). Pointers give per-member unread counts and 'delivered/read by all'
    ticks + seen-by lists without a row per (message, member)."""
    __tablename__ = "conversation_members"

    id = Column(Integer, primary_key=True, index=True)
    conversation_id = Column(
        Integer, ForeignKey("conversations.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    role = Column(String, default="member", nullable=False)  # "admin" | "member"
    joined_at = Column(DateTime(timezone=True), server_default=func.now())

    last_read_message_id = Column(Integer, nullable=True)
    last_read_at = Column(DateTime(timezone=True), nullable=True)
    last_delivered_message_id = Column(Integer, nullable=True)
    last_delivered_at = Column(DateTime(timezone=True), nullable=True)

    conversation = relationship("Conversation", back_populates="members")
    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)

    __table_args__ = (
        UniqueConstraint("conversation_id", "user_id", name="_conv_member_uc"),
    )

    def __repr__(self):
        return (
            f"<ConversationMember(conversation_id={self.conversation_id}, "
            f"user_id={self.user_id}, role='{self.role}')>"
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


class LoginLink(Base):
    """A desktop QR-login handshake (WhatsApp-Web style).

    The desktop creates a pending link and shows `code` as a QR (and `pair_code`
    for manual entry). The signed-in phone approves it, which mints tokens stored
    here; the desktop polls with `code`, picks the tokens up ONCE, then the row is
    marked consumed. Links expire after a few minutes.
    """
    __tablename__ = "login_links"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String, unique=True, index=True, nullable=False)
    pair_code = Column(String, unique=True, index=True, nullable=False)
    status = Column(String, default="pending", nullable=False)  # pending|approved|consumed
    device_label = Column(String, nullable=True)
    device_platform = Column(String, nullable=True)
    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=True
    )
    access_token = Column(Text, nullable=True)
    refresh_token = Column(Text, nullable=True)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)

    def __repr__(self):
        return f"<LoginLink(status='{self.status}', user_id={self.user_id})>"


class UserContactBook(Base):
    """The user's own phone-book name map (number-key → saved name), uploaded by
    their phone so the desktop app can personalise friends' names. Private to the
    user; one row per user, stored as a JSON string."""
    __tablename__ = "user_contact_books"

    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    data = Column(Text, nullable=False, default="{}")
    updated_at = Column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)


class UserTrackOverrides(Base):
    """The user's edited song details (custom title/artist/album/genre/year),
    keyed by track path, backed up to their account so they survive an app
    reinstall / update or a move to a new device on the same account. Private to
    the user; one row per user, stored as a JSON string (same shape the client
    keeps in local prefs)."""
    __tablename__ = "user_track_overrides"

    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    data = Column(Text, nullable=False, default="{}")
    updated_at = Column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)


class DeviceSession(Base):
    """A revocable session for a device linked via QR (WhatsApp "linked devices").

    Tokens minted for a QR link carry this session's `sid`; every authenticated
    request checks the session still exists and isn't revoked, so the user can
    sign a linked computer out remotely from their phone.
    """
    __tablename__ = "device_sessions"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    sid = Column(String, unique=True, index=True, nullable=False)
    label = Column(String, nullable=True)
    platform = Column(String, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    last_seen_at = Column(DateTime(timezone=True), server_default=func.now())
    revoked = Column(Boolean, default=False, nullable=False)

    user = relationship("User", foreign_keys=[user_id], passive_deletes=True)

    def __repr__(self):
        return f"<DeviceSession(user_id={self.user_id}, label='{self.label}', revoked={self.revoked})>"


class Story(Base):
    """An ephemeral 24-hour "Story": a photo, a short video clip, or a
    "now playing" music moment posted by a user and shown to their friends.

    Media (photo/video) bytes live in a MediaAsset (uploaded via /upload/media
    with ephemeral=true); `media_asset_id` references it and the stories router
    serves those bytes friend-scoped at /stories/media/<asset_id>. A "music"
    story carries no uploaded media — just the track fields below.

    There is no scheduler: a story is "active" while `expires_at > now`, and
    expired rows are swept opportunistically on write (see routers/stories.py),
    mirroring the ephemeral-media purge pattern.
    """
    __tablename__ = "stories"

    id = Column(String, primary_key=True, index=True)   # uuid hex
    author_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    # "photo" | "video" | "music"
    kind = Column(String, nullable=False, default="photo")
    # For photo/video: the MediaAsset holding the bytes. Null for music stories.
    media_asset_id = Column(String, nullable=True)
    media_mime = Column(String, nullable=True)
    # Optional caption overlaid on the story.
    caption = Column(Text, nullable=True)
    # "Now playing" fields (music stories, or a caption's track badge).
    music_title = Column(String, nullable=True)
    music_artist = Column(String, nullable=True)
    music_art_url = Column(String, nullable=True)
    # Background colour (hex like "#RRGGBB" or "#AARRGGBB") for a text-only
    # story (kind == "text"); the caption holds the text.
    background = Column(String, nullable=True)

    created_at = Column(DateTime(timezone=True), server_default=func.now())
    expires_at = Column(DateTime(timezone=True), index=True, nullable=False)

    author = relationship("User", foreign_keys=[author_id], passive_deletes=True)

    def __repr__(self):
        return f"<Story(id={self.id}, author_id={self.author_id}, kind='{self.kind}')>"


class StoryView(Base):
    """One "seen" record: `viewer_id` watched `story_id`. Unique per pair so a
    repeat view is idempotent; drives the author's "who viewed" list and the
    unseen-ring state on each viewer's tray."""
    __tablename__ = "story_views"

    id = Column(Integer, primary_key=True, index=True)
    story_id = Column(
        String, ForeignKey("stories.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    viewer_id = Column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"),
        index=True, nullable=False,
    )
    viewed_at = Column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        UniqueConstraint('story_id', 'viewer_id', name='_story_viewer_uc'),
    )

    def __repr__(self):
        return f"<StoryView(story_id={self.story_id}, viewer_id={self.viewer_id})>"
