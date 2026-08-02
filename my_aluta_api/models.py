from sqlalchemy import (
    Column, DateTime, Integer, String, Text, TIMESTAMP, ForeignKey, Boolean, UniqueConstraint
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
    content = Column(Text, nullable=False)
    timestamp = Column(DateTime(timezone=True), default=func.now())
    is_read = Column(Boolean, default=False)
    read_at = Column(DateTime(timezone=True), nullable=True)
    delivered = Column(Boolean, default=False)

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
