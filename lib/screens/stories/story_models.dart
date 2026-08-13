/// Plain data models for the Stories feature, parsed from the backend's
/// /stories/feed and /stories/{id}/viewers payloads. Kept dependency-free so
/// they can be used from any widget.
library;

class StoryItem {
  final String id;
  final int authorId;
  final String kind; // "photo" | "video" | "music"
  final String? mediaUrl; // relative, e.g. /stories/media/<asset_id>
  final String? mediaMime;
  final String? caption;
  final String? musicTitle;
  final String? musicArtist;
  final String? musicArtUrl;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  bool viewed; // mutable so the viewer can flip it locally
  final int viewCount; // only meaningful for my own stories

  StoryItem({
    required this.id,
    required this.authorId,
    required this.kind,
    this.mediaUrl,
    this.mediaMime,
    this.caption,
    this.musicTitle,
    this.musicArtist,
    this.musicArtUrl,
    this.createdAt,
    this.expiresAt,
    this.viewed = false,
    this.viewCount = 0,
  });

  bool get isVideo => kind == 'video';
  bool get isMusic => kind == 'music';
  bool get isPhoto => kind == 'photo';

  static DateTime? _dt(dynamic v) =>
      v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

  factory StoryItem.fromJson(Map<String, dynamic> j) => StoryItem(
        id: j['id'].toString(),
        authorId: (j['author_id'] as num?)?.toInt() ?? 0,
        kind: (j['kind'] ?? 'photo').toString(),
        mediaUrl: j['media_url'] as String?,
        mediaMime: j['media_mime'] as String?,
        caption: j['caption'] as String?,
        musicTitle: j['music_title'] as String?,
        musicArtist: j['music_artist'] as String?,
        musicArtUrl: j['music_art_url'] as String?,
        createdAt: _dt(j['created_at']),
        expiresAt: _dt(j['expires_at']),
        viewed: j['viewed'] == true,
        viewCount: (j['view_count'] as num?)?.toInt() ?? 0,
      );
}

class StoryGroup {
  final int authorId;
  final String username;
  final String? avatarUrl;
  final String? phone;
  final bool isMe;
  bool hasUnseen;
  final List<StoryItem> stories;

  StoryGroup({
    required this.authorId,
    required this.username,
    this.avatarUrl,
    this.phone,
    this.isMe = false,
    this.hasUnseen = false,
    this.stories = const [],
  });

  factory StoryGroup.fromJson(Map<String, dynamic> j) => StoryGroup(
        authorId: (j['author_id'] as num?)?.toInt() ?? 0,
        username: (j['username'] ?? '').toString(),
        avatarUrl: j['avatar_url'] as String?,
        phone: j['phone'] as String?,
        isMe: j['is_me'] == true,
        hasUnseen: j['has_unseen'] == true,
        stories: ((j['stories'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => StoryItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class StoryViewer {
  final int userId;
  final String username;
  final String? avatarUrl;
  final String? phone;
  final DateTime? viewedAt;

  StoryViewer({
    required this.userId,
    required this.username,
    this.avatarUrl,
    this.phone,
    this.viewedAt,
  });

  factory StoryViewer.fromJson(Map<String, dynamic> j) => StoryViewer(
        userId: (j['user_id'] as num?)?.toInt() ?? 0,
        username: (j['username'] ?? '').toString(),
        avatarUrl: j['avatar_url'] as String?,
        phone: j['phone'] as String?,
        viewedAt: StoryItem._dt(j['viewed_at']),
      );
}
