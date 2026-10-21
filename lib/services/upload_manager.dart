import 'dart:async';
import 'package:flutter/foundation.dart';
import 'keystroke_sounds.dart';

/// One in-flight media upload: its optimistic message map (shared by reference
/// with the chat's message list so progress stays live), and the retry closure.
class ChatUpload {
  ChatUpload(this.convKey, this.optimistic, this.attempt);
  final String convKey;
  final Map<String, dynamic> optimistic;
  Future<void> Function() attempt;
  String get tempId => optimistic['id'].toString();
}

/// Keeps media uploads alive across navigation.
///
/// A media upload used to live inside the ChatPage state, so leaving the chat
/// (opening another DM) disposed the screen and orphaned the optimistic bubble
/// and its progress — the upload still finished server-side, but the sender lost
/// all sight of it. This singleton now owns the optimistic + progress + retry,
/// so any ChatPage showing that conversation can sync to it (and a reopened one
/// picks the upload back up), while the transfer runs independently.
class UploadManager {
  UploadManager._();
  static final UploadManager instance = UploadManager._();

  // convKey -> in-flight uploads.
  final Map<String, List<ChatUpload>> _active = {};
  // convKey -> finished sends waiting for a live ChatPage to adopt them.
  final Map<String, List<Map<String, dynamic>>> _done = {};

  /// Bumps on every change so a listening ChatPage re-syncs/re-renders.
  final ValueNotifier<int> rev = ValueNotifier<int>(0);

  List<ChatUpload> active(String convKey) =>
      _active[convKey] ?? const <ChatUpload>[];

  bool has(String convKey, String tempId) => _find(convKey, tempId) != null;

  /// Register an optimistic upload and start it.
  void begin(String convKey, Map<String, dynamic> optimistic,
      Future<void> Function() attempt) {
    final up = ChatUpload(convKey, optimistic, attempt);
    (_active[convKey] ??= <ChatUpload>[]).add(up);
    _bump();
    unawaited(attempt());
  }

  /// Live byte-phase progress (0..1), throttled so a big file doesn't rebuild
  /// per chunk. Milestone values (>=0.90) always apply.
  void progress(String convKey, String tempId, double? p) {
    final up = _find(convKey, tempId);
    if (up == null) return;
    final prev = up.optimistic['__upProgress'] as double?;
    if (p != null && p < 0.90 && prev != null && (p - prev).abs() < 0.01) {
      return;
    }
    up.optimistic['__upProgress'] = p;
    _bump();
  }

  /// Finish an upload: [sent] is the real created message, or null on failure
  /// (the optimistic is kept, marked failed, so the ! retry still works).
  void finish(String convKey, String tempId, Map<String, dynamic>? sent) {
    final up = _find(convKey, tempId);
    if (up == null) return;
    if (sent != null) {
      _active[convKey]?.removeWhere((u) => u.tempId == tempId);
      (_done[convKey] ??= <Map<String, dynamic>>[])
          .add({'tempId': tempId, 'sent': sent});
      try {
        KeystrokeSounds.instance.playSent();
      } catch (_) {}
    } else {
      up.optimistic['status'] = 'failed';
    }
    _bump();
  }

  /// Drain the finished sends for a conversation (the ChatPage swaps the
  /// optimistic bubble for the real message).
  List<Map<String, dynamic>> drainDone(String convKey) {
    final d = _done.remove(convKey);
    return d ?? const <Map<String, dynamic>>[];
  }

  void retry(String convKey, String tempId) {
    final up = _find(convKey, tempId);
    if (up == null) return;
    up.optimistic['status'] = 'sending';
    _bump();
    unawaited(up.attempt());
  }

  ChatUpload? _find(String convKey, String tempId) {
    for (final u in _active[convKey] ?? const <ChatUpload>[]) {
      if (u.tempId == tempId) return u;
    }
    return null;
  }

  void _bump() => rev.value = rev.value + 1;
}
