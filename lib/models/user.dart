class User {
  final int? id;
  final String username;
  final String email;
  final String? password;
  final bool isOnline;
  int unreadCount;
  final String lastMessage;
  final String lastTimestamp;
  final int? lastSenderId;
  final bool? lastMessageDelivered;
  final bool? lastMessageRead;
  final bool isMuted;
  final String? lastSeen;
  final String? lastMessageType; // text, image, video, audio
  final String? profileImageUrl;

  bool get hasUnreadMessages => unreadCount > 0;

  User({
    this.id,
    required this.username,
    required this.email,
    this.password,
    this.isOnline = false,
    this.unreadCount = 0,
    this.lastMessage = '',
    this.lastTimestamp = '',
    required this.lastSenderId,
    required this.lastMessageDelivered,
    required this.lastMessageRead,
    this.isMuted = false,
    this.lastSeen,
    this.lastMessageType,
    this.profileImageUrl,
  });

  // ✅ Factory to create User from API map
  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['friend_id'] ?? map['id'],
      username: map['username'] ?? '',
      email: map['email'] ?? '',
      isOnline: map['is_online'] == true,
      unreadCount: map['unread_count'] ?? 0,
      lastMessage: map['last_message'] ?? '',
      lastTimestamp: map['last_timestamp'] ?? '',
      lastSenderId: map['last_sender_id'],
      lastMessageDelivered: map['last_message_delivered'],
      lastMessageRead: map['last_message_read'],
      isMuted: map['is_muted'] ?? false,
      lastSeen: map['last_seen'],
      lastMessageType: map['last_message_type']?.toString(),
      profileImageUrl: map['profile_image_url']?.toString(),
    );
  }

  // ✅ Added toMap method for comparison and other use cases
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'is_online': isOnline,
      'unread_count': unreadCount,
      'last_message': lastMessage,
      'last_timestamp': lastTimestamp,
      'last_sender_id': lastSenderId,
      'last_message_delivered': lastMessageDelivered,
      'last_message_read': lastMessageRead,
      'is_muted': isMuted,
      'last_seen': lastSeen,
      'last_message_type': lastMessageType,
      'profile_image_url': profileImageUrl,
    };
  }
}
