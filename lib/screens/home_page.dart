import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../utils/toast_helper.dart';
import '../utils/app_reload.dart';
import 'auth_page.dart';
import 'theme_provider.dart';
import 'music_controls.dart';
import 'web_music_panel.dart';
import 'chat_page.dart';
import 'api_service.dart';
import '../utils/avatar_widget.dart';
import '../utils/app_config.dart';

String _formatFriendTimestamp(String raw) {
  if (raw.isEmpty) return '';
  try {
    final dt = DateTime.parse(raw).toLocal();
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

// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  static const String routeName = '/home';
  const HomePage({super.key});

  static HomePageState? of(BuildContext context) =>
      context.findAncestorStateOfType<HomePageState>();

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
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
  List<Map<String, dynamic>> _filteredFriends = [];
  bool _isLoadingFriends = false;

  // ── Layout state ──────────────────────────────────────────────────────────
  double _musicPanelWidth = 280;
  bool _isMusicFullScreen = false;
  bool _isChatFullScreen = false;
  double _prevMusicWidth = 280;
  bool _isDragging = false;

  // ── Chat state ────────────────────────────────────────────────────────────
  String? _activeFriendId;
  String? _activeFriendName;
  bool? _activeFriendOnline;
  String? _activeFriendLastSeen;

  Timer? _refreshTimer;
  StreamSubscription? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _loadCachedFriends();    // show cached list instantly (no spinner flash)
    _fetchFriends();          // then refresh from network
    _loadLayoutState();
    _discoverServer();

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
        if (mounted) setState(() => _isCurrentUserOnline = false);
      }
    });

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _fetchFriends(quiet: true),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
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

  Future<void> _loadUserData() async {
    try {
      final data = await ApiService().getUserData();
      final prefs = await SharedPreferences.getInstance();
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
        _isLoadingFriends = false;
      });
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
          _isLoadingFriends = false;
        });
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
        setState(() => _isCurrentUserOnline = true);
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
      setState(() => _isCurrentUserOnline = true);
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
  }) {
    final visible = containerWidth > 0.5;
    // Fade out quickly when collapsing to prevent OverflowBox visual artifact
    final opacity = (containerWidth / minRenderWidth).clamp(0.0, 1.0);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
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
                          ? 'Last seen $_activeFriendLastSeen'
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

    return Row(
      children: [
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
        Icon(Icons.chat_bubble_outline_rounded,
            color: scheme.primary, size: 20),
        const SizedBox(width: 6),
        const Text(
          'Messages',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const Spacer(),
        // Online/offline status indicator with reconnect button
        if (!_isCurrentUserOnline)
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

  Widget _buildFooter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: nowPlayingNotifier,
      builder: (context, _) {
        final np = nowPlayingNotifier;
        final hasTrack = np.track.isNotEmpty;

        return Container(
          height: 44,
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // ── Left: now playing ────────────────────────────────────────
              Icon(
                hasTrack && np.playing
                    ? Icons.equalizer_rounded
                    : Icons.music_off_rounded,
                size: 16,
                color: hasTrack && np.playing
                    ? scheme.primary
                    : scheme.onSurface.withAlpha(120),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: hasTrack
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            np.track,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (np.artist.isNotEmpty)
                            Text(
                              np.artist,
                              style: TextStyle(
                                color:
                                    scheme.onSurface.withAlpha(160),
                                fontSize: 10,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      )
                    : Text(
                        'No track playing',
                        style: TextStyle(
                          color: scheme.onSurface.withAlpha(120),
                          fontSize: 12,
                        ),
                      ),
              ),

              // ── Right: server status + user + online count ───────────────
              const SizedBox(width: 8),

              // Server IP chip — tap to configure
              Tooltip(
                message: _serverReachable
                    ? 'Connected to ${(kIsWeb || kReleaseMode) ? _serverIp : '$_serverIp:${AppConfig.port}'}\nLong-press to reconfigure'
                    : 'Not connected — tap to configure',
                child: GestureDetector(
                  onTap: _showServerSettings,
                  onLongPress: () => _discoverServer(forceReset: true),
                  behavior: HitTestBehavior.opaque,
                  // Just a status dot — green (live) / red (offline).
                  // No domain text; full info lives in the tooltip.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    child: _isDiscovering
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
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _serverReachable
                                  ? Colors.green
                                  : Colors.red,
                              // Soft glow so the dot "emits"
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
                  ),
                ),
              ),
              const SizedBox(width: 8),

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
                  '$_onlineFriendsCount',
                  style: TextStyle(
                    color: scheme.onSurface.withAlpha(180),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(Icons.person_rounded,
                  size: 14,
                  color: scheme.onSurface.withAlpha(160)),
              const SizedBox(width: 4),
              Text(
                _username,
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

    return Scaffold(
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
            onPressed: () =>
                themeProvider.toggleTheme(!themeProvider.isDarkMode),
          ),
          IconButton(
            icon: Icon(Icons.logout_rounded,
                color: scheme.onSurface),
            onPressed: _logout,
            tooltip: 'Sign out',
          ),
        ],
      ),
      // ── Body: always Row — panels never leave the tree ─────────────────
      body: LayoutBuilder(
        builder: (context, constraints) {
          final total = constraints.maxWidth;

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
      bottomNavigationBar: _buildFooter(context),
    );
  }
}

// ─── Small toggle button ───────────────────────────────────────────────────

class _PanelToggleBtn extends StatelessWidget {
  final bool isFullScreen;
  final VoidCallback onTap;
  final IconData? customIcon;

  const _PanelToggleBtn({
    required this.isFullScreen,
    required this.onTap,
    this.customIcon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
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
    );
  }
}
