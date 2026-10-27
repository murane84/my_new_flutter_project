// Drop-in for `package:http/http.dart` (import it `as http`) that remembers
// WHY the last request failed — offline, timed out, server busy, session
// expired, gone, too large, or the server's own reason — so an error toast
// can say it in plain words instead of a bare "Could not …" (see
// toast_helper.dart). Everything else is plain package:http.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;

export 'package:http/http.dart' hide get, post, put, patch, delete;

/// The most recent request failure, in words that finish the sentence
/// "Could not send — …". Read it right after a failed call; it expires fast
/// so an old failure never explains a new one.
class NetStatus {
  NetStatus._();

  static String? _reason;
  static DateTime? _at;
  static int _seq = 0;
  static int _reasonSeq = 0;

  static int _set(String reason) {
    _reason = reason;
    _at = DateTime.now();
    return _reasonSeq = ++_seq;
  }

  /// Why the last request failed, if that happened within [within].
  /// [consume] clears it so it explains one toast only.
  static String? recentReason(
      {Duration within = const Duration(seconds: 5), bool consume = true}) {
    final r = _reason, at = _at;
    if (r == null || at == null) return null;
    if (DateTime.now().difference(at) > within) return null;
    if (consume) {
      _reason = null;
      _at = null;
    }
    return r;
  }

  static void noteResponse(h.BaseResponse r) {
    final c = r.statusCode;
    if (c < 400) return;
    String? detail;
    if (r is h.Response) {
      try {
        final d = jsonDecode(r.body);
        if (d is Map && d['detail'] is String) {
          final s = (d['detail'] as String).trim();
          if (s.isNotEmpty && s.length <= 140) detail = s;
        }
      } catch (_) {
        // Not JSON — use the status wording.
      }
    }
    _set(reasonFor(c, detail));
  }

  static void noteError(Object e) {
    _set(e is TimeoutException
        ? 'the connection timed out'
        : 'no internet connection');
  }

  static String reasonFor(int code, String? detail) {
    if (code == 401) return 'your session expired — sign in again';
    if (code == 403) return detail ?? "you don't have access to that";
    if (code == 404) return detail ?? "it's no longer on the server";
    if (code == 408) return 'the connection timed out';
    if (code == 413) return 'that file is too large';
    if (code == 429) return 'too many tries — wait a moment';
    if (code >= 500) return "Aluta's server is busy — try again shortly";
    return detail ?? "the server didn't accept it";
  }
}

/// Record a failure from a request sent outside these helpers (multipart).
void noteNetError(Object e) => NetStatus.noteError(e);

/// [h.Response.fromStream] that also records a failed status.
Future<h.Response> responseFrom(h.StreamedResponse s) async {
  final r = await h.Response.fromStream(s);
  NetStatus.noteResponse(r);
  return r;
}

// Callers usually put their own `.timeout()` around the call, which abandons
// this future — so a request still pending after this long is marked slow
// itself (and un-marked if it then succeeds).
const _slowAfter = Duration(seconds: 10);

Future<h.Response> _track(Future<h.Response> Function() send) async {
  int? slowSeq;
  final slow = Timer(_slowAfter, () {
    slowSeq = NetStatus._set('the connection timed out');
  });
  try {
    final r = await send();
    slow.cancel();
    if (r.statusCode >= 400) {
      NetStatus.noteResponse(r);
    } else if (slowSeq != null && NetStatus._reasonSeq == slowSeq) {
      NetStatus._reason = null; // it got through after all
      NetStatus._at = null;
    }
    return r;
  } catch (e) {
    slow.cancel();
    NetStatus.noteError(e);
    rethrow;
  }
}

Future<h.Response> get(Uri url, {Map<String, String>? headers}) =>
    _track(() => h.get(url, headers: headers));

Future<h.Response> post(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _track(() => h.post(url, headers: headers, body: body, encoding: encoding));

Future<h.Response> put(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _track(() => h.put(url, headers: headers, body: body, encoding: encoding));

Future<h.Response> patch(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _track(
        () => h.patch(url, headers: headers, body: body, encoding: encoding));

Future<h.Response> delete(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _track(
        () => h.delete(url, headers: headers, body: body, encoding: encoding));
