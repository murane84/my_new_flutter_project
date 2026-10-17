import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'link_ozilane_screen.dart';
import 'message_search_screen.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform, ValueListenable;
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
import 'chat/formatted_text.dart' show previewSpans;
import 'group_screens.dart';
import 'user_profile_sheet.dart';
import 'device_link.dart';
import 'call_reliability_screen.dart';
import 'music/song_identifier.dart' show showSongIdentifier;
import 'profile_screen.dart';
import '../utils/popup_shell.dart';
import '../utils/bounce_tap.dart';
import '../utils/brand_theme.dart';
import '../widgets/chat_wallpaper_sheet.dart';
import 'api_service.dart';
import 'websocket_manager.dart';
import 'live_session_screen.dart';
import 'legal_screen.dart';
import 'relationship_space_page.dart';
import 'appearance_screen.dart';
import 'backup_screen.dart';
import 'together_screen.dart';
import '../services/live_session_service.dart'
    show activeLiveSession, endActiveLiveSession, ActiveLiveSession;
import '../services/notif_service.dart';
import '../services/fcm_service.dart';
import '../services/share_inbox.dart';
import '../services/contact_names.dart';
import '../services/metadata_overrides.dart';
import '../services/track_title.dart' show splitTitleArtist;
import 'listening_audience_sheet.dart' show PresenceShareButton;
import '../services/app_busy.dart';
import '../utils/net_image.dart';
import 'token_helper.dart';
import '../services/media_store.dart';
import '../utils/avatar_widget.dart';
import '../utils/app_config.dart';
import '../utils/chat_background.dart';
import '../utils/message_preview.dart';
import '../utils/bubble_theme.dart';
import '../services/biometric_service.dart';
import '../services/call_service.dart';
import '../services/group_call_service.dart';
import '../state/group_call_state.dart' show groupCallProvider;
import '../state/call_state.dart' show callProvider, CallSnapshot;
import 'call_screen.dart';
import 'group_call_screen.dart';
import 'stories/stories_tray.dart';
import 'stories/story_models.dart';
import 'stories/story_viewer.dart';
import 'policy_gate.dart';
import 'add_friend_sheet.dart';
import 'spinning_vinyl_ring.dart';
import '../services/connected_contacts_service.dart';
import '../services/now_playing_presence.dart';
import '../services/live_rooms_registry.dart';
import '../services/telecom_service.dart';
import '../utils/file_bytes.dart';
import '../main.dart' show navigatorKey;
import '../utils/time_utils.dart';
// Prefixed: this file also imports package:provider, which exports colliding
// names (Consumer, Provider, ChangeNotifierProvider). `rp.` keeps them distinct.
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import 'package:flutter_slidable/flutter_slidable.dart';
import '../state/playback_state.dart';
import '../state/unread_state.dart';
import '../state/presence_state.dart';

part 'home/home_playback.dart'; // playback bus + per-tick value-notifiers
part 'home/home_widgets.dart'; // panel toggle, scrolling text, logout glyph, live-invite dialog
part 'home/home_friend_list.dart'; // friend/chat list, Our Space hero, chips, tiles
part 'home/home_space_actions.dart'; // Our Space + friend action flows (open/pin/unpin/moment + sheets)
part 'home/home_phone_body.dart'; // phone layout body + expandable player sheet
part 'home/home_banners.dart'; // live-session + call-return banners, live chip
part 'home/home_menu.dart'; // header overflow menu (grouped submenus)
part 'home/home_hub.dart'; // mobile two-tile accordion hub (Harmony / Circle) + badges
part 'home/home_page_helpers_1.dart'; // HomePageState helpers (41 methods)
part 'home/home_page_helpers_2.dart'; // HomePageState helpers (13 methods)

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
  // Active stories feed (mine + friends), grouped by author. Owned here so BOTH
  // the stories tray AND the friend-list tiles (their avatar rings) reflect the
  // same seen-state. Refreshed on init, after posting/viewing, and on the
  // 'story_posted' WebSocket nudge.
  List<StoryGroup> _storyGroups = [];
  // Guards the one-shot legal-consent check so it can't stack multiple gates.
  bool _policyChecked = false;
  // "Our Space" — the user's pinned relationship profiles (light maps). Loaded
  // once on init and again only on pull-to-refresh; never polled or socket-held,
  // so it costs nothing in the background. The primary (hero) renders as the
  // wedge at the very top of the friend list.
  List<Map<String, dynamic>> _spaces = [];
  // Pending incoming bond requests (the "pin a bond" handshake) awaiting MY
  // yes/no — drives the friend-list banner + friend-tile chip. Loaded once + on
  // refresh and kept live by the bond_request* socket events.
  List<Map<String, dynamic>> _incomingBondRequests = [];
  // Monetization: whether the signed-in user is on the Together plan. Drives the
  // hero badge and unlocks the multiple-Spaces gate. Loaded once + on refresh.
  bool _isTogether = false;
  // Friends who are typing to me right now → a live "typing…" line on their
  // tile. A short-lived one-shot timer per active typer (no periodic polling):
  // the timer's presence IS the "typing" state, and it self-clears after 5s.
  final Map<int, Timer> _typingTimers = {};
  // Groups being typed in right now → a live "typing…" line on the GROUP
  // tile, keyed by the group's conversation id (a separate id space from DM
  // user ids, so a group never lights up a friend's DM row). Self-clears 5s.
  final Map<int, Timer> _groupTypingTimers = {};
  // When a chat is opened from a message notification, the id of the message to
  // scroll to + highlight once the thread loads (null for normal opens). Passed
  // to ChatPage; cleared to null on every ordinary open so it fires once.
  String? _pendingJumpMessageId;
  List<Map<String, dynamic>> _filteredGroups = [];
  final TextEditingController _searchCtrl = TextEditingController();
  // A SEPARATE controller for the Harmony (spaces) search, so the two layers'
  // search boxes are independent — required on desktop where both columns show
  // their own search at once, and nice on mobile so switching keeps each query.
  final TextEditingController _spaceSearchCtrl = TextEditingController();
  bool _isLoadingFriends = false;

  // Which friend-page layer is expanded in the MOBILE accordion hub ('harmony'
  // or 'circle'). Both tile headers — with their badges — always stay visible;
  // this only picks which one fills the screen. Defaults to Circle so unread
  // conversations are the first thing in view. (setState lives here in the main
  // class; the hub builder in home_hub.dart just calls _setFriendLayer.)
  String _friendLayer = 'circle';
  // Contextual-search query for the HARMONY layer (spaces). The CIRCLE layer
  // uses the existing _searchQuery / _filterFriends. Switching layers clears the
  // box so a query never bleeds from one side to the other.
  String _spaceQuery = '';
  void _filterSpaces(String query) {
    setState(() => _spaceQuery = query.trim().toLowerCase());
  }

  void _setFriendLayer(String layer) {
    if (_friendLayer == layer) return;
    // Drop any active search focus first, so switching layers never carries the
    // keyboard/focus onto the other layer's (separate) search box.
    FocusManager.instance.primaryFocus?.unfocus();
    // Each layer keeps its OWN search box/controller (Circle: _searchCtrl,
    // Harmony: _spaceSearchCtrl), so switching preserves each side's query
    // rather than wiping it.
    setState(() => _friendLayer = layer);
  }

  // Mobile CIRCLE layer: whether the pinned "Status & Stories" tray is expanded.
  // Collapsing it hands the vertical space to the conversation list for users
  // who want chats front-and-centre; tapping its header toggles it back. (Kept
  // here in the main State so the home_hub extension can flip it without
  // touching @protected setState directly.)
  bool _storiesExpanded = true;
  void _toggleStories() {
    setState(() => _storiesExpanded = !_storiesExpanded);
  }

  // Images shared into Aluta from another app, waiting to be handed to the chat
  // the user next taps (screenshot-share flow). Null when nothing is pending.
  List<String>? _shareToSend;

  // ── Layout state ──────────────────────────────────────────────────────────
  // ONE persistent key for the music player so its State (the just_audio player,
  // the loaded playlist, the current track) survives when the layout switches
  // between the desktop two-pane and the narrow phone body across the 640px
  // breakpoint. Without a shared key, crossing the breakpoint disposed the
  // playing instance and mounted an empty one ("No track loaded").
  final GlobalKey _musicPanelKey = GlobalKey(debugLabel: 'musicControls');
  // Same shared-key trick for the web ('lite') player, so squeezing the
  // window across the mobile breakpoint (or minimising) keeps its loaded queue
  // instead of disposing it and mounting an empty 'Play music here' panel.
  final GlobalKey _webMusicPanelKey = GlobalKey(debugLabel: 'webMusicPanel');
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

  // Global-space point of the last tap that opens an Our Space (its bond hero /
  // chip), so the Space page genies out of / back into that exact spot.
  Offset? _spaceOpenOrigin;
  // The space whose tile was last tapped + a stable key per space tile, so the
  // genie can resolve that tile's LIVE position (it survives the friend list
  // reordering — new message, presence — while the Space page is open).
  int? _spaceOpenOriginId;
  final Map<int, GlobalKey> _spaceTileKeys = {};

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
    // Repaint the friend list when the phone-book name map finishes a
    // (re)read, so saved names appear the moment they load.
    ContactNames.instance.revision.addListener(_onContactsChanged);
    // Phonebook name map so saved contact names show in the friend list.
    // Deferred ~4s off the first frame (never competes with cold-start render/
    // audio), and allowPrompt so it REQUESTS contacts permission if it isn't
    // granted yet — requestPermission only shows a dialog when not already
    // granted, so a user who already allowed contacts sees no prompt and their
    // names just load. Without this, a device that never granted READ_CONTACTS
    // would silently show every chat as a bare number.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 4), () {
        if (!mounted) return;
        ContactNames.instance.ensureLoaded(allowPrompt: true).then((_) {
          if (mounted) setState(() {});
        });
      });
    });
    // Restore the user's backed-up song-detail edits (custom titles/artists) for
    // this account, so they survive a reinstall/update or a new device. Merges
    // into local storage (local edits win), then repaint so titles show at once.
    metadataStore.pullFromServer().then((_) {
      if (mounted) setState(() {});
    });
    _loadUserData();
    _loadCachedFriends();    // show cached DM list instantly (no spinner flash)
    _loadCachedGroups();     // and the cached group chats, for offline Circle
    _loadCachedSpaces();     // and the pinned Our Space hero(es), for offline
    _loadCachedStories();    // status & stories, for offline (24h-filtered)
    loadChatBackground();    // the chosen chat wallpaper (photo/motif/default)
    loadBubbleTheme();       // the chosen message-bubble colour theme
    _fetchFriends();          // then refresh from network
    _loadSpaces();            // pinned "Our Space" hero(es) — one-shot, no poll
    _loadBondRequests();      // pending "pin a bond" requests (banner + chip)
    _loadPlan();              // Together entitlement (badge + gating)
    _fetchStories();          // active stories for the tray + tile rings
    _loadLayoutState();
    _discoverServer();

    // Legal consent: after the first frame, check whether this user must read &
    // agree to the current Privacy Policy + Terms (a fresh account, or an
    // existing user after we bump the policy version). Runs post-frame so a
    // valid BuildContext is available to present the blocking gate.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePolicyAccepted());

    // Register this device for push notifications (Android/iOS; no-op else) so
    // messages/calls wake the phone when the app is backgrounded or closed. The
    // authed home only mounts after login, so this doubles as "register on
    // login" and re-registers on every relaunch (token can rotate).
    FcmService.instance.registerToken();

    // Android "Connected apps": surface Aluta actions ("Voice call on Aluta",
    // "Message on Aluta") under matched phone-book contacts, like WhatsApp /
    // Telegram. Register the tap-router + drain any cold-start action now, then
    // refresh the matched rows shortly after launch (self-gates on the contacts
    // permission; a no-op off Android).
    // Only the lightweight action channel is wired at launch (no device read).
    // The contacts SCAN is fully on demand — it runs when the user asks to find
    // friends (see _findFriendsFromContacts), never automatically at launch, so
    // a fresh install never blocks on a cold contacts read.
    ConnectedContactsService.instance.onAction = _onConnectedContactAction;
    ConnectedContactsService.instance.init();

    // Live "Listening now": repaint tiles when a friend's playback changes, and
    // seed the current snapshot of who's playing right now.
    NowPlayingPresence.instance.addListener(_onPresenceChanged);
    // Keep the "Listening now" zone fresh. On web, poll the snapshot as a
    // safety net — live friend_now_playing events can be missed there, which
    // left friends' listening status never appearing.
    NowPlayingPresence.instance.startReceiving(poll: kIsWeb);
    // Seed any live "Listening Rooms" a friend is already hosting (events keep
    // this current afterwards).
    LiveRoomsRegistry.instance.loadSnapshot();

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
    // After the first frame, nudge users who haven't linked a recovery key.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybePromptRecoverySetup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectionStatus.instance.online.removeListener(_onGlobalConnChanged);
    SessionEvents.instance.expired.removeListener(_onSessionExpired);
    ShareInbox.instance.removeListener(_onSharePending);
    ContactNames.instance.revision.removeListener(_onContactsChanged);
    playlistDrawerBus.isOpen.removeListener(_onPlaylistDrawerToggled);
    NowPlayingPresence.instance.removeListener(_onPresenceChanged);
    NowPlayingPresence.instance.stopReceiving();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    for (final t in _groupTypingTimers.values) {
      t.cancel();
    }
    _playlistDrawerCtrl.dispose();
    _searchCtrl.dispose();
    _spaceSearchCtrl.dispose();
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

  // The playlist toggle in a chat header. On WEB there's no device music library
  // to load, so opening the drawer does nothing useful — tell the user which
  // apps DO support it instead of silently toggling an empty drawer.
  void _openChatPlaylist() {
    if (kIsWeb) {
      _showWebQueueSheet();
      return;
    }
    playlistDrawerBus.toggle?.call();
  }


  bool _handlingExpiry = false;
  Future<void> _onSessionExpired() async {
    if (!SessionEvents.instance.expired.value) return;
    if (_handlingExpiry || !mounted) return;
    // WhatsApp-style: a dropped connection is NOT an expired session. NEVER
    // bounce to the phone-number screen while offline — a token we simply can't
    // refresh right now (no internet) must not sign the user out. Keep them on
    // their cached data behind the biometric lock; the reconnect path re-checks
    // the real session the moment the network is back, and only a server that
    // is actually reachable AND rejects the session sends them to login.
    final conn = await Connectivity().checkConnectivity();
    if (conn.every((r) => r == ConnectivityResult.none)) {
      SessionEvents.instance.reset(); // let it fire again once truly online
      return;
    }
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
      // Keep the launch gate consistent: a genuine, online expiry is a real
      // sign-out, so the next cold start shows login (not a tokenless Home).
      await prefs.setBool('isLoggedIn', false);
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
      // Re-seed who's listening now (a live event may have been missed while
      // backgrounded).
      NowPlayingPresence.instance.loadSnapshot();
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

  /// Open the sender's thread from a tapped message notification. Uses the
  /// loaded friend list when available (so avatar/phone are correct), else a
  /// minimal record from the payload — ChatPage fetches the rest by id.
  void _handleMessageTap(Map<String, dynamic> payload) {
    if (!mounted) return;
    // The exact message that was notified — the thread scrolls to + highlights
    // it once open (completes the deep-link, not just landing in the thread).
    final jumpMsg = (payload['message_id'] ?? '').toString();
    final jump = jumpMsg.isEmpty ? null : jumpMsg;
    // Group message → land directly in the group thread (mirrors the DM path).
    final convId =
        int.tryParse((payload['conversation_id'] ?? '').toString());
    if (convId != null) {
      Map<String, dynamic> group = _groups.firstWhere(
        (g) => (g['id']).toString() == convId.toString(),
        orElse: () => <String, dynamic>{},
      );
      if (group.isEmpty) {
        // Not in the loaded list yet — open a minimal record and refresh so the
        // header (name/members) fills in.
        group = {
          'id': convId,
          'title': (payload['group_title'] ?? 'Group').toString(),
          'members': const [],
        };
        _fetchGroups();
      }
      openGroupInPanel(group, jumpToMessageId: jump);
      return;
    }
    final fid = int.tryParse((payload['friend_id'] ?? '').toString());
    if (fid == null) return;
    Map<String, dynamic> friend = _allFriends.firstWhere(
      (e) => (e['id']).toString() == fid.toString(),
      orElse: () => <String, dynamic>{},
    );
    if (friend.isEmpty) {
      friend = {
        'id': fid,
        'username': (payload['sender_name'] ?? 'Friend').toString(),
      };
    }
    openChat(friend, jumpToMessageId: jump);
  }

  bool _callLaunchConsumed = false;

  /// Handle Accept/Decline tapped on the ringing notification while the app is
  /// alive (the offer is already in memory).
  void _handleCallNotificationAction(
      String actionId, Map<String, dynamic> payload) {
    final isGroup = payload['group'] == true;
    if (actionId == kCallAccept) {
      if (isGroup) {
        _openGroupCallScreen();
        GroupCallService.instance.accept();
      } else {
        _openCallScreen();
        CallService.instance.acceptCall();
      }
    } else if (actionId == kCallDecline) {
      if (isGroup) {
        GroupCallService.instance.leave();
      } else {
        CallService.instance.declineCall();
      }
    }
  }

  bool _callScreenOpen = false;
  bool _groupCallScreenOpen = false;

  /// Show the full-screen group-call UI (incoming ring or an outgoing call).
  void _openGroupCallScreen() {
    if (_groupCallScreenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _groupCallScreenOpen = true;
    nav
        .push(PageRouteBuilder(
          opaque: true,
          barrierColor: Colors.black,
          transitionDuration: const Duration(milliseconds: 240),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, _, _) => const GroupCallScreen(),
          transitionsBuilder: (_, anim, _, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: child,
          ),
        ))
        .then((_) {
          _groupCallScreenOpen = false;
          // The screen was popped (minimized or ended). Rebuild so the global
          // "return to call" banner appears while the call is still active.
          if (mounted) setState(() {});
        });
    if (mounted) setState(() {});
  }

  /// Show the full-screen call UI (for an incoming ring or an outgoing call).
  void _openCallScreen() {
    if (_callScreenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _callScreenOpen = true;
    // Cross-fade in/out rather than the default fullscreen-dialog slide. The
    // slide made hang-up look like the screen was "splitting" as the call UI
    // slid down and revealed the home screen; a fade dismisses cleanly.
    nav
        .push(PageRouteBuilder(
          opaque: true,
          barrierColor: Colors.black,
          transitionDuration: const Duration(milliseconds: 240),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, _, _) => const CallScreen(),
          transitionsBuilder: (_, anim, _, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: child,
          ),
        ))
        .then((_) => _callScreenOpen = false);
  }

  void _handleNotification(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type']?.toString();
    // Group (mesh) call signaling — group_call_*, group_offer/answer/ice.
    if (type != null &&
        (type.startsWith('group_call') ||
            type == 'group_offer' ||
            type == 'group_answer' ||
            type == 'group_ice')) {
      GroupCallService.instance.onSignal(event);
      return;
    }
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
    if (type == 'live_declined') {
      _showLiveDeclined(event);
      return;
    }
    // A friend opened a live "Listening Room" → surface a drop-in card in the
    // Live Room slot. (Ignore my own room echoed back to me.)
    if (type == 'live_room_available') {
      final data = (event['data'] as Map?) ?? const {};
      final hostId = (data['host_id'] as num?)?.toInt();
      if (hostId != null && hostId != _myUserId) {
        LiveRoomsRegistry.instance.applyAvailable(data);
      }
      return;
    }
    // A friend's room closed → remove its card.
    if (type == 'live_room_ended') {
      LiveRoomsRegistry.instance.applyEnded((event['data'] as Map?) ?? const {});
      return;
    }
    // Your partner pinned a moment / dedicated a song in Our Space — a warm
    // live nudge, and refresh the hero so the new moment is there when opened.
    if (type == 'space_moment') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} pinned a moment for you 💛')
          .toString();
      if (mounted) showToast(context, line, type: ToastType.info);
      _loadSpaces();
      spaceEventBus.value++; // live-reload an open Our Space page
      return;
    }
    // Your partner reacted to a moment you pinned.
    if (type == 'space_moment_react') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final who = (data['from_username'] ?? 'Your partner').toString();
      final emoji = (data['emoji'] ?? '❤️').toString();
      if (mounted) {
        showToast(context, '$who reacted $emoji to your moment',
            type: ToastType.info);
      }
      spaceEventBus.value++;
      return;
    }
    // Your partner added a song to Our Playlist — warm toast + refresh the hero.
    if (type == 'space_playlist_add') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} added a song to your '
                  'playlist 🎶')
          .toString();
      if (mounted) showToast(context, line, type: ToastType.info);
      _loadSpaces();
      spaceEventBus.value++;
      return;
    }
    // Your partner removed a song — keep the shared crate in sync by refreshing
    // any open Our Space page (quietly, no toast).
    if (type == 'space_playlist_remove') {
      _loadSpaces();
      spaceEventBus.value++;
      return;
    }
    // A dedication just arrived for you — warm toast + refresh the hub badge.
    if (type == 'dedication_received') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} sent you a dedication 💝')
          .toString();
      if (mounted) showToast(context, line, type: ToastType.info);
      _loadSpaces();
      spaceEventBus.value++;
      return;
    }
    // Daily "Us" question — your partner answered, or you both just revealed.
    if (type == 'prompt_answered' || type == 'prompt_revealed') {
      final reveal = type == 'prompt_revealed';
      if (mounted) {
        showToast(
          context,
          reveal
              ? 'You both answered today\'s question 💞'
              : 'Your partner answered today\'s question 💬',
          type: ToastType.info,
        );
      }
      _loadSpaces();
      spaceEventBus.value++;
      return;
    }
    // Your partner wrote in, commented on, or reacted in Our Diary — live-
    // refresh any open Our Space page (and its open memory + comment feed)
    // without a manual refresh. A toast for a new entry/comment; reactions are
    // silent (just the visual update).
    if (type == 'space_diary' ||
        type == 'space_diary_comment' ||
        type == 'space_diary_react' ||
        type == 'space_moment_comment' ||
        type == 'space_capsule' ||
        type == 'capsule_unlocked') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ?? '').toString();
      if (type != 'space_diary_react' && line.isNotEmpty && mounted) {
        showToast(context, line, type: ToastType.info);
      }
      _loadSpaces();
      spaceEventBus.value++; // live-reload an open Our Space page + memory
      return;
    }
    // Your partner tapped "Thinking of you" in Our Space — a warm live ping.
    if (type == 'space_nudge') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} is thinking of you 💭')
          .toString();
      if (mounted) showToast(context, line, type: ToastType.info);
      return;
    }
    // Someone wants to pin a bond with you → show the approval banner + toast.
    if (type == 'bond_request') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} wants to pin a bond 💞')
          .toString();
      if (mounted) showToast(context, line, type: ToastType.info);
      _loadBondRequests();
      return;
    }
    // They accepted your bond → the Space is live for both of you.
    if (type == 'bond_request_accepted') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} accepted — your Space is '
                  'live 🎉')
          .toString();
      if (mounted) showToast(context, line, type: ToastType.success);
      _loadBondRequests();
      _loadSpaces();
      return;
    }
    // A bond request was declined or withdrawn → clear it from my lists quietly.
    if (type == 'bond_request_declined' || type == 'bond_request_cancelled') {
      _loadBondRequests();
      return;
    }
    // A friend posted a story → refresh the feed so their ring appears on the
    // tray + their conversation tile, without the user pulling to refresh.
    if (type == 'story_posted') {
      _fetchStories();
      return;
    }
    // A friend started/stopped/changed what they're listening to → update the
    // live "Listening now" indicator on their tile.
    if (type == 'friend_now_playing') {
      NowPlayingPresence.instance.applyEvent(event);
      return;
    }
    // A friend is typing to me → show a live "typing…" line on their tile.
    if (type == 'typing') {
      // Group typing carries a conversation_id → light the GROUP tile, not the
      // sender's DM row (which would wrongly suggest the reply lands in the DM).
      // DM typing has no conversation_id → light the friend's DM tile as before.
      final convRaw = (event['conversation_id'] ?? '').toString();
      final convId = int.tryParse(convRaw);
      if (convId != null) {
        _setGroupTyping(convId);
      } else {
        final uid = (event['user_id'] as num?)?.toInt();
        if (uid != null) _setFriendTyping(uid);
      }
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
      // Badge the sender immediately (unless their chat is open) — the fetch
      // below reconciles to the server's authoritative count a moment later.
      final senderId = (senderObj?['id'] as num?)?.toInt() ??
          (data['sender_id'] as num?)?.toInt();
      if (!_appForeground) {
        final convId = (data['conversation_id'] ?? '').toString();
        final gTitle = (data['group_title'] ?? '').toString();
        final msgId = (data['id'] ?? data['message_id'] ?? '').toString();
        final isGroup = convId.isNotEmpty;
        showMessageNotification(
          title: isGroup && gTitle.isNotEmpty ? gTitle : sender,
          body: isGroup
              ? '$sender: ${text.isEmpty ? 'Sent a message' : text}'
              : (text.isEmpty ? 'Sent you a message' : text),
          senderId: senderId?.toString(),
          senderName: sender,
          conversationId: convId.isEmpty ? null : convId,
          groupTitle: gTitle.isEmpty ? null : gTitle,
          messageId: msgId.isEmpty ? null : msgId,
        );
      }
      if (senderId != null && senderId.toString() != _activeFriendId) {
        ref.read(unreadProvider.notifier).bump(senderId);
      }
      // Refresh the conversation list so previews/unread update either way.
      _fetchFriends();
    }
  }

  Future<void> _loadUserData() async {
    appBusy.begin();
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
    } finally {
      appBusy.end();
    }
  }

  // ── Friends — cache-first, refresh on network ────────────────────────────

  static const _kFriendsCache = 'cached_friends_v1';
  static const _kGroupsCache = 'cached_groups_v1';

  /// Load the last-known GROUP conversations from disk so the Circle's group
  /// chats are present offline (DMs already cache via _loadCachedFriends; per-
  /// chat messages cache in chat_page). Without this, a cold offline start
  /// showed no groups until the network came back.
  Future<void> _loadCachedGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kGroupsCache);
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      await _hydratePreviewsFromCache(list, group: true);
      if (!mounted) return;
      setState(() {
        _groups = list;
        _filteredGroups = _applyGroupQuery(list, _searchQuery);
      });
    } catch (_) {}
  }

  Future<void> _saveGroupsCache(List<Map<String, dynamic>> groups) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kGroupsCache, jsonEncode(groups));
    } catch (_) {}
  }

  Future<void> _loadCachedFriends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kFriendsCache);
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      await _hydratePreviewsFromCache(list, group: false);
      if (!mounted) return;
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
    appBusy.begin();
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
      // Don't let a purge-blanked server preview erase a good local one, and
      // rebuild any still-empty preview from the durable local chat cache.
      _preservePreviews(friends, _allFriends);
      await _hydratePreviewsFromCache(friends, group: false);
      // Save fresh data to cache
      await _saveFriendsCache(friends);
      setState(() {
        _allFriends = friends;
        // Respect an active search query — mirrors _fetchGroups so a background
        // refresh can't leave friends unfiltered while groups stay filtered.
        _filteredFriends = _applyFriendQuery(friends, _searchQuery);
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
    } finally {
      appBusy.end();
    }
  }

  /// Fetch the group conversations the user belongs to and keep them in
  /// `_groups` (they render at the top of the friend list). Silent on failure —
  /// a group fetch error must never disturb the DM list.
  Future<void> _fetchGroups() async {
    appBusy.begin();
    try {
      final convs = await ApiService().listConversations();
      if (!mounted) return;
      final groups = convs
          .where((c) => c['is_group'] == true)
          .toList();
      _preservePreviews(groups, _groups);
      await _hydratePreviewsFromCache(groups, group: true);
      // Persist so the group list survives offline / a cold restart.
      await _saveGroupsCache(groups);
      setState(() {
        _groups = groups;
        _filteredGroups = _applyGroupQuery(groups, _searchQuery);
      });
    } catch (_) {
      // Offline / fetch error — fall back to the cached list if we have none.
      if (mounted && _groups.isEmpty) await _loadCachedGroups();
    } finally {
      appBusy.end();
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

  String _searchQuery = '';

  void _filterFriends(String query) {
    setState(() {
      _searchQuery = query;
      _filteredFriends = _applyFriendQuery(_allFriends, query);
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

  void _onContactsChanged() {
    if (mounted) setState(() {});
  }

  void _cancelShare() {
    ShareInbox.instance.clear();
    setState(() => _shareToSend = null);
  }

  /// Resolve a user id → {name, phone, avatar} from the app's own data so a
  /// group-call participant (the backend sends only ids) shows a proper
  /// identity. Prefers the friend list (whose phone drives the phonebook-name
  /// lookup), then any group's member roster; returns the registered username
  /// as the fallback name so tiles never read "Member". Wired into
  /// GroupCallService.resolveIdentity.
  Map<String, dynamic>? _identityForUser(int userId) {
    final key = userId.toString();
    for (final f in _allFriends) {
      if (f['id']?.toString() == key) {
        return {
          'name': (f['username'] ?? '').toString(),
          'phone': f['phone'] as String?,
          'avatar': f['avatar_url'] as String?,
        };
      }
    }
    for (final g in _groups) {
      for (final m in (g['members'] as List?) ?? const []) {
        if (m is Map && m['user_id']?.toString() == key) {
          return {
            'name': (m['username'] ?? '').toString(),
            'phone': m['phone'] as String?,
            'avatar': m['avatar_url'] as String?,
          };
        }
      }
    }
    return null;
  }

  /// Fetch the active stories feed (mine + friends) that drives the tray AND
  /// the friend-list avatar rings. Silent on failure.
  static const _kStoriesCache = 'cached_stories_v1';

  Future<void> _loadCachedStories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawStr = prefs.getString(_kStoriesCache);
      if (rawStr == null || !mounted) return;
      final list = (jsonDecode(rawStr) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final groups =
          _activeStoryGroups(list.map(StoryGroup.fromJson).toList());
      if (!mounted) return;
      setState(() => _storyGroups = groups);
      _prefetchStories(groups);
    } catch (_) {}
  }

  Future<void> _fetchStories() async {
    try {
      final raw = await ApiService().fetchStoriesFeed();
      if (!mounted) return;
      // Persist the feed for offline; the 24h filter is applied on read so a
      // cached status still clears on time even with no connection.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kStoriesCache, jsonEncode(raw));
      } catch (_) {}
      final groups = _activeStoryGroups(raw.map(StoryGroup.fromJson).toList());
      setState(() => _storyGroups = groups);
      _prefetchStories(groups);
    } catch (_) {
      // Offline / fetch error — keep whatever the cache already loaded.
    }
  }

  /// Repaint the friend list when a friend starts / stops / changes what
  /// they're listening to (driven by NowPlayingPresence).
  void _onPresenceChanged() {
    if (mounted) setState(() {});
  }

  /// Mark [id] as typing to me and auto-clear after 5s (each typing event
  /// refreshes the timer). No periodic polling — the timer's presence IS the
  /// state, and it only exists while someone is actively typing.
  void _setFriendTyping(int id) {
    final was = _typingTimers.containsKey(id);
    _typingTimers[id]?.cancel();
    _typingTimers[id] = Timer(const Duration(seconds: 5), () {
      _typingTimers.remove(id);
      if (mounted) setState(() {});
    });
    if (!was && mounted) setState(() {});
  }

  /// Mark group [convId] as having a live typer and auto-clear after 5s. Keyed
  /// by conversation id so it drives the group tile, never a DM row.
  void _setGroupTyping(int convId) {
    final was = _groupTypingTimers.containsKey(convId);
    _groupTypingTimers[convId]?.cancel();
    _groupTypingTimers[convId] = Timer(const Duration(seconds: 5), () {
      _groupTypingTimers.remove(convId);
      if (mounted) setState(() {});
    });
    if (!was && mounted) setState(() {});
  }

  /// Sign out directly from the consent gate when the user declines to accept.
  /// No confirm dialog — declining consent is itself the deliberate choice.
  Future<void> _signOutFromGate() async {
    try {
      await FcmService.instance.unregisterToken();
    } catch (_) {}
    NowPlayingPresence.instance.stop();
    await ConnectedContactsService.instance.clear();
    await ApiService().logoutUser();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthPage()),
      (route) => false,
    );
  }

  // ── Chat open/close ───────────────────────────────────────────────────────

  void openChat(Map<String, dynamic> friend, {String? jumpToMessageId}) {
    setState(() {
      _pendingJumpMessageId = jumpToMessageId;
      _clearSearchState();
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
  void openGroupInPanel(Map<String, dynamic> conv, {String? jumpToMessageId}) {
    setState(() {
      _pendingJumpMessageId = jumpToMessageId;
      _clearSearchState();
      _activeGroup = conv;
      // Groups and DMs are mutually exclusive in the panel.
      _activeFriendId = null;
      _activeFriendName = null;
      _activeFriendOnline = null;
      _activeFriendLastSeen = null;
      _avatarExpanded = false;
      _playerExpanded = false; // make sure the chat panel is the front surface
    });
    // Ask the server whether a call is already live in this group, so the
    // "call in progress · Join" banner shows even if we missed the ring.
    _refreshGroupCallState(conv);
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

  /// Routed from the phone's Contacts app when the user taps Aluta's "Voice
  /// call" / "Message" row under a contact. Resolves the friend (falling back to
  /// a minimal record if not loaded yet) and opens the call or chat.
  void _onConnectedContactAction(String action, int userId, String number) {
    if (userId <= 0) return;
    Map<String, dynamic>? friend;
    for (final f in _allFriends) {
      if ((f['id']?.toString() ?? '') == userId.toString()) {
        friend = Map<String, dynamic>.from(f);
        break;
      }
    }
    friend ??= <String, dynamic>{
      'id': userId,
      'username': 'Aluta user',
      'phone': number.isNotEmpty ? number : null,
      'avatar_url': null,
      'is_online': false,
    };
    if (action == 'message') {
      openChat(friend);
    } else if (action == 'call') {
      _startAlutaCall(
        userId,
        (friend['username'] ?? 'Aluta user').toString(),
        friend['avatar_url'] as String?,
        (friend['phone'] as String?) ?? (number.isNotEmpty ? number : null),
      );
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
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.logout_rounded,
                        color: scheme.primary, size: 26),
                  ),
                  const SizedBox(height: 14),
                  Text('Sign out?',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface)),
                  const SizedBox(height: 8),
                  Text(
                    'You will stop receiving messages and calls on this device '
                    'until you sign back in. Your chats and account stay safe '
                    'on the server.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.primary,
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (confirmed != true) return;
    // Stop pushes reaching this device for the account we're leaving (done while
    // the token is still valid, before logoutUser clears it). Best-effort.
    await FcmService.instance.unregisterToken();
    NowPlayingPresence.instance.stop();
    // Remove Aluta's "Connected apps" contact rows for the account we're leaving.
    await ConnectedContactsService.instance.clear();
    await ApiService().logoutUser();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AuthPage()),
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
          // Group actions live under a hamburger ☰ — the classic partner to a
          // kebab. The app-wide menu (top-right) owns the vertical ⋮, so pairing
          // ☰ (this chat) with ⋮ (app) makes the two instantly distinct, and a
          // hamburger avoids the dots that would echo the typing indicator.
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu_rounded),
            tooltip: 'Group options',
            onSelected: (v) {
              switch (v) {
                case 'info':
                  _openGroupInfo();
                  break;
                case 'call':
                  _startGroupCall(g);
                  break;
                case 'playlist':
                  _openChatPlaylist();
                  break;
                case 'wallpaper':
                  showChatWallpaperSheet(
                    context,
                    convKey: chatConvKey(
                        conversationId: (g['id'] as num).toInt()),
                    title: (g['title'] ?? 'Group').toString(),
                  );
                  break;
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'info',
                child: _groupMenuRow(
                    Icons.info_outline_rounded, 'Group info', scheme),
              ),
              PopupMenuItem(
                value: 'call',
                child:
                    _groupMenuRow(Icons.call_rounded, 'Group call', scheme),
              ),
              PopupMenuItem(
                value: 'playlist',
                child: _groupMenuRow(
                    Icons.queue_music_rounded,
                    playlistDrawerBus.isOpen.value
                        ? 'Hide playlist'
                        : 'Playlist',
                    scheme),
              ),
              PopupMenuItem(
                value: 'wallpaper',
                child: _groupMenuRow(
                    Icons.wallpaper_rounded, 'Wallpaper', scheme),
              ),
            ],
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
              // If this friend has an active status, tap opens it; otherwise
              // tap expands the profile photo (when there's one to show).
              final story = _friendStory(_activeFriendId);
              if (story != null) {
                _openFriendStory(story);
              } else if (_avatarFull(_activeFriendAvatar) != null) {
                setState(() => _avatarExpanded = !_avatarExpanded);
              }
            },
            // Same status ring as the friend list (colourful=unseen, grey=seen).
            child: _statusRing(
              InitialsAvatar(
                name: _contactDisplayName(
                    _activeFriendPhone, _activeFriendName ?? ''),
                radius: 17,
                isOnline: _activeFriendOnline == true,
                imageUrl: _avatarFull(_activeFriendAvatar),
              ),
              _friendStory(_activeFriendId),
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
          _dmHeaderCluster(scheme),
        ],
      );
    }

    // Header adapts to the PANE's own width (via LayoutBuilder), not the whole
    // window — so a shrunk desktop pane falls back to the SAME mobile chrome as
    // the body below: the Harmony/Circle switch pills instead of the logo +
    // expand toggle. The 600 threshold matches _buildFriendList, so header and
    // body flip together (never a desktop header over a mobile body).
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool phone = constraints.maxWidth < 600;
        return Row(
      children: [
        if (phone) ...[
          // The two flagship layers as compact toggle-pills — replacing the logo
          // + "Messages". Tap to switch; the active one is lit, both carry their
          // badge so anything pending shows at first glance. The lit pill IS the
          // header, so the whole screen below is that layer's content.
          _layerTab(scheme, 'harmony', 'Harmony', Icons.favorite_rounded,
              _harmonyBadge()),
          const SizedBox(width: 14),
          _layerTab(scheme, 'circle', 'Circle', Icons.forum_rounded,
              _circleBadge()),
          const Spacer(),
        ] else ...[
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
          // Brand mark leads the desktop header; the HARMONY / CIRCLE column
          // headers below name the two layers, so no "Messages" title is needed.
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
          const Spacer(),
        ],
        // Right side status: when online, a green "N online" chip (moved up
        // from the status strip) balances the logo+title on the left; when
        // offline, the tap-to-reconnect badge takes its place.
        if (_serverReachable)
          Tooltip(
            message:
                'Connected to $_serverIp\nTap to configure · long-press to rediscover',
            child: GestureDetector(
              onTap: _showServerSettings,
              onLongPress: () => _discoverServer(forceReset: true),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(28),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _statusDot(const Color(0xFF2FA84F)),
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
      },
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
          _buildGroupJoinBanner(context),
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
                      initialJumpMessageId: _pendingJumpMessageId,
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
                      initialJumpMessageId: _pendingJumpMessageId,
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
    _loadSpaces();
    _loadPlan();
  }

  static const _kSpacesCache = 'cached_spaces_v1';

  /// Show the last-known pinned Spaces from disk so the Our Space hero is
  /// present offline / instantly at cold start.
  Future<void> _loadCachedSpaces() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSpacesCache);
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (_spaces.isEmpty) setState(() => _spaces = list);
    } catch (_) {}
  }

  /// Load my pinned Spaces (best-effort, fail-soft). Runs once on init and on
  /// pull-to-refresh only — never on a timer.
  Future<void> _loadSpaces() async {
    final spaces = await ApiService().listSpaces();
    if (!mounted) return;
    // Offline (empty result while disconnected) must NOT wipe the pinned hero —
    // keep showing the cached list; a real fetch replaces + re-caches it.
    if (spaces.isEmpty && !ConnectionStatus.instance.isOnline) {
      await _loadCachedSpaces();
      return;
    }
    setState(() => _spaces = spaces);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSpacesCache, jsonEncode(spaces));
    } catch (_) {}
  }

  /// Load pending bond requests (best-effort). Runs on init, on refresh, and
  /// whenever a bond_request* socket event lands.
  Future<void> _loadBondRequests() async {
    final data = await ApiService().listBondRequests();
    if (!mounted) return;
    setState(() {
      _incomingBondRequests = ((data['incoming'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    });
  }

  /// Load the Together entitlement (fail-soft → free).
  Future<void> _loadPlan() async {
    final plan = await ApiService().getPlan();
    if (!mounted) return;
    setState(() => _isTogether = plan['is_together'] == true);
  }


  void _reopenLiveSession() {
    if (activeLiveSession == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.resume(),
    ));
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
    final hasRealTrack = title.isNotEmpty && title != 'No track loaded';
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.primary,
    );
    // Jump straight to the full player panel — remembering it came from the
    // pill, so closing it returns here (bar stays dismissed).
    void openPanel() => setState(() {
          _panelFromPill = true;
          _playerExpanded = true;
        });
    // Single tap: if a track is loaded, bring the collapsed now-playing bar back
    // above the footer; if nothing's loaded yet (fresh launch — the library is
    // scanned lazily, on demand), there's no bar to show, so open the full
    // player so the user can pick/scan music. Double-tap/long-press always opens
    // the full panel.
    void tapAction() {
      if (hasRealTrack) {
        setState(() => _barDismissed = false);
      } else {
        openPanel();
      }
    }
    return GestureDetector(
      onTap: tapAction,
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
      // Don't resize the (heavy) home body for the keyboard while the MUSIC
      // panel is the front surface. The only keyboard there is the edit-details
      // sheet, which positions itself above the keyboard via its own viewInsets
      // padding (unaffected by this). Resizing would relayout the whole album-art
      // playlist on every keyboard frame, stalling the keyboard's rise — the
      // "slow/stuck keyboard" when editing song details. Chats (panel collapsed)
      // still resize so the message input rides above the keyboard.
      resizeToAvoidBottomInset: !_playerExpanded,
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
          IconButton(
            tooltip: 'Search messages',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const MessageSearchScreen())),
          ),
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
          _buildCallReturnBanner(context),
          _buildDmCallReturnBanner(context),
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

/// Rebuilds [builder] once a second — drives the live MM:SS label on the
/// minimized-call "return to call" banner without a Timer living in the page.
class _CallTicker extends StatefulWidget {
  const _CallTicker({required this.builder});
  final Widget Function() builder;

  @override
  State<_CallTicker> createState() => _CallTickerState();
}

class _CallTickerState extends State<_CallTicker> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder();
}


// ─── In-chat web queue sheet ──────────────────────────────────────────────────
// A live view of the web ("lite") player's in-memory queue, with a full
// transport strip, reachable from the chat header's playlist button. All of its
// controls drive the lite player through playbackBus; it mirrors how the native
// playlist drawer is reachable from a chat.
class _WebQueueSheet extends StatefulWidget {
  const _WebQueueSheet();

  @override
  State<_WebQueueSheet> createState() => _WebQueueSheetState();
}

class _WebQueueSheetState extends State<_WebQueueSheet> {
  Timer? _tick;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() {});
    });
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms < 0 ? 0 : ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rev = playbackBus.webQueueRev;
    return SafeArea(
      child: rev == null
          ? _content(scheme)
          : ValueListenableBuilder<int>(
              valueListenable: rev,
              builder: (_, _, _) => _content(scheme),
            ),
    );
  }

  Widget _avatar(ColorScheme scheme, bool isNow) {
    final accent = scheme.primary;
    final isDark = scheme.brightness == Brightness.dark;
    const d = 42.0;
    if (isNow) {
      return Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(accent, Colors.white, 0.22)!,
              accent,
              Color.lerp(accent, Colors.black, 0.14)!,
            ],
          ),
          boxShadow: [
            BoxShadow(
                color: accent.withValues(alpha: 0.45),
                blurRadius: 12,
                spreadRadius: 1),
          ],
        ),
        child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 20),
      );
    }
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
                accent.withValues(alpha: isDark ? 0.16 : 0.10), scheme.surface),
            Color.alphaBlend(accent.withValues(alpha: isDark ? 0.26 : 0.18),
                scheme.surfaceContainerHighest),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Icon(Icons.music_note_rounded,
          size: 19, color: accent.withValues(alpha: 0.95)),
    );
  }

  Widget _content(ColorScheme scheme) {
    final accent = scheme.primary;
    final items = playbackBus.webQueue?.call() ?? const [];
    final current = playbackBus.webCurrentIndex?.call() ?? -1;
    final playing = playbackBus.isPlaying?.call() ?? false;
    final posMs = playbackBus.currentPositionMs?.call() ?? 0;
    final durMs = playbackBus.webDurationMs?.call() ?? 0;
    final title = (playbackBus.currentTitle?.call() ?? '').trim();
    final frac = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;
    final maxH = MediaQuery.of(context).size.height * 0.82;

    final matches = <int>[];
    for (var i = 0; i < items.length; i++) {
      if (_query.isEmpty || items[i].title.toLowerCase().contains(_query)) {
        matches.add(i);
      }
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header — Playlist (N) + add.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded, size: 20, color: accent),
                const SizedBox(width: 8),
                Text('Playlist (${items.length})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                IconButton(
                  tooltip: 'Add songs',
                  iconSize: 22,
                  color: accent,
                  onPressed: () => playbackBus.webAddSongs?.call(),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
          // Search.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search tracks…',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor:
                    scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // List.
          Flexible(
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                        items.isEmpty ? 'No songs loaded' : 'No matches',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 2),
                    itemCount: matches.length,
                    itemBuilder: (_, k) {
                      final i = matches[k];
                      final isNow = i == current;
                      final ta = splitTitleArtist(items[i].title);
                      return ListTile(
                        dense: true,
                        leading: _avatar(scheme, isNow),
                        title: Text(
                          ta.$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isNow ? FontWeight.w700 : FontWeight.w600,
                            color: isNow ? accent : null,
                          ),
                        ),
                        subtitle: (ta.$2 != null && ta.$2!.isNotEmpty)
                            ? Text(
                                ta.$2!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isNow
                                      ? accent.withValues(alpha: 0.75)
                                      : scheme.onSurfaceVariant,
                                ),
                              )
                            : null,
                        onTap: () => playbackBus.webPlayAt?.call(i),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'More',
                          icon: Icon(Icons.more_vert_rounded,
                              color: scheme.onSurfaceVariant),
                          onSelected: (v) {
                            if (v == 'play') {
                              playbackBus.webPlayAt?.call(i);
                            } else if (v == 'remove') {
                              playbackBus.webRemoveAt?.call(i);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'play',
                              child: Row(children: [
                                Icon(Icons.play_arrow_rounded, size: 20),
                                SizedBox(width: 10),
                                Text('Play'),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Row(children: [
                                Icon(Icons.close_rounded, size: 20),
                                SizedBox(width: 10),
                                Text('Remove from queue'),
                              ]),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          // Now-playing bar — seek + mini art + title + share + prev/play/next.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: accent,
                    inactiveTrackColor: accent.withValues(alpha: 0.20),
                    thumbColor: accent,
                    overlayColor: accent.withValues(alpha: 0.14),
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                  ),
                  child: Slider(
                    value: frac.toDouble(),
                    onChanged: durMs > 0
                        ? (v) => playbackBus.onSeekFraction?.call(v)
                        : null,
                  ),
                ),
                Row(
                  children: [
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title.isEmpty ? 'Nothing playing' : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${_fmt(posMs)}  /  ${durMs > 0 ? _fmt(durMs) : "--:--"}',
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    PresenceShareButton(color: accent, size: 18),
                    IconButton(
                      iconSize: 26,
                      color: scheme.onSurface,
                      onPressed: () => playbackBus.onPrev?.call(),
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.lerp(accent, Colors.white, 0.22)!,
                            accent,
                            Color.lerp(accent, Colors.black, 0.14)!,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                              color: accent.withValues(alpha: 0.45),
                              blurRadius: 12,
                              spreadRadius: 1),
                        ],
                      ),
                      child: IconButton(
                        iconSize: 26,
                        color: Colors.white,
                        onPressed: () => playbackBus.onToggle?.call(),
                        icon: Icon(playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                      ),
                    ),
                    IconButton(
                      iconSize: 26,
                      color: scheme.onSurface,
                      onPressed: () => playbackBus.onNext?.call(),
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
