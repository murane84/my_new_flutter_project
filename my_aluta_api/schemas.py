from pydantic import BaseModel, EmailStr, ConfigDict, Field
from datetime import datetime
from typing import Optional

# ---------------------- USER SCHEMAS ----------------------

class UserCreate(BaseModel):
    username: str
    email: EmailStr
    password: str
    phone: Optional[str] = None


class UserLogin(BaseModel):
    email: EmailStr
    password: str


class UserUpdate(BaseModel):
    # Email is intentionally immutable and not accepted here.
    username: Optional[str] = None
    phone: Optional[str] = None
    avatar_url: Optional[str] = None
    current_password: Optional[str] = None
    new_password: Optional[str] = None


class UserOut(BaseModel):
    id: int
    username: str
    email: EmailStr
    is_online: Optional[bool] = False
    phone: Optional[str] = None
    avatar_url: Optional[str] = None

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


class MessageEdit(BaseModel):
    content: Optional[str] = ""


class Message(BaseModel):
    id: int
    sender_id: int
    receiver_id: Optional[int] = None
    conversation_id: Optional[int] = None
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
    reactions: Optional[str] = None
    edited: Optional[bool] = False
    is_deleted: Optional[bool] = False
    pinned_until: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


class MessageWithSender(BaseModel):
    id: int
    sender_id: int
    sender: UserOut  # The sender is now a full UserOut object
    receiver_id: Optional[int] = None
    conversation_id: Optional[int] = None
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
    reactions: Optional[str] = None
    edited: Optional[bool] = False
    is_deleted: Optional[bool] = False
    pinned_until: Optional[datetime] = None

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
    phone: Optional[str] = None                      # for direct call
    avatar_url: Optional[str] = None                 # profile picture

    model_config = ConfigDict(from_attributes=True)  # For Pydantic v2

class FriendLastSeen(BaseModel):
    id: int
    username: str
    last_seen: Optional[datetime]

    model_config = ConfigDict(from_attributes=True)


# ---------------------- CONVERSATION (DM + GROUP) SCHEMAS ----------------------

class GroupCreate(BaseModel):
    title: str
    member_ids: list[int] = []
    avatar_url: Optional[str] = None


class GroupMessageCreate(BaseModel):
    # Like MessageCreate but WITHOUT receiver_id — the conversation determines
    # the recipients (its members).
    content: Optional[str] = ""
    message_type: Optional[str] = "text"
    media_url: Optional[str] = None
    media_name: Optional[str] = None
    media_mime: Optional[str] = None
    media_size: Optional[int] = None
    media_duration: Optional[int] = None


class AddMembers(BaseModel):
    user_ids: list[int]


class RenameGroup(BaseModel):
    # Group settings update — either/both. (Kept the name for compatibility.)
    title: Optional[str] = None
    avatar_url: Optional[str] = None


class ReadUpTo(BaseModel):
    # Mark read up to a message id; omit to mark the whole conversation read.
    message_id: Optional[int] = None


class ConversationMemberOut(BaseModel):
    user_id: int
    username: str
    avatar_url: Optional[str] = None
    is_online: Optional[bool] = False
    role: str = "member"

    model_config = ConfigDict(from_attributes=True)


class ConversationOut(BaseModel):
    id: int
    is_group: bool
    title: Optional[str] = None       # group name; for DMs the client shows the other user
    avatar_url: Optional[str] = None
    created_by: Optional[int] = None
    updated_at: Optional[datetime] = None
    members: list[ConversationMemberOut] = []
    # Convenience fields the chat list needs.
    other_user: Optional[UserOut] = None   # for DMs: the OTHER member (not me)
    last_message: Optional[str] = None
    last_timestamp: Optional[datetime] = None
    last_sender_id: Optional[int] = None
    unread_count: int = 0
    my_role: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class SeenByEntry(BaseModel):
    user_id: int
    username: str
    avatar_url: Optional[str] = None
    read_at: Optional[datetime] = None


class MessageInfoMember(BaseModel):
    user_id: int
    username: str
    avatar_url: Optional[str] = None
    phone: Optional[str] = None
    # When they read (read list) or received (delivered list) the message.
    timestamp: Optional[datetime] = None


class MessageInfoOut(BaseModel):
    # WhatsApp-style "Message info": every OTHER group member bucketed into
    # exactly one of the three states for this message.
    read: list[MessageInfoMember] = []
    delivered: list[MessageInfoMember] = []
    sent: list[MessageInfoMember] = []


# ---------------------- CONTACTS SYNC ----------------------

class ContactsSync(BaseModel):
    # Phone numbers read from the device address book (any format — the server
    # normalises them before matching against registered users' phone numbers).
    phones: list[str] = []


class ContactNamesUpload(BaseModel):
    # Number-key → saved contact name, uploaded by the phone so the desktop app
    # can personalise friends' names. Keys are already normalised on the client.
    names: dict[str, str] = {}


class ContactNamesOut(BaseModel):
    names: dict[str, str] = {}


# ---------------------- PUSH / DEVICE SCHEMAS ----------------------

class DeviceTokenIn(BaseModel):
    token: str
    platform: Optional[str] = None  # "android" | "ios" | "web"