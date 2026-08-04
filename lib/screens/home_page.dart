import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
// Hide intl's TextDirection so TextPainter/TextDirection.ltr resolve to dart:ui's.
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:marquee/marquee.dart';
import '../utils/toast_helper.dart';
import '../utils/app_reload.dart';
import '../utils/connection_status.dart';
import '../utils/session_events.dart';
import 'auth_page.dart';
import 'theme_provider.dart';
import 'music_controls.dart';
import 'web_music_panel.dart';
import 'chat_page.dart';
import 'api_service.dart';
import 'websocket_manager.dart';
import 'live_session_screen.dart';
import 'legal_screen.dart';
import '../services/live_session_service.dart'
    show activeLiveSession, endActiveLiveSession;
import '../services/notif_service.dart';
import 'token_helper.dart';
import '../utils/avatar_widget.dart';
import '../utils/app_config.dart';
import '../utils/time_utils.dart';

String _formatFriendTimestamp(String raw) {
  if (raw.isEmpty) return '';
  try {
    final dt = parseServerTime(raw);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return DateFormat('h:mm a').format(dt);
    if (diff.inDays < 7) return DateFormat('EEE').format(dt);
    return DateFormat('d MMM').format(dt);
  } catch (_) {
    return '';
  }
}

// Persists now-playing info from MusicControls → footer
class NowPlayingNotifier extends ChangeNotifier {
  String _track = '';
  String _artist = '';
  bool _playing = false;

  String get track => _track;
  String get artist => _artist;
  bool get playing => _playing;

  void update({required String track, required String artist, required bool playing}) {
    if (_track == track && _artist == artist && _playing == playing) return;
    _track = track;
    _artist = artist;
    _playing = playing;
    notifyListeners();
  }
}

final nowPlayingNotifier = NowPlayingNotifier();

// Tracks an active live "Listen Together" session so ambient UI (like the
// phone now-playing bar) can highlight who you're streaming with.
class LiveSessionNotifier extends ChangeNotifier {
  bool _active = false;
  String _peer = '';
  bool _asHost = false;

  bool get active => _active;
  String get peer => _peer;
  bool get asHost => _asHost;

  void start({required String peer, required bool asHost}) {
    _active = true;
    _peer = peer;
    _asHost = asHost;
    notifyListeners();
  }

  void stop() {
    if (!_active) return;
    _active = false;
    _peer = '';
    notifyListeners();
  }
}

final liveSessionNotifier = LiveSessionNotifier();

// A tiny command bus so lightweight ambient controls (e.g. the collapsed
// now-playing bar) can drive the ONE mounted player without owning the
// AudioPlayer. MusicControls registers its handlers on init and clears them
// on dispose.
class PlaybackBus {
  VoidCallback? onToggle;
  VoidCallback? onNext;
  VoidCallback? onPrev;
  // Seek to a fraction (0..1) of the current track's duration.
  void Function(double fraction)? onSeekFraction;
  // Pause the local player (used when a live session takes over playback so
  // the same song isn't heard twice).
  VoidCallback? onPause;
  // Resume playback (media-button "play"); seek to an absolute position
  // (media-button / notification scrub).
  VoidCallback? onPlay;
  void Function(Duration position)? onSeekTo;
  // Read-backs so the live-share flow can sync to what's playing now.
  String? Function()? currentPath; // file path of the current track, if any
  int Function()? currentPositionMs; // current playback position
  bool Function()? isPlaying;
  // Toggle "favourite" on the currently-playing track (driven by the bar heart).
  VoidCallback? onToggleFavorite;
}

final playbackBus = PlaybackBus();

// Elapsed / total for the current track, so the now-playing bar can show tiny
// time labels flanking the seek bar. Updated per position tick alongside
// [playProgressNotifier]; kept separate so only the times rebuild.
class PlayClock {
  const PlayClock(this.position, this.duration);
  final Duration position;
  final Duration duration;
}

final ValueNotifier<PlayClock> playClockNotifier =
    ValueNotifier<PlayClock>(const PlayClock(Duration.zero, Duration.zero));

// Whether the currently-playing track is a favourite — drives the bar's heart.
final ValueNotifier<bool> favoriteNotifier = ValueNotifier<bool>(false);

// Current playback progress (0..1), updated by the player's position stream.
// Kept separate from nowPlayingNotifier so the frequent per-tick updates only
// rebuild the tiny progress bar — not the whole chat surface.
final ValueNotifier<double> playProgressNotifier = ValueNotifier<double>(0.0);

// The music player's currently-loaded playlist (file paths), mirrored here so
// other features — like starting a live "Listen Together" from already-loaded
// songs instead of the file browser — can read it without owning the player.
final ValueNotifier<List<String>> playlistNotifier =
    ValueNotifier<List<String>>(<String>[]);

// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  static const String routeName = '/home';
  const HomePage({super.key});

  static HomePageState? of(BuildContext context) =>
      context.findAncestorStateOfType<HomePageState>();

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String _username = '';
  int _onlineFriendsCount = 0;
  List<Map<String, dynamic>> _allFriends = [];

  // ── Server discovery state ────────────────────────────────────────────────
  String _serverIp = 'discovering…';
  bool _serverReachable = false;
  bool _isDiscovering = false;

  // ── Current user online status ────────────────────────────────────────────
  bool _isCurrentUserOnline = true;
  bool _isGoingOnline = false;
  int? _myUserId;
  // App-wide notification socket so "Listen Together" invites reach the user on
  // ANY screen — not only when the matching chat happens to be open.
  WebSocketManager? _notifyWs;
  // Whether the app is currently in the foreground (drives whether an incoming
  // message pops a local notification).
  bool _appForeground = true;
  List<Map<String, dynamic>> _filteredFriends = [];
  bool _isLoadingFriends = false;

  // ── Layout state ──────────────────────────────────────────────────────────
  double _musicPanelWidth = 280;
  bool _isMusicFullScreen = false;
  bool _isChatFullScreen = false;
  double _prevMusicWidth = 280;
  bool _isDragging = false;
  // Phone-only: whether the slide-up full player sheet is expanded.
  bool _playerExpanded = false;
  // Phone-only: user dismissed the now-playing bar → collapses to a small
  // floating music button that reopens it.
  bool _barDismissed = false;
  // Draggable position of the music FAB. null = default bottom-right anchor
  // (reset there whenever the bar is freshly collapsed into a FAB).
  Offset? _fabOffset;

  // ── Chat state ────────────────────────────────────────────────────────────
  String? _activeFriendId;
  String? _activeFriendName;
  bool? _activeFriendOnline;
  String? _activeFriendLastSeen;

  Timer? _refreshTimer;
  Timer? _heartbeatTimer;
  StreamSubscription? _connectivitySub;
  // Throttles presence pings triggered by user interaction.
  DateTime _lastActivityPing = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // React to the shared connection status so the footer dot / header badge
    // update even when the change originates elsewhere (e.g. the chat page).
    ConnectionStatus.instance.online.addListener(_onGlobalConnChanged);
    // When the token genuinely expires (server returns 401/403), sign out to a
    // fresh login instead of leaving the user stuck offline.
    SessionEvents.instance.expired.addListener(_onSessionExpired);
    _loadUserData();
    _loadCachedFriends();    // show cached list instantly (no spinner flash)
    _fetchFriends();          // then refresh from network
    _loadLayoutState();
    _discoverServer();

    // Foreground heartbeat: keep the server-side presence alive while the app
    // is open, so idling no longer silently drops the user offline.
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendHeartbeat(),
    );

    // WhatsApp-style: auto-reconnect when network comes back,
    // silently go offline when it disappears.
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) {
        AppConfig.clearSessionCache();
        _discoverServer(forceReset: true);
        _autoReconnect();      // go online + refresh data
      } else {
        // Lost network — mark offline, cached data stays visible
        ConnectionStatus.instance.set(false);
        if (mounted) {
          setState(() {
            _isCurrentUserOnline = false;
            _serverReachable = false;
          });
        }
      }
    });

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _fetchFriends(quiet: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectionStatus.instance.online.removeListener(_onGlobalConnChanged);
    SessionEvents.instance.expired.removeListener(_onSessionExpired);
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    _connectivitySub?.cancel();
    _notifyWs?.close();
    super.dispose();
  }

  // ── Session expiry → clean auto sign-out ──────────────────────────────────
  bool _handlingExpiry = false;
  Future<void> _onSessionExpired() async {
    if (!SessionEvents.instance.expired.value) return;
    if (_handlingExpiry || !mounted) return;
    _handlingExpiry = true;
    SessionEvents.instance.reset();

    // Stop all background chatter first.
    _heartbeatTimer?.cancel();
    _refreshTimer?.cancel();
    _notifyWs?.close();

    // Best-effort tell the user why they're back at login.
    if (mounted) {
      showToast(context, 'Your session expired — please sign in again',
          type: ToastType.info, duration: const Duration(seconds: 3));
    }

    await ApiService().logoutUser();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('access_token');
    } catch (_) {}

    if (!mounted) return;
    // Clear the whole stack so any open chat/live popup is dismissed too.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthPage()),
      (route) => false,
    );
  }

  // Mirrors the shared connection status into the local flags the UI reads.
  void _onGlobalConnChanged() {
    final v = ConnectionStatus.instance.isOnline;
    if (mounted && (_serverReachable != v || _isCurrentUserOnline != v)) {
      setState(() {
        _serverReachable = v;
        _isCurrentUserOnline = v;
      });
    }
  }

  // ── App lifecycle: reconnect the session when the app is resumed ───────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _appForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // Coming back from idle/background — re-check the server and go online.
      _discoverServer();
      _autoReconnect();
    }
  }

  // Sends a presence heartbeat to the server and makes it the single source of
  // truth for BOTH the header badge and the footer dot — so they always agree.
  Future<void> _sendHeartbeat() async {
    if (!mounted) return;
    try {
      final ok = await ApiService().setOnlineStatus(true);
      if (!mounted) return;
      ConnectionStatus.instance.set(ok);
      if (_serverReachable != ok || _isCurrentUserOnline != ok) {
        setState(() {
          _serverReachable = ok;
          _isCurrentUserOnline = ok;
        });
      }
    } catch (_) {
      ConnectionStatus.instance.set(false);
      if (mounted && (_serverReachable || _isCurrentUserOnline)) {
        setState(() {
          _serverReachable = false;
          _isCurrentUserOnline = false;
        });
      }
    }
  }

  // Called on ANY touch/pointer down anywhere in the app. Immediately recovers
  // the session if we're offline, and keeps presence fresh (throttled to 30s)
  // so the user never has to log out / back in just to reconnect.
  void _onUserActivity() {
    if (!_serverReachable || !_isCurrentUserOnline) {
      _autoReconnect();
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastActivityPing).inSeconds >= 30) {
      _lastActivityPing = now;
      _sendHeartbeat();
    }
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _loadLayoutState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _musicPanelWidth = prefs.getDouble('musicPanelWidth') ?? 280;
      _isMusicFullScreen = prefs.getBool('isMusicFullScreen') ?? false;
      _isChatFullScreen = prefs.getBool('isChatFullScreen') ?? false;
    });
  }

  void _saveLayoutState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('musicPanelWidth', _musicPanelWidth);
    await prefs.setBool('isMusicFullScreen', _isMusicFullScreen);
    await prefs.setBool('isChatFullScreen', _isChatFullScreen);
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  // ── Server discovery ──────────────────────────────────────────────────────

  Future<void> _discoverServer({bool forceReset = false}) async {
    if (_isDiscovering) return;
    setState(() {
      _isDiscovering = true;
      _serverIp = forceReset ? 'scanning…' : (_serverIp == 'discovering…' ? 'discovering…' : _serverIp);
    });

    // Web / release builds always talk to the production server on the same
    // origin — there's no LAN to scan. Probe /health directly and report status.
    if (kIsWeb || kReleaseMode) {
      final ok = await AppConfig.probeServer();
      ConnectionStatus.instance.set(ok);
      if (mounted) {
        setState(() {
          _serverIp = AppConfig.displayHost;
          _serverReachable = ok;
          _isDiscovering = false;
        });
      }
      return;
    }

    if (forceReset) await AppConfig.resetDiscovery();

    try {
      await AppConfig.baseUrl; // trigger discovery
      final ip = AppConfig.cachedIp ?? 'unknown';
      final reachable = await AppConfig.probeIp(ip);
      ConnectionStatus.instance.set(reachable);
      if (mounted) {
        setState(() {
          _serverIp = ip;
          _serverReachable = reachable;
          _isDiscovering = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isDiscovering = false);
    }
  }

  void _showServerSettings() {
    // On the live app (web / release) the server is fixed to the production
    // domain — manual IP override and LAN auto-detect do nothing here. Show a
    // clean read-only status card instead of the dev configuration dialog.
    if (kIsWeb || kReleaseMode) {
      showDialog(
        context: context,
        builder: (ctx) {
          final scheme = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.wifi_tethering_rounded),
                SizedBox(width: 8),
                Text('Server Connection'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _serverReachable
                        ? Colors.green.withAlpha(30)
                        : Colors.red.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _serverReachable ? Colors.green : Colors.red,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _serverReachable
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 16,
                        color: _serverReachable ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _serverReachable
                              ? 'Connected: $_serverIp'
                              : 'Not reachable: $_serverIp',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                _serverReachable ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Aluta connects to its secure cloud server automatically.',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            actions: [
              if (kIsWeb)
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    hardReloadApp();
                  },
                  child: const Text('Reload app'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
      return;
    }

    final controller = TextEditingController(
      text: _serverIp == 'discovering…' || _serverIp == 'scanning…'
          ? ''
          : _serverIp,
    );
    bool testing = false;
    String? testResult;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.wifi_tethering_rounded),
              SizedBox(width: 8),
              Text('Server Connection'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status indicator
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _serverReachable
                      ? Colors.green.withAlpha(30)
                      : Colors.red.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _serverReachable ? Colors.green : Colors.red,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _serverReachable
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 16,
                      color:
                          _serverReachable ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _serverReachable
                            ? 'Connected: ${(kIsWeb || kReleaseMode) ? _serverIp : '$_serverIp:${AppConfig.port}'}'
                            : 'Not reachable: ${(kIsWeb || kReleaseMode) ? _serverIp : '$_serverIp:${AppConfig.port}'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: _serverReachable
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('Manual IP override:',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'e.g. 192.168.2.205',
                  isDense: true,
                  filled: true,
                  suffixIcon: testing
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2)),
                        )
                      : null,
                ),
              ),
              if (testResult != null) ...[
                const SizedBox(height: 6),
                Text(
                  testResult!,
                  style: TextStyle(
                    fontSize: 12,
                    color: testResult!.startsWith('✅')
                        ? Colors.green
                        : Colors.red,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Tip: Run "flutter run --dart-define=SERVER_IP=192.168.x.x" '
                'to set this permanently at build time.',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _discoverServer(forceReset: true);
              },
              child: const Text('Auto-detect'),
            ),
            TextButton(
              onPressed: () async {
                final ip = controller.text.trim();
                if (ip.isEmpty) return;
                setS(() { testing = true; testResult = null; });
                final ok = await AppConfig.probeIp(ip);
                setS(() {
                  testing = false;
                  testResult = ok
                      ? '✅ Server found at $ip'
                      : '❌ No Aluta server at $ip:${AppConfig.port}';
                });
              },
              child: const Text('Test'),
            ),
            FilledButton(
              onPressed: () async {
                final ip = controller.text.trim();
                if (ip.isNotEmpty) {
                  await AppConfig.setManualIp(ip);
                  if (mounted) {
                    setState(() {
                      _serverIp = ip;
                      _serverReachable = false;
                    });
                    _discoverServer();
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  // ── App-wide notification socket (Listen Together invites, etc.) ──────────
  void _startNotifyWs() {
    final id = _myUserId;
    if (id == null) return;
    _notifyWs?.close();
    _notifyWs = WebSocketManager(
      userId: id.toString(),
      onEventReceived: _handleNotification,
      onDisconnected: () {},
    );
    _notifyWs!.connect();
  }

  void _handleNotification(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type']?.toString();
    if (type == 'live_invite') {
      _showLiveInvite(event);
      return;
    }
    // A new chat message arriving on the per-user notify socket. When the app
    // is backgrounded (e.g. music playing in the car), pop a local
    // notification so the user is prompted back. Requires the backend to emit
    // a message event on this socket.
    if (type == 'new_message' || type == 'message' || type == 'chat_message') {
      final data =
          (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      // Backend payload is a MessageWithSender: sender is a nested user object
      // and the text lives in `content`.
      final senderObj = (data['sender'] as Map?)?.cast<String, dynamic>();
      final sender = (senderObj?['username'] ??
              data['sender_name'] ??
              data['username'] ??
              'New message')
          .toString();
      final text =
          (data['content'] ?? data['text'] ?? data['message'] ?? '').toString();
      if (!_appForeground) {
        showMessageNotification(
            title: sender, body: text.isEmpty ? 'Sent you a message' : text);
      }
      // Refresh the conversation list so previews/unread update either way.
      _fetchFriends();
    }
  }

  /// Show the "Listen together?" prompt anywhere in the app and, on accept,
  /// open the live session popup as a listener.
  Future<void> _showLiveInvite(Map<String, dynamic> event) async {
    final data = (event['data'] as Map?)?.cast<String, dynamic>();
    if (data == null) return;
    final sessionId = data['session_id']?.toString();
    if (sessionId == null) return;
    final track =
        (data['track'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final hostName = data['host_username']?.toString() ?? 'Someone';

    final accept = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withAlpha(120),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, __, ___) => _LiveInviteDialog(
        hostName: hostName,
        trackTitle: (track['title'] ?? 'a song').toString(),
      ),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1.0).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
          ),
          child: child,
        ),
      ),
    );
    if (accept != true) return;

    final token = await getToken();
    final myUserId = _myUserId;
    if (token == null || myUserId == null || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LiveSessionScreen.listener(
        token: token,
        myUserId: myUserId,
        sessionId: sessionId,
        track: track,
        peerName: hostName,
      ),
    );
  }

  Future<void> _loadUserData() async {
    try {
      final data = await ApiService().getUserData();
      final prefs = await SharedPreferences.getInstance();
      final id = data['id'];
      if (id != null) {
        _myUserId = int.tryParse(id.toString());
        _startNotifyWs();
      }
      if (data.isNotEmpty && data['username'] != null) {
        await prefs.setString('username', data['username']);
        if (mounted) setState(() => _username = data['username']);
      } else {
        if (mounted) setState(() => _username = prefs.getString('username') ?? 'User');
      }
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) setState(() => _username = prefs.getString('username') ?? 'User');
    }
  }

  // ── Friends — cache-first, refresh on network ────────────────────────────

  static const _kFriendsCache = 'cached_friends_v1';

  Future<void> _loadCachedFriends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kFriendsCache);
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      setState(() {
        _allFriends = list;
        _filteredFriends = list;
        _onlineFriendsCount = 0; // unknown until refreshed
        _isLoadingFriends = false;
      });
    } catch (_) {}
  }

  Future<void> _saveFriendsCache(List<Map<String, dynamic>> friends) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kFriendsCache, jsonEncode(friends));
    } catch (_) {}
  }

  Future<void> _fetchFriends({bool quiet = false}) async {
    try {
      final friends = await ApiService().getFriends();
      if (!mounted) return;
      // Save fresh data to cache
      await _saveFriendsCache(friends);
      setState(() {
        _allFriends = friends;
        _filteredFriends = friends;
        _onlineFriendsCount =
            friends.where((f) => f['is_online'] == true).length;
        _isCurrentUserOnline = true;
        _serverReachable = true;
        _isLoadingFriends = false;
      });
      ConnectionStatus.instance.set(true);
    } catch (_) {
      // ─── API error (401 session expired, network down, etc.) ────────────
      // IMPORTANT: do NOT overwrite _allFriends here.
      // Keep showing whatever is already loaded (from cache or last fetch)
      // so the user can read previous conversations in offline mode.
      if (mounted) {
        // Load from cache if list is empty (first launch after session expires)
        if (_allFriends.isEmpty) await _loadCachedFriends();
        setState(() {
          _isCurrentUserOnline = false;
          _serverReachable = false;
          _isLoadingFriends = false;
        });
        ConnectionStatus.instance.set(false);
      }
    }
  }

  // ── Auto-reconnect (WhatsApp style) ──────────────────────────────────────

  bool _reconnecting = false;

  Future<void> _autoReconnect() async {
    if (_reconnecting || !mounted) return;
    _reconnecting = true;
    try {
      final ok = await ApiService().setOnlineStatus(true);
      if (!mounted) return;
      if (ok) {
        final wasOffline = !_isCurrentUserOnline;
        ConnectionStatus.instance.set(true);
        setState(() {
          _isCurrentUserOnline = true;
          _serverReachable = true;
        });
        await _fetchFriends(quiet: true);
        if (wasOffline && mounted) {
          showToast(context, 'Back online',
              type: ToastType.success,
              duration: const Duration(seconds: 2));
        }
      }
    } catch (_) {}
    _reconnecting = false;
  }

  // Called when user manually taps the Offline chip
  Future<void> _goOnline() async {
    if (_isGoingOnline) return;
    setState(() => _isGoingOnline = true);
    final ok = await ApiService().setOnlineStatus(true);
    if (!mounted) return;
    setState(() => _isGoingOnline = false);
    if (ok) {
      ConnectionStatus.instance.set(true);
      setState(() {
        _isCurrentUserOnline = true;
        _serverReachable = true;
      });
      _fetchFriends(quiet: true);
      showToast(context, 'You are online', type: ToastType.success);
    } else {
      showToast(context, 'Network error — cannot connect',
          type: ToastType.error);
    }
  }

  void _filterFriends(String query) {
    final q = query.toLowerCase();
    setState(() {
      _filteredFriends = _allFriends
          .where((f) =>
              (f['username'] as String? ?? '').toLowerCase().contains(q))
          .toList();
    });
  }

  // ── Chat open/close ───────────────────────────────────────────────────────

  void openChat(Map<String, dynamic> friend) {
    setState(() {
      _activeFriendId = friend['id'].toString();
      _activeFriendName = friend['username'] ?? 'Friend';
      _activeFriendOnline = friend['is_online'] ?? false;
      _activeFriendLastSeen = friend['last_timestamp'] ?? '';
      friend['unread_count'] = 0;
    });
    ApiService().markMessagesAsReadPatch(friend['id'] as int);
  }

  void _logout() async {
    await ApiService().logoutUser();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AuthPage()),
    );
  }

  // ── Panel helpers ─────────────────────────────────────────────────────────

  // Returns an always-in-tree panel container.
  // ClipRect hides the overflow; OverflowBox lets the child render at minRenderWidth
  // even when containerWidth < minRenderWidth — preserving widget state.
  Widget _animatedPanel({
    required double containerWidth,
    required double minRenderWidth,
    required Widget child,
    Duration duration = const Duration(milliseconds: 300),
  }) {
    final visible = containerWidth > 0.5;
    // Fade out quickly when collapsing to prevent OverflowBox visual artifact
    final opacity = (containerWidth / minRenderWidth).clamp(0.0, 1.0);

    return AnimatedContainer(
      // Zero duration while the user is actively dragging the divider, so the
      // panel tracks the pointer 1:1 (no chasing/lag); the smooth 300ms tween is
      // kept for collapse/expand toggles.
      duration: duration,
      curve: Curves.easeInOut,
      width: containerWidth,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: opacity,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeIn,
          child: OverflowBox(
            minWidth: 0,
            maxWidth: max(containerWidth, minRenderWidth),
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: max(containerWidth, minRenderWidth),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _panelDecor(BuildContext context, Widget child, {bool isMusicPanel = false}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Music panel: faint waveform gradient; Chat panel: uses its own wallpaper
    final bgColor = isMusicPanel
        ? (isDark
            ? const Color(0xFF0F1B2A)   // deep navy for music
            : const Color(0xFFF5F0FF))  // lavender-white for music
        : theme.colorScheme.surface;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withAlpha(35),
            blurRadius: 10,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }

  // ── Music panel ───────────────────────────────────────────────────────────

  Widget _buildMusicHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        _PanelToggleBtn(
          isFullScreen: _isMusicFullScreen,
          onTap: () {
            setState(() {
              if (!_isMusicFullScreen) {
                _prevMusicWidth = _musicPanelWidth;
                _isMusicFullScreen = true;
                _isChatFullScreen = false;
              } else {
                _musicPanelWidth = _prevMusicWidth;
                _isMusicFullScreen = false;
              }
            });
            _saveLayoutState();
          },
        ),
        const SizedBox(width: 10),
        Icon(Icons.music_note_rounded, color: scheme.primary, size: 20),
        const SizedBox(width: 6),
        const Text(
          'Music',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildMusicContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _panelDecor(
      context,
      Column(
        children: [
          _buildMusicHeader(context),
          const SizedBox(height: 10),
          Expanded(
            child: kIsWeb
                ? WebMusicPanel(textColor: scheme.onSurface)
                : MusicControls(textColor: scheme.onSurface),
          ),
        ],
      ),
      isMusicPanel: true,
    );
  }

  // ── Chat panel ────────────────────────────────────────────────────────────

  Widget _buildChatHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    if (_activeFriendId != null) {
      return Row(
        children: [
          _PanelToggleBtn(
            isFullScreen: false,
            customIcon: Icons.arrow_back_ios_new_rounded,
            tooltip: 'Back to messages',
            onTap: () => setState(() {
              _activeFriendId = null;
              _activeFriendName = null;
              _activeFriendOnline = null;
              _activeFriendLastSeen = null;
            }),
          ),
          const SizedBox(width: 10),
          InitialsAvatar(
            name: _activeFriendName ?? '',
            radius: 17,
            isOnline: _activeFriendOnline == true,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _activeFriendName ?? '',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _activeFriendOnline == true
                      ? 'Online'
                      : _activeFriendLastSeen?.isNotEmpty == true
                          ? 'Last seen ${formatLastSeen(_activeFriendLastSeen!)}'
                          : 'Offline',
                  style: TextStyle(
                    fontSize: 11,
                    color: _activeFriendOnline == true
                        ? Colors.green
                        : textColor.withAlpha(130),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // On phones there's no split to expand, so the ⤢ toggle is meaningless —
    // hide it and let the "Messages" title lead the header.
    final bool phone = MediaQuery.of(context).size.width < 640;

    return Row(
      children: [
        if (!phone) ...[
          _PanelToggleBtn(
            isFullScreen: _isChatFullScreen,
            onTap: () {
              setState(() {
                if (!_isChatFullScreen) {
                  _prevMusicWidth = _musicPanelWidth;
                  _isChatFullScreen = true;
                  _isMusicFullScreen = false;
                } else {
                  _musicPanelWidth = _prevMusicWidth;
                  _isChatFullScreen = false;
                }
              });
              _saveLayoutState();
            },
          ),
          const SizedBox(width: 10),
        ],
        Icon(Icons.chat_bubble_outline_rounded,
            color: scheme.primary, size: 20),
        const SizedBox(width: 6),
        const Text(
          'Messages',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const Spacer(),
        // Online/offline badge — reads the SAME server-side signal as the
        // footer status dot (_serverReachable), so the two never disagree.
        if (!_serverReachable)
          Tooltip(
            message: 'You are offline — tap to go online',
            child: GestureDetector(
              onTap: _goOnline,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _isGoingOnline
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onErrorContainer,
                            ),
                          )
                        : Icon(Icons.wifi_off_rounded,
                            size: 13,
                            color: scheme.onErrorContainer),
                    const SizedBox(width: 4),
                    Text(
                      _isGoingOnline ? 'Connecting…' : 'Offline',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChatContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    return _panelDecor(
      context,
      Column(
        children: [
          _buildChatHeader(context),
          const SizedBox(height: 10),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.04, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: _activeFriendId != null
                  ? ChatPage(
                      key: ValueKey(_activeFriendId),
                      friendId: int.parse(_activeFriendId!),
                      friendName: _activeFriendName!,
                      textColor: textColor,
                      showAppBar: false,
                      onFriendOnlineStatusChanged: (online, lastSeen) {
                        if (mounted) {
                          setState(() {
                            _activeFriendOnline = online;
                            _activeFriendLastSeen = lastSeen;
                          });
                        }
                      },
                    )
                  : _buildFriendList(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    return Column(
      key: const ValueKey('friendList'),
      children: [
        TextField(
          onChanged: _filterFriends,
          decoration: InputDecoration(
            hintText: 'Search messages…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _isLoadingFriends
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _onPullToRefresh,
                  // AlwaysScrollable → the list can overscroll (and so trigger
                  // the pull gesture) even when it's short or empty.
                  child: _filteredFriends.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 110),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.chat_bubble_outline,
                                      size: 48,
                                      color: scheme.outlineVariant),
                                  const SizedBox(height: 10),
                                  Text('No conversations yet',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant)),
                                  const SizedBox(height: 6),
                                  Text('Pull down to refresh',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: scheme.onSurfaceVariant
                                              .withAlpha(150))),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _filteredFriends.length,
                          separatorBuilder: (ctx, i) => Divider(
                            height: 1,
                            indent: 68,
                            color: scheme.outlineVariant.withAlpha(70),
                          ),
                          itemBuilder: (_, i) => _buildFriendTile(
                              _filteredFriends[i], textColor, scheme),
                        ),
                ),
        ),
      ],
    );
  }

  Widget _buildFriendTile(
      Map<String, dynamic> f, Color textColor, ColorScheme scheme) {
    final name = f['username'] as String? ?? '';
    final isOnline = f['is_online'] == true;
    final lastMsg = f['last_message'] as String? ?? '';
    final lastTime = f['last_timestamp'] as String? ?? '';
    final unread = (f['unread_count'] as num?)?.toInt() ?? 0;
    final hasUnread = unread > 0;

    return InkWell(
      onTap: () => openChat(f),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            InitialsAvatar(name: name, radius: 22, isOnline: isOnline),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight:
                          hasUnread ? FontWeight.bold : FontWeight.w500,
                      fontSize: 14,
                      color: textColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lastMsg,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: hasUnread
                          ? textColor.withAlpha(200)
                          : textColor.withAlpha(110),
                      fontWeight: hasUnread
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatFriendTimestamp(lastTime),
                  style: TextStyle(
                    fontSize: 11,
                    color: hasUnread
                        ? scheme.primary
                        : textColor.withAlpha(110),
                    fontWeight: hasUnread
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                if (hasUnread) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Draggable divider ─────────────────────────────────────────────────────

  Widget _buildDivider(double totalWidth) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => setState(() => _isDragging = true),
      onHorizontalDragEnd: (_) {
        setState(() => _isDragging = false);
        _saveLayoutState();
      },
      onHorizontalDragUpdate: (d) {
        setState(() {
          _musicPanelWidth = (_musicPanelWidth + d.delta.dx)
              .clamp(180.0, totalWidth - 180.0);
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 14,
          color: _isDragging
              ? scheme.primary.withAlpha(30)
              : Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _isDragging ? 4 : 3,
              height: _isDragging ? 60 : 40,
              decoration: BoxDecoration(
                color: _isDragging
                    ? scheme.primary
                    : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────────

  /// Pull-to-refresh handler.
  /// On web this performs a real full page reload so the newest deployed
  /// build is fetched. On native it just re-fetches the conversation list.
  Future<void> _onPullToRefresh() async {
    if (kIsWeb) {
      if (mounted) {
        showToast(context, 'Refreshing…', type: ToastType.info);
      }
      // Small delay so the pull animation settles before the page navigates.
      await Future.delayed(const Duration(milliseconds: 350));
      hardReloadApp();
      // The page is now reloading; keep the spinner until it does.
      await Future.delayed(const Duration(seconds: 2));
      return;
    }
    await _fetchFriends();
  }

  // ── Phone layout ───────────────────────────────────────────────────────────
  // Chat is the primary full-width surface. The music player stays mounted the
  // whole time (so audio never stops) but lives off-screen below; a slim
  // now-playing bar sits above the footer and expands the player on tap.

  Widget _buildPhoneBody(BuildContext context, BoxConstraints constraints) {
    return ListenableBuilder(
      // Rebuild the bar/sheet visibility when the track or live session changes.
      listenable: Listenable.merge([nowPlayingNotifier, liveSessionNotifier]),
      builder: (context, _) {
        final hasTrack = nowPlayingNotifier.track.isNotEmpty;
        final live = liveSessionNotifier.active;
        // The now-playing bar is for the user's OWN music (the live session has
        // its own audio and is surfaced by the top banner). Show it when a
        // personal track is loaded and the user hasn't dismissed it; otherwise
        // a small floating music button stands in as the entry point.
        final barVisible = hasTrack && !_barDismissed;
        // Reserve enough chat space for the now-playing bar (grab handle +
        // title + progress row).
        final barSpace = 84.0;
        final h = constraints.maxHeight;

        return Stack(
          children: [
            // Chat surface — full width, leaving room only for the full bar.
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(
                    bottom: (_playerExpanded || !barVisible) ? 0 : barSpace),
                child: _buildChatContent(context),
              ),
            ),

            // The one, always-mounted player. Off-screen (top = h) when
            // collapsed → State (and the AudioPlayer) stay alive; slides to
            // the top when expanded.
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              left: 0,
              right: 0,
              height: h,
              top: _playerExpanded ? 0 : h,
              child: _buildPhonePlayerSheet(context),
            ),

            // Collapsed now-playing bar (hidden while expanded or dismissed).
            if (barVisible)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                bottom: _playerExpanded ? -barSpace : 0,
                child: _buildNowPlayingBar(context),
              ),

            // Floating music button — the entry point when the bar is hidden.
            // Draggable; defaults to bottom-right (above the chat input so it
            // never covers the send button).
            if (!barVisible && !_playerExpanded)
              _buildDraggableFab(context, constraints, live),
          ],
        );
      },
    );
  }

  Widget _buildPhonePlayerSheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _panelDecor(
      context,
      Column(
        children: [
          // Grab handle + header. Swiping DOWN anywhere on this handle/header
          // area minimises the panel (in addition to the chevron button), and a
          // tap on the handle collapses it too.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _playerExpanded = false),
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 120) {
                setState(() => _playerExpanded = false);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Draggable grab handle — the swipe-down affordance.
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withAlpha(90),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Row(
                  children: [
                    _PanelToggleBtn(
                      isFullScreen: false,
                      customIcon: Icons.keyboard_arrow_down_rounded,
                      onTap: () => setState(() => _playerExpanded = false),
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.music_note_rounded,
                        color: scheme.primary, size: 20),
                    const SizedBox(width: 6),
                    const Text('Now Playing',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                    const Spacer(),
                    // Live badge in the sheet header too, for context.
                    if (liveSessionNotifier.active) _liveChip(context),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: kIsWeb
                ? WebMusicPanel(textColor: scheme.onSurface)
                : MusicControls(textColor: scheme.onSurface),
          ),
        ],
      ),
      isMusicPanel: true,
    );
  }

  Widget _liveChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = liveSessionNotifier.peer;
    final asHost = liveSessionNotifier.asHost;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pulsing dot connotes a live stream.
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary,
              boxShadow: [
                BoxShadow(
                    color: scheme.primary.withAlpha(160),
                    blurRadius: 6,
                    spreadRadius: 1),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              asHost ? 'Streaming to $peer' : 'Listening with $peer',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── Live session banner (both layouts) ──────────────────────────────────────
  Widget _buildLiveBanner(BuildContext context) {
    return ListenableBuilder(
      listenable: liveSessionNotifier,
      builder: (context, _) {
        if (!liveSessionNotifier.active) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final peer = liveSessionNotifier.peer;
        final host = liveSessionNotifier.asHost;
        return Material(
          color: scheme.primary,
          child: InkWell(
            onTap: _reopenLiveSession,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
              child: Row(
                children: [
                  // Pulsing live dot.
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                            color: Colors.white.withAlpha(160),
                            blurRadius: 6,
                            spreadRadius: 1),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.headphones_rounded,
                      size: 17, color: Colors.white.withAlpha(230)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      host
                          ? 'Live · streaming to $peer'
                          : 'Live · listening with $peer',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Text('Tap to open',
                      style: TextStyle(color: Colors.white70, fontSize: 11)),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _endLiveSession,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(host ? 'End' : 'Leave',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _reopenLiveSession() {
    if (activeLiveSession == null) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LiveSessionScreen.resume(),
    );
  }

  Future<void> _endLiveSession() async {
    await endActiveLiveSession();
    liveSessionNotifier.stop();
    if (mounted) setState(() {});
  }

  // Positions the music FAB (default bottom-right) and makes it draggable.
  Widget _buildDraggableFab(
      BuildContext context, BoxConstraints constraints, bool live) {
    const fabSize = 52.0;
    const margin = 14.0;
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;
    // Default anchor: bottom-right, above the chat input.
    final defaultLeft = w - margin - fabSize;
    final defaultTop = h - 78 - fabSize;
    final left = _fabOffset?.dx ?? defaultLeft;
    final top = _fabOffset?.dy ?? defaultTop;

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanStart: (_) {
          // Seed the offset from wherever it's currently anchored.
          _fabOffset ??= Offset(defaultLeft, defaultTop);
        },
        onPanUpdate: (d) {
          setState(() {
            final cur = _fabOffset ?? Offset(defaultLeft, defaultTop);
            final nx = (cur.dx + d.delta.dx).clamp(margin, w - fabSize - margin);
            final ny = (cur.dy + d.delta.dy)
                .clamp(margin, h - fabSize - margin);
            _fabOffset = Offset(nx.toDouble(), ny.toDouble());
          });
        },
        child: _buildMusicFab(context, live),
      ),
    );
  }

  Widget _buildMusicFab(BuildContext context, bool live) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() {
        // Bring the bar back and open the player so the user can start music.
        _barDismissed = false;
        _playerExpanded = true;
      }),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primary,
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withAlpha(120),
              blurRadius: 14,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            ),
          ],
          border: live
              ? Border.all(color: Colors.white.withAlpha(220), width: 2)
              : null,
        ),
        child: const Icon(Icons.music_note_rounded,
            color: Colors.white, size: 26),
      ),
    );
  }

  Widget _buildNowPlayingBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final np = nowPlayingNotifier;

    return GestureDetector(
      // Tap anywhere (except the play button) to expand; swipe up too.
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _playerExpanded = true),
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < 0) {
          setState(() => _playerExpanded = true);
        }
      },
      child: Container(
        // Flush, full-width strip that sits directly on the footer so the two
        // read as ONE continuous bottom module (not a floating card above a
        // separate bar). Rounded only at the top; a soft upward shadow lifts the
        // whole unit off the chat above.
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(
            top: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(28),
              blurRadius: 14,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grab handle — caps the module and signals swipe-up to expand.
            Container(
              margin: const EdgeInsets.only(top: 7, bottom: 1),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withAlpha(70),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
              child: Row(
                children: [
                  // Mini disc / art placeholder — glows when playing.
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        scheme.primary.withAlpha(np.playing ? 110 : 60),
                        scheme.surfaceContainerHighest,
                      ]),
                      boxShadow: np.playing
                          ? [
                              BoxShadow(
                                color: scheme.primary.withAlpha(90),
                                blurRadius: 12,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                      np.playing
                          ? Icons.graphic_eq_rounded
                          : Icons.music_note_rounded,
                      size: 19,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Title (auto-scrolls if long) sits directly above a slim
                  // seekable progress bar — the footer is now status-only.
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 17,
                          child: _ScrollingText(
                            text: np.track.isEmpty ? 'No track' : np.track,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        _barProgress(context),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  // Quick favourite toggle for the current track.
                  ValueListenableBuilder<bool>(
                    valueListenable: favoriteNotifier,
                    builder: (_, fav, __) => GestureDetector(
                      onTap: () => playbackBus.onToggleFavorite?.call(),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Icon(
                          fav
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 20,
                          color: fav
                              ? scheme.primary
                              : scheme.onSurface.withAlpha(150),
                        ),
                      ),
                    ),
                  ),
                  // Previous / Play / Next — drive the mounted player via the bus.
                  _barBtn(
                    context,
                    Icons.skip_previous_rounded,
                    () => playbackBus.onPrev?.call(),
                    size: 22,
                  ),
                  _barBtn(
                    context,
                    np.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    () => playbackBus.onToggle?.call(),
                    size: 26,
                    filled: true,
                  ),
                  _barBtn(
                    context,
                    Icons.skip_next_rounded,
                    () => playbackBus.onNext?.call(),
                    size: 22,
                  ),
                  const SizedBox(width: 2),
                  // Close the bar entirely → collapses to the floating button,
                  // freshly reset to the bottom-right anchor.
                  GestureDetector(
                    onTap: () => setState(() {
                      _barDismissed = true;
                      _fabOffset = null;
                    }),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 18, color: scheme.onSurface.withAlpha(140)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Seek row for the now-playing bar: elapsed · slim seekable bar · remaining.
  // Driven by playClockNotifier so only this row rebuilds each tick, not the
  // chat surface. Horizontal drag / tap scrubs; taps bubble up to expand.
  Widget _barProgress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timeStyle = TextStyle(
      fontSize: 9.5,
      height: 1.0,
      color: scheme.onSurface.withAlpha(150),
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ValueListenableBuilder<PlayClock>(
      valueListenable: playClockNotifier,
      builder: (_, clock, __) {
        final durMs = clock.duration.inMilliseconds;
        final frac =
            durMs > 0 ? (clock.position.inMilliseconds / durMs).clamp(0.0, 1.0) : 0.0;
        var remaining = clock.duration - clock.position;
        if (remaining < Duration.zero) remaining = Duration.zero;
        return Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(_fmtClock(clock.position), style: timeStyle),
            ),
            const SizedBox(width: 6),
            Expanded(child: _seekTrack(context, frac)),
            const SizedBox(width: 6),
            SizedBox(
              width: 34,
              child: Text('-${_fmtClock(remaining)}',
                  style: timeStyle, textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }

  // The draggable track itself (bar + gradient fill). [frac] is 0..1.
  Widget _seekTrack(BuildContext context, double frac) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth;
        void seekAt(double dx) {
          if (w <= 0) return;
          playbackBus.onSeekFraction?.call((dx / w).clamp(0.0, 1.0));
        }

        final f = frac.clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => seekAt(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekAt(d.localPosition.dx),
          child: SizedBox(
            height: 22,
            child: Center(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withAlpha(40),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: f == 0 ? 0.001 : f,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          Color.lerp(scheme.primary, Colors.white, 0.25)!,
                          scheme.primary,
                        ]),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // mm:ss (or h:mm:ss for long tracks).
  String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
    return '$m:$s';
  }

  Widget _barBtn(BuildContext context, IconData icon, VoidCallback onTap,
      {double size = 22, bool filled = false}) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: filled ? 40 : 34,
        height: filled ? 40 : 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? scheme.primary : Colors.transparent,
        ),
        child: Icon(
          icon,
          size: size,
          color: filled ? Colors.white : scheme.onSurface.withAlpha(200),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: nowPlayingNotifier,
      builder: (context, _) {
        // Pure status strip now — no track info (that lives in the bar above).
        final statusWord = _isDiscovering
            ? 'Connecting…'
            : (_serverReachable ? 'Connected' : 'Offline');
        return Container(
          height: 44,
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // ── Left: server / connection status (tap to configure) ───────
              Tooltip(
                message: _serverReachable
                    ? 'Connected to ${(kIsWeb || kReleaseMode) ? _serverIp : '$_serverIp:${AppConfig.port}'}\nLong-press to reconfigure'
                    : 'Not connected — tap to configure',
                child: GestureDetector(
                  onTap: _showServerSettings,
                  onLongPress: () => _discoverServer(forceReset: true),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _isDiscovering
                          ? SizedBox(
                              width: 11,
                              height: 11,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: scheme.onSurface.withAlpha(160),
                              ),
                            )
                          : AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _serverReachable
                                    ? Colors.green
                                    : Colors.red,
                                boxShadow: [
                                  BoxShadow(
                                    color: (_serverReachable
                                            ? Colors.green
                                            : Colors.red)
                                        .withAlpha(150),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                      const SizedBox(width: 7),
                      Text(
                        statusWord,
                        style: TextStyle(
                          color: scheme.onSurface.withAlpha(180),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(),

              // ── Right: online friends + current user ──────────────────────
              if (_onlineFriendsCount > 0) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  '$_onlineFriendsCount online',
                  style: TextStyle(
                    color: scheme.onSurface.withAlpha(170),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 1,
                  height: 16,
                  color: scheme.outlineVariant.withAlpha(90),
                ),
                const SizedBox(width: 10),
              ],
              Icon(Icons.person_rounded,
                  size: 14,
                  color: scheme.onSurface.withAlpha(160)),
              const SizedBox(width: 4),
              Text(
                // On phones, show just the first name so a full "First Last"
                // doesn't eat the footer's horizontal space.
                MediaQuery.of(context).size.width < 640
                    ? _username.trim().split(RegExp(r'\s+')).first
                    : _username,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final scheme = Theme.of(context).colorScheme;

    // Back / swipe-back should step DOWN the view stack (close an open chat →
    // collapse a full-screen panel → then exit), not jump off the app.
    final canLeave = !(_isMusicFullScreen ||
        _isChatFullScreen ||
        _playerExpanded ||
        _activeFriendId != null);

    // Listener sits above the whole app and is passive (it never consumes
    // events), so every touch also nudges the session back online if needed.
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (_playerExpanded) {
            // Collapse the slide-up player back to the mini bar first.
            _playerExpanded = false;
          } else if (_activeFriendId != null) {
            // Close the open conversation → back to the messages list.
            _activeFriendId = null;
            _activeFriendName = null;
            _activeFriendOnline = null;
            _activeFriendLastSeen = null;
          } else {
            // Collapse a full-screen panel back to the split view.
            _isMusicFullScreen = false;
            _isChatFullScreen = false;
            _musicPanelWidth = _prevMusicWidth;
          }
        });
        _saveLayoutState();
      },
      child: Listener(
        onPointerDown: (_) => _onUserActivity(),
        child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: scheme.surfaceContainerHighest,
        titleSpacing: 14,
        title: Row(
          children: [
            Text(
              'Aluta',
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.isDarkMode
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              color: scheme.onSurface,
            ),
            tooltip: themeProvider.isDarkMode
                ? 'Switch to light mode'
                : 'Switch to dark mode',
            onPressed: () =>
                themeProvider.toggleTheme(!themeProvider.isDarkMode),
          ),
          IconButton(
            icon: Icon(Icons.shield_outlined, color: scheme.onSurface),
            tooltip: 'Legal & About',
            onPressed: () => showLegalMenu(context),
          ),
          IconButton(
            icon: _LogoutGlyph(color: scheme.onSurface.withAlpha(210)),
            onPressed: _logout,
            tooltip: 'Sign out',
          ),
        ],
      ),
      // ── Body ───────────────────────────────────────────────────────────
      // A persistent live-session banner (both layouts) sits above everything
      // when a "Listen Together" session is minimised, so the user can keep
      // chatting and jump back in from anywhere.
      body: Column(
        children: [
          _buildLiveBanner(context),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final total = constraints.maxWidth;

                if (total < 640) {
                  return _buildPhoneBody(context, constraints);
                }

          // Compute widths for each mode
          double musicW, chatW, divW;
          final bool showDiv;

          if (_isMusicFullScreen) {
            musicW = total;
            chatW = 0;
            divW = 0;
            showDiv = false;
          } else if (_isChatFullScreen) {
            musicW = 0;
            chatW = total;
            divW = 0;
            showDiv = false;
          } else {
            _musicPanelWidth =
                _musicPanelWidth.clamp(180.0, total - 194.0);
            musicW = _musicPanelWidth;
            divW = 14;
            chatW = total - musicW - divW;
            showDiv = true;
          }

          // Chat opacity: fades when collapsing so OverflowBox content
          // doesn't visually bleed. Music panel uses _animatedPanel which
          // already handles its own fade + clip.
          // IMPORTANT: chat panel uses Expanded (not a fixed width) so the
          // Row never overflows — Expanded always fills exactly what's left.
          final chatOpacity = (chatW / 220.0).clamp(0.0, 1.0);

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Music panel ─────────────────────────────────────────────
              _animatedPanel(
                containerWidth: musicW,
                minRenderWidth: 220,
                duration: _isDragging
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                child: _buildMusicContent(context),
              ),

              // ── Draggable divider ────────────────────────────────────────
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                width: showDiv ? divW : 0,
                child: showDiv
                    ? _buildDivider(total)
                    : const SizedBox.shrink(),
              ),

              // ── Chat panel — Expanded prevents any Row overflow ──────────
              Expanded(
                child: AnimatedOpacity(
                  opacity: chatOpacity,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeIn,
                  child: IgnorePointer(
                    ignoring: chatW < 1,
                    child: _buildChatContent(context),
                  ),
                ),
              ),
            ],
          );
                },
              ),
            ),
          ],
        ),
      bottomNavigationBar: _buildFooter(context),
      ),
      ),
    );
  }
}

// ─── Small toggle button ───────────────────────────────────────────────────

class _PanelToggleBtn extends StatelessWidget {
  final bool isFullScreen;
  final VoidCallback onTap;
  final IconData? customIcon;
  final String? tooltip;

  const _PanelToggleBtn({
    required this.isFullScreen,
    required this.onTap,
    this.customIcon,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = tooltip ??
        (customIcon == Icons.keyboard_arrow_down_rounded
            ? 'Minimize'
            : (isFullScreen ? 'Exit full screen' : 'Full screen'));
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: isFullScreen
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            customIcon ??
                (isFullScreen
                    ? Icons.close_fullscreen_rounded
                    : Icons.open_in_full_rounded),
            size: 17,
            color:
                isFullScreen ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A single-line label that gently auto-scrolls (marquee) ONLY when the text is
/// too wide to fit; short titles render as a plain static label. Used by the
/// now-playing bar so long song filenames stay fully readable without stealing
/// vertical space.
class _ScrollingText extends StatelessWidget {
  const _ScrollingText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final overflows = tp.width > constraints.maxWidth;
        if (!overflows) {
          return Text(text,
              style: style, maxLines: 1, overflow: TextOverflow.clip);
        }
        return Marquee(
          text: text,
          style: style,
          blankSpace: 46,
          velocity: 26,
          pauseAfterRound: const Duration(seconds: 2),
          fadingEdgeStartFraction: 0.06,
          fadingEdgeEndFraction: 0.12,
          showFadingOnlyWhenScrolling: true,
        );
      },
    );
  }
}

/// A refined, thin-stroke logout mark — a rounded door frame with an arrow
/// gliding out through the opening. Lighter and more elegant than the stock
/// filled Material "exit" glyph.
class _LogoutGlyph extends StatelessWidget {
  const _LogoutGlyph({required this.color, this.size = 22});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _LogoutPainter(color),
      );
}

class _LogoutPainter extends CustomPainter {
  _LogoutPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.15 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Door frame: a rounded "[" open on the right.
    final frame = Path()
      ..moveTo(14 * s, 4 * s)
      ..lineTo(8 * s, 4 * s)
      ..cubicTo(6.9 * s, 4 * s, 6 * s, 4.9 * s, 6 * s, 6 * s)
      ..lineTo(6 * s, 18 * s)
      ..cubicTo(6 * s, 19.1 * s, 6.9 * s, 20 * s, 8 * s, 20 * s)
      ..lineTo(14 * s, 20 * s);
    canvas.drawPath(frame, stroke);

    // Arrow gliding out through the opening.
    canvas.drawLine(Offset(11 * s, 12 * s), Offset(20 * s, 12 * s), stroke);
    final head = Path()
      ..moveTo(16.5 * s, 8.5 * s)
      ..lineTo(20 * s, 12 * s)
      ..lineTo(16.5 * s, 15.5 * s);
    canvas.drawPath(head, stroke);
  }

  @override
  bool shouldRepaint(covariant _LogoutPainter old) => old.color != color;
}

/// Polished "Listen together?" invitation — a centered brand card with a
/// headphones badge, the host's avatar + name, the track on a pill, and clear
/// Decline / Join actions. Pops `true` on Join, `false`/null otherwise.
class _LiveInviteDialog extends StatelessWidget {
  const _LiveInviteDialog({required this.hostName, required this.trackTitle});

  final String hostName;
  final String trackTitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial =
        hostName.trim().isNotEmpty ? hostName.trim()[0].toUpperCase() : '?';
    // Tidy a messy filename-title a little for display.
    var title = trackTitle.trim();
    if (title.startsWith('- ')) title = title.substring(2).trim();
    if (title.isEmpty) title = 'a song';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: scheme.outlineVariant.withAlpha(70)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(80),
                    blurRadius: 34,
                    offset: const Offset(0, 14),
                  ),
                  BoxShadow(
                    color: scheme.primary.withAlpha(40),
                    blurRadius: 26,
                    spreadRadius: -6,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Headphones badge with a soft brand halo.
                  Center(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          scheme.primary.withAlpha(60),
                          scheme.primary.withAlpha(18),
                        ]),
                        border:
                            Border.all(color: scheme.primary.withAlpha(90)),
                      ),
                      child: Icon(Icons.headphones_rounded,
                          size: 30, color: scheme.primary),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'Listen together?',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Host row.
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          initial,
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: TextStyle(
                                fontSize: 13.5,
                                color: scheme.onSurface.withAlpha(220),
                                height: 1.3),
                            children: [
                              TextSpan(
                                text: hostName,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const TextSpan(
                                  text: ' wants to listen with you, live.'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Track pill.
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withAlpha(140),
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: scheme.outlineVariant.withAlpha(70)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.music_note_rounded,
                            size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Actions.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                        ),
                        child: const Text('Decline'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.headphones_rounded, size: 18),
                        label: const Text('Join'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
