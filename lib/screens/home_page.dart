import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
// Hide intl's TextDirection so TextPainter/TextDirection.ltr resolve to dart:ui's.
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:url_launcher/url_launcher.dart';
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
import 'group_screens.dart';
import 'user_profile_sheet.dart';
import 'device_link.dart';
import 'call_reliability_screen.dart';
import 'music/song_identifier.dart' show showSongIdentifier;
import 'profile_screen.dart';
import '../utils/popup_shell.dart';
import 'api_service.dart';
import 'websocket_manager.dart';
import 'live_session_screen.dart';
import 'legal_screen.dart';
import '../services/live_session_service.dart'
    show activeLiveSession, endActiveLiveSession;
import '../services/notif_service.dart';
import '../services/fcm_service.dart';
import '../services/share_inbox.dart';
import '../services/contact_names.dart';
import '../utils/net_image.dart';
import 'token_helper.dart';
import '../utils/avatar_widget.dart';
import '../utils/app_config.dart';
import '../services/call_service.dart';
import 'call_screen.dart';
import '../main.dart' show navigatorKey;
import '../utils/time_utils.dart';
// Prefixed: this file also imports package:provider, which exports colliding
// names (Consumer, Provider, ChangeNotifierProvider). `rp.` keeps them distinct.
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import '../state/playback_state.dart';
import '../state/unread_state.dart';
import '../state/presence_state.dart';

part 'home/home_playback.dart'; // playback bus + per-tick value-notifiers
part 'home/home_widgets.dart'; // panel toggle, scrolling text, logout glyph, live-invite dialog

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


// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends rp.ConsumerStatefulWidget {
  static const String routeName = '/home';
  const HomePage({super.key});

  static HomePageState? of(BuildContext context) =>
      context.findAncestorStateOfType<HomePageState>();

  @override
  rp.ConsumerState<HomePage> createState() => HomePageState();
}

class HomePageState extends rp.ConsumerState<HomePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  String _username = '';
  String? _myAvatar;
  // Online-friends count + per-friend dots now come from presenceProvider.
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
  // Group conversations the user belongs to. They sit at the TOP of the same
  // list as DMs, so a created/joined group appears right alongside friends.
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _filteredGroups = [];
  bool _isLoadingFriends = false;

  // Images shared into Aluta from another app, waiting to be handed to the chat
  // the user next taps (screenshot-share flow). Null when nothing is pending.
  List<String>? _shareToSend;

  // ── Layout state ──────────────────────────────────────────────────────────
  double _musicPanelWidth = 280;
  bool _isMusicFullScreen = false;
  bool _isChatFullScreen = false;
  double _prevMusicWidth = 280;
  bool _isDragging = false;
  // Phone-only: whether the slide-up full player sheet is expanded.
  bool _playerExpanded = false;
  // Where the full panel was opened FROM: true = the footer pill (collapsed
  // state), false = the now-playing bar. Closing returns to whichever it
  // emerged from, so the UI genies back into its origin.
  bool _panelFromPill = false;
  // Phone-only: user dismissed the now-playing bar → collapses to a small
  // pill docked in the footer centre that reopens it.
  bool _barDismissed = false;

  // Drives the app-wide playlist drawer's slide/fade (hosted below the active
  // header — see _playlistDrawerHost).
  late final AnimationController _playlistDrawerCtrl;
  // Passive swipe tracking for the playlist drawer (a Listener, so it works even
  // over the swipe-to-delete rows that would otherwise eat a GestureDetector).
  int? _drawerPointer;
  double _drawerSwipeDx = 0;
  double _drawerSwipeDy = 0;

  // ── Chat state ────────────────────────────────────────────────────────────
  String? _activeFriendId;
  // When a GROUP is open, its conversation map lives here and the chat panel
  // renders it (instead of a DM) — so groups sit in the chat panel on desktop,
  // never taking over the whole window.
  Map<String, dynamic>? _activeGroup;
  String? _activeFriendName;
  bool? _activeFriendOnline;
  String? _activeFriendLastSeen;
  String? _activeFriendPhone;
  String? _activeFriendAvatar;
  // Chat header: tap the friend's avatar to expand their photo above the thread.
  bool _avatarExpanded = false;
  String _apiBase = '';

  // Build a full avatar URL from a stored relative ref (/attachments/<id>).
  String? _avatarFull(dynamic rel) {
    final s = rel?.toString() ?? '';
    if (s.isEmpty) return null;
    return s.startsWith('http') ? s : '$_apiBase$s';
  }

  Timer? _refreshTimer;
  Timer? _heartbeatTimer;
  StreamSubscription? _connectivitySub;
  // Throttles presence pings triggered by user interaction.
  DateTime _lastActivityPing = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Drives the playlist drawer's smooth slide/fade in & out. MusicControls
    // flips playlistDrawerBus.isOpen; we animate the host from that.
    _playlistDrawerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      reverseDuration: const Duration(milliseconds: 260),
    );
    playlistDrawerBus.isOpen.addListener(_onPlaylistDrawerToggled);
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _apiBase = b);
    });
    // React to the shared connection status so the footer dot / header badge
    // update even when the change originates elsewhere (e.g. the chat page).
    ConnectionStatus.instance.online.addListener(_onGlobalConnChanged);
    // When the token genuinely expires (server returns 401/403), sign out to a
    // fresh login instead of leaving the user stuck offline.
    SessionEvents.instance.expired.addListener(_onSessionExpired);
    // Screenshot / photo shared into Aluta → surface the "pick a chat to send"
    // banner and react if one arrives while Home is already open.
    ShareInbox.instance.addListener(_onSharePending);
    // Warm the phonebook name map (silent — only if contacts already granted) so
    // the friend list, DM header and group headers can show your SAVED names for
    // known numbers. Repaint once it's ready so names resolve on first view.
    ContactNames.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _loadUserData();
    _loadCachedFriends();    // show cached list instantly (no spinner flash)
    _fetchFriends();          // then refresh from network
    _loadLayoutState();
    _discoverServer();

    // Register this device for push notifications (Android/iOS; no-op else) so
    // messages/calls wake the phone when the app is backgrounded or closed. The
    // authed home only mounts after login, so this doubles as "register on
    // login" and re-registers on every relaunch (token can rotate).
    FcmService.instance.registerToken();

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

    // Nudge users who have no phone number saved to add one (so friends can
    // discover them via contacts). Shown after the first frame; dismissible.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptForPhone());
  }

  Future<void> _maybePromptForPhone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('phone_prompt_dismissed') == true) return;
      final me = await ApiService().getUserData();
      final phone = (me['phone'] ?? '').toString().trim();
      if (phone.isNotEmpty) return; // already has a number
      if (!mounted) return;
      _showAddPhoneDialog();
    } catch (_) {/* never block the app on this */}
  }

  void _showAddPhoneDialog() {
    final ctrl = TextEditingController();
    bool saving = false;
    showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setLocal) {
          final scheme = Theme.of(dctx).colorScheme;
          Future<void> dismiss() async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('phone_prompt_dismissed', true);
            if (dctx.mounted) Navigator.pop(dctx);
          }

          Future<void> save() async {
            if (ctrl.text.trim().isEmpty) {
              showToast(context, 'Enter your phone number.',
                  type: ToastType.error);
              return;
            }
            setLocal(() => saving = true);
            final res =
                await ApiService().updateProfile(phone: ctrl.text.trim());
            if (res['success'] == true) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('phone_prompt_dismissed', true);
              if (dctx.mounted) Navigator.pop(dctx);
              if (mounted) {
                showToast(context, 'Saved — friends can now find you.',
                    type: ToastType.success);
              }
            } else {
              setLocal(() => saving = false);
              if (mounted) {
                showToast(context,
                    (res['message'] ?? 'Could not save your number.').toString(),
                    type: ToastType.error);
              }
            }
          }

          return AlertDialog(
            title: const Text('Add your phone number'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'So friends who have your number can find you on Aluta. '
                  'It stays private — only used for contact matching.',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                IntlPhoneField(
                  initialCountryCode: 'TZ',
                  decoration: InputDecoration(
                    labelText: 'Phone number',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (p) => ctrl.text = p.completeNumber,
                  invalidNumberMessage: 'Enter a valid phone number',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : dismiss,
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: saving ? null : save,
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectionStatus.instance.online.removeListener(_onGlobalConnChanged);
    SessionEvents.instance.expired.removeListener(_onSessionExpired);
    ShareInbox.instance.removeListener(_onSharePending);
    playlistDrawerBus.isOpen.removeListener(_onPlaylistDrawerToggled);
    _playlistDrawerCtrl.dispose();
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    _connectivitySub?.cancel();
    _notifyWs?.close();
    super.dispose();
  }

  // Animate the playlist drawer in/out whenever its open-state flips.
  void _onPlaylistDrawerToggled() {
    if (!mounted) return;
    if (playlistDrawerBus.isOpen.value) {
      _playlistDrawerCtrl.forward();
    } else {
      _playlistDrawerCtrl.reverse();
    }
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

    // Wire the voice-call service to this always-on socket: it sends call
    // signaling out through here, and asks us to surface the call screen.
    CallService.instance.sendSignal = (msg) => _notifyWs?.sendEvent(msg);
    CallService.instance.onShowCallUI = _openCallScreen;
  }

  bool _callScreenOpen = false;

  /// Show the full-screen call UI (for an incoming ring or an outgoing call).
  void _openCallScreen() {
    if (_callScreenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _callScreenOpen = true;
    nav
        .push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const CallScreen(),
        ))
        .then((_) => _callScreenOpen = false);
  }

  void _handleNotification(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type']?.toString();
    // Aluta voice-call signaling — hand every call_* event to the call service.
    // (call_offer makes it ask us to open the ring screen via onShowCallUI.)
    if (type != null && type.startsWith('call_')) {
      CallService.instance.onSignal(event);
      return;
    }
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
      // Mark delivered the moment our device receives the message — on ANY
      // screen — so the sender's tick turns to a gray double without us having
      // to open the chat. (Read is only marked when we actually view it.)
      // NOTE: dropped during an earlier home_page rebuild, which regressed the
      // gray double-tick — keep this here.
      final mid = data['id'];
      if (mid != null &&
          data['receiver_id']?.toString() == _myUserId?.toString() &&
          data['delivered'] == false) {
        ApiService().markMessageAsDelivered(mid);
      }
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
      // Badge the sender immediately (unless their chat is open) — the fetch
      // below reconciles to the server's authoritative count a moment later.
      final senderId = (senderObj?['id'] as num?)?.toInt() ??
          (data['sender_id'] as num?)?.toInt();
      if (senderId != null && senderId.toString() != _activeFriendId) {
        ref.read(unreadProvider.notifier).bump(senderId);
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
      pageBuilder: (_, _, _) => _LiveInviteDialog(
        hostName: hostName,
        trackTitle: (track['title'] ?? 'a song').toString(),
      ),
      transitionBuilder: (_, anim, _, child) => FadeTransition(
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
      _myAvatar = data['avatar_url'] as String?;
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
        _isLoadingFriends = false;
      });
      // Presence is unknown until a fresh fetch — show everyone offline for now.
      ref.read(presenceProvider.notifier).syncFromFriends(const {});
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
      // While a chat is open you're actively reading it, so never let a refresh
      // resurrect that friend's unread badge — the read PATCH may not have
      // round-tripped to the server yet. This kills the stale-badge flicker on
      // returning to the list.
      if (_activeFriendId != null) {
        for (final f in friends) {
          if (f['id'].toString() == _activeFriendId) {
            f['unread_count'] = 0;
          }
        }
      }
      // Save fresh data to cache
      await _saveFriendsCache(friends);
      setState(() {
        _allFriends = friends;
        _filteredFriends = friends;
        _isCurrentUserOnline = true;
        _serverReachable = true;
        _isLoadingFriends = false;
      });
      // Mirror the authoritative unread counts + online presence into Riverpod
      // (the badges and friend-list dots/count now read from these providers).
      final counts = <int, int>{};
      final online = <int>{};
      for (final f in friends) {
        final id = (f['id'] as num?)?.toInt();
        if (id == null) continue;
        counts[id] = (f['unread_count'] as num?)?.toInt() ?? 0;
        if (f['is_online'] == true) online.add(id);
      }
      ref.read(unreadProvider.notifier).syncFromFriends(counts);
      ref.read(presenceProvider.notifier).syncFromFriends(online);
      ConnectionStatus.instance.set(true);
      // Groups live in the same list — refresh them too (non-blocking).
      _fetchGroups();
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

  /// Fetch the group conversations the user belongs to and keep them in
  /// `_groups` (they render at the top of the friend list). Silent on failure —
  /// a group fetch error must never disturb the DM list.
  Future<void> _fetchGroups() async {
    try {
      final convs = await ApiService().listConversations();
      if (!mounted) return;
      final groups = convs
          .where((c) => c['is_group'] == true)
          .toList();
      setState(() {
        _groups = groups;
        _filteredGroups = _applyGroupQuery(groups, _searchQuery);
      });
    } catch (_) {
      // Keep whatever groups we already have.
    }
  }

  List<Map<String, dynamic>> _applyGroupQuery(
      List<Map<String, dynamic>> groups, String query) {
    final q = query.toLowerCase();
    if (q.isEmpty) return groups;
    return groups
        .where((g) => (g['title'] as String? ?? '').toLowerCase().contains(q))
        .toList();
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

  String _searchQuery = '';

  void _filterFriends(String query) {
    final q = query.toLowerCase();
    setState(() {
      _searchQuery = query;
      _filteredFriends = _allFriends
          .where((f) {
            final username = (f['username'] as String? ?? '').toLowerCase();
            // Match the SHOWN name too (saved phone-book name), so searching by
            // how you know them works even if their app username differs.
            final shown = _contactDisplayName(
                    f['phone']?.toString(), f['username'] as String? ?? '')
                .toLowerCase();
            return username.contains(q) || shown.contains(q);
          })
          .toList();
      _filteredGroups = _applyGroupQuery(_groups, query);
    });
  }

  // ── Share-into-Aluta (pick a chat to send a shared photo) ─────────────────

  bool get _isSharing => ShareInbox.instance.hasPending;

  /// A photo/screenshot was shared into Aluta. Return to the friend list so the
  /// user can tap a recipient, and repaint to show the share banner.
  void _onSharePending() {
    if (!mounted) return;
    if (ShareInbox.instance.hasPending) {
      _activeFriendId = null;
      _activeFriendName = null;
      _activeGroup = null;
      _playerExpanded = false;
    }
    setState(() {});
  }

  /// User tapped a recipient while a share is pending: grab the images, clear
  /// the inbox, and open that chat — it sends them via the preview flow.
  void _sendShareTo({Map<String, dynamic>? friend, Map<String, dynamic>? group}) {
    final paths = List<String>.from(ShareInbox.instance.pending);
    ShareInbox.instance.clear();
    _shareToSend = paths.isEmpty ? null : paths;
    if (friend != null) {
      openChat(friend);
    } else if (group != null) {
      openGroupInPanel(group);
    }
  }

  void _cancelShare() {
    ShareInbox.instance.clear();
    setState(() => _shareToSend = null);
  }

  /// The name to SHOW for a friend/contact: their SAVED phone-book name when we
  /// have that number saved on this device, otherwise their app username. Same
  /// priority the group message headers use, now applied to the friend list and
  /// DMs so a person reads the same everywhere.
  String _contactDisplayName(String? phone, String username) {
    final p = (phone ?? '').trim();
    if (p.isNotEmpty) {
      final saved = ContactNames.instance.nameFor(p);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    return username;
  }

  // ── Chat open/close ───────────────────────────────────────────────────────

  void openChat(Map<String, dynamic> friend) {
    setState(() {
      _activeFriendId = friend['id'].toString();
      _activeFriendName = friend['username'] ?? 'Friend';
      _activeFriendOnline = friend['is_online'] ?? false;
      _activeFriendLastSeen = friend['last_timestamp'] ?? '';
      _activeFriendPhone = friend['phone'] as String?;
      _activeFriendAvatar = friend['avatar_url'] as String?;
      _avatarExpanded = false;
    });
    // Optimistically clear the badge (was: friend['unread_count'] = 0).
    ref.read(unreadProvider.notifier).clear(friend['id'] as int);
    ApiService().markMessagesAsReadPatch(friend['id'] as int);
  }

  /// Open a GROUP conversation inside the chat panel (leaving the music panel
  /// visible on desktop). Called from the Groups popup / after creating a group.
  void openGroupInPanel(Map<String, dynamic> conv) {
    setState(() {
      _activeGroup = conv;
      // Groups and DMs are mutually exclusive in the panel.
      _activeFriendId = null;
      _activeFriendName = null;
      _activeFriendOnline = null;
      _activeFriendLastSeen = null;
      _avatarExpanded = false;
      _playerExpanded = false; // make sure the chat panel is the front surface
    });
  }

  void _closeGroupPanel() => setState(() => _activeGroup = null);

  /// Open the group info / settings sheet for the active group (tapped from the
  /// chat header). Refreshes the open header afterwards so a renamed group, a
  /// new photo, or member changes reflect immediately; closes the panel if the
  /// user left the group.
  Future<void> _openGroupInfo() async {
    final g = _activeGroup;
    if (g == null) return;
    final cid = (g['id'] as num).toInt();
    final result = await showAppPopup<String>(
      context,
      GroupInfoScreen(conversationId: cid),
    );
    if (!mounted) return;
    if (result == 'left') {
      _closeGroupPanel();
      _fetchGroups();
      return;
    }
    // Any edit (rename / photo / members) → re-pull the conversation so the
    // header and the group's list tile show the latest state.
    final fresh = await ApiService().getConversation(cid);
    if (!mounted) return;
    if (fresh != null &&
        _activeGroup != null &&
        (_activeGroup!['id'] as num).toInt() == cid) {
      setState(() => _activeGroup = fresh);
    }
    _fetchGroups();
  }

  /// Read the phone's address book, match numbers against registered users, and
  /// auto-add the matches as friends. Android/iOS only.
  Future<void> _findFriendsFromContacts() async {
    final mobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (!mobile) {
      if (mounted) {
        showToast(context, 'Contact sync is only available on the phone app.',
            type: ToastType.info);
      }
      return;
    }
    try {
      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (mounted) {
          showToast(context, 'Contacts permission denied.',
              type: ToastType.error);
        }
        return;
      }
      if (mounted) {
        showToast(context, 'Checking your contacts…', type: ToastType.info);
      }
      final contacts =
          await FlutterContacts.getContacts(withProperties: true);
      // Contacts are authorised now — populate the phonebook-name map too so
      // group headers immediately show saved names.
      ContactNames.instance.ensureLoaded();
      // Default region for LOCAL (no country code) contact numbers = the
      // device's country. Numbers already in +international form are parsed as
      // written. Everything is normalised to E.164 so matching is correct
      // across countries.
      IsoCode region = IsoCode.TZ;
      final cc =
          WidgetsBinding.instance.platformDispatcher.locale.countryCode;
      if (cc != null) {
        try {
          region = IsoCode.values.byName(cc.toUpperCase());
        } catch (_) {/* keep default */}
      }
      final phoneSet = <String>{};
      for (final c in contacts) {
        for (final p in c.phones) {
          final raw = p.number.trim();
          if (raw.isEmpty) continue;
          try {
            final parsed = PhoneNumber.parse(raw, callerCountry: region);
            if (parsed.isValid()) {
              phoneSet.add(parsed.international); // +<cc><number>
            } else {
              phoneSet.add(raw); // fall back to raw (server tail-match may hit)
            }
          } catch (_) {
            phoneSet.add(raw);
          }
        }
      }
      final phones = phoneSet.toList();
      if (phones.isEmpty) {
        if (mounted) {
          showToast(context, 'No phone numbers found in your contacts.',
              type: ToastType.info);
        }
        return;
      }
      final res = await ApiService().syncContacts(phones);
      final added = (res['added'] as num?)?.toInt() ?? 0;
      final matched = (res['matched'] as List?)?.length ?? 0;
      if (!mounted) return;
      showToast(
        context,
        matched == 0
            ? 'None of your contacts are on Aluta yet.'
            : 'Found $matched on Aluta · added $added new friend${added == 1 ? '' : 's'}.',
        type: ToastType.success,
      );
      _fetchFriends(); // refresh the list with any newly-added friends
    } catch (e) {
      if (mounted) {
        showToast(context, 'Could not sync contacts.', type: ToastType.error);
      }
    }
  }

  // Direct call to a friend's saved phone number (tel: dialer).
  Future<void> _callNumber(String? phone, String name) async {
    final p = (phone ?? '').trim();
    if (p.isEmpty) {
      if (mounted) {
        showToast(context, '$name has no phone number saved',
            type: ToastType.info);
      }
      return;
    }
    try {
      await launchUrl(Uri(scheme: 'tel', path: p));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not start the call', type: ToastType.error);
      }
    }
  }

  /// Ask whether to call over the internet (Aluta) or the device dialer, then
  /// route accordingly. Same chooser the chat screen uses, so every call button
  /// in the app offers the choice.
  /// Open the active DM friend's profile details (tapped from the chat header).
  void _openActiveFriendProfile() {
    final status = _activeFriendOnline == true
        ? 'Online'
        : (_activeFriendLastSeen?.isNotEmpty == true
            ? 'Last seen ${formatLastSeen(_activeFriendLastSeen!)}'
            : 'Offline');
    showUserProfile(
      context,
      username: _activeFriendName ?? '',
      phone: _activeFriendPhone,
      avatarUrl: _avatarFull(_activeFriendAvatar),
      isOnline: _activeFriendOnline == true,
      statusLine: status,
      onCall: () => _showCallChoice(
        friendId: int.tryParse(_activeFriendId ?? '') ?? -1,
        name: _activeFriendName ?? 'This user',
        avatar: _activeFriendAvatar,
        phone: _activeFriendPhone,
      ),
    );
  }

  void _showCallChoice({
    required int friendId,
    required String name,
    String? avatar,
    String? phone,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final online = ConnectionStatus.instance.isOnline;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Call $name',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.wifi_calling_3_rounded,
                    color: online ? scheme.primary : scheme.onSurfaceVariant),
                title: Text(online
                    ? 'Aluta call (over the internet)'
                    : 'Aluta call — you’re offline'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startAlutaCall(friendId, name, avatar, phone);
                },
              ),
              ListTile(
                leading: Icon(Icons.phone_rounded, color: scheme.onSurface),
                title: const Text('Phone call (uses your carrier)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _callNumber(phone, name);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startAlutaCall(
      int friendId, String name, String? avatar, String? phone) async {
    if (!ConnectionStatus.instance.isOnline) {
      if (mounted) {
        showToast(context, 'No internet — starting a phone call instead',
            type: ToastType.info);
      }
      _callNumber(phone, name);
      return;
    }
    if (friendId <= 0) return;
    final ok = await CallService.instance.startCall(
      peerId: friendId,
      peerName: name,
      peerAvatar: avatar,
      myName: _username.isNotEmpty ? _username : 'Aluta user',
      myAvatar: _myAvatar,
      fallbackPhone: phone,
    );
    if (!ok && mounted) {
      showToast(context, 'You’re already in a call', type: ToastType.info);
    }
  }

  void _logout() async {
    // Confirm first — signing out is deliberate, so an accidental tap on the
    // header icon can never drop the session (and, with quick-unlock off, wipe
    // the saved login).
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.logout_rounded, color: scheme.primary, size: 30),
          title: const Text('Sign out?'),
          content: const Text(
            'You will stop receiving messages and calls on this device until you '
            'sign back in. Your chats and account stay safe on the server.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: scheme.primary),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    // Stop pushes reaching this device for the account we're leaving (done while
    // the token is still valid, before logoutUser clears it). Best-effort.
    await FcmService.instance.unregisterToken();
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
      // Round the clip to match the inner card so there are NO triangular corner
      // gaps — previously a rectangular hard-edge clip cut the card's shadow into
      // hard dark wedges at the corners. The shadow lives on THIS container now
      // (outside the clip), so it renders as a soft halo instead.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: visible
            ? [
                BoxShadow(
                  color: Theme.of(context).shadowColor.withAlpha(30),
                  blurRadius: 12,
                ),
              ]
            : const [],
      ),
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

  Widget _panelDecor(BuildContext context, Widget child,
      {bool isMusicPanel = false, EdgeInsetsGeometry? padding}) {
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
        // Rounded on ALL FOUR corners so the panel reads as one floating card —
        // the bottom corners emerge from the footer just like the top corners
        // emerge from the header (both sit on the same surfaceContainerHighest
        // background), for a smoother, symmetric look.
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withAlpha(35),
            blurRadius: 12,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      // Clip the child to the rounded shape so scrolling content can never
      // paint into the corners (which was flickering faint pockets at the top
      // during a fast scroll; the same clip now also cleans the bottom corners).
      clipBehavior: Clip.antiAlias,
      padding: padding ?? const EdgeInsets.all(14),
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
            child: Stack(
              children: [
                kIsWeb
                    ? WebMusicPanel(textColor: scheme.onSurface)
                    : MusicControls(textColor: scheme.onSurface),
                _playlistDrawerHost(context, music: true),
              ],
            ),
          ),
        ],
      ),
      isMusicPanel: true,
    );
  }

  // ── Chat panel ────────────────────────────────────────────────────────────

  // Tap-to-expand profile photo: drops an enlarged, collapsible view of the
  // friend's avatar in between the header and the thread. Tap the header avatar
  // to open, tap the enlarged photo (or the header avatar again) to collapse.
  Widget _buildExpandedAvatar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final full = _avatarFull(_activeFriendAvatar);
    final show = _avatarExpanded && full != null;
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: !show
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _avatarExpanded = false),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: scheme.primary.withAlpha(60)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InitialsAvatar(
                        name: _activeFriendName ?? '',
                        radius: 78,
                        isOnline: false,
                        imageUrl: full,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _activeFriendName ?? '',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.keyboard_arrow_up_rounded,
                              size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 3),
                          Text('Tap to collapse',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildChatHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    // Group header (back · icon · title · member count).
    if (_activeGroup != null) {
      final g = _activeGroup!;
      final members = (g['members'] as List?) ?? const [];
      final groupAvatar = _avatarFull(g['avatar_url']);
      return Row(
        children: [
          _PanelToggleBtn(
            isFullScreen: false,
            customIcon: Icons.arrow_back_ios_new_rounded,
            tooltip: 'Back to messages',
            onTap: _closeGroupPanel,
          ),
          const SizedBox(width: 6),
          // Tapping anywhere on the group identity opens Group info / settings.
          Expanded(
            child: InkWell(
              onTap: _openGroupInfo,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: scheme.primaryContainer,
                      backgroundImage: groupAvatar != null
                          ? authNetworkImageProvider(
                              groupAvatar, mediaAuthHeaders(groupAvatar))
                          : null,
                      child: groupAvatar == null
                          ? Icon(Icons.groups_rounded,
                              color: scheme.onPrimaryContainer, size: 20)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (g['title'] ?? 'Group').toString(),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${members.length} members · tap for info',
                            style: TextStyle(
                                fontSize: 11, color: textColor.withAlpha(130)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 20, color: textColor.withAlpha(90)),
                  ],
                ),
              ),
            ),
          ),
          // Quick playlist drawer toggle — same shortcut as the DM header so the
          // music library can pop in without leaving the group conversation.
          ValueListenableBuilder<bool>(
            valueListenable: playlistDrawerBus.isOpen,
            builder: (_, open, _) => IconButton(
              tooltip: open ? 'Hide playlist' : 'Playlist',
              icon: Icon(Icons.queue_music_rounded,
                  color: open ? scheme.primary : null),
              onPressed: () => playlistDrawerBus.toggle?.call(),
            ),
          ),
        ],
      );
    }

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
              _avatarExpanded = false;
            }),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              // Only expand when there's an actual photo to show.
              if (_avatarFull(_activeFriendAvatar) != null) {
                setState(() => _avatarExpanded = !_avatarExpanded);
              }
            },
            child: InitialsAvatar(
              name: _contactDisplayName(
                  _activeFriendPhone, _activeFriendName ?? ''),
              radius: 17,
              isOnline: _activeFriendOnline == true,
              imageUrl: _avatarFull(_activeFriendAvatar),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            // Tap the friend's name to open their profile details (phone, etc.).
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openActiveFriendProfile,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _contactDisplayName(
                        _activeFriendPhone, _activeFriendName ?? ''),
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
          ),
          // Quick playlist drawer toggle — pop the music library in from the
          // right without leaving the conversation (or opening the music panel).
          ValueListenableBuilder<bool>(
            valueListenable: playlistDrawerBus.isOpen,
            builder: (_, open, _) => IconButton(
              tooltip: open ? 'Hide playlist' : 'Playlist',
              icon: Icon(Icons.queue_music_rounded,
                  color: open ? scheme.primary : null),
              onPressed: () => playlistDrawerBus.toggle?.call(),
            ),
          ),
          IconButton(
            tooltip:
                'Call ${_contactDisplayName(_activeFriendPhone, _activeFriendName ?? '')}',
            icon: const Icon(Icons.call_rounded),
            onPressed: () => _showCallChoice(
              friendId: int.tryParse(_activeFriendId ?? '') ?? -1,
              name: _contactDisplayName(
                  _activeFriendPhone, _activeFriendName ?? 'This user'),
              avatar: _activeFriendAvatar,
              phone: _activeFriendPhone,
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
        // App logo as the brand mark leading the Messages header.
        SizedBox(
          width: 24,
          height: 24,
          child: Image.asset(
            'assets/images/logo.png',
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Icon(
              Icons.chat_bubble_outline_rounded,
              color: scheme.primary,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'Messages',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const Spacer(),
        // Right side status: when online, a green "N online" chip (moved up
        // from the status strip) balances the logo+title on the left; when
        // offline, the tap-to-reconnect badge takes its place.
        if (_serverReachable)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.green.withAlpha(28),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF2FA84F),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${ref.watch(presenceProvider).onlineCount} online',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface.withAlpha(200),
                  ),
                ),
              ],
            ),
          ),
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

  Widget _buildChatContent(BuildContext context, {bool phone = false}) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    return _panelDecor(
      context,
      Column(
        children: [
          _buildChatHeader(context),
          const SizedBox(height: 10),
          if (_activeFriendId != null) _buildExpandedAvatar(context),
          Expanded(
            child: Stack(
              children: [
                AnimatedSwitcher(
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
              child: _activeGroup != null
                  ? ChatPage(
                      key: ValueKey('g${_activeGroup!['id']}'),
                      friendName: (_activeGroup!['title'] ?? 'Group').toString(),
                      textColor: textColor,
                      showAppBar: false,
                      conversationId: (_activeGroup!['id'] as num).toInt(),
                      isGroup: true,
                      groupTitle:
                          (_activeGroup!['title'] ?? 'Group').toString(),
                      groupAvatar:
                          (_activeGroup!['avatar_url'] ?? '').toString(),
                      memberCount:
                          ((_activeGroup!['members'] as List?) ?? const [])
                              .length,
                      initialSharePaths: _shareToSend,
                      onShareConsumed: () => _shareToSend = null,
                    )
                  : _activeFriendId != null
                  ? ChatPage(
                      key: ValueKey(_activeFriendId),
                      friendId: int.parse(_activeFriendId!),
                      friendName: _contactDisplayName(
                          _activeFriendPhone, _activeFriendName!),
                      friendAvatar: _activeFriendAvatar ?? '',
                      textColor: textColor,
                      showAppBar: false,
                      onFriendOnlineStatusChanged: (online, lastSeen) {
                        if (mounted) {
                          setState(() {
                            _activeFriendOnline = online;
                            _activeFriendLastSeen = lastSeen;
                          });
                          // Live-update the friend-list dot + count too.
                          final id = int.tryParse(_activeFriendId ?? '');
                          if (id != null) {
                            ref
                                .read(presenceProvider.notifier)
                                .setOnline(id, online);
                          }
                        }
                      },
                      initialSharePaths: _shareToSend,
                      onShareConsumed: () => _shareToSend = null,
                    )
                  : _buildFriendList(context),
                ),
                _playlistDrawerHost(context, music: false),
              ],
            ),
          ),
        ],
      ),
      // On phones, trim the side margins (wider chat) and drop the bottom
      // padding so the composer sits flush against the player/footer module.
      padding: phone ? const EdgeInsets.fromLTRB(4, 12, 4, 0) : null,
    );
  }

  // Whether the music surface (not the chat/friends surface) is front-most —
  // decides which host renders the drawer's single content instance.
  bool get _musicIsFront =>
      _isMusicFullScreen ||
      _playerExpanded ||
      MediaQuery.of(context).size.width >= 640;

  /// The playlist drawer, hosted BELOW the active header so the header (and the
  /// chat's playlist toggle) stay visible above it. Slides/fades in from the
  /// right on [_playlistDrawerCtrl]; swipe right or tap the scrim to close.
  /// [music] hosts live on the music surface, the other on the chat surface —
  /// only the front-most one builds content, so it's never duplicated.
  Widget _playlistDrawerHost(BuildContext context, {required bool music}) {
    final builder = playlistDrawerBus.contentBuilder;
    if (builder == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _playlistDrawerCtrl,
      builder: (context, _) {
        final t = _playlistDrawerCtrl.value;
        if (t <= 0.001 || music != _musicIsFront) {
          return const SizedBox.shrink();
        }
        // Tell the playlist body which surface it's on: chat surface (music:false)
        // has the app now-playing bar, so the body drops its inline strip there.
        playlistDrawerBus.hostIsChatSurface = !music;
        final scheme = Theme.of(context).colorScheme;
        final eased = Curves.easeOutCubic.transform(t);
        return LayoutBuilder(
          builder: (ctx, cons) {
            final isPhone = cons.maxWidth < 520;
            final double panelW =
                isPhone ? cons.maxWidth : cons.maxWidth.clamp(0.0, 460.0).toDouble();
            // Full-width (phone): sharp corners so no dimmed layer peeks through
            // the rounding. Narrower (desktop): keep the soft left "curtain" edge.
            final bool fullWidth = panelW >= cons.maxWidth - 0.5;
            final BorderRadius panelRadius = fullWidth
                ? BorderRadius.zero
                : const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                  );
            return Stack(
              children: [
                // Dim scrim — fades with the drawer; tap to close.
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: t < 0.05,
                    child: Opacity(
                      opacity: 0.5 * eased,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => playlistDrawerBus.close?.call(),
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),
                  ),
                ),
                // The sliding panel — glides in from the right edge.
                Align(
                  alignment: Alignment.centerRight,
                  child: FractionalTranslation(
                    translation: Offset(1 - eased, 0),
                    // A passive Listener (not a GestureDetector) tracks a RIGHT
                    // swipe to close the drawer like a curtain. Because it never
                    // enters the gesture arena, it works EVERYWHERE on the panel
                    // — including over the swipe-to-delete rows — without blocking
                    // taps, vertical scrolling, or the rows' left-swipe delete.
                    child: Listener(
                      onPointerDown: (e) {
                        _drawerPointer = e.pointer;
                        _drawerSwipeDx = 0;
                        _drawerSwipeDy = 0;
                      },
                      onPointerMove: (e) {
                        if (e.pointer != _drawerPointer) return;
                        _drawerSwipeDx += e.delta.dx;
                        _drawerSwipeDy += e.delta.dy;
                      },
                      onPointerUp: (e) {
                        if (e.pointer != _drawerPointer) return;
                        // Rightward + clearly horizontal = a close swipe.
                        if (_drawerSwipeDx > 64 &&
                            _drawerSwipeDx > _drawerSwipeDy.abs() * 1.4) {
                          playlistDrawerBus.close?.call();
                        }
                        _drawerPointer = null;
                        _drawerSwipeDx = 0;
                        _drawerSwipeDy = 0;
                      },
                      onPointerCancel: (e) {
                        if (e.pointer == _drawerPointer) {
                          _drawerPointer = null;
                          _drawerSwipeDx = 0;
                          _drawerSwipeDy = 0;
                        }
                      },
                      child: SizedBox(
                        width: panelW,
                        height: double.infinity,
                        child: Material(
                          color: scheme.surface,
                          elevation: 16,
                          shadowColor: Colors.black.withAlpha(120),
                          borderRadius: panelRadius,
                          clipBehavior: Clip.antiAlias,
                          child: ValueListenableBuilder<int>(
                            valueListenable: playlistDrawerBus.revision,
                            builder: (c, _, _) => builder(c),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildFriendList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    // Groups sit at the TOP of the same list as DMs (WhatsApp-style unified
    // chat list). Each item carries is_group so the builder picks the right row.
    final combined = <Map<String, dynamic>>[
      ..._filteredGroups,
      ..._filteredFriends,
    ];

    return Column(
      key: const ValueKey('friendList'),
      children: [
        if (_isSharing) _buildShareBanner(scheme),
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
                  child: combined.isEmpty
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
                          itemCount: combined.length,
                          separatorBuilder: (ctx, i) => Divider(
                            height: 1,
                            indent: 68,
                            color: scheme.outlineVariant.withAlpha(70),
                          ),
                          itemBuilder: (_, i) {
                            final item = combined[i];
                            return item['is_group'] == true
                                ? _buildGroupTile(item, textColor, scheme)
                                : _buildFriendTile(item, textColor, scheme);
                          },
                        ),
                ),
        ),
      ],
    );
  }

  /// Banner shown across the top of the chat list while a photo shared into
  /// Aluta is waiting for the user to pick a recipient.
  Widget _buildShareBanner(ColorScheme scheme) {
    final n = ShareInbox.instance.pending.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      child: Row(
        children: [
          Icon(Icons.photo_library_rounded,
              size: 20, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n > 1 ? 'Sharing $n photos' : 'Sharing a photo',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                Text(
                  'Tap a chat below to send it',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onPrimaryContainer.withAlpha(200),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _cancelShare,
            style: TextButton.styleFrom(
              foregroundColor: scheme.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendTile(
      Map<String, dynamic> f, Color textColor, ColorScheme scheme) {
    // Show your saved phone-book name for this number when you have it saved,
    // otherwise their app username.
    final name = _contactDisplayName(
        f['phone']?.toString(), f['username'] as String? ?? '');
    // Online dot now comes from Riverpod (single source of truth for presence).
    final isOnline = ref.watch(presenceProvider).isOnline((f['id'] as num).toInt());
    final lastMsg = f['last_message'] as String? ?? '';
    final lastTime = f['last_timestamp'] as String? ?? '';
    // Unread now comes from Riverpod (single source of truth for the badge).
    final unread = ref.watch(unreadProvider).countFor((f['id'] as num).toInt());
    final hasUnread = unread > 0;

    return InkWell(
      onTap: () => _isSharing ? _sendShareTo(friend: f) : openChat(f),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            InitialsAvatar(
                name: name,
                radius: 22,
                isOnline: isOnline,
                imageUrl: _avatarFull(f['avatar_url'])),
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
            IconButton(
              tooltip: 'Call $name',
              icon: Icon(Icons.call_rounded, color: scheme.primary, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showCallChoice(
                friendId: int.tryParse(f['id'].toString()) ?? -1,
                name: name,
                avatar: f['avatar_url'] as String?,
                phone: f['phone'] as String?,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A group conversation row in the unified chat list. Tapping opens the group
  /// inside the chat panel (never a full-window route).
  Widget _buildGroupTile(
      Map<String, dynamic> g, Color textColor, ColorScheme scheme) {
    final title = (g['title'] as String?)?.trim();
    final name = (title == null || title.isEmpty) ? 'Group' : title;
    final lastMsg = g['last_message'] as String? ?? '';
    final lastTime = (g['last_timestamp'] ?? '').toString();
    final unread = (g['unread_count'] as num?)?.toInt() ?? 0;
    final hasUnread = unread > 0;
    final avatar = _avatarFull(g['avatar_url']);

    return InkWell(
      onTap: () => _isSharing ? _sendShareTo(group: g) : openGroupInPanel(g),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: avatar != null
                  ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar))
                  : null,
              child: avatar == null
                  ? Icon(Icons.groups_rounded,
                      color: scheme.onPrimaryContainer, size: 24)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.groups_rounded,
                          size: 14, color: textColor.withAlpha(120)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontWeight:
                                hasUnread ? FontWeight.bold : FontWeight.w500,
                            fontSize: 14,
                            color: textColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lastMsg.isEmpty ? 'Tap to open the group' : lastMsg,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: hasUnread
                          ? textColor.withAlpha(200)
                          : textColor.withAlpha(110),
                      fontWeight:
                          hasUnread ? FontWeight.w500 : FontWeight.normal,
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
                    color:
                        hasUnread ? scheme.primary : textColor.withAlpha(110),
                    fontWeight:
                        hasUnread ? FontWeight.w600 : FontWeight.normal,
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
    return rp.Consumer(
      // Rebuild the bar/sheet visibility when the track or live session changes.
      // (Was: ListenableBuilder over merged nowPlayingNotifier+liveSessionNotifier.)
      builder: (context, ref, _) {
        final hasTrack = ref.watch(nowPlayingProvider).track.isNotEmpty;
        // The now-playing bar is for the user's OWN music (the live session has
        // its own audio and is surfaced by the top banner). Show it when a
        // personal track is loaded and the user hasn't dismissed it; otherwise
        // a compact pill docked in the footer centre is the entry point.
        final barVisible = hasTrack && !_barDismissed;
        // Reserve just enough chat space for the now-playing bar (grab handle +
        // title + progress row) so it sits flush under the composer with no gap.
        final barSpace = 70.0;

        return Stack(
          children: [
            // Chat surface — full width; reserve room for the collapsed bar.
            // AnimatedPadding so the reflow eases in step with the bar's genie.
            Positioned.fill(
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(
                    bottom: (_playerExpanded || !barVisible) ? 0 : barSpace),
                child: _buildChatContent(context, phone: true),
              ),
            ),

            // Full player — ALWAYS mounted (AudioPlayer stays alive). Instead of
            // sliding from the top it "genie" scales into / out of the footer-pill
            // spot (bottom-centre anchor, smooth, no bounce), so it reads as being
            // pulled out of the pill and sucked back into it.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_playerExpanded,
                child: AnimatedScale(
                  scale: _playerExpanded ? 1.0 : 0.0,
                  alignment: Alignment.bottomCenter,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _playerExpanded ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    child: _buildPhonePlayerSheet(context),
                  ),
                ),
              ),
            ),

            // Collapsed now-playing bar. Kept mounted while a track is loaded so
            // it can genie-scale DOWN into the footer pill on dismiss and back
            // OUT of it on resume (bottom-centre anchor, no bounce).
            if (hasTrack && !_playerExpanded)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: _barDismissed,
                  child: AnimatedScale(
                    scale: _barDismissed ? 0.0 : 1.0,
                    alignment: Alignment.bottomCenter,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: _barDismissed ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      child: _buildNowPlayingBar(context),
                    ),
                  ),
                ),
              ),

            // When collapsed the entry point is a compact pill docked in the
            // footer centre (see _footerMusicChip) — not a button over the chat.
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
            onTap: _closePanel,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 120) {
                _closePanel();
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
                      onTap: _closePanel,
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
                    if (ref.read(liveSessionProvider).active) _liveChip(context),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Stack(
              children: [
                kIsWeb
                    ? WebMusicPanel(textColor: scheme.onSurface)
                    : MusicControls(textColor: scheme.onSurface),
                _playlistDrawerHost(context, music: true),
              ],
            ),
          ),
        ],
      ),
      isMusicPanel: true,
    );
  }

  Widget _liveChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = ref.read(liveSessionProvider);
    final peer = session.peer;
    final asHost = session.asHost;
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
    return rp.Consumer(
      builder: (context, ref, _) {
        final session = ref.watch(liveSessionProvider);
        if (!session.active) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final peer = session.peer;
        final host = session.asHost;
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
    ref.read(liveSessionProvider.notifier).stop();
    if (mounted) setState(() {});
  }

  // Close the full panel and return to wherever it emerged from: back to the
  // footer pill if it opened from there, otherwise back to the now-playing bar.
  void _closePanel() => setState(() {
        _playerExpanded = false;
        _barDismissed = _panelFromPill;
      });

  // The collapsed music control: a compact pill docked in the footer centre.
  // Single tap resurfaces the now-playing bar; long-press / double-tap jumps
  // straight to the full music panel. Shows a marquee of the current title.
  Widget _footerMusicChip(ColorScheme scheme) {
    final title = ref.read(nowPlayingProvider).track;
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.primary,
    );
    // Bring the collapsed now-playing bar back above the footer (no full panel).
    void resumeBar() => setState(() => _barDismissed = false);
    // Jump straight to the full player panel — remembering it came from the
    // pill, so closing it returns here (bar stays dismissed).
    void openPanel() => setState(() {
          _panelFromPill = true;
          _playerExpanded = true;
        });
    return GestureDetector(
      onTap: resumeBar,
      onDoubleTap: openPanel,
      onLongPress: openPanel,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.primary.withAlpha(28),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.primary.withAlpha(90)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 5),
            // Marquee the title (only scrolls when it overflows) so long song
            // names stay readable inside the compact pill.
            SizedBox(
              width: 120,
              height: 16,
              child: _ScrollingText(
                text: title.isEmpty ? 'Music' : title,
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNowPlayingBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Snapshot: this bar is built inside _buildPhoneBody's Consumer, which
    // watches nowPlayingProvider — so it rebuilds when the track/play-state
    // changes and this read is always fresh.
    final np = ref.read(nowPlayingProvider);

    return GestureDetector(
      // Tap anywhere (except the play button) to expand; swipe up too.
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Tapping the bar opens the full player (origin = bar). Drop the
        // keyboard so the composer isn't focused behind the expanded player.
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() {
          _panelFromPill = false;
          _playerExpanded = true;
        });
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < 0) {
          // Swipe UP → expand into the full music panel (origin = bar).
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() {
            _panelFromPill = false;
            _playerExpanded = true;
          });
        } else if (v > 120) {
          // Swipe DOWN → collapse the bar into the footer pill.
          setState(() => _barDismissed = true);
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
                  const SizedBox(width: 2),
                  // Transport leads the bar now (logo moved to the status
                  // strip): Previous · Play · Next. The favourite heart is by
                  // the seek
                  // bar so the controls nudge left and the space balances out.
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
                  const SizedBox(width: 10),
                  // Title (auto-scrolls if long) above a slim seekable bar.
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
                  const SizedBox(width: 8),
                  // Share to chat — the quick action that used to live in the
                  // drawer's transport strip (dropped on the chat surface). It's
                  // more useful than the heart on this in-chat bar, so it takes
                  // that spot; favouriting still lives in the full player.
                  Tooltip(
                    message: 'Share to chat',
                    child: GestureDetector(
                      onTap: () => playbackBus.onShareToChat?.call(),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Icon(
                          Icons.share_rounded,
                          size: 20,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Close the bar → it genies down into the footer pill.
                  GestureDetector(
                    onTap: () => setState(() => _barDismissed = true),
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
      builder: (_, clock, _) {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: filled ? 40 : 34,
        height: filled ? 40 : 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Soft brand tint for the primary play/pause button — a pink circle
          // with a red glyph and thin ring, matching the voice-note button and
          // composer mic instead of the solid-red FAB.
          color: filled
              ? scheme.primary.withAlpha(isDark ? 48 : 30)
              : Colors.transparent,
          border: filled
              ? Border.all(
                  color: scheme.primary.withAlpha(isDark ? 90 : 70), width: 1)
              : null,
        ),
        child: Icon(
          icon,
          size: size,
          color: filled
              ? (isDark ? const Color(0xFFFF8A93) : scheme.primary)
              : scheme.onSurface.withAlpha(200),
        ),
      ),
    );
  }

  // One row of the header overflow menu (icon + label).
  // ── Overflow menu (grouped, MenuAnchor with submenus) ─────────────────────

  /// The header overflow menu. Related actions are nested under parent
  /// submenus (Devices, Tools & settings…) so the top level stays short as new
  /// features are added, instead of the flat list growing ever taller.
  Widget _buildOverflowMenu(
      BuildContext context, ThemeProvider themeProvider, ColorScheme scheme) {
    final bool mobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(scheme.surface),
      elevation: const WidgetStatePropertyAll(10),
      // Faint red hairline so the menu (and each submenu) lifts off the UI.
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
              color: const Color(0xFFE53935).withAlpha(70), width: 1),
        ),
      ),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6, horizontal: 4)),
    );

    return MenuAnchor(
      style: menuStyle,
      builder: (ctx, controller, child) => IconButton(
        icon: Icon(Icons.more_vert_rounded, color: scheme.onSurface),
        tooltip: 'Menu',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        _menuBtn(scheme, Icons.groups_rounded, 'Groups', () async {
          final conv = await showAppPopup<Map<String, dynamic>>(
              context, const GroupsScreen());
          if (conv != null && mounted) openGroupInPanel(conv);
        }),
        // Devices — QR linking + the linked-devices manager.
        SubmenuButton(
          menuStyle: menuStyle,
          leadingIcon: Icon(Icons.devices_rounded,
              size: 20, color: scheme.primary),
          menuChildren: [
            if (mobile)
              _menuBtn(scheme, Icons.laptop_chromebook_rounded,
                  'Link a computer', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DeviceLinkScanScreen()),
                );
              }),
            _menuBtn(scheme, Icons.devices_other_rounded, 'Linked devices',
                () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const LinkedDevicesScreen()),
              );
            }),
          ],
          child: const Text('Devices'),
        ),
        // Tools & settings — the catch-all so future actions nest here.
        SubmenuButton(
          menuStyle: menuStyle,
          leadingIcon:
              Icon(Icons.tune_rounded, size: 20, color: scheme.primary),
          menuChildren: [
            _menuBtn(scheme, Icons.hearing_rounded, 'Identify song',
                () => showSongIdentifier(context)),
            _menuBtn(scheme, Icons.contacts_rounded, 'Find friends',
                () => _findFriendsFromContacts()),
            if (mobile)
              _menuBtn(scheme, Icons.phonelink_ring_rounded,
                  'Call reliability', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const CallReliabilityScreen()),
                );
              }),
            _menuBtn(
              scheme,
              themeProvider.isDarkMode
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              themeProvider.isDarkMode ? 'Light mode' : 'Dark mode',
              () => themeProvider.toggleTheme(!themeProvider.isDarkMode),
            ),
            _menuBtn(scheme, Icons.shield_outlined, 'Legal & About',
                () => showLegalMenu(context)),
          ],
          child: const Text('Tools & settings'),
        ),
        _menuBtn(scheme, Icons.person_rounded, 'Profile', () async {
          await showAppPopup(context, const ProfileScreen());
          if (mounted) _loadUserData();
        }),
        const Divider(height: 10),
        _menuBtn(scheme, Icons.logout_rounded, 'Sign out', _logout,
            destructive: true),
      ],
    );
  }

  MenuItemButton _menuBtn(
      ColorScheme scheme, IconData icon, String label, VoidCallback onPressed,
      {bool destructive = false}) {
    final accent = destructive ? scheme.error : scheme.primary;
    return MenuItemButton(
      leadingIcon: Icon(icon, size: 20, color: accent),
      onPressed: onPressed,
      child: Text(
        label,
        style: destructive ? TextStyle(color: scheme.error) : null,
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return rp.Consumer(
      builder: (context, ref, _) {
        // Pure status strip: a connection dot + online-friends count on the
        // left, profile pill on the right. The "Connected" label is dropped —
        // seeing your online friends (plus the toast) already tells you you're
        // back online, so the word was redundant.
        return Container(
          // Fill the footer colour behind the system navigation bar area too,
          // then SafeArea lifts the 44px status row up above the 3-button nav
          // bar (or the gesture pill) so the footer — and, because this is the
          // Scaffold's bottomNavigationBar, the whole body above it (chat
          // composer + now-playing bar) — never hides under the system controls.
          color: scheme.surfaceContainerHighest,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 44,
              child: Padding(
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
                      // (Online-friends count moved to the Messages header.)
                    ],
                  ),
                ),
              ),

              const Spacer(),

              // Collapsed music control lives here, centred, instead of floating
              // over the chat and covering message bubbles. Shown only while the
              // bar is dismissed and the full panel isn't open.
              if (ref.watch(nowPlayingProvider).track.isNotEmpty &&
                  _barDismissed &&
                  !_playerExpanded) ...[
                _footerMusicChip(scheme),
                const Spacer(),
              ],

              // ── Right: profile pill only (online count now sits by the dot) ─
              // Tap the name (a pill-shaped button) to open your profile.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () async {
                    await showAppPopup(context, const ProfileScreen());
                    // Refresh the cached username in case it changed.
                    if (mounted) _loadUserData();
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: scheme.primary.withAlpha(22),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: scheme.primary.withAlpha(70)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_rounded,
                            size: 14, color: scheme.primary),
                        const SizedBox(width: 5),
                        Text(
                          // On phones, show just the first name so a full
                          // "First Last" doesn't eat the footer's space.
                          MediaQuery.of(context).size.width < 640
                              ? _username.trim().split(RegExp(r'\s+')).first
                              : _username,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(Icons.expand_less_rounded,
                            size: 14,
                            color: scheme.onSurface.withAlpha(130)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
                ),
              ),
            ),
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
        _activeGroup != null ||
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
          } else if (_activeGroup != null) {
            // Close the open group → back to the messages list.
            _activeGroup = null;
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
      // Match the header colour so the rounded-top chat/music panels appear to
      // emerge seamlessly from the header — no visible "triangle pocket" of a
      // different shade behind their top corners in either light or dark theme.
      backgroundColor: scheme.surfaceContainerHighest,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: scheme.surfaceContainerHighest,
        // Keep the header a flat, opaque colour — no Material-3 scroll-under
        // tint that would shift its shade (and momentarily show content through)
        // as the conversation scrolls beneath it.
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
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
          // Single overflow menu with GROUPED submenus, so adding new actions
          // nests them under a parent instead of making the menu grow taller.
          _buildOverflowMenu(context, themeProvider, scheme),
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

