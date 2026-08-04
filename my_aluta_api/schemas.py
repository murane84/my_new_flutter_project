from pydantic import BaseModel, EmailStr, ConfigDict, Field
from datetime import datetime
from typing import Optional

# ---------------------- USER SCHEMAS ----------------------

class UserCreate(BaseModel):
    username: str
    email: EmailStr
    password: str


class UserLogin(BaseModel):
    email: EmailStr
    password: str


class UserOut(BaseModel):
    id: int
    username: str
    email: EmailStr
    is_online: Optional[bool] = False

    model_config = ConfigDict(from_attributes=True)


class UserStatus(BaseModel):
    user_id: int
    is_online: bool


# ---------------------- MESSAGE SCHEMAS ----------------------

class MessageCreate(BaseModel):
    receiver_id: int
    content: Optional[str] = ""
    # Attachment fields — omitted for plain text messages.
    message_type: Optional[str] = "text"   # text | image | file | audio
    media_url: Optional[str] = None
    media_name: Optional[str] = None
    media_mime: Optional[str] = None
    media_size: Optional[int] = None
    media_duration: Optional[int] = None


class Message(BaseModel):
    id: int
    sender_id: int
    receiver_id: int
    content: Optional[str] = ""
    timestamp: datetime
    is_read: bool
    delivered: bool
    message_type: Optional[str] = "text"
    media_url: Optional[str] = None
    media_name: Optional[str] = None
    media_mime: Optional[str] = None
    media_size: Optional[int] = None
    media_duration: Optional[int] = None

    model_config = ConfigDict(from_attributes=True)


class MessageWithSender(BaseModel):
    id: int
    sender_id: int
    sender: UserOut  # The sender is now a full UserOut object
    receiver_id: int
    content: Optional[str] = ""
    timestamp: datetime
    is_read: bool
    delivered: bool
    message_type: Optional[str] = "text"
    media_url: Optional[str] = None
    media_name: Optional[str] = None
    media_mime: Optional[str] = None
    media_size: Optional[int] = None
    media_duration: Optional[int] = None

    model_config = ConfigDict(from_attributes=True)

class FriendWithUnread(BaseModel):
    id: int
    username: str
    is_online: bool
    last_timestamp: Optional[str] = None
    last_message: Optional[str] = None
    unread_count: int
    last_sender_id: Optional[int] = None             # ✅ Add this
    last_message_delivered: Optional[bool] = None    # ✅ Add this
    last_message_read: Optional[bool] = None         # ✅ Add this

    model_config = ConfigDict(from_attributes=True)  # For Pydantic v2

class FriendLastSeen(BaseModel):
    id: int
    username: str
    last_seen: Optional[datetime]

    model_config = ConfigDict(from_attributes=True)