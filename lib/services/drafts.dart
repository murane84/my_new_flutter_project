import 'package:flutter/foundation.dart';

import '../utils/prefs_now.dart';

/// Unsent composer text, per chat (saved by the chat page as
/// `draft_<convKey>`: `d<friendId>` for a DM, `g<conversationId>` for a
/// group).
/// The Circle list shows it on the chat's tile until it's sent or cleared.
class Drafts {
  Drafts._();

  /// Bumped whenever a draft is saved or cleared.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void changed() => revision.value++;

  static String? _of(String key) {
    final t = prefsNow?.getString('draft_$key');
    return (t == null || t.trim().isEmpty) ? null : t;
  }

  static String? ofFriend(Object? friendId) =>
      friendId == null ? null : _of('d$friendId');

  static String? ofGroup(Object? conversationId) =>
      conversationId == null ? null : _of('g$conversationId');
}
