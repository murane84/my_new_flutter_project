import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'link_ozilane_screen.dart';
import 'message_search_screen.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter/foundation.dart'
    show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform, ValueListenable;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
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
import 'chat/formatted_text.dart' show previewSpans, MentionSelf;
import 'group_screens.dart';
import 'user_profile_sheet.dart';
import 'device_link.dart';
import 'call_reliability_screen.dart';
import 'music/song_identifier.dart' show showSongIdentifier;
import 'profile_screen.dart';
import 'feedback_screen.dart';
import '../utils/popup_shell.dart';
import '../utils/bounce_tap.dart';
import '../utils/brand_theme.dart';
import '../widgets/ambient_backdrop.dart';
import '../widgets/chat_wallpaper_sheet.dart';
import '../widgets/person_avatar.dart';
import '../widgets/story_ring.dart';
import '../widgets/net_gate.dart';
import '../widgets/now_glow.dart';
import 'api_service.dart';
import '../services/device_report.dart';
import '../services/app_updater.dart';
import '../services/bond_live.dart';
import '../services/net_check.dart';
import 'websocket_manager.dart';
import 'live_session_screen.dart';
import 'legal_screen.dart';
import 'relationship_space_page.dart';
import 'appearance_screen.dart';
import 'backup_screen.dart';
import 'together_screen.dart';
import '../services/live_session_service.dart'
    show
        activeLiveSession,
        endActiveLiveSession,
        ActiveLiveSession,
        LiveSessionController,
        LiveTrack;
import '../services/notif_service.dart';
import '../services/fcm_service.dart';
import '../widgets/reply_banner.dart';
import '../services/download_manager.dart';
import '../services/share_inbox.dart';
import '../services/contact_names.dart';
import '../widgets/heart_toast.dart';
import '../services/metadata_overrides.dart';
import '../services/track_title.dart' show splitTitleArtist;
import 'listening_audience_sheet.dart' show PresenceShareButton;
import '../services/tune_in.dart';
import '../widgets/tune_in_ask.dart';
import '../widgets/playing_bars.dart';
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
import '../services/call_lock.dart';
import 'lock_screen.dart';
import '../services/group_call_service.dart';
import '../state/group_call_state.dart' show groupCallProvider, GroupCallPhase;
import '../state/call_state.dart' show callProvider, CallSnapshot;
import 'call_screen.dart';
import 'group_call_screen.dart';
import 'stories/stories_tray.dart';
import 'stories/story_models.dart';
import 'stories/story_viewer.dart';
import 'stories/song_moment.dart' show pickLoadedSong;
import '../services/story_mute.dart';
import '../services/block_list.dart';
import '../services/story_posting.dart';
import '../widgets/section_switch.dart';
import '../services/section_transition.dart';
import 'policy_gate.dart';
import 'add_friend_sheet.dart';
import 'spinning_vinyl_ring.dart';
import '../widgets/presence_ring_avatar.dart';
import '../services/connected_contacts_service.dart';
import '../services/now_playing_presence.dart';
import '../services/steady_listening.dart';
import '../services/online_watch.dart';
import '../services/heartbeat_log.dart';
import '../services/last_seen_privacy.dart';
import '../services/quick_status.dart';
import '../services/live_inbox.dart';
import '../services/live_rooms_registry.dart';
import '../services/group_meta.dart';
import '../services/telecom_service.dart';
import '../utils/file_bytes.dart';
import '../main.dart' show navigatorKey;
import '../utils/time_utils.dart';
// Prefixed: this file also imports package:provider, which exports colliding
// names (Consumer, Provider, ChangeNotifierProvider). `rp.` keeps them distinct.
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import '../widgets/swipe_action_tile.dart';
import '../state/playback_state.dart';
import '../state/unread_state.dart';
import '../state/presence_state.dart';
import '../widgets/genie_menu.dart';
import '../widgets/moment_card.dart';
import '../services/aluta_mood.dart';
import '../services/song_insights.dart';
import '../widgets/glow_feed.dart';
import '../widgets/pixel_snap.dart';
import '../data/glow_cards.dart';
import '../services/moment_prefs.dart';
import '../widgets/welcome_tour.dart';
import 'moments_settings_screen.dart';
import '../utils/readable.dart';
import '../services/account_prefs.dart';
import '../services/gallery_autosave.dart';
import '../widgets/week_in_music_sheet.dart';
import '../widgets/pill_search.dart';
import '../services/haptics.dart';
import '../widgets/slide_track.dart';
import '../widgets/edge_scroll_row.dart';
import '../utils/motion.dart';
import '../utils/radii.dart';
import '../widgets/skeleton.dart';
import '../utils/adaptive_sheet.dart';
import '../utils/depth.dart';
import '../widgets/avatar_flight.dart';

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
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return DateFormat('h:mm a').format(dt);
    if (days == 1) return 'Yesterday';
    if (days < 7) return DateFormat('EEE').format(dt);
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

  /// Open a one-on-one chat the way the Circle list does (in the chat panel,
  /// beside the music on desktop) — reachable from screens outside the home
  /// tree too (Group info is a popup). Null when no home is mounted.
  static void Function(Map<String, dynamic> friend,
      {Map<String, dynamic>? replyTo})? openDm;

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
  // Welcome-back moments: when the app went to the background, and when we
  // last greeted (so it stays special, not nagging).
  DateTime? _bgSince;
  DateTime? _lastMomentAt;
  // Heartbeat tap: whose avatar is glowing right now (sent or received).
  int? _glowFriendId;
  DateTime? _lastComposeAt; // SongBridge.messagePartner tap de-bounce
  String? _lastComposeSig;
  Timer? _glowTimer;
  // "In tune" streak per Space id (Our Space), for the DM header flame.
  final Map<int, int> _streakDays = {};
  final Set<int> _streakFetching = {};
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
  // Bond requests I sent that are still waiting (the friend sheet shows them).
  List<Map<String, dynamic>> _outgoingBondRequests = [];
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
  // The first name of whoever is typing in each group (phonebook-resolved), so
  // the group tile can say "Belyner typing…" rather than a bare "typing…".
  final Map<int, String> _groupTypingNames = {};
  // Group typers' kind: 'typing' or 'recording' (a voice note).
  final Map<int, String> _groupTypingKind = {};
  // Groups where someone @-mentioned me since I last opened them → an "@"
  // chip on the tile; value = the mentioning message id (opening the group
  // jumps to it). Fed by the notify socket's `mention` event.
  final Map<int, String> _groupMentions = {};
  // Chats pinned to the top of "Your circle" (this device): 'dm:<id>' /
  // 'grp:<id>', oldest pin first. A bonded partner's pin shows a heart.
  List<String> _pinnedChats = [];
  static const _pinsPref = 'pinned_chats_v1';
  static const _maxPins = 5;

  String _pinKeyOf(Map<String, dynamic> m) =>
      m['is_group'] == true ? 'grp:${m['id']}' : 'dm:${m['id']}';

  Future<void> _loadPinnedChats() async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getStringList(_pinsPref) ?? const <String>[];
      if (mounted) setState(() => _pinnedChats = List.of(l));
    } catch (_) {}
  }

  void _togglePinChat(Map<String, dynamic> m) {
    final k = _pinKeyOf(m);
    final was = _pinnedChats.contains(k);
    if (!was && _pinnedChats.length >= _maxPins) {
      showToast(context, 'You can pin up to $_maxPins chats',
          type: ToastType.info);
      return;
    }
    Haptics.selectionClick();
    setState(() {
      _pinnedChats = was
          ? (_pinnedChats.where((e) => e != k).toList())
          : [..._pinnedChats, k];
    });
    showToast(context, was ? 'Chat unpinned' : 'Chat pinned to the top',
        type: ToastType.success);
    final snap = List.of(_pinnedChats);
    () async {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setStringList(_pinsPref, snap);
      } catch (_) {}
      AccountPrefs.touch();
    }();
  }
  // When a chat is opened from a message notification, the id of the message to
  // scroll to + highlight once the thread loads (null for normal opens). Passed
  // to ChatPage; cleared to null on every ordinary open so it fires once.
  String? _pendingJumpMessageId;
  // "Reply privately" from a group: the DM opens with that message quoted.
  Map<String, dynamic>? _pendingReplyTo;
  List<Map<String, dynamic>> _filteredGroups = [];
  final TextEditingController _searchCtrl = TextEditingController();
  // Circle search: the switcher row turned into the search box.
  bool _circleSearching = false;
  late final FocusNode _circleSearchFocus = FocusNode()
    ..addListener(_onCircleSearchFocus);

  void _openCircleSearch() {
    setState(() => _circleSearching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _circleSearchFocus.requestFocus();
    });
  }

  /// × / Esc / Back: clear the search and give the row back to the pills.
  void _closeCircleSearch() {
    _circleSearchFocus.unfocus();
    if (_searchCtrl.text.isNotEmpty) {
      _searchCtrl.clear();
      _filterFriends('');
    }
    setState(() => _circleSearching = false);
  }

  /// Leaving an EMPTY search box (tapping elsewhere) folds it away too.
  void _onCircleSearchFocus() {
    if (!_circleSearchFocus.hasFocus &&
        _searchCtrl.text.isEmpty &&
        _circleSearching &&
        mounted) {
      setState(() => _circleSearching = false);
    }
  }
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

  // Which way the Harmony · Circle · Glow switch moves (for the transition).
  bool _layerForward = true;
  // Where a ripple starts across the top (0..1) for the last layer change;
  // null = the side it comes from.
  double? _layerRippleFrom;
  // The box the layers switch in (to place the desktop toggle's ripple).
  final GlobalKey _layerBoxKey = GlobalKey(debugLabel: 'layerBox');

  /// Where [button]'s centre sits across the layer box (0..1) — a ripple
  /// grows from right under it. Null if either isn't laid out.
  double? _rippleXOf(BuildContext button) {
    final b = button.findRenderObject() as RenderBox?;
    final box = _layerBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (b == null || box == null || !b.hasSize || !box.hasSize) return null;
    final c = b.localToGlobal(b.size.center(Offset.zero));
    final o = box.localToGlobal(Offset.zero);
    return ((c.dx - o.dx) / box.size.width).clamp(0.0, 1.0);
  }

  /// Desktop Glow toggle: in AND out from the button itself — the ripple
  /// starts under it and the wave / slide come from its side (it sits on
  /// the left), instead of leaving toward the far right.
  void _toggleGlowFrom(BuildContext button) {
    final fx = _rippleXOf(button);
    // forward = "comes from the right"; the button sits on the left, so
    // both ways come from the left (backward).
    final onRight = (fx ?? 0) >= 0.5;
    _setFriendLayer(_friendLayer == 'glow' ? 'circle' : 'glow',
        forward: onRight, rippleFrom: fx);
  }
  static const List<String> _kLayers = ['harmony', 'circle', 'glow'];

  /// [forward] / [rippleFrom] override where the change seems to come from
  /// (the desktop Glow toggle: always from the button, both ways).
  void _setFriendLayer(String layer, {bool? forward, double? rippleFrom}) {
    if (_friendLayer == layer) return;
    _layerForward = forward ??
        (_kLayers.indexOf(layer) > _kLayers.indexOf(_friendLayer));
    _layerRippleFrom = rippleFrom;
    Haptics.tab(); // the same tab tick as every tab bar
    // Drop any active search focus first, so switching layers never carries the
    // keyboard/focus onto the other layer's (separate) search box.
    FocusManager.instance.primaryFocus?.unfocus();
    // Each layer keeps its OWN search box/controller (Circle: _searchCtrl,
    // Harmony: _spaceSearchCtrl), so switching preserves each side's query
    // rather than wiping it.
    setState(() => _friendLayer = layer);
    // Arriving on Circle at its top → the chats that got news while I was
    // away blink now (the chip only shows when they're above me).
    if (layer == 'circle') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealNewIfAtTop());
    }
  }

  /// Back on the Circle list and already at its top: the chats that got new
  /// messages while I was elsewhere are right there — blink them and drop the
  /// "↑ N new" count (otherwise it would pop up stale the next time I scroll
  /// down).
  void _revealNewIfAtTop() {
    if (!mounted || _newWhileAway.isEmpty || !_circleListVisible) return;
    final c = _circleScroll;
    if (c.hasClients && _offsetOf(c) > 40) return; // the chip handles it
    final fresh = Set<String>.of(_newWhileAway);
    setState(_newWhileAway.clear);
    _flashRows(fresh);
  }

  // Mobile CIRCLE layer: whether the pinned "Status & Stories" tray is expanded.
  // Collapsing it hands the vertical space to the conversation list for users
  // who want chats front-and-centre; tapping its header toggles it back. (Kept
  // here in the main State so the home_hub extension can flip it without
  // touching @protected setState directly.)
  bool _storiesExpanded = true;
  void _toggleStories() {
    setState(() => _storiesExpanded = !_storiesExpanded);
    // Remembered (also across restarts) — maximising / minimising a section
    // must never undo "Hide".
    SharedPreferences.getInstance()
        .then((p) => p.setBool('stories_strip_open_v1', _storiesExpanded))
        .then((_) => AccountPrefs.touch())
        .catchError((_) {});
  }

  /// The account copy came back (new install / update / another device):
  /// re-read the Circle view + strip choice it carries.
  Future<void> _reloadCirclePrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    final open = p.getBool('stories_strip_open_v1');
    final view = p.getString('circle_view_v1');
    setState(() {
      if (open != null) _storiesExpanded = open;
      if (view != null &&
          const {'all', 'stories', 'listening', 'chats'}.contains(view)) {
        _circleView = view;
      }
    });
  }

  // Circle sections share the column's height by default ('all'). Any one of
  // them — 'stories', 'listening' or 'chats' — can be maximised to take the
  // whole column (desktop) / screen (mobile), and minimised back. Remembered.
  String _circleView = 'all';
  // The switcher's bar is folded (a very narrow phone: only the chosen key
  // shows its label) — the ripple origin follows that layout.
  bool _circleTrackFolded = false;
  void _setCircleView(String v) {
    // Tapping the maximised section's control again minimises it.
    _goCircleView((_circleView == v) ? 'all' : v);
  }

  /// Go straight to a Circle view (no toggle) — shortcuts, swipes, the
  /// smart landing. [remember] false = a one-off (don't overwrite the
  /// choice the user made themselves).
  void _goCircleView(String next, {bool remember = true}) {
    if (next == _circleView) return;
    _smartLandingDone = true; // any move of mine beats the smart landing
    // Which way the cube turns: further along the order → forward.
    _CircleFlip.forward = kCircleViews.indexOf(next) >
        kCircleViews.indexOf(_circleView);
    // …and the ripple grows from that section's segment in the switcher
    // (All · Status · Listening · Circle; no Status segment before "me").
    final segs = kCircleViews
        .where((k) => k != 'stories' || _myUserId != null)
        .toList();
    final si = segs.indexOf(next);
    if (si < 0) {
      _CircleFlip.rippleFrom = null;
    } else if (!_circleTrackFolded) {
      _CircleFlip.rippleFrom = (si + 0.5) / segs.length;
    } else {
      // Folded: the chosen key is wider (7 : 3) — use the NEW layout.
      final total = 7.0 + 3.0 * (segs.length - 1);
      _CircleFlip.rippleFrom = (3.0 * si + 3.5) / total;
    }
    // The same tab tick as every tab bar (not for the automatic landing).
    if (remember) Haptics.tab();
    setState(() {
      _circleView = next;
      // (Maximising Status shows its own full grid; the shared view's strip
      // keeps whatever Hide / Show I chose.)
    });
    if (!remember) return;
    SharedPreferences.getInstance()
        .then((p) => p.setString('circle_view_v1', next))
        .then((_) => AccountPrefs.touch())
        .catchError((_) {});
  }

  /// Order for swiping / Alt+1…4: All · Status · Listening · Your circle.
  static const List<String> kCircleViews = [
    'all', 'stories', 'listening', 'chats'
  ];

  /// Smart landing, once per launch: if I like a focused Circle (a section
  /// was maximised when I left), open the one where something is WAITING —
  /// unread chats, else new statuses, else someone live — instead of a
  /// quiet one. My remembered choice stays the fallback, and it's never
  /// saved over. The shared view ("All") shows everything, so it stays.
  bool _smartLandingDone = false;
  void _maybeSmartLanding({
    required int unread,
    required int newStatuses,
    required int live,
  }) {
    if (_smartLandingDone || _isLoadingFriends) return;
    _smartLandingDone = true;
    if (_circleView == 'all') return;
    final has = {
      'chats': unread > 0,
      'stories': newStatuses > 0,
      'listening': live > 0,
    };
    if (has[_circleView] == true) return; // already somewhere lively
    final target = unread > 0
        ? 'chats'
        : newStatuses > 0
            ? 'stories'
            : live > 0
                ? 'listening'
                : null;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _goCircleView(target, remember: false);
    });
  }

  /// Desktop: Alt+1 All · Alt+2 Status · Alt+3 Listening · Alt+4 Your
  /// circle (never while typing).
  bool _onCircleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final kb = HardwareKeyboard.instance;
    // Ctrl+Shift+F (⌘⇧F on a Mac): the chat panel full screen ↔ back —
    // the same as its ⤢ button (desktop / wide web only, Home in front).
    // (⌘ only on a Mac — on Windows that key is the system's Win key.)
    final mod = defaultTargetPlatform == TargetPlatform.macOS
        ? kb.isMetaPressed
        : kb.isControlPressed;
    if (mod &&
        kb.isShiftPressed &&
        e.logicalKey == LogicalKeyboardKey.keyF) {
      if (!mounted ||
          MediaQuery.sizeOf(context).width < 640 ||
          ModalRoute.of(context)?.isCurrent != true) {
        return false;
      }
      _toggleChatFullScreen();
      return true;
    }
    // Ctrl+F (⌘F on a Mac): search the open Circle section (wide layouts,
    // Home in front — a chat's own search keeps its place inside the chat).
    final cmd = defaultTargetPlatform == TargetPlatform.macOS
        ? kb.isMetaPressed
        : kb.isControlPressed;
    if (cmd &&
        !kb.isShiftPressed &&
        !kb.isAltPressed &&
        e.logicalKey == LogicalKeyboardKey.keyF) {
      if (!mounted ||
          MediaQuery.sizeOf(context).width < 640 ||
          _friendLayer == 'glow' ||
          ModalRoute.of(context)?.isCurrent != true) {
        return false;
      }
      _openCircleSearch();
      return true;
    }
    if (!kb.isAltPressed) return false;
    final i = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
    ].indexOf(e.logicalKey);
    if (i < 0 || !mounted) return false;
    if (_friendLayer == 'glow') return false;
    // Only while Home is the page in front (not under Appearance, a chat
    // route, a sheet or a dialog).
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    _goCircleView(kCircleViews[i]);
    return true;
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
  // null = not known yet (header stays blank until /status answers).
  String? _activeFriendLastSeen;
  // Freshest "last seen" per friend this session (from /status in the chat).
  final Map<String, String> _lastSeenCache = {};
  // Their last song while offline ({title, artist}), when they let me see it.
  Map<String, dynamic>? _activeFriendLastTrack;
  // Ticks every 5 s so "Last seen 3 min ago" ages by itself and "ending
  // soon" shows on time.
  final ValueNotifier<int> _minuteTick = ValueNotifier<int>(0);
  // Their clock (UTC offset, minutes) when they let me see it.
  int? _activeFriendTz;
  // DM typers' kind: 'typing' or 'recording' (a voice note).
  final Map<int, String> _typingKind = {};
  Timer? _minuteTimer;
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
    HomePage.openDm = _openDmHook;
    // App open: incoming chat messages show Aluta's reply banner.
    ReplyBanner.onIncoming = _showReplyBanner;
    LiveRoomsRegistry.instance.joinRoom = _dropIntoRoom;
    LiveSessionController.onUnseenSongAsk = _onUnseenSongAsk;
    LiveSessionController.onUnseenSongShare = _onUnseenSongShare;
    GroupMeta.instance.addListener(_onGroupMeta);
    BlockList.instance.addListener(_onBlockList);
    HardwareKeyboard.instance.addHandler(_onCircleKey);
    StoryPosting.instance.addListener(_onStoryPosting);
    // Changing who sees my last seen also changes whose I see (both ways):
    // once the choice has reached the server, refetch the list.
    LastSeenPrivacy.instance.load();
    LastSeenPrivacy.instance.mode.addListener(_onLastSeenPrivacy);
    spacesListStale.addListener(_loadSpaces);
    // A status is a way IN to Aluta, not just a picture: the viewer asks
    // Home about bonds, live music and my songs through these.
    StoryMute.instance.load();
    StoryHooks.isBonded = (id) => _bondWith(id) != null;
    StoryHooks.closeness = (id) =>
        _isHarmonyPartner(id) ? 2 : (_bondWith(id) != null ? 1 : 0);
    StoryHooks.isPlayingNow =
        (id) => NowPlayingPresence.instance.trackFor(id) != null;
    StoryHooks.tuneIn = (ctx, id, name, title) =>
        askToTuneIn(ctx, friendId: id, name: name, title: title);
    StoryHooks.playOnMine = _playLoadedSong;
    // A music status → our chat, Listen Together starting with that song.
    StoryHooks.listenTogether = (ctx, id, title) {
      Navigator.of(ctx).maybePop(); // leave the viewer
      pendingListenTitle = title;
      pendingListenTogether.value = 's$id';
      _handleMessageTap({
        'type': 'message',
        'friend_id': '$id',
        'sender_name': _nameForUser(id),
      });
    };
    StoryHooks.answerWithSong = _answerStatusWithSong;
    StoryHooks.myPartner = () {
      final s = _primarySpace;
      if (s == null || (s['status'] != null && s['status'] != 'active')) {
        return null;
      }
      for (final m in ((s['members'] as List?) ?? const []).whereType<Map>()) {
        final id = (m['id'] as num?)?.toInt();
        if (id != null && id != _myUserId) {
          return (id: id, name: _nameForUser(id));
        }
      }
      return null;
    };
    // Scrolled back up by hand → the "↑ N new" chip has done its job.
    _circleScroll.addListener(() {
      if (_newWhileAway.isNotEmpty &&
          _circleScroll.hasClients &&
          _offsetOf(_circleScroll) <= 40 &&
          mounted) {
        setState(_newWhileAway.clear);
      }
    });
    // Replied from a notification while the app is alive → refresh that card
    // (its preview becomes "✓ You: …" and the unread clears).
    onInlineReplySent = (fid, cid) {
      if (!mounted) return;
      if (fid != null && cid == null) {
        ref.read(unreadProvider.notifier).clear(fid);
      }
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        _fetchFriends(quiet: true);
        _fetchGroups();
      });
    };
    // Our Space reads its saved copy synchronously → opens complete.
    warmSpacePrefs();
    _loadPinnedChats();
    AccountPrefs.onRestore(_loadPinnedChats); // pins back from the account
    AccountPrefs.onRestore(_reloadCirclePrefs); // view + strip, likewise
    _wireSongMoments();
    // Drives the playlist drawer's smooth slide/fade in & out. MusicControls
    // flips playlistDrawerBus.isOpen; we animate the host from that.
    _playlistDrawerCtrl = AnimationController(
      vsync: this,
      duration: Motion.emphasized,
      reverseDuration: Motion.standard,
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
    // Know who "me" is from the last session at once (the profile call can be
    // slow or offline) — the partner lookup (Glow, Our Space) depends on it.
    SharedPreferences.getInstance().then((p) {
      final open = p.getBool('stories_strip_open_v1');
      if (open != null && open != _storiesExpanded && mounted) {
        setState(() => _storiesExpanded = open);
      }
      final view = p.getString('circle_view_v1');
      if (view != null &&
          const {'stories', 'listening', 'chats'}.contains(view) &&
          mounted) {
        setState(() => _circleView = view);
      }
      final cached = int.tryParse(p.getString('my_user_id') ?? '');
      if (cached != null && _myUserId == null && mounted) {
        setState(() => _myUserId = cached);
      }
    });
    _loadUserData();
    _loadCachedFriends();    // show cached DM list instantly (no spinner flash)
    _loadCachedGroups();     // and the cached group chats, for offline Circle
    _loadCachedSpaces();     // and the pinned Our Space hero(es), for offline
    _loadCachedStories();    // status & stories, for offline (24h-filtered)
    loadChatBackground();    // the chosen chat wallpaper (photo/motif/default)
    // …and reconcile it with the account copy in the background (a reinstall
    // or a new phone gets its wallpapers back; never blocks startup).
    syncChatBackgroundWithAccount();
    AccountPrefs.sync(); // theme, bubbles, tones, nudges — same idea
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
    // What this install runs on (admin panel's device split). Once per run.
    DeviceReport.send();
    // Pick up any file downloads left unfinished (app killed / slept).
    DownloadManager.instance.init();
    // Android outside the Play Store: is a newer Aluta published? (quietly,
    // at most every 6 h; a few seconds in so it never competes with start-up)
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) AppUpdater.instance.check(context);
    });
    // …and each time Aluta comes back to the front (same 6 h gate), so a
    // phone that never closes the app still hears about a new build.
    AppUpdater.instance.watchResume(() => context);

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
    // The steady reading (hero line, badge, Listening zone) changes on its
    // own timers — repaint for it too.
    SteadyListening.instance.addListener(_onPresenceChanged);
    // Keep the "Listening now" zone fresh. On web, poll the snapshot as a
    // safety net — live friend_now_playing events can be missed there, which
    // left friends' listening status never appearing.
    NowPlayingPresence.instance.startReceiving(poll: kIsWeb);
    // "Tell me when they're online" watches I'm still waiting on.
    OnlineWatchList.instance.load();
    HeartbeatLog.instance.load();
    _minuteTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _minuteTick.value++);
    GalleryAutoSave.instance.load();
    // Quick statuses ("Free to talk" …): mine + my circle's.
    QuickStatus.instance.addListener(_onPresenceChanged);
    QuickStatus.instance.load();
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
    if (HomePage.openDm == _openDmHook) HomePage.openDm = null;
    BlockList.instance.removeListener(_onBlockList);
    HardwareKeyboard.instance.removeHandler(_onCircleKey);
    StoryPosting.instance.removeListener(_onStoryPosting);
    LastSeenPrivacy.instance.mode.removeListener(_onLastSeenPrivacy);
    spacesListStale.removeListener(_loadSpaces);
    if (ReplyBanner.onIncoming == _showReplyBanner) {
      ReplyBanner.onIncoming = null;
      LiveRoomsRegistry.instance.joinRoom = null;
      LiveSessionController.onUnseenSongAsk = null;
      LiveSessionController.onUnseenSongShare = null;
      GroupMeta.instance.removeListener(_onGroupMeta);
      onInlineReplySent = null;
    }
    ReplyBanner.hide();
    _glowTimer?.cancel();
    SongInsights.instance.pending.removeListener(_onSongNudge);
    final sb = SongBridge.instance;
    sb.partnerName = null;
    sb.partnerId = null;
    sb.messagePartner = null;
    sb.listenTogether = null;
    sb.shareCurrent = null;
    sb.canShare = null;
    sb.pairSeed = null;
    sb.addToOurs = null;
    WidgetsBinding.instance.removeObserver(this);
    ConnectionStatus.instance.online.removeListener(_onGlobalConnChanged);
    SessionEvents.instance.expired.removeListener(_onSessionExpired);
    ShareInbox.instance.removeListener(_onSharePending);
    ContactNames.instance.revision.removeListener(_onContactsChanged);
    playlistDrawerBus.isOpen.removeListener(_onPlaylistDrawerToggled);
    NowPlayingPresence.instance.removeListener(_onPresenceChanged);
    SteadyListening.instance.removeListener(_onPresenceChanged);
    QuickStatus.instance.removeListener(_onPresenceChanged);
    AccountPrefs.offRestore(_loadPinnedChats);
    AccountPrefs.offRestore(_reloadCirclePrefs);
    NowPlayingPresence.instance.stopReceiving();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    for (final t in _groupTypingTimers.values) {
      t.cancel();
    }
    _playlistDrawerCtrl.dispose();
    _searchCtrl.dispose();
    _circleSearchFocus.dispose();
    _spaceSearchCtrl.dispose();
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    _minuteTimer?.cancel();
    _flashTimer?.cancel();
    _burstTimer?.cancel();
    _circleScroll.dispose();
    _harmonyScroll.dispose();
    _circleMaxScroll.dispose();
    _minuteTick.dispose();
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _bgSince ??= DateTime.now();
    }
    if (state == AppLifecycleState.resumed) {
      // Back in the app on the Circle list's top → news blinks in place.
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealNewIfAtTop());
      _resumedAt = DateTime.now();
      // Heartbeats that arrived by push while I was away.
      HeartbeatLog.instance.load();
      // A banner tapped in the shade clears itself but not its person header.
      tidyNotificationBundles();
      // Keep my Listen Together signal dot fresh for friends (≤ every 30 min).
      NetCheck.refreshInBackground();
      final since = _bgSince;
      _bgSince = null;
      if (since != null) {
        final away = DateTime.now().difference(since);
        // Let the screen settle (reconnect, repaint) before greeting.
        Future.delayed(const Duration(milliseconds: 1400), () {
          if (_maybeMusicWelcome(away)) return;
          // A music nudge that waited for you to come back.
          if (_onSongNudge() || _maybeWeeklyRecap()) return;
          _maybeTogetherMusic(); // shared top 3 (Sun) · our soundtrack (1st)
          if (away >= const Duration(minutes: 30)) _maybeReconnectNudge();
          // Long time away → wait for the reconnect refresh, then summarise.
          if (away >= const Duration(hours: 3)) {
            Future.delayed(const Duration(milliseconds: 2600),
                () => _maybeAwaySummary());
          }
        });
      }
      // Coming back from idle/background — re-check the server and go online.
      _discoverServer();
      _autoReconnect();
      // Re-seed who's listening now (a live event may have been missed while
      // backgrounded).
      NowPlayingPresence.instance.loadSnapshot();
      // Same for quick statuses + watches (socket events may have been missed).
      QuickStatus.instance.load();
      OnlineWatchList.instance.load();
    }
  }

  /// Came back to Aluta with music still playing → a warm, one-off moment
  /// card: share it with your partner, tune in if they're listening too, or
  /// message them. Needs ≥1 min away, at most once every 25 min, and never
  /// during a live session (you're already together).
  /// The bonded partner (primary Space): their id + first name as I know
  /// them (phone-book name first), or null with no Space.
  ({Map<String, dynamic> space, int id, String name})? _partnerInfo() {
    final space = _primarySpace;
    if (space == null) return null;
    final me = _myUserId;
    for (final m
        in ((space['members'] as List?) ?? const []).whereType<Map>()) {
      final id = (m['id'] as num?)?.toInt();
      if (id == null || id == me) continue;
      // Who "me" is may not be known yet (profile still loading / offline at
      // start). Then only a member who is in my friend list can be the
      // partner — I'm never in my own — so Glow never offers to message me.
      if (me == null &&
          !_allFriends.any((x) => (x['id'] as num?)?.toInt() == id)) {
        continue;
      }
      final f = _allFriends.firstWhere(
          (x) => (x['id'] as num?)?.toInt() == id,
          orElse: () => <String, dynamic>{});
      final full = _contactDisplayName(
          (f['phone'] ?? m['phone'])?.toString(),
          (m['username'] ?? f['username'] ?? '').toString());
      return (
        space: space,
        id: id,
        name: full.trim().split(RegExp(r'\s+')).first
      );
    }
    return null;
  }

  bool get _momentCooling {
    final last = _lastMomentAt;
    return last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 25);
  }

  /// Back after hours away → "Belyner sent you 4 messages 💌" (or a gentle
  /// nudge to say hi when it's quiet). Opens the partner's chat in one tap.
  void _maybeAwaySummary() {
    if (!MomentPrefs.instance.welcomeCards.value) return;
    if (WelcomeTour.showing) return;
    if (!mounted || !_appForeground || _momentCooling) return;
    if (ref.read(liveSessionProvider).active) return;
    final p = _partnerInfo();
    final unread = ref.read(unreadProvider);
    final fromPartner = p == null ? 0 : unread.countFor(p.id);
    var others = 0, chats = 0;
    unread.counts.forEach((id, c) {
      if (c > 0 && id != p?.id) {
        others += c;
        chats++;
      }
    });
    for (final g in _groups) {
      final gid = (g['id'] as num?)?.toInt();
      if (gid != null && GroupMeta.instance.isMuted(gid)) continue; // muted
      final c = (g['unread_count'] as num?)?.toInt() ?? 0;
      if (c > 0) {
        others += c;
        chats++;
      }
    }
    final me = _username.trim().split(RegExp(r'\s+')).first;
    final title = AlutaMood.awaySummary(
      me: me,
      partner: p?.name ?? '',
      fromPartner: fromPartner,
      others: others,
      chats: chats,
    );
    if (title.isEmpty) return;
    _lastMomentAt = DateTime.now();
    final actions = <MomentAction>[];
    if (p != null) {
      actions.add(MomentAction(
          fromPartner > 0 ? Icons.mark_email_unread_rounded : Icons.waving_hand_rounded,
          fromPartner > 0 ? 'Open chat' : 'Say hi',
          () => _messageSpacemate(p.space),
          primary: true));
    }
    showMomentCard(
      context,
      title: title,
      leading: fromPartner > 0
          ? Icons.favorite_rounded
          : Icons.waving_hand_rounded,
      actions: actions,
    );
  }

  // ── Song moments (SongInsights) ──────────────────────────────────────────
  // The player tells SongInsights what plays; when a song is on repeat (or a
  // "missing someone" song returns, or one has been "ours" for weeks) it
  // queues ONE nudge a day, shown here as a moment card. Its follow-ups reach
  // the partner / chats / Our Space through SongBridge (also used by the
  // player's feel strip). On-device only; ignored twice → never again.
  void _wireSongMoments() {
    MomentPrefs.instance.load();
    // First run on this device: the short Aluta tour.
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) WelcomeTour.maybeShow(context);
    });
    final b = SongBridge.instance;
    b.partnerName = () => _partnerInfo()?.name;
    b.partnerId = () => _partnerInfo()?.id;
    b.messagePartner = ({String? text, bool heart = false, String? mood}) {
      final p = _partnerInfo();
      if (p == null) return;
      // A double/triple tap is one intent, not three messages.
      final now = DateTime.now();
      final last = _lastComposeAt;
      final sig = '$text|$heart|$mood';
      if (sig == _lastComposeSig &&
          last != null &&
          now.difference(last) < const Duration(seconds: 2)) {
        return; // the same tap again
      }
      _lastComposeAt = now;
      _lastComposeSig = sig;
      chatComposeRequest.value = {
        'friendId': p.id,
        'text': text ?? '',
        'heart': heart,
        'mood': ?mood,
      };
      _messageSpacemate(p.space);
    };
    b.listenTogether = () {
      final p = _partnerInfo();
      if (p != null) _openSpace(p.space);
    };
    b.shareCurrent = () => playbackBus.onShareToChat?.call();
    b.canShare = () => playbackBus.onShareToChat != null;
    b.pairSeed = () {
      final p = _partnerInfo();
      final me = _myUserId;
      if (p == null || me == null) return null;
      return (me < p.id ? me * 7919 + p.id : p.id * 7919 + me);
    };
    b.addToOurs = (title, artist) async {
      final p = _partnerInfo();
      final sid = (p?.space['id'] as num?)?.toInt();
      if (sid == null) return false;
      final r = await ApiService().addTrack(sid,
          title: title,
          artist: artist.isEmpty ? null : artist,
          memo: 'our song 💞',
          source: 'insight');
      if (r != null) spaceEventBus.value++;
      return r != null;
    };
    // First signal-dot reading once the app has settled.
    Future.delayed(const Duration(seconds: 20), NetCheck.refreshInBackground);
    SongInsights.instance.load().then((_) {
      if (!mounted) return;
      // Your listening history follows the account (merge, never lose).
      SongInsights.instance.syncWithAccount();
      SongInsights.instance.pending.addListener(_onSongNudge);
      Future.delayed(const Duration(seconds: 6), () {
        if (!mounted) return;
        if (!_maybeWeeklyRecap()) {
          _maybeGlowOfDay();
          Future.delayed(const Duration(seconds: 30), _maybeTogetherMusic);
        }
      });
    });
    // Listen Together sessions count toward the weekly recap.
    ref.listenManual(liveSessionProvider, (prev, next) {
      if (next.active && !(prev?.active ?? false)) {
        SongInsights.instance.recordTogether();
      }
    });
  }

  /// Returns true when a nudge is (about to be) shown.
  bool _onSongNudge() {
    final n = SongInsights.instance.pending.value;
    if (n == null || !mounted || !_appForeground) return false;
    if (WelcomeTour.showing) {
      Future.delayed(const Duration(minutes: 1), () {
        if (mounted) _onSongNudge();
      });
      return false;
    }
    // Already together, or another moment card just showed → try again in a
    // bit rather than dropping it.
    if (ref.read(liveSessionProvider).active || _momentCooling) {
      Future.delayed(const Duration(minutes: 2), () {
        if (mounted) _onSongNudge();
      });
      return false;
    }
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || SongInsights.instance.pending.value != n) return;
      _showSongNudge(n);
    });
    return true;
  }

  /// "Your week in music" with everything wired: send to partner, the
  /// shared top songs, and Listen Together.
  void _openWeekInMusic() {
    final partner = _partnerInfo();
    showWeekInMusic(
      context,
      partnerName: partner?.name,
      onSend: partner == null ? null : (t) => _sendToPartner(partner, t),
      partnerTop: partner == null
          ? null
          : () => ApiService().partnerMusicTop(partner.id),
      onListenTogether: partner == null
          ? null
          : () => SongBridge.instance.listenTogether?.call(),
    );
  }

  Future<void> _sendToPartner(
      ({Map<String, dynamic> space, int id, String name}) partner,
      String text) async {
    final sent = await ApiService().sendMessage(partner.id, text);
    if (mounted) {
      showToast(
          context,
          sent != null
              ? 'Sent to ${partner.name} 💞'
              : 'Could not send it right now',
          type: sent != null ? ToastType.success : ToastType.error);
    }
  }

  /// Sundays: "You both had X in your top 3" (once a week). The 1st–3rd:
  /// "Our `month` soundtrack" — the songs you both played most last month,
  /// keepable in Our Space. Only with a partner who shares their listening.
  bool _togetherMusicBusy = false;
  Future<void> _maybeTogetherMusic() async {
    if (_togetherMusicBusy) return;
    if (!mounted || !_appForeground || _momentCooling) return;
    if (WelcomeTour.showing || !MomentPrefs.instance.welcomeCards.value) return;
    if (ref.read(liveSessionProvider).active) return;
    final partner = _partnerInfo();
    if (partner == null) return;
    final si = SongInsights.instance;
    final now = DateTime.now();
    _togetherMusicBusy = true;
    try {
      final p = await SharedPreferences.getInstance();
      // ── Monthly soundtrack ──
      if (si.monthCardDue()) {
        final theirs = await ApiService().partnerMusicTop(partner.id, days: 30);
        if (theirs == null || !mounted) return;
        final mine = si.topTitles(days: 30, limit: 15);
        final keys = {for (final t in theirs) SongInsights.keyOf(t)};
        final both = [
          for (final t in mine)
            if (keys.contains(SongInsights.keyOf(t))) t,
        ].take(5).toList();
        si.markMonthCardShown();
        if (both.isEmpty) return;
        final month = DateFormat('MMMM')
            .format(DateTime(now.year, now.month - 1, 1));
        final tog = si.togetherSince(31);
        _lastMomentAt = DateTime.now();
        showMomentCard(
          context,
          title: 'Your $month soundtrack 💞',
          subtitle: '${both.join(' · ')}${tog > 0 ? ' · together $tog×' : ''}',
          leading: Icons.album_rounded,
          hold: const Duration(seconds: 14),
          actions: [
            MomentAction(Icons.push_pin_rounded, 'Keep in Our Space',
                () async {
              final sid = (partner.space['id'] as num?)?.toInt();
              if (sid == null) return;
              final res = await ApiService().addMoment(sid,
                  kind: 'note',
                  caption: '🎶 Our $month soundtrack\n'
                      '${[for (var i = 0; i < both.length; i++) '${i + 1}. ${both[i]}'].join('\n')}'
                      '${tog > 0 ? '\nWe listened together $tog× 💞' : ''}');
              if (res != null) spaceEventBus.value++;
              if (mounted) {
                showToast(context,
                    res != null ? 'Kept in Our Space 💛' : 'Could not keep that',
                    type: res != null ? ToastType.success : ToastType.error);
              }
            }, primary: true),
            MomentAction(Icons.headphones_rounded, 'Listen together',
                () => SongBridge.instance.listenTogether?.call()),
          ],
        );
        return;
      }
      // ── Sunday: both in your top 3 ──
      if (now.weekday != DateTime.sunday || now.hour < 12) return;
      final wk = '${now.year}-${now.difference(DateTime(now.year)).inDays ~/ 7}';
      if (p.getString('shared_top_week') == wk) return;
      final theirs = await ApiService().partnerMusicTop(partner.id);
      if (theirs == null || !mounted) return;
      await p.setString('shared_top_week', wk);
      final mine = si.topTitles(days: 7, limit: 3);
      final their3 = {for (final t in theirs.take(3)) SongInsights.keyOf(t)};
      final hit = mine.where((t) => their3.contains(SongInsights.keyOf(t)));
      if (hit.isEmpty || !mounted) return;
      _lastMomentAt = DateTime.now();
      showMomentCard(
        context,
        title: AlutaMood.sharedTop(hit.first, partner.name),
        leading: Icons.favorite_rounded,
        hold: const Duration(seconds: 12),
        onTap: _openWeekInMusic,
        actions: [
          MomentAction(Icons.headphones_rounded, 'Play it together',
              () => SongBridge.instance.listenTogether?.call(),
              primary: true),
          MomentAction(Icons.format_list_numbered_rounded, 'See my week',
              _openWeekInMusic),
        ],
      );
    } catch (_) {
    } finally {
      _togetherMusicBusy = false;
    }
  }

  /// Tap a song banner → its insight card (plays chart, rank, feel, …).
  void _openSongInsight(String title) {
    final partner = _partnerInfo();
    showSongInsight(context, title,
        partnerName: partner?.name,
        // Who brought it to me (from my chats) → a one-tap thank-you.
        sharedBy: () async {
          final r = await _whoSharedSong(title);
          if (r == null) return null;
          return (
            name: r.$2,
            thank: () => openChat(r.$1),
          );
        },
        onOpenWeek: _openWeekInMusic,
        onSendWeek: partner == null
            ? null
            : (text) async {
                final sent = await ApiService().sendMessage(partner.id, text);
                if (mounted) {
                  showToast(
                      context,
                      sent != null
                          ? 'Sent to ${partner.name} 💞'
                          : 'Could not send it right now',
                      type: sent != null
                          ? ToastType.success
                          : ToastType.error);
                }
              });
  }

  void _showSongNudge(SongNudge n) {
    final si = SongInsights.instance;
    // Partner-only nudges with no partner: drop quietly (no slot spent, no
    // "ignore" counted).
    if ((n.kind == 'missing' || n.kind == 'ours') && _partnerInfo() == null) {
      si.pending.value = null;
      return;
    }
    si.markShown(n);
    _lastMomentAt = DateTime.now();
    final partner = _partnerInfo();
    final pname = partner?.name ?? '';
    void acted() => si.markActed(n.title);
    switch (n.kind) {
      case 'repeat':
        showMomentCard(
          context,
          title: AlutaMood.songOnRepeat(n.title),
          subtitle: n.artist.isEmpty ? null : n.artist,
          leading: Icons.repeat_rounded,
          hold: const Duration(seconds: 12),
          onIgnored: () => si.markIgnored(n.title),
          onTap: () => _openSongInsight(n.title),
          actions: [
            for (final f in SongFeel.values)
              MomentAction(Icons.circle, f.label, () {
                si.setFeel(n.title, f);
                Future.delayed(const Duration(milliseconds: 650),
                    () => _songFollowUp(n.title, n.artist, f));
              }, emoji: f.emoji),
          ],
        );
        break;
      case 'back':
      case 'streak':
      case 'night':
        showMomentCard(
          context,
          title: n.kind == 'back'
              ? AlutaMood.songBack(n.title)
              : n.kind == 'streak'
                  ? AlutaMood.songStreak(n.title)
                  : AlutaMood.songNight(n.title),
          subtitle: n.artist.isEmpty ? null : n.artist,
          leading: n.kind == 'back'
              ? Icons.history_rounded
              : n.kind == 'streak'
                  ? Icons.local_fire_department_rounded
                  : Icons.nights_stay_rounded,
          onIgnored: () => si.markIgnored(n.title),
          onTap: () => _openSongInsight(n.title),
          actions: [
            MomentAction(Icons.insights_rounded, 'See its story', () {
              acted();
              _openSongInsight(n.title);
            }, primary: true),
            if (partner != null)
              MomentAction(Icons.send_rounded, 'Send to $pname', () {
                acted();
                SongBridge.instance.messagePartner?.call(
                    text: n.kind == 'night'
                        ? '🌙 My late-night song this week: “${n.title}”'
                        : n.kind == 'streak'
                            ? '🔁 5 days in a row with “${n.title}” — listen?'
                            : '🎶 Back on “${n.title}” again — remember it?');
              }),
          ],
        );
        break;
      case 'missing':
        showMomentCard(
          context,
          title: AlutaMood.songMissingAgain(n.title, pname),
          leading: Icons.favorite_rounded,
          onIgnored: () => si.markIgnored(n.title),
          onTap: () => _openSongInsight(n.title),
          actions: [
            if (partner != null)
              MomentAction(Icons.favorite_rounded, 'Send a heart', () {
                acted();
                SongBridge.instance.messagePartner?.call(
                    text: '“${n.title}” made me miss you 🥹', heart: true, mood: 'miss');
              }, primary: true),
          ],
        );
        break;
      case 'ours':
        showMomentCard(
          context,
          title: AlutaMood.songOurs(n.title, pname),
          leading: Icons.queue_music_rounded,
          onIgnored: () => si.markIgnored(n.title),
          onTap: () => _openSongInsight(n.title),
          actions: [
            if (partner != null)
              MomentAction(Icons.playlist_add_rounded, 'Add to Our Playlist',
                  () async {
                acted();
                final ok = await SongBridge.instance.addToOurs
                        ?.call(n.title, n.artist) ??
                    false;
                if (ok) si.markOurs(n.title);
                if (mounted) {
                  showToast(
                      context,
                      ok
                          ? 'Added to your soundtrack 💞'
                          : 'Could not add it right now',
                      type: ok ? ToastType.success : ToastType.error);
                }
              }, primary: true),
          ],
        );
        break;
    }
  }

  /// After the feeling is picked: who this song is for.
  Future<void> _songFollowUp(String title, String artist, SongFeel f) async {
    if (!mounted) return;
    final partner = _partnerInfo();
    final pname = partner?.name ?? '';
    final bridge = SongBridge.instance;
    final playingNow = ref.read(nowPlayingProvider).track.trim() == title &&
        playbackBus.onShareToChat != null; // web player can't share yet
    final sharer = await _whoSharedSong(title, exclude: partner?.id);
    if (!mounted) return;
    final actions = <MomentAction>[];
    String headline;
    String? sub;
    IconData lead = Icons.music_note_rounded;
    switch (f) {
      case SongFeel.love:
        headline = AlutaMood.songLove(title, pname);
        lead = Icons.favorite_rounded;
        if (partner != null) {
          actions.add(MomentAction(Icons.favorite_rounded, 'Send to $pname',
              () => bridge.messagePartner
                  ?.call(text: '“$title” reminds me of you 💞'),
              primary: true));
          actions.add(MomentAction(Icons.headphones_rounded,
              'Listen together', () => bridge.listenTogether?.call()));
        } else if (playingNow) {
          actions.add(MomentAction(Icons.send_rounded, 'Share it',
              () => bridge.shareCurrent?.call(),
              primary: true));
        }
        break;
      case SongFeel.missing:
        headline = AlutaMood.songMissing(pname);
        lead = Icons.favorite_rounded;
        if (partner != null) {
          actions.add(MomentAction(Icons.favorite_rounded, 'Send a heart',
              () => bridge.messagePartner?.call(
                  text: '“$title” made me miss you 🥹', heart: true, mood: 'miss'),
              primary: true));
          actions.add(MomentAction(Icons.headphones_rounded,
              'Listen together', () => bridge.listenTogether?.call()));
        }
        break;
      case SongFeel.hyped:
        headline = AlutaMood.songHyped();
        lead = Icons.bolt_rounded;
        if (playingNow) {
          actions.add(MomentAction(Icons.send_rounded, 'Share to a chat',
              () => bridge.shareCurrent?.call(),
              primary: true));
        }
        break;
      case SongFeel.calm:
        headline = AlutaMood.songCalm();
        lead = Icons.spa_rounded;
        break;
      case SongFeel.hurting:
        // Gentle, never pushy: no "share it" here — just a hand to hold.
        headline = AlutaMood.songHurting(pname);
        sub = 'If it ever feels like too much, reach out to someone you trust.';
        lead = Icons.favorite_border_rounded;
        if (partner != null) {
          actions.add(MomentAction(Icons.chat_bubble_rounded,
              'Talk to $pname', () => bridge.messagePartner?.call(),
              primary: true));
        }
        actions.add(MomentAction(Icons.check_rounded, "I'm okay", () {}));
        break;
    }
    // 3) Someone who shared this song with you would love it too.
    if (sharer != null &&
        f != SongFeel.hurting &&
        f != SongFeel.calm &&
        actions.length < 3) {
      final who = sharer.$2;
      actions.add(MomentAction(Icons.person_rounded, 'Share with $who',
          () => openChat(sharer.$1)));
      sub ??= '$who shared this one with you before';
    }
    showMomentCard(
      context,
      title: headline,
      subtitle: sub,
      leading: lead,
      hold: Duration(seconds: f == SongFeel.hurting ? 14 : 9),
      onTap: () => _openSongInsight(title),
      actions: actions,
    );
  }

  /// A friend who sent me this song in a DM (from on-device chat caches).
  Future<(Map<String, dynamic>, String)?> _whoSharedSong(String title,
      {int? exclude}) async {
    final me = _myUserId;
    if (me == null) return null;
    final key = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    if (key.length < 3) return null;
    try {
      final p = await SharedPreferences.getInstance();
      for (final f in _allFriends) {
        final id = (f['id'] as num?)?.toInt();
        if (id == null || id == exclude) continue;
        final raw = p.getString('chat_cache_${me}_$id');
        if (raw == null || !raw.contains('"song"')) continue;
        final list = jsonDecode(raw);
        if (list is! List) continue;
        for (final m in list) {
          if (m is! Map || m['message_type'] != 'song') continue;
          if (m['sender_id']?.toString() != '$id') continue;
          final t = '${m['content'] ?? ''} ${m['media_name'] ?? ''}'
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]+'), '');
          if (t.contains(key)) {
            final name = _contactDisplayName(
                    f['phone']?.toString(), (f['username'] ?? '').toString())
                .trim()
                .split(RegExp(r'\s+'))
                .first;
            return (f, name);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Once a day: today's Glow card as a soft moment (Open Glow / send it).
  Future<bool> _maybeGlowOfDay() async {
    if (!mounted || !_appForeground || _momentCooling) return false;
    if (WelcomeTour.showing) return false;
    try {
      final p = await SharedPreferences.getInstance();
      await MomentPrefs.instance.load();
      if (!MomentPrefs.instance.glowDaily.value) return false;
      final d = DateTime.now();
      final key = '${d.year}-${d.month}-${d.day}';
      if (p.getString('glow_nudge_day') == key) return false;
      await p.setString('glow_nudge_day', key);
    } catch (_) {
      return false;
    }
    if (!mounted) return false;
    await loadGlowToday();
    if (!mounted) return false;
    final c = glowToday();
    final partner = _partnerInfo();
    final line = c.title.isNotEmpty
        ? c.title
        : (c.text.length > 70 ? '${c.text.characters.take(68)}…' : c.text)
            .replaceAll('\n', ' ');
    _lastMomentAt = DateTime.now();
    showMomentCard(
      context,
      title: '✨ Today\'s glow: $line',
      subtitle: c.source.isEmpty ? null : c.source,
      leading: Icons.auto_awesome_rounded,
      // The banner trims the glow — tap opens it whole in Glow.
      onTap: () {
        setState(() {
          _activeFriendId = null;
          _activeGroup = null;
        });
        _setFriendLayer('glow');
      },
      actions: [
        MomentAction(Icons.auto_awesome_rounded, 'Open Glow', () {
          setState(() {
            _activeFriendId = null;
            _activeGroup = null;
          });
          _setFriendLayer('glow');
        }, primary: true),
        if (partner != null)
          MomentAction(Icons.send_rounded, 'Send to ${partner.name}', () {
            SongBridge.instance.messagePartner
                ?.call(text: glowShareText(c));
          }),
      ],
    );
    return true;
  }

  /// 6) Sunday evening: your week in music, shareable with your partner.
  bool _maybeWeeklyRecap() {
    if (!mounted || !_appForeground || _momentCooling) return false;
    if (WelcomeTour.showing) return false;
    final r = SongInsights.instance.weeklyRecapDue();
    if (r == null) return false;
    SongInsights.instance.markRecapShown();
    _lastMomentAt = DateTime.now();
    final partner = _partnerInfo();
    final lines = <String>[
      for (var i = 0; i < r.top.length; i++) '${i + 1}. ${r.top[i]}',
    ];
    final feelLabel =
        r.feel == null ? null : '${r.feel!.emoji} ${r.feel!.label.toLowerCase()}';
    final together = r.together > 0
        ? ' · together ${r.together}×'
        : '';
    Future<void> send(String text) async {
      if (partner == null) return;
      final sent = await ApiService().sendMessage(partner.id, text);
      if (mounted) {
        showToast(
            context,
            sent != null
                ? 'Sent to ${partner.name} 💞'
                : 'Could not send it right now',
            type: sent != null ? ToastType.success : ToastType.error);
      }
    }

    // The banner only fits a couple of titles — tap it (or "See all") for
    // the whole week, ranked.
    void openFull() => _openWeekInMusic();

    showMomentCard(
      context,
      title: AlutaMood.weeklyRecapTitle(feelLabel),
      subtitle: '${lines.join('  ')}$together',
      leading: Icons.insights_rounded,
      hold: const Duration(seconds: 14),
      onTap: openFull,
      actions: [
        MomentAction(Icons.format_list_numbered_rounded, 'See all', openFull,
            primary: true),
        if (partner != null)
          MomentAction(Icons.send_rounded, 'Send to ${partner.name}', () {
            send('🎶 My week in music\n${lines.join('\n')}'
                '${feelLabel == null ? '' : '\nMostly $feelLabel'}'
                '${r.together > 0 ? '\nWe listened together ${r.together}× 💞' : ''}');
          }),
      ],
    );
    return true;
  }

  // ── Heartbeat tap ─────────────────────────────────────────────────────────
  void _glow(int friendId) {
    _glowTimer?.cancel();
    setState(() => _glowFriendId = friendId);
    _glowTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _glowFriendId = null);
    });
  }

  Future<void> _lubDub() async {
    Haptics.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 170));
    Haptics.mediumImpact();
  }

  /// Double-tap a bonded partner's avatar → a wordless "thinking of you".
  Future<void> _sendHeartbeatTap(int friendId, String name) async {
    final space = _bondWith(friendId);
    if (space == null && _spaceWithFriend(friendId) != null) {
      showToast(context,
          'Heartbeats start once $name accepts your bond 💞',
          type: ToastType.info);
      return;
    }
    if (space == null) {
      showToast(context, 'Pin a bond with $name to send heartbeats 💓',
          type: ToastType.info);
      return;
    }
    final sid = (space['id'] as num?)?.toInt();
    if (sid == null) return;
    _lubDub();
    _glow(friendId);
    final ok = await ApiService().sendHeartbeat(sid);
    if (!mounted) return;
    final first = name.trim().split(RegExp(r'\s+')).first;
    showToast(
        context,
        ok
            ? AlutaMood.heartbeatSent(first)
            : 'Your last heartbeat is still on its way 💓',
        type: ok ? ToastType.success : ToastType.info);
  }

  void _onHeartbeatReceived(Map<String, dynamic> d) {
    final fromId = (d['from_id'] as num?)?.toInt();
    if (fromId == null || !mounted) return;
    final f = _allFriends.firstWhere(
        (x) => (x['id'] as num?)?.toInt() == fromId,
        orElse: () => <String, dynamic>{});
    final name = _contactDisplayName(f['phone']?.toString(),
        (f['username'] ?? d['from_name'] ?? 'Someone').toString());
    final first = name.trim().split(RegExp(r'\s+')).first;
    HeartbeatLog.record(fromId, d['at']?.toString());
    _lubDub();
    _glow(fromId);
    if (!_appForeground) return;
    showMomentCard(
      context,
      title: AlutaMood.heartbeatReceived(first),
      leading: Icons.favorite_rounded,
      hold: const Duration(seconds: 7),
      actions: [
        MomentAction(Icons.favorite_rounded, 'Send one back',
            () => _sendHeartbeatTap(fromId, name),
            primary: true),
        if (f.isNotEmpty)
          MomentAction(Icons.chat_bubble_rounded, 'Message', () => openChat(f)),
      ],
    );
  }

  /// A line the server wrote with the actor's REGISTERED name in it ("Belina
  /// pinned a moment for you") → the same line with the name I saved for them.
  String _inMyNames(Map data, String line) {
    final reg = (data['from_username'] ?? data['from_name'] ?? '').toString();
    if (reg.isEmpty) return line;
    final mine = ContactNames.instance
        .displayName(userId: data['from_id'], registered: reg);
    return mine == reg ? line : line.replaceAll(reg, mine);
  }

  /// The flame next to a bonded partner's name (fetched lazily, cached).
  int? _streakFor(int friendId) {
    final space = _bondWith(friendId);
    final sid = (space?['id'] as num?)?.toInt();
    if (sid == null) return null;
    if (!_streakDays.containsKey(sid) && _streakFetching.add(sid)) {
      // Always cache something (0 hides the flame), so an offline / empty
      // answer doesn't refetch on every rebuild.
      ApiService().getStreak(sid).then((s) {
        if (!mounted) return;
        setState(() =>
            _streakDays[sid] = (s?['current_days'] as num?)?.toInt() ?? 0);
      }).catchError((_) {}).whenComplete(() => _streakFetching.remove(sid));
    }
    return _streakDays[sid];
  }

  /// Returns true when it showed a card.
  bool _maybeMusicWelcome(Duration away) {
    if (!mounted || !_appForeground) return false;
    if (!MomentPrefs.instance.welcomeCards.value) return false;
    if (WelcomeTour.showing) return false;
    if (away < const Duration(minutes: 1)) return false;
    if (_momentCooling) return false;
    if (ref.read(liveSessionProvider).active) return false;
    final np = ref.read(nowPlayingProvider);
    final playing = np.playing || (playbackBus.isPlaying?.call() ?? false);
    if (!playing) return false;
    _lastMomentAt = DateTime.now();

    final me = _username.trim().split(RegExp(r'\s+')).first;
    final partner = _partnerInfo();
    final space = partner?.space;
    final int? pid = partner?.id;
    final pname = partner?.name ?? '';
    final partnerListening =
        pid != null && NowPlayingPresence.instance.trackFor(pid) != null;
    final track = np.track;
    final title = AlutaMood.musicWelcome(
      me: me,
      track: track,
      partner: pname,
      partnerListening: partnerListening,
    );
    final artist = np.artist.trim();
    final subtitle = track.trim().isEmpty
        ? null
        : 'Now playing · ${track.trim()}${artist.isEmpty ? '' : ' — $artist'}';
    final actions = <MomentAction>[];
    if (space != null && pid != null) {
      final id = pid;
      final name = pname.isEmpty ? 'them' : pname;
      actions.add(partnerListening
          ? MomentAction(Icons.headphones_rounded, 'Tune in with $name',
              () => _tuneInto(id, name),
              primary: true)
          : MomentAction(Icons.favorite_rounded, 'Listen together',
              () => _openSpace(space),
              primary: true));
      actions.add(MomentAction(Icons.chat_bubble_rounded, 'Message $name',
          () => _messageSpacemate(space)));
    } else if (playbackBus.onShareToChat != null) {
      actions.add(MomentAction(Icons.send_rounded, 'Share to a chat',
          () => playbackBus.onShareToChat?.call(),
          primary: true));
    }
    showMomentCard(
      context,
      title: title,
      subtitle: subtitle,
      leading: partnerListening
          ? Icons.headphones_rounded
          : Icons.music_note_rounded,
      actions: actions,
    );
    return true;
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
                    borderRadius: BorderRadius.circular(Radii.sm),
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
                  borderRadius: BorderRadius.circular(Radii.sm),
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
  /// Aluta's own message banner (app open): reply in it — text or voice —
  /// without leaving the screen; tap it to open the chat.
  // A group was muted / its DJ changed → repaint the Circle list rows.
  void _onGroupMeta() {
    if (mounted) setState(() {});
  }

  bool _showReplyBanner({
    required String title,
    required String body,
    String? senderId,
    String? conversationId,
    String? groupTitle,
    String? messageId,
    bool mention = false,
  }) {
    if (!mounted) return false;
    // A muted group: no banner — and report it handled so no notification
    // pops instead. A personal @-mention of me still comes through.
    final mutedGid = int.tryParse(conversationId ?? '');
    if (!mention &&
        mutedGid != null &&
        GroupMeta.instance.isMuted(mutedGid)) {
      return true;
    }
    final payload = <String, dynamic>{
      'type': 'message',
      'friend_id': ?senderId,
      'sender_name': title,
      'conversation_id': ?conversationId,
      'group_title': ?groupTitle,
      'message_id': ?messageId,
    };
    // The home page's own context: it sits INSIDE the navigator, so the
    // overlay is found (the navigator key's context is above it → nothing
    // showed and the message went unannounced).
    return ReplyBanner.show(
      context,
      title: title,
      body: body,
      friendId: conversationId == null ? int.tryParse(senderId ?? '') : null,
      conversationId: int.tryParse(conversationId ?? ''),
      messageId: messageId,
      onOpen: () => _handleMessageTap(payload),
      onVoiceInChat: () => _handleMessageTap({...payload, 'voice': true}),
      // Replied from the banner → I've seen it: clear the unread badge too
      // (the banner already marked the thread read on the server).
      onReplied: () {
        if (!mounted) return;
        final fid = int.tryParse(senderId ?? '');
        if (conversationId == null && fid != null) {
          ref.read(unreadProvider.notifier).clear(fid);
        }
        _fetchFriends(quiet: true);
      },
    );
  }

  void _handleMessageTap(Map<String, dynamic> payload) {
    if (!mounted) return;
    // 🎤 Voice (notification) / mic (reply banner) → the chat starts
    // recording as soon as it's open.
    if (payload['voice'] == true) {
      final c = (payload['conversation_id'] ?? '').toString();
      final f = (payload['friend_id'] ?? '').toString();
      pendingVoiceReply.value =
          c.isNotEmpty ? 'c$c' : (f.isNotEmpty ? 's$f' : null);
    }
    // Whatever sits on top of home (a sheet, Our Space, Now Playing, a pushed
    // chat…) would hide the thread we're about to open — close back to home
    // first, so the tap always visibly lands in that chat. A live call screen
    // is left alone (the chat opens underneath it).
    if (!_callScreenOpen && !_groupCallScreenOpen) {
      final home = ModalRoute.of(context);
      final nav = Navigator.of(context);
      if (home != null && !home.isCurrent) {
        nav.popUntil((r) => r == home);
      }
    }
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
  // When Aluta last came to the front — a call Accepted from the banner that
  // just brought it forward still counts as "answered from the background".
  DateTime? _resumedAt;

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
        // Accepted from the banner while Aluta was in the background (or the
        // tap is what just brought it forward): tuck away once connected.
        final ra = _resumedAt;
        final fromBackground = !_appForeground ||
            (ra != null &&
                DateTime.now().difference(ra) < const Duration(seconds: 3));
        if (fromBackground) CallService.instance.tuckAwayOnConnect = true;
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
          transitionDuration: Motion.standard,
          reverseTransitionDuration: Motion.emphasized,
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
          transitionDuration: Motion.standard,
          reverseTransitionDuration: Motion.emphasized,
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
    // Desktop window in the background → what a phone would get by push.
    _mirrorForDesktop(type, event);
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
    // "Tune in" — asking to join what a friend is already playing.
    if (type != null && type.startsWith('tune_in_')) {
      _onTuneInSignal(event);
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
      if (mounted) showToast(context, _inMyNames(data, line), type: ToastType.info);
      _loadSpaces();
      spaceEventBus.value++; // live-reload an open Our Space page
      return;
    }
    // Your partner reacted to a moment you pinned.
    if (type == 'space_moment_react') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final who = ContactNames.instance.displayName(
          userId: data['from_id'],
          registered: (data['from_username'] ?? 'Your partner').toString());
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
      if (mounted) showToast(context, _inMyNames(data, line), type: ToastType.info);
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
      if (mounted) showToast(context, _inMyNames(data, line), type: ToastType.info);
      _loadSpaces();
      spaceEventBus.value++;
      return;
    }
    // Daily "Us" question — your partner answered, or you both just revealed.
    if (type == 'prompt_answered' || type == 'prompt_revealed') {
      final reveal = type == 'prompt_revealed';
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (mounted) {
        showToast(
          context,
          reveal
              ? 'You both answered today\'s question 💞'
              : '${ContactNames.instance.displayName(userId: data['from_id'], registered: (data['from_username'] ?? 'Your partner').toString())} answered today\'s question — your turn 💬',
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
        showToast(context, _inMyNames(data, line), type: ToastType.info);
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
      if (mounted) showToast(context, _inMyNames(data, line), type: ToastType.info);
      return;
    }
    // Someone wants to pin a bond with you → show the approval banner + toast.
    if (type == 'bond_request') {
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final line = (data['line'] ??
              '${data['from_username'] ?? 'Someone'} wants to pin a bond 💞')
          .toString();
      if (mounted) showToast(context, _inMyNames(data, line), type: ToastType.info);
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
      if (mounted) showToast(context, _inMyNames(data, line), type: ToastType.success);
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
    // "Show to …" while I'm elsewhere in Aluta (not in that chat): a gentle
    // nudge with See → the chat opens and lands on the message, ringing.
    if (type == 'msg_pulse' && event['away'] == true) {
      final who = ContactNames.instance.displayName(
          of: {'username': event['name'], 'phone': event['phone']},
          registered: (event['name'] ?? 'Someone').toString());
      final cid = event['conversation_id']?.toString();
      final from = event['user_id']?.toString();
      // That chat is already open here → it rings there itself.
      final openGroupId = _activeGroup?['id']?.toString();
      final open = cid != null
          ? openGroupId == cid
          : _activeGroup == null && _activeFriendId == from;
      if (mounted && !open) {
        showToast(context, '$who wants to show you a message 👀',
            duration: const Duration(seconds: 8),
            actions: [
              ToastAction('See', () {
                _handleMessageTap({
                  'message_id': event['message_id'],
                  'conversation_id': ?cid,
                  if (cid == null) 'friend_id': from,
                  'sender_name': event['name'],
                });
              }),
            ]);
      }
      return;
    }
    // A friend I asked about just came online (one-shot watch, server
    // online_watch.py). Phones also get the push; this is the in-app line.
    if (type == 'friend_status') {
      final d = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      QuickStatus.instance.applyEvent(d);
      return;
    }
    // "Tell me when they play music" fired — offer Tune in right here.
    if (type == 'friend_started_playing') {
      final d = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final fid = (d['user_id'] as num?)?.toInt();
      if (fid == null) return;
      OnlineWatchList.instance.playFired(fid);
      if (!_appForeground || !mounted) return; // push / desktop note has it
      final known = _allFriends.any((f) => (f['id'] as num?)?.toInt() == fid);
      final who =
          known ? _nameForUser(fid) : (d['username'] ?? 'Your friend').toString();
      final song = (d['title'] ?? '').toString().trim();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          content: Text(song.isEmpty
              ? '🎶 $who is playing music'
              : '🎶 $who is playing “$song”'),
          action: SnackBarAction(
            label: 'Tune in',
            onPressed: () => _tuneInto(fid, who),
          ),
        ));
      return;
    }
    if (type == 'friend_came_online') {
      final d = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final fid = (d['user_id'] as num?)?.toInt();
      if (fid != null) _onWatchedFriendOnline(fid, d);
      return;
    }
    // They opened a secret heart I sent (server hearts.py). Phones get the
    // FCM ping; desktop/web have no FCM, so show a tender in-app bar here
    // unless that chat is already open (its bubble updates in place).
    // Partner's heartbeat tap (server spaces.py) → lub-dub + glow + card.
    if (type == 'heartbeat_tap') {
      final d = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      _onHeartbeatReceived(d);
      return;
    }
    if (type == 'heart_opened') {
      // In the app (any platform): the in-app heart pill. In the background
      // the push (phones) / nothing (desktop) handles it.
      if (!_appForeground || !mounted) return;
      final d = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final byId = d['by_id']?.toString();
      if (byId != null && byId == _activeFriendId?.toString()) return;
      final phone = (d['by_phone'] ?? '').toString();
      final saved =
          phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
      final who = (saved != null && saved.isNotEmpty)
          ? saved
          : (d['by_name'] ?? 'Someone').toString();
      showHeartOpenedToast(context, who);
      return;
    }
    // Someone @-mentioned me in a group (server: routers/conversations.py).
    if (type == 'mention') {
      final cid = int.tryParse((event['conversation_id'] ?? '').toString());
      if (cid == null) return;
      final mid = (event['message_id'] ?? '').toString();
      final viewing = _activeGroup != null &&
          _activeGroup!['id']?.toString() == cid.toString();
      if (viewing && _appForeground) return; // it's right there on screen
      if (mounted) setState(() => _groupMentions[cid] = mid);
      // Android/iOS get the FCM "mentioned you" heads-up. Desktop/web have no
      // FCM, so prompt from here: an in-app bar while open, a local
      // notification when the window is in the background.
      if (!fcmSupported) {
        // My phone-book name for the sender, else their Aluta username.
        final sPhone = (event['sender_phone'] ?? '').toString();
        final saved =
            sPhone.isNotEmpty ? ContactNames.instance.nameFor(sPhone) : null;
        final who = (saved != null && saved.isNotEmpty)
            ? saved
            : (event['sender_name'] ?? 'Someone').toString();
        final gTitle = (event['group_title'] ?? '').toString();
        final everyone = event['all'] == true;
        final line = everyone
            ? '$who mentioned everyone${gTitle.isEmpty ? '' : ' in $gTitle'}'
            : '$who mentioned you${gTitle.isEmpty ? '' : ' in $gTitle'}';
        if (_appForeground) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
              content: Row(children: [
                const Icon(Icons.alternate_email_rounded,
                    size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(child: Text(line)),
              ]),
              action: SnackBarAction(
                label: 'View',
                onPressed: () => _handleMessageTap({
                  'conversation_id': cid.toString(),
                  'group_title': gTitle,
                  'message_id': mid,
                }),
              ),
            ));
        } else {
          showMessageNotification(
            title: gTitle.isEmpty ? who : gTitle,
            body: line,
            senderName: who,
            conversationId: cid.toString(),
            groupTitle: gTitle.isEmpty ? null : gTitle,
            messageId: mid.isEmpty ? null : mid,
            bypassMute: !everyone, // a mention of me pierces a mute
          );
        }
      }
      return;
    }
    // A friend is typing to me → show a live "typing…" line on their tile.
    // My message was read / delivered → the card's ✓✓ updates live.
    if (type == 'messages_read' || type == 'message_delivered') {
      final d = (event['data'] as Map?) ?? const {};
      final who = type == 'messages_read'
          ? (d['reader_id'] as num?)?.toInt()
          : (d['receiver_id'] as num?)?.toInt();
      if (who == null) return;
      for (final f in _allFriends) {
        if ((f['id'] as num?)?.toInt() != who) continue;
        if ((f['last_sender_id'] as num?)?.toInt() != _myUserId) break;
        if (mounted) {
          setState(() {
            f['last_message_delivered'] = true;
            if (type == 'messages_read') f['last_message_read'] = true;
          });
        }
        break;
      }
      // (the open chat handles its own bubbles — don't swallow the event)
    }
    if (type == 'app_update') {
      // Just published (server announce) → check now, toast if newer.
      AppUpdater.instance.announced(context,
          (event['build'] as num?)?.toInt() ?? 0, '${event['platform']}');
    }
    if (type == 'bond_ping' && event['kind'] == 'touch') {
      // My person is holding the heart and I'm elsewhere in the app: feel it
      // (the open chat with them shows its own heart instead).
      final sid = '${event['user_id']}';
      if (!ActiveChat.instance.suppresses(senderId: sid)) _feelHeld(sid);
    }
    if (type == 'typing') {
      // Group typing carries a conversation_id → light the GROUP tile, not the
      // sender's DM row (which would wrongly suggest the reply lands in the DM).
      // DM typing has no conversation_id → light the friend's DM tile as before.
      final convRaw = (event['conversation_id'] ?? '').toString();
      final convId = int.tryParse(convRaw);
      if (convId != null) {
        // Prefer the recipient's own phonebook name for this friend; fall back
        // to the app username. Show just the first name on the tile.
        final phone = (event['phone'] ?? '').toString();
        final uname = (event['name'] ?? '').toString();
        final saved =
            phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
        final full = (saved != null && saved.isNotEmpty) ? saved : uname;
        final first = full.trim().isEmpty
            ? ''
            : full.trim().split(RegExp(r'\s+')).first;
        _setGroupTyping(
            convId, first, (event['kind'] ?? 'typing').toString());
      } else {
        final uid = (event['user_id'] as num?)?.toInt();
        if (uid != null) {
          _setFriendTyping(uid, (event['kind'] ?? 'typing').toString());
        }
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
      // Keep it for the thread: opening that chat paints it at once (with the
      // "new messages" divider) instead of after the history fetch.
      LiveInbox.instance.add(data, _myUserId?.toString());
      // Its chat moves to the top of the list: glide + blink, or the chip.
      _noteIncomingForList(data);
      // "Save to Gallery" on → a received photo / video goes there now.
      GalleryAutoSave.instance.consider(data, _myUserId?.toString());
      if (mid != null &&
          data['receiver_id']?.toString() == _myUserId?.toString() &&
          data['delivered'] == false) {
        ApiService().markMessageAsDelivered(mid);
      }
      // Backend payload is a MessageWithSender: sender is a nested user object
      // and the text lives in `content`.
      final senderObj = (data['sender'] as Map?)?.cast<String, dynamic>();
      final registeredName = (senderObj?['username'] ??
              data['sender_name'] ??
              data['username'] ??
              'New message')
          .toString();
      // How *I* saved them (phonebook), same as the push path.
      final sender = ContactNames.instance.displayName(
          of: senderObj,
          userId: senderObj?['id'] ?? data['sender_id'],
          registered: registeredName);
      // A secret heart's note never goes into a notification.
      final text = (data['message_type'] ?? '').toString() == 'heart'
          ? '❤️ Sent you a secret heart'
          : (data['content'] ?? data['text'] ?? data['message'] ?? '')
              .toString();
      // Badge the sender immediately (unless their chat is open) — the fetch
      // below reconciles to the server's authoritative count a moment later.
      final senderId = (senderObj?['id'] as num?)?.toInt() ??
          (data['sender_id'] as num?)?.toInt();
      if (!_appForeground) {
        // Every message now carries a conversation_id — DMs too — so only a
        // message with no receiver is a GROUP one. Treating DMs as groups gave
        // them a different notification slot than the push for the same
        // message → two banners. Same slot now: the second just replaces the
        // first.
        final isGroup = data['receiver_id'] == null &&
            (data['conversation_id'] ?? '').toString().isNotEmpty;
        final convId =
            isGroup ? (data['conversation_id'] ?? '').toString() : '';
        final gTitle = (data['group_title'] ?? '').toString();
        final msgId = (data['id'] ?? data['message_id'] ?? '').toString();
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
      } else if (senderId != null &&
          senderId.toString() != _myUserId?.toString()) {
        // App open, the message is for a chat that isn't on screen → the
        // in-app reply banner (not Android's notification).
        final isGroup = data['receiver_id'] == null &&
            (data['conversation_id'] ?? '').toString().isNotEmpty;
        final convId =
            isGroup ? (data['conversation_id'] ?? '').toString() : '';
        final gTitle = (data['group_title'] ?? '').toString();
        final msgId = (data['id'] ?? data['message_id'] ?? '').toString();
        if (!ActiveChat.instance.suppresses(
            senderId: senderId.toString(), convId: convId)) {
          _showReplyBanner(
            title: isGroup && gTitle.isNotEmpty ? gTitle : sender,
            body: isGroup
                ? '$sender: ${text.isEmpty ? 'Sent a message' : text}'
                : (text.isEmpty ? 'Sent you a message' : text),
            senderId: senderId.toString(),
            conversationId: convId.isEmpty ? null : convId,
            groupTitle: gTitle.isEmpty ? null : gTitle,
            messageId: msgId.isEmpty ? null : msgId,
          );
        }
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
        final me = _myUserId;
        if (me != null) BlockList.instance.load(me);
      }
      _myAvatar = data['avatar_url'] as String?;
      if (data.isNotEmpty && data['username'] != null) {
        await prefs.setString('username', data['username']);
        MentionSelf.username = data['username'].toString();
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
      // Every friend's number by id → my saved names anywhere in the app.
      ContactNames.instance.rememberAll(list);
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
      ContactNames.instance.rememberAll(friends);
      setState(() {
        _allFriends = friends;
        // Respect an active search query — mirrors _fetchGroups so a background
        // refresh can't leave friends unfiltered while groups stay filtered.
        _filteredFriends = _applyFriendQuery(friends, _searchQuery);
        _isCurrentUserOnline = true;
        _serverReachable = true;
        _isLoadingFriends = false;
      });
      // Sunday's gentle "it's been a while" card, once the list is fresh.
      if (!_reconnectChecked) {
        _reconnectChecked = true;
        Future.delayed(const Duration(seconds: 6), _maybeReconnectNudge);
      }
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
      _prefetchUnread(counts);
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
      _prefetchUnreadGroups(groups);
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
    appBusy.beginMajor(label: 'Reconnecting…');
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
    appBusy.endMajor(label: 'Reconnecting…');
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
  // The circle search I had typed when I opened a chat from its results —
  // restored when I come back, so "back" returns to exactly what I left.
  String _searchBeforeChat = '';
  bool _wasInChat = false;

  // ── List navigation ──
  // Circle / Harmony list scroll (phone + desktop columns share them; the
  // lists' PageStorageKeys keep the position across a chat).
  final ScrollController _circleScroll = ScrollController();
  final ScrollController _harmonyScroll = ScrollController();
  // The maximised Status grid / Listening list (one is on screen at a time).
  final ScrollController _circleMaxScroll = ScrollController();
  // Rows blinking right now ('s<friendId>' / 'g<convId>').
  final Set<String> _flashKeys = {};
  // Bumped on every _flashRows, so a row that is asked again while it is
  // still marked (came back + a new message within a second) breathes again.
  int _flashGen = 0;
  Timer? _flashTimer;
  // The row I opened a chat from — it blinks when I come back.
  String? _openedKey;
  // Chats that got a new message while I was scrolled away / elsewhere →
  // the "↑ N new" chip (newest last).
  final Set<String> _newWhileAway = <String>{};
  // New messages landing together glide up ONCE (a burst, not a jitter).
  final Set<String> _burst = {};
  Timer? _burstTimer;
  DateTime _lastUserScroll = DateTime.fromMillisecondsSinceEpoch(0);

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
    _maybeBothListening();
  }

  // Unread that came in while the socket was down (app in the background,
  // push only) never reached LiveInbox. Fetch those threads' newest messages
  // quietly now, so opening one is instant too. Only when a count GREW, at
  // most 3 chats per refresh.
  final Map<int, int> _prefetchedUnread = {};

  Future<void> _prefetchUnread(Map<int, int> counts) async {
    final me = _myUserId;
    if (me == null) return;
    final due = <int>[
      for (final e in counts.entries)
        if (e.value > 0 && e.value > (_prefetchedUnread[e.key] ?? 0)) e.key,
    ];
    _prefetchedUnread
      ..removeWhere((k, _) => (counts[k] ?? 0) == 0)
      ..addAll({for (final id in due) id: counts[id]!});
    for (final fid in due.take(3)) {
      if (fid.toString() == _activeFriendId) continue; // open chat has it
      try {
        final msgs = await ApiService()
            .fetchMessagesBetween(me, fid, skip: 0, limit: 20);
        for (final m in msgs.reversed) {
          LiveInbox.instance.add(m, me.toString());
          GalleryAutoSave.instance.consider(m, me.toString());
        }
      } catch (_) {}
    }
  }

  // Groups: same quiet prefetch for unread that arrived by push only.
  final Map<int, int> _prefetchedGroupUnread = {};

  Future<void> _prefetchUnreadGroups(List<Map<String, dynamic>> groups) async {
    final me = _myUserId;
    if (me == null) return;
    final due = <int>[];
    for (final g in groups) {
      final cid = (g['id'] as num?)?.toInt();
      final n = (g['unread_count'] as num?)?.toInt() ?? 0;
      if (cid == null) continue;
      if (n == 0) {
        _prefetchedGroupUnread.remove(cid);
      } else if (n > (_prefetchedGroupUnread[cid] ?? 0)) {
        _prefetchedGroupUnread[cid] = n;
        due.add(cid);
      }
    }
    for (final cid in due.take(3)) {
      if ((_activeGroup?['id'] as num?)?.toInt() == cid) continue;
      try {
        final msgs = await ApiService()
            .fetchConversationMessages(cid, skip: 0, limit: 20);
        for (final m in msgs) {
          LiveInbox.instance.add(m, me.toString());
          GalleryAutoSave.instance.consider(m, me.toString());
        }
      } catch (_) {}
    }
  }

  // ── "It's been a while" — gentle reconnect 🌱 ─────────────────────────────
  // Sundays only, at most ONE card a week: the friend who's gone quiet the
  // longest (2+ weeks, but not a stale contact from months ago). "Not now"
  // twice for a person → never again for them. No streaks, no pressure.
  bool _reconnectChecked = false;

  Future<void> _maybeReconnectNudge() async {
    if (!mounted || !_appForeground || WelcomeTour.showing) return;
    if (!MomentPrefs.instance.welcomeCards.value || _momentCooling) return;
    if (ref.read(liveSessionProvider).active) return;
    final now = DateTime.now();
    if (now.weekday != DateTime.sunday || now.hour < 9) return;
    final SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final week = '${now.year}-${now.difference(DateTime(now.year)).inDays ~/ 7}';
    if (p.getString('reconnect_week') == week) return;
    Map<String, dynamic>? pick;
    var pickDays = 0;
    for (final f in _allFriends) {
      final fid = (f['id'] as num?)?.toInt();
      final ts = (f['last_timestamp'] ?? '').toString();
      if (fid == null || ts.isEmpty) continue;
      if ((p.getInt('reconnect_no_$fid') ?? 0) >= 2) continue;
      final days = now.difference(parseServerTime(ts)).inDays;
      if (days < 14 || days > 120) continue;
      if (days > pickDays) {
        pick = f;
        pickDays = days;
      }
    }
    if (pick == null || !mounted) return;
    final f = pick;
    final fid = (f['id'] as num).toInt();
    await p.setString('reconnect_week', week);
    // A song they shared before, from this device's copy of the chat.
    String? song;
    try {
      final raw = p.getString('chat_cache_${_myUserId ?? 'x'}_$fid');
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final m in list.whereType<Map>()) {
            if ((m['message_type'] ?? '') != 'song') continue;
            final t = ((m['content'] ?? '').toString().trim().isNotEmpty
                    ? m['content']
                    : m['media_name'] ?? '')
                .toString()
                .replaceAll(RegExp(r'\.(mp3|m4a|aac|wav|flac|ogg|opus)$',
                    caseSensitive: false), '')
                .trim();
            if (t.isNotEmpty && !t.startsWith('>')) {
              song = t;
              break;
            }
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    final name = _contactDisplayName(
        f['phone']?.toString(), (f['username'] ?? 'Friend').toString());
    final first = name.trim().split(RegExp(r'\s+')).first;
    final weeks = pickDays ~/ 7;
    final quiet = weeks >= 2 ? '$weeks weeks quiet' : 'a while quiet';
    _lastMomentAt = DateTime.now();
    Future<void> notNow() async {
      try {
        await p.setInt(
            'reconnect_no_$fid', (p.getInt('reconnect_no_$fid') ?? 0) + 1);
      } catch (_) {}
    }

    showMomentCard(
      context,
      title: '$first — $quiet 🌱',
      subtitle: song == null
          ? 'Send $first a song?'
          : 'You two once shared “$song” — send $first a song?',
      leading: Icons.spa_rounded,
      hold: const Duration(seconds: 12),
      onIgnored: notNow,
      actions: [
        MomentAction(Icons.music_note_rounded, 'Send a song', () => openChat(f),
            primary: true),
        MomentAction(Icons.close_rounded, 'Not now', notNow),
      ],
    );
  }

  /// "Belyner is online now 🟢" — the watch I set fired (once, then ends).
  void _onWatchedFriendOnline(int fid, Map<String, dynamic> d) {
    OnlineWatchList.instance.fired(fid);
    if (!mounted) return;
    final f = _allFriends.firstWhere(
        (x) => (x['id'] as num?)?.toInt() == fid,
        orElse: () => <String, dynamic>{});
    final name = _contactDisplayName(f['phone']?.toString(),
        (f['username'] ?? d['username'] ?? 'Your friend').toString());
    final first = name.trim().split(RegExp(r'\s+')).first;
    Haptics.lightImpact();
    _lastMomentAt = DateTime.now();
    // Waited so we could listen together → that's the first button.
    final forListen = d['purpose'] == 'listen' ||
        OnlineWatchList.instance.wantsListen(fid);
    OnlineWatchList.instance.clearListen(fid);
    final space = _spaceWithFriend(fid);
    showMomentCard(
      context,
      title: '$first is online now 🟢',
      subtitle: forListen
          ? 'Ready to listen together?'
          : 'You asked to know — say hi while they\'re here',
      leading: forListen
          ? Icons.headphones_rounded
          : Icons.notifications_active_rounded,
      hold: Duration(seconds: forListen ? 14 : 9),
      actions: [
        if (forListen)
          MomentAction(Icons.headphones_rounded, 'Listen together', () {
            if (space != null) {
              spaceAutoListen.value = fid; // the Space starts it on open
              _openSpace(space);
            } else if (f.isNotEmpty) {
              openChat(f);
            }
          }, primary: true),
        if (f.isNotEmpty)
          MomentAction(Icons.waving_hand_rounded, 'Say hi', () => openChat(f),
              primary: !forListen),
        if (f.isNotEmpty)
          MomentAction(Icons.call_rounded, 'Call', () {
            _showCallChoice(
              friendId: fid,
              name: name,
              avatar: f['avatar_url'] as String?,
              phone: f['phone'] as String?,
            );
          }),
      ],
    );
  }

  // ── "You're both listening" ──────────────────────────────────────────────
  // Two friends independently playing the same song (or the same artist) at
  // the same moment → one gentle line with a one-tap Listen Together. Only
  // when I share my listening with them (so it's mutual), at most once per
  // friend every 4 h, never during a Listen Together session.
  final Set<String> _bothShownThisRun = {};

  static String _normSong(String t) => t
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), ' ')
      .replaceAll(RegExp(r'\b(feat|ft)\.?\b.*'), ' ')
      .replaceAll(RegExp(r'\.(mp3|m4a|aac|wav|flac|ogg|opus)$'), ' ')
      .replaceAll(RegExp(r'[^a-z0-9\u00c0-\uffff]+'), ' ')
      .trim();

  static String _normArtist(String a) {
    final n = _normSong(a.split(RegExp(r',|&| x | feat', caseSensitive: false))
        .first);
    return (n == 'aluta' || n == 'unknown' || n == 'unknown artist') ? '' : n;
  }

  Future<void> _maybeBothListening() async {
    if (!mounted || !_appForeground || WelcomeTour.showing) return;
    if (ref.read(liveSessionProvider).active) return;
    final presence = NowPlayingPresence.instance;
    final mine = presence.myTrack;
    if (mine == null) return;
    final myTitle = _normSong(mine.title);
    final myArtist = _normArtist(mine.artist);
    if (myTitle.isEmpty) return;
    for (final f in _allFriends) {
      final fid = (f['id'] as num?)?.toInt();
      if (fid == null || !presence.sharesWith(fid)) continue;
      final t = presence.trackFor(fid);
      if (t == null) continue;
      final theirTitle = _normSong((t['title'] ?? '').toString());
      final theirArtist = _normArtist((t['artist'] ?? '').toString());
      final sameSong = theirTitle.isNotEmpty &&
          theirTitle == myTitle &&
          (myArtist.isEmpty || theirArtist.isEmpty || myArtist == theirArtist);
      final sameArtist =
          !sameSong && myArtist.isNotEmpty && myArtist == theirArtist;
      if (!sameSong && !sameArtist) continue;
      final runKey = '$fid|${sameSong ? myTitle : myArtist}';
      if (_bothShownThisRun.contains(runKey)) continue;
      _bothShownThisRun.add(runKey);
      // Throttle across launches: once per friend every 4 h.
      try {
        final p = await SharedPreferences.getInstance();
        final k = 'both_listening_at_$fid';
        final last = p.getInt(k) ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - last < const Duration(hours: 4).inMilliseconds) continue;
        await p.setInt(k, now);
      } catch (_) {}
      if (!mounted) return;
      final name = _contactDisplayName(
          f['phone']?.toString(), (f['username'] ?? 'Friend').toString());
      final first = name.trim().split(RegExp(r'\s+')).first;
      final what = sameSong
          ? mine.title.trim()
          : (t['artist'] ?? mine.artist).toString().trim();
      final bonded = _bondWith(fid) != null;
      _lastMomentAt = DateTime.now();
      Haptics.lightImpact();
      showMomentCard(
        context,
        title: sameSong
            ? 'You and $first are both listening to $what 🎧'
            : 'You and $first are both on $what right now 🎧',
        // Bonded → straight into your Space (Listen Together lives there);
        // otherwise the chat, where the 🎧 starts it.
        subtitle: bonded
            ? 'Listen together?'
            : 'Listen together from your chat?',
        leading: Icons.headphones_rounded,
        hold: const Duration(seconds: 9),
        actions: [
          if (bonded)
            MomentAction(Icons.headphones_rounded, 'Listen together',
                () => _tuneInto(fid, first),
                primary: true),
          MomentAction(Icons.chat_bubble_rounded,
              bonded ? 'Message' : 'Open chat', () => openChat(f),
              primary: !bonded),
        ],
      );
      return; // one line at a time
    }
  }

  /// Mark [id] as typing to me and auto-clear after 5s (each typing event
  /// refreshes the timer). No periodic polling — the timer's presence IS the
  /// state, and it only exists while someone is actively typing.
  void _setFriendTyping(int id, [String kind = 'typing']) {
    final was = _typingTimers.containsKey(id);
    final kindChanged = _typingKind[id] != kind;
    _typingKind[id] = kind;
    _typingTimers[id]?.cancel();
    _typingTimers[id] = Timer(const Duration(seconds: 5), () {
      _typingTimers.remove(id);
      _typingKind.remove(id);
      if (mounted) setState(() {});
    });
    if ((!was || kindChanged) && mounted) setState(() {});
  }

  /// Mark group [convId] as having a live typer and auto-clear after 5s. Keyed
  /// by conversation id so it drives the group tile, never a DM row.
  void _setGroupTyping(int convId,
      [String typerName = '', String kind = 'typing']) {
    final was = _groupTypingTimers.containsKey(convId);
    final kindChanged = _groupTypingKind[convId] != kind;
    _groupTypingKind[convId] = kind;
    _groupTypingTimers[convId]?.cancel();
    if (typerName.isNotEmpty) {
      _groupTypingNames[convId] = typerName;
    }
    _groupTypingTimers[convId] = Timer(const Duration(seconds: 5), () {
      _groupTypingTimers.remove(convId);
      _groupTypingNames.remove(convId);
      _groupTypingKind.remove(convId);
      if (mounted) setState(() {});
    });
    if ((!was || kindChanged) && mounted) setState(() {});
  }

  /// Sign out directly from the consent gate when the user declines to accept.
  /// No confirm dialog — declining consent is itself the deliberate choice.
  Future<void> _signOutFromGate() async {
    try {
      await FcmService.instance.unregisterToken();
    } catch (_) {}
    NowPlayingPresence.instance.stop();
    LiveInbox.instance.clearAll(); // no messages carried into another account
    BlockList.instance.clear(); // …nor whom this account blocked
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

  /// I blocked / unblocked someone: their listening, status and presence go
  /// (or come back) at once — refetch the circle and statuses, and drop any
  /// track of theirs still showing.
  // A status of mine was just posted (from anywhere — the composer, Share as
  // status, a song share): fetch statuses so "Your story" lights up.
  int _storyPostedSeen = 0;
  void _onStoryPosting() {
    final n = StoryPosting.instance.posted;
    if (n != _storyPostedSeen) {
      _storyPostedSeen = n;
      _fetchStories();
    }
  }

  /// The open DM friend's Listen-Together readiness (from the friend list).
  String? _activeNetGrade() {
    final id = _activeFriendId;
    if (id == null) return null;
    for (final f in _allFriends) {
      if (f['id']?.toString() == id) return f['net_grade']?.toString();
    }
    return null;
  }

  int _blockVersion = 0;
  void _onBlockList() {
    for (final p in BlockList.instance.people) {
      final id = (p['id'] as num?)?.toInt();
      if (id != null) {
        NowPlayingPresence.instance.forget(id);
        SteadyListening.instance.forget(id); // no "paused" grace for a block
      }
    }
    if (BlockList.instance.version != _blockVersion) {
      _blockVersion = BlockList.instance.version;
      _fetchFriends();
      _fetchStories();
    }
    if (mounted) setState(() {});
  }

  void _onLastSeenPrivacy() {
    // The account sync uploads ~3 s after a change; refetch after that.
    _lastSeenCache.clear();
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (mounted) _fetchFriends(quiet: true);
    });
  }

  /// A one-sided chat says so, kindly, above the messages: until BOTH have
  /// saved each other we can only message — statuses, music, last seen and
  /// the rest wait. If they saved me, one tap adds them back.
  Widget _withCircleBanner(Widget chat) {
    final fid = int.tryParse(_activeFriendId ?? '');
    final f = fid == null
        ? null
        : _allFriends.firstWhere((x) => (x['id'] as num?)?.toInt() == fid,
            orElse: () => <String, dynamic>{});
    if (f == null || f.isEmpty) return chat;
    final byMe = f['added_by_me'] != false;
    final me = f['added_me'] != false;
    if (byMe && me) return chat;
    final scheme = Theme.of(context).colorScheme;
    final first = _contactDisplayName(_activeFriendPhone, _activeFriendName ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .first;
    final banner = Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(children: [
          Icon(Icons.person_add_alt_1_rounded,
              size: 18, color: accentInk(scheme)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              !byMe
                  ? '$first saved your number. Add them to your circle to '
                      'share statuses, music and more.'
                  : 'Waiting for $first to save your number — until then '
                      'you can message each other.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
            ),
          ),
          if (!byMe)
            TextButton(
              onPressed: () async {
                final ok = await ApiService().addFriend(fid!);
                if (!mounted) return;
                showToast(
                    context,
                    ok
                        ? 'Added — you and $first are in each other’s circle 💛'
                        : 'Couldn’t add them — try again',
                    type: ok ? ToastType.success : ToastType.error);
                if (ok) _fetchFriends(quiet: true);
              },
              child: const Text('Add'),
            ),
        ]),
      ),
    );
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 2), child: banner),
      Expanded(child: chat),
    ]);
  }

  /// The chat header's photo slot: a 34 px photo in a 42 px ring slot that
  /// LAYS OUT 36 px tall — the rim overhangs into the header's padding — so
  /// the header is the same height with or without a ring.
  Widget _headerPhotoSlot(Widget ring) => AvatarFlightTarget(
        // The photo tapped in the list lands here (PanelFlight).
        child: SizedBox(
          width: 42,
          height: 36,
          child: OverflowBox(
            minWidth: 42,
            maxWidth: 42,
            minHeight: 42,
            maxHeight: 42,
            child: ring,
          ),
        ),
      );

  // Where each friend's photo sits in the list right now (for the flight
  // into the chat header). Plain contexts, not GlobalKeys: a friend can be
  // built twice (a swipe preview) without clashing.
  final Map<int, BuildContext> _tileAvatarCtx = {};

  /// The flight from the tapped photo into the chat header.
  void _flyAvatarFor(int id, String name, String? avatarRel) {
    final c = _tileAvatarCtx[id];
    if (c == null || !c.mounted) return;
    final box = c.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final from = box.localToGlobal(Offset.zero) & box.size;
    final face = Rect.fromCenter(
        center: from.center,
        width: min(from.width, 44),
        height: min(from.height, 44));
    PanelFlight.fly(
        context,
        face,
        InitialsAvatar(
            name: name, radius: 22, imageUrl: _avatarFull(avatarRel)));
  }

  /// The story rim on a friend's photo — the SAME language as the status
  /// tray: my Harmony partner's new status glows warm theme → rose → gold,
  /// their seen one a soft rose; everyone else the usual gradient / grey.
  /// The status ring on a friend's photo: one arc per status, watched ones
  /// grey — the same painter and colours as the status row.
  StoryRingPainter _storyRim(int id, StoryGroup story, ColorScheme scheme) {
    final partner = _isHarmonyPartner(id);
    return StoryRingPainter(
      seen: [
        for (final s in story.stories)
          // A muted friend never lights up as new.
          s.viewed || !story.hasUnseen,
      ],
      colors: partner ? StoryRingStyle.partner(scheme) : StoryRingStyle.unseen,
      seenColor:
          partner ? StoryRingStyle.partnerSeen : StoryRingStyle.seen(scheme),
      stroke: 3.5,
    );
  }

  /// A bond milestone hit today ("🔥 30 days in tune today"), else null.
  String? _milestoneWhisper(Map<String, dynamic>? space) {
    final r = (space?['stats'] as Map?)?['milestone_reached'];
    if (r is! Map) return null;
    final label = (r['label'] ?? '').toString();
    if (r['kind'] == 'streak') {
      final v = (r['value'] as num?)?.toInt();
      return v == null ? null : '🔥 $v days in tune today';
    }
    return label.isEmpty ? null : '💞 $label close today';
  }

  /// "🌙 2:14 AM there" when their clock differs from mine by an hour+.
  String? _theirLocalTime() {
    final tz = _activeFriendTz;
    if (tz == null) return null;
    final mine = DateTime.now().timeZoneOffset.inMinutes;
    if ((tz - mine).abs() < 60) return null;
    final at = DateTime.now().toUtc().add(Duration(minutes: tz));
    final night = at.hour >= 21 || at.hour < 6;
    return '${night ? '🌙' : '☀️'} ${DateFormat('h:mm a').format(at)} there';
  }

  /// A song's colour, nudged toward the text colour until it reads well on
  /// the page (album colours can be very dark or very light).
  Color _readableInk(Color c, ColorScheme s) {
    double contrast(Color x, Color y) {
      final a = x.computeLuminance(), b = y.computeLuminance();
      return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
    }

    var out = c;
    for (var i = 1; i <= 10 && contrast(out, s.surface) < 4.5; i++) {
      out = Color.lerp(c, s.onSurface, i / 10)!;
    }
    return out;
  }

  /// Our Space's "your song" for this partner (title), else null.
  String? _yourSongWith(int fid) {
    final ys = (_bondWith(fid)?['stats'] as Map?)?['your_song'];
    final t = ys is Map ? (ys['title'] ?? '').toString().trim() : '';
    return t.isEmpty ? null : t;
  }

  /// Play "your song" from my loaded songs (matched loosely by title).
  void _playYourSong(String title) {
    final ok = _playLoadedSong(title);
    showToast(
        context,
        ok
            ? 'Playing your song — “$title” 💞'
            : '“$title” isn’t in your loaded songs yet',
        type: ToastType.info);
  }

  /// Play a song from MY loaded songs, matched loosely by title (exact,
  /// then "file starts with / contains it"). false = not loaded here.
  bool _playLoadedSong(String title) => playLoadedSongByTitle(title);

  /// "🎵 Answer with a song" on a friend's status: pick one of my songs; it
  /// goes to our chat as a playable song, with a line saying what it's for.
  Future<void> _answerStatusWithSong(
      BuildContext ctx, int id, String name, String about) async {
    final first = name.trim().split(RegExp(r'\s+')).first;
    final pick = await pickLoadedSong(ctx,
        title: 'Answer with a song',
        subtitle: 'It goes to $first’s chat, for $about');
    if (pick == null) return;
    final api = ApiService();
    try {
      final bytes = await pick.load();
      if (bytes.length > 25 * 1024 * 1024) throw Exception('too big');
      final mime = pick.fileName.toLowerCase().endsWith('.m4a')
          ? 'audio/mp4'
          : 'audio/mpeg';
      final up = await api.uploadMedia(
          bytes: bytes, filename: pick.fileName, mime: mime, ephemeral: true);
      if (up == null || up['url'] == null) throw Exception('upload');
      await api.sendMessage(id, '🎵 This one’s for $about',
          messageType: 'text');
      final sent = await api.sendMessage(id, pick.title,
          messageType: 'song',
          mediaUrl: up['url'].toString(),
          mediaName: (up['name'] ?? pick.fileName).toString(),
          mediaMime: (up['mime'] ?? mime).toString(),
          mediaSize: (up['size'] as num?)?.toInt() ?? bytes.length);
      if (sent == null) throw Exception('send');
      if (ctx.mounted) {
        showToast(ctx, '🎵 “${pick.title}” sent to $first',
            type: ToastType.success);
      }
    } catch (_) {
      if (ctx.mounted) {
        showToast(ctx, 'Couldn’t send that song — try again',
            type: ToastType.error);
      }
    }
  }

  /// My person is holding the heart while I'm elsewhere in the app: a
  /// lub-dub, and (at most every 15 s) a quiet line saying who.
  DateTime? _heldToastAt;
  void _feelHeld(String senderId) {
    final id = int.tryParse(senderId);
    if (id == null || _bondWith(id) == null) return;
    () async {
      await Haptics.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 170));
      await Haptics.lightImpact();
    }();
    final now = DateTime.now();
    if (_heldToastAt != null &&
        now.difference(_heldToastAt!) < const Duration(seconds: 15)) {
      return;
    }
    _heldToastAt = now;
    if (!mounted) return;
    final first = _nameForUser(id).trim().split(RegExp(r'\s+')).first;
    showToast(context, '💓 $first is holding you — open your chat to hold back',
        type: ToastType.info);
  }

  // ── List navigation ─────────────────────────────────────────────────────

  /// "Here it is": these rows breathe once (the ⌖ glow; a partner's row also
  /// gets its circling hearts).
  void _flashRows(Set<String> keys) {
    if (keys.isEmpty) return;
    _flashTimer?.cancel();
    setState(() {
      _flashGen++;
      _flashKeys
        ..clear()
        ..addAll(keys);
    });
    _flashTimer = Timer(const Duration(milliseconds: 1700), () {
      if (mounted) setState(_flashKeys.clear);
    });
  }

  /// Is the Circle list on screen right now? (Desktop columns: always.)
  bool get _circleListVisible {
    if (!_appForeground) return false;
    // Status or Listening maximised: the chat list isn't on screen, so news
    // waits on the "↑ N new" chip for when it's back.
    if (_circleView == 'stories' || _circleView == 'listening') return false;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    // Wide: the Circle column is always beside Harmony — unless Glow fills
    // the panel.
    if (wide) return _friendLayer != 'glow';
    return _activeFriendId == null &&
        _activeGroup == null &&
        _friendLayer == 'circle';
  }

  /// Glide a list to the top; arriving there clears the "new" chip and
  /// blinks what was new.
  void _scrollListToTop(ScrollController c) {
    if (!c.hasClients) return;
    final fresh = Set<String>.of(_newWhileAway);
    c.animateTo(0,
        duration: Motion.slow,
        curve: Curves.easeOutCubic);
    if (fresh.isNotEmpty) {
      setState(_newWhileAway.clear);
      Future<void>.delayed(const Duration(milliseconds: 480), () {
        if (mounted) _flashRows(fresh);
      });
    }
  }

  /// Tapped the layer pill that's already lit → that list back to the top.
  void _scrollLayerToTop(String layer) {
    Haptics.selectionClick();
    switch (layer) {
      case 'circle':
        // Status / Listening maximised → that full view glides up instead.
        if ((_circleView == 'stories' || _circleView == 'listening') &&
            _circleMaxScroll.hasClients) {
          _circleMaxScroll.animateTo(0,
              duration: Motion.slow,
              curve: Curves.easeOutCubic);
        } else {
          _scrollListToTop(_circleScroll);
        }
      case 'harmony':
        _scrollListToTop(_harmonyScroll);
      case 'glow':
        glowScrollTopRequest.value++;
    }
  }

  /// A message just arrived. Its chat jumps to the top of the Circle list:
  /// if I can see the list but I'm scrolled down (and not busy scrolling or
  /// searching), glide up to it and blink it. Several at once → one glide.
  /// Otherwise (scrolling, searching, in a chat, another layer) it waits on
  /// the "↑ N new" chip. Never for my own messages, an open chat, or a
  /// group I muted.
  void _noteIncomingForList(Map<String, dynamic> data) {
    final me = _myUserId?.toString();
    final sObj = data['sender'] as Map?;
    final sid = (sObj?['id'] ?? data['sender_id'])?.toString();
    if (sid == null || sid == me) return;
    final cid = (data['conversation_id'] ?? '').toString();
    final isGroup = data['receiver_id'] == null && cid.isNotEmpty;
    if (isGroup) {
      final gid = int.tryParse(cid);
      if (gid != null && GroupMeta.instance.isMuted(gid)) return;
      if (_activeGroup?['id']?.toString() == cid) return;
    } else if (_activeFriendId == sid) {
      return;
    }
    final key = isGroup ? 'g$cid' : 's$sid';
    final c = _circleScroll;
    final atTop = c.hasClients && _offsetOf(c) <= 40;
    final busy = DateTime.now().difference(_lastUserScroll) <
        const Duration(seconds: 3);
    if (_circleListVisible && _searchQuery.isEmpty && (atTop || !busy)) {
      _burst.add(key);
      _burstTimer?.cancel();
      // Let the list re-sort (and more messages land) first.
      _burstTimer = Timer(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        final keys = Set<String>.of(_burst);
        _burst.clear();
        if (c.hasClients && _offsetOf(c) > 40) {
          c.animateTo(0,
              duration: const Duration(milliseconds: 520),
              curve: Curves.easeOutCubic);
          Future<void>.delayed(const Duration(milliseconds: 540), () {
            if (mounted) _flashRows(keys);
          });
        } else {
          _flashRows(keys);
        }
      });
      return;
    }
    setState(() {
      _newWhileAway
        ..remove(key)
        ..add(key);
    });
  }

  /// The floating "↑ Top" / "↑ 3 new" chip over a list: shows once you're
  /// well down the list, or when new chats are waiting above you.
  /// A list's scroll offset that never throws. The Circle list is ONE
  /// controller shared by the shared view and the maximised chats list (two
  /// differently-keyed ListViews); for the frame they swap, both are
  /// attached and `.offset` asserts — which painted the grey error veil over
  /// the list. Read the newest position instead.
  double _offsetOf(ScrollController c) =>
      c.positions.isEmpty ? 0.0 : c.positions.last.pixels;

  Widget _listTopChip(ScrollController c, ColorScheme scheme,
      {bool countsNew = false}) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final off = c.hasClients ? _offsetOf(c) : 0.0;
        final n = countsNew ? _newWhileAway.length : 0;
        final show = off > 600 || (n > 0 && off > 40);
        return IgnorePointer(
          ignoring: !show,
          child: AnimatedSlide(
            offset: show ? Offset.zero : const Offset(0, 0.6),
            duration: Motion.standard,
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: Motion.quick,
              child: Material(
                color: n > 0 ? scheme.primary : scheme.surfaceContainerHigh,
                elevation: Depth.low,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => _scrollListToTop(c),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.arrow_upward_rounded,
                          size: 16,
                          color: n > 0
                              ? readableOn(scheme.primary)
                              : accentInk(scheme)),
                      const SizedBox(width: 4),
                      Text(n > 0 ? '$n new' : 'Top',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: n > 0
                                  ? readableOn(scheme.primary)
                                  : accentInk(scheme))),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The later of two server "last seen" times (either may be missing).
  String? _freshestLastSeen(String? a, String? b) {
    if (a == null || a.isEmpty) return (b == null || b.isEmpty) ? null : b;
    if (b == null || b.isEmpty) return a;
    try {
      return parseServerTime(a).isAfter(parseServerTime(b)) ? a : b;
    } catch (_) {
      return a;
    }
  }

  // A real method so the static hook can be compared on dispose.
  // A friend I already have in my list opens with everything the list
  // knows (online, last seen…), exactly like tapping their row.
  void _openDmHook(Map<String, dynamic> friend,
      {Map<String, dynamic>? replyTo}) {
    final id = friend['id']?.toString();
    final known = _allFriends.firstWhere((e) => e['id']?.toString() == id,
        orElse: () => <String, dynamic>{});
    openChat(known.isNotEmpty ? Map<String, dynamic>.from(known) : friend,
        replyTo: replyTo);
  }

  void openChat(Map<String, dynamic> friend,
      {String? jumpToMessageId, Map<String, dynamic>? replyTo}) {
    var leftFull = false;
    final flyId = int.tryParse(friend['id'].toString());
    if (flyId != null && _activeFriendId != friend['id'].toString()) {
      _flyAvatarFor(
          flyId,
          _contactDisplayName(friend['phone'] as String?,
              (friend['username'] ?? '').toString()),
          friend['avatar_url'] as String?);
    }
    if (_searchQuery.isNotEmpty) _searchBeforeChat = _searchQuery;
    _openedKey = 's${friend['id']}';
    _newWhileAway.remove(_openedKey);
    setState(() {
      _pendingJumpMessageId = jumpToMessageId;
      _pendingReplyTo = replyTo;
      _clearSearchState();
      // From a group (Message / Reply privately): the DM takes the panel.
      _activeGroup = null;
      _activeFriendId = friend['id'].toString();
      _activeFriendName = friend['username'] ?? 'Friend';
      _activeFriendOnline = friend['is_online'] ?? false;
      // Their real last-seen — never the last MESSAGE's time (that showed a
      // wrong "Last seen" that snapped to the right one a second later).
      // The list's value decides whether we may show one at all (null =
      // unknown or kept private), so a cached time never resurrects a last
      // seen they've since hidden.
      final listSeen = friend['last_seen'] as String?;
      _activeFriendLastSeen = (listSeen == null || listSeen.isEmpty)
          ? null
          : _freshestLastSeen(
              _lastSeenCache[friend['id'].toString()], listSeen);
      _activeFriendLastTrack = null;
      _activeFriendTz = null;
      _activeFriendPhone = friend['phone'] as String?;
      _activeFriendAvatar = friend['avatar_url'] as String?;
      _avatarExpanded = false;
      // The chat must be the front surface: fold the phone's music panel and
      // leave a full-screen music layout on desktop (e.g. "Send to Belyner"
      // tapped from the player).
      _playerExpanded = false;
      if (_isMusicFullScreen) {
        _isMusicFullScreen = false;
        _musicPanelWidth = _prevMusicWidth;
        leftFull = true;
      }
    });
    if (leftFull) _saveLayoutState();
    // Optimistically clear the badge (was: friend['unread_count'] = 0).
    ref.read(unreadProvider.notifier).clear(friend['id'] as int);
    ApiService().markMessagesAsReadPatch(friend['id'] as int);
    // Fetch their profile card's details now, so tapping the chat header
    // opens it complete (streak + hearts + status) with nothing popping in.
    final fid = friend['id'] as int;
    warmUserProfile(
        userId: fid,
        spaceId: (_bondWith(fid)?['id'] as num?)?.toInt(),
        showHearts: true);
  }

  /// Open a GROUP conversation inside the chat panel (leaving the music panel
  /// visible on desktop). Called from the Groups popup / after creating a group.
  void openGroupInPanel(Map<String, dynamic> conv, {String? jumpToMessageId}) {
    // Opening the group clears its "@" chip; with no explicit target, land on
    // the message that mentioned me.
    final gid = int.tryParse(conv['id']?.toString() ?? '');
    final mentionMid = gid == null ? null : _groupMentions.remove(gid);
    jumpToMessageId ??=
        (mentionMid != null && mentionMid.isNotEmpty) ? mentionMid : null;
    if (_searchQuery.isNotEmpty) _searchBeforeChat = _searchQuery;
    _openedKey = 'g${conv['id']}';
    _newWhileAway.remove(_openedKey);
    setState(() {
      _pendingJumpMessageId = jumpToMessageId;
      _clearSearchState();
      _activeGroup = conv;
      // Groups and DMs are mutually exclusive in the panel.
      _activeFriendId = null;
      _activeFriendName = null;
      _activeFriendOnline = null;
      _activeFriendLastSeen = null;
      _activeFriendLastTrack = null;
      _activeFriendTz = null;
      _avatarExpanded = false;
      _playerExpanded = false; // make sure the chat panel is the front surface
    });
    // Ask the server whether a call is already live in this group, so the
    // "call in progress · Join" banner shows even if we missed the ring.
    _refreshGroupCallState(conv);
    // Same for a jam room: re-check what's really live (prunes a room whose
    // "ended" notice was missed, so no dead Join bar).
    LiveRoomsRegistry.instance.loadSnapshot();
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
        ? onlineDotFor(_activeNetGrade()).$2
        : (_activeFriendLastSeen?.isNotEmpty == true
            ? 'Last seen ${formatLastSeen(_activeFriendLastSeen!)}'
            // Unknown or kept private → nothing (never "Offline").
            : '');
    final fid = int.tryParse(_activeFriendId ?? '');
    final space = fid == null ? null : _bondWith(fid);
    final name = _contactDisplayName(_activeFriendPhone, _activeFriendName ?? '');
    showUserProfile(
      context,
      username: _activeFriendName ?? '',
      userId: fid,
      phone: _activeFriendPhone,
      avatarUrl: _avatarFull(_activeFriendAvatar),
      isOnline: _activeFriendOnline == true,
      statusLine: status,
      netGrade:
          _activeFriendOnline == true ? _activeNetGrade() : null,
      // The bond: In-tune streak + Our Space, hearts between you, and
      // "Tune in" when they're playing something right now.
      spaceId: (space?['id'] as num?)?.toInt(),
      spaceName: space?['name']?.toString(),
      onOpenSpace: space == null ? null : () => _openSpace(space),
      onTuneIn: fid == null ? null : () => _tuneInto(fid, name),
      showHearts: true,
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
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
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
                        color: accentInk(scheme), size: 26),
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
                                borderRadius: BorderRadius.circular(Radii.lg)),
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
                                borderRadius: BorderRadius.circular(Radii.lg)),
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
    LiveInbox.instance.clearAll(); // no messages carried into another account
    BlockList.instance.clear(); // …nor whom this account blocked
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

  /// Chat search: a full page on phones; on a wide screen a panel sliding
  /// in from the right over the chats, so the music and lists stay in view.
  void _openMessageSearch(Widget screen) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (!wide) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close search',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: Motion.standard,
      pageBuilder: (ctx, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
          child: Material(
            color: scheme.surface,
            elevation: Depth.high,
            borderRadius: BorderRadius.circular(Radii.xl),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 560, child: screen),
          ),
        ),
      ),
      transitionBuilder: (ctx, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0.08, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: FadeTransition(opacity: a, child: child),
      ),
    );
  }

  /// The chat panel full screen ↔ back to the split (the ⤢ button and
  /// Ctrl+Shift+F). Remembered across launches.
  void _toggleChatFullScreen() {
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
  }

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
        Icon(Icons.music_note_rounded, color: accentInk(scheme), size: 20),
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
      duration: Motion.standard,
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
                    borderRadius: BorderRadius.circular(Radii.xl),
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

  /// First names (as I know them) of group members playing music right now.
  /// Several of a group on the SAME song right now (me included) → the most
  /// shared one and how many: "3 of you are on “Song”". Null under 2.
  ({String title, int count})? _groupSharedSong(List members) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final counts = <String, int>{};
    final shown = <String, String>{};
    void add(String? t) {
      final title = (t ?? '').trim();
      final k = norm(title);
      if (k.isEmpty) return;
      counts[k] = (counts[k] ?? 0) + 1;
      shown.putIfAbsent(k, () => title);
    }

    for (final m in members.whereType<Map>()) {
      final id = int.tryParse((m['user_id'] ?? m['id'] ?? '').toString());
      if (id == null || id == _myUserId) continue;
      add(NowPlayingPresence.instance.trackFor(id)?['title']?.toString());
    }
    add(NowPlayingPresence.instance.myTrack?.title);
    if (counts.isEmpty) return null;
    final best =
        counts.entries.reduce((a, b) => b.value > a.value ? b : a);
    if (best.value < 2) return null;
    return (title: shown[best.key]!, count: best.value);
  }

  List<String> _groupListeners(List members) {
    final out = <String>[];
    for (final m in members.whereType<Map>()) {
      // Group members carry `user_id` (fall back to `id`).
      final id = int.tryParse((m['user_id'] ?? m['id'] ?? '').toString());
      if (id == null || id == _myUserId) continue;
      if (NowPlayingPresence.instance.trackFor(id) == null) continue;
      final f = _allFriends.firstWhere(
          (x) => (x['id'] as num?)?.toInt() == id,
          orElse: () => <String, dynamic>{});
      final name = _contactDisplayName(
          (f['phone'] ?? m['phone'])?.toString(),
          (m['username'] ?? f['username'] ?? '').toString());
      final first = name.trim().split(RegExp(r'\s+')).first;
      if (first.isNotEmpty) out.add(first);
    }
    return out;
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
              borderRadius: BorderRadius.circular(Radii.md),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    // Same slot as a friend's header photo, and the same
                    // live rings as the group's tile: a call beats, a group
                    // Listen Together weaves.
                    _headerPhotoSlot(ListenableBuilder(
                      listenable: Listenable.merge([
                        GroupCallService.instance.ongoingCalls,
                        LiveRoomsRegistry.instance,
                      ]),
                      builder: (context, _) {
                        final gid = (g['id'] as num?)?.toInt() ?? -1;
                        final gcs = GroupCallService.instance;
                        final inCall =
                            gcs.ongoingCalls.value.containsKey(gid) ||
                                (gcs.room == gid &&
                                    gcs.phase != GroupCallPhase.idle);
                        final jam = activeLiveSession
                                    ?.controller.conversationId ==
                                gid ||
                            LiveRoomsRegistry.instance
                                    .roomForConversation(gid) !=
                                null;
                        return PresenceRingAvatar(
                          key: ValueKey('hdr-gring-$gid'),
                          face: 34,
                          mode: inCall
                              ? RingMode.call
                              : (jam ? RingMode.together : RingMode.none),
                          color: scheme.primary,
                          color2: const Color(0xFFF2A541),
                          gapColor: scheme.surface,
                          child: CircleAvatar(
                            radius: 17,
                            backgroundColor: scheme.primaryContainer,
                            backgroundImage: groupAvatar != null
                                ? authNetworkImageProvider(
                                    groupAvatar, mediaAuthHeaders(groupAvatar))
                                : null,
                            child: groupAvatar == null
                                ? Icon(Icons.groups_rounded,
                                    color: scheme.onPrimaryContainer,
                                    size: 20)
                                : null,
                          ),
                        );
                      },
                    )),
                    SizedBox(
                        width: MediaQuery.sizeOf(context).width < 360 ? 6 : 10),
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
                          // The group's line, same rules as a friend's
                          // header (strongest first): someone typing /
                          // recording › a call live (join) › a jam live
                          // (join) › members listening (start a jam) ›
                          // member count. Same marquee + fade.
                          ListenableBuilder(
                            listenable: Listenable.merge([
                              NowPlayingPresence.instance,
                              GroupCallService.instance.ongoingCalls,
                              LiveRoomsRegistry.instance,
                            ]),
                            builder: (context, _) {
                              final gid = (g['id'] as num?)?.toInt() ?? -1;
                              final gcs = GroupCallService.instance;
                              final inMyCall = gcs.room == gid &&
                                  gcs.phase != GroupCallPhase.idle;
                              final inCall = inMyCall ||
                                  gcs.ongoingCalls.value.containsKey(gid);
                              final myJam = activeLiveSession
                                      ?.controller.conversationId ==
                                  gid;
                              final room = LiveRoomsRegistry.instance
                                  .roomForConversation(gid);
                              final typer = _groupTypingTimers
                                      .containsKey(gid)
                                  ? (_groupTypingNames[gid] ?? '')
                                  : null;
                              final who = _groupListeners(members);
                              String text;
                              (int, int)? bold;
                              Color color = accentInk(scheme);
                              VoidCallback? onTap;
                              if (typer != null) {
                                final n = typer.isEmpty ? 'Someone' : typer;
                                text = _groupTypingKind[gid] == 'recording'
                                    ? '🎤 $n is recording a voice note…'
                                    : '$n is typing…';
                              } else if (inCall) {
                                text = inMyCall
                                    ? '📞 You’re in the call · tap to return'
                                    : '📞 Call in progress · tap to join';
                                onTap = () => _joinGroupCall(g);
                              } else if (myJam || room != null) {
                                final song = (myJam
                                        ? activeLiveSession!.title
                                        : ((room?['track'] as Map?)?['title'] ??
                                                '')
                                            .toString())
                                    .trim();
                                final lead = myJam
                                    ? '🎧 In the jam'
                                    : '🎧 Jam live';
                                final tail = myJam
                                    ? ' · tap to return'
                                    : ' · tap to join';
                                text = song.isEmpty
                                    ? '$lead$tail'
                                    : '$lead · “$song”$tail';
                                if (song.isNotEmpty) {
                                  bold = (lead.length + 4,
                                      lead.length + 4 + song.length);
                                }
                                onTap = myJam
                                    ? _reopenLiveSession
                                    : () => LiveRoomsRegistry.instance
                                        .joinRoom
                                        ?.call(room!);
                              } else if (_groupSharedSong(members)
                                  case final shared?) {
                                // Several of us on the same song → a jam
                                // is one tap away.
                                const lead = '🎶 ';
                                final mid =
                                    '${shared.count} of you are on “';
                                text =
                                    '$lead$mid${shared.title}” · Start a jam';
                                bold = (lead.length + mid.length,
                                    lead.length + mid.length +
                                        shared.title.length);
                                onTap = () {
                                  Haptics.selectionClick();
                                  chatJamRequest.value++;
                                };
                              } else if (who.isNotEmpty) {
                                final names = who.length == 1
                                    ? '${who[0]} is'
                                    : who.length == 2
                                        ? '${who[0]} and ${who[1]} are'
                                        : '${who[0]}, ${who[1]} +${who.length - 2} are';
                                text = '🎧 $names listening now · Start a jam';
                                onTap = () {
                                  Haptics.selectionClick();
                                  chatJamRequest.value++;
                                };
                              } else {
                                text = '${members.length} members · tap for info';
                                color = textColor.withAlpha(130);
                              }
                              final line = SizedBox(
                                height: 15,
                                child: AnimatedSwitcher(
                                  duration:
                                      Motion.standard,
                                  layoutBuilder: (cur, prev) => Stack(
                                    alignment: Alignment.centerLeft,
                                    children: [...prev, ?cur],
                                  ),
                                  child: _ScrollingText(
                                    key: ValueKey(text),
                                    text: text,
                                    bold: bold,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: onTap == null
                                          ? FontWeight.normal
                                          : FontWeight.w600,
                                      color: color,
                                    ),
                                  ),
                                ),
                              );
                              if (onTap == null) return line;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: onTap,
                                child: line,
                              );
                            },
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
          GeniePopupMenuButton<String>(
            icon: const Icon(Icons.menu_rounded),
            tooltip: 'Group options',
            onSelected: (v) {
              switch (v) {
                case 'search':
                  chatSearchRequest.value++;
                  break;
                case 'media':
                  chatMediaRequest.value++;
                  break;
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
                value: 'search',
                child: _groupMenuRow(
                    Icons.search_rounded, 'Search in chat', scheme),
              ),
              PopupMenuItem(
                value: 'media',
                child: _groupMenuRow(Icons.library_music_rounded,
                    'Songs, media & docs', scheme),
              ),
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
      // Tight phones (< 360 px): slimmer gaps so the name + status line keep
      // room next to the action pill; the photo slot never shrinks.
      final tight = MediaQuery.sizeOf(context).width < 360;
      final gap = tight ? 6.0 : 10.0;
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
              _activeFriendLastTrack = null;
              _activeFriendTz = null;
              _avatarExpanded = false;
            }),
          ),
          SizedBox(width: gap),
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
            // Double-tap a bonded partner → heartbeat ("thinking of you").
            // Only for a bonded partner — a double-tap handler delays every
            // single tap (~300ms), so others keep instant taps.
            onDoubleTap:
                _bondWith(int.tryParse(_activeFriendId ?? '') ?? -1) == null
                    ? null
                    : () => _sendHeartbeatTap(
                        int.tryParse(_activeFriendId ?? '') ?? -1,
                        _contactDisplayName(
                            _activeFriendPhone, _activeFriendName ?? '')),
            // Same status ring as the friend list (colourful=unseen, grey=seen).
            // Glows in the theme colour while a heartbeat passes between you.
            // The 42 px ring slot lays out as 36 px tall (its rim overhangs
            // 3 px into the header's padding), so the header row is exactly
            // as tall as it was with a bare photo — no jump, no extra height.
            child: _headerPhotoSlot(AnimatedContainer(
              duration: Motion.emphasized,
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  if (_glowFriendId != null &&
                      _glowFriendId.toString() == _activeFriendId)
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.65),
                      blurRadius: Depth.md,
                      spreadRadius: 3,
                    ),
                ],
              ),
              // ONE fixed geometry, like the friend list: a 34 px photo in a
              // 42 px slot whose 4 px rim says what's happening — together
              // with me › the song's progress (their colour; ❤️ same song as
              // mine) › unseen/seen story › bonded glow › empty. The photo
              // never grows or shrinks as music starts and stops.
              child: ListenableBuilder(
                listenable: NowPlayingPresence.instance,
                builder: (context, _) {
                  final fid = int.tryParse(_activeFriendId ?? '') ?? -1;
                  final presence = NowPlayingPresence.instance;
                  final ls = activeLiveSession?.controller;
                  final together = ls != null &&
                      ls.isPrivatePair &&
                      ls.partnerIds.contains(fid);
                  final playing = !together && presence.trackFor(fid) != null;
                  final paused = !together &&
                      !playing &&
                      presence.pausedTrackFor(fid) != null;
                  final music = together || playing || paused;
                  const face = 34.0;
                  final dot = onlineDotFor(_activeNetGrade());
                  final photo = InitialsAvatar(
                    name: _contactDisplayName(
                        _activeFriendPhone, _activeFriendName ?? ''),
                    radius: face / 2,
                    isOnline: _activeFriendOnline == true && !music,
                    onlineDot: dot.$1,
                    onlineTip: dot.$2,
                    imageUrl: _avatarFull(_activeFriendAvatar),
                  );
                  final story = _friendStory(_activeFriendId);
                  if (!music && story != null) {
                    // Story ring drawn IN the same rim (not around it).
                    return SizedBox(
                      width: face + 8,
                      height: face + 8,
                      child: Stack(alignment: Alignment.center, children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _storyRim(fid, story, scheme),
                          ),
                        ),
                        Container(
                          width: face + 2,
                          height: face + 2,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle, color: scheme.surface),
                        ),
                        photo,
                      ]),
                    );
                  }
                  final c = presence.colorFor(fid);
                  return PresenceRingAvatar(
                    key: ValueKey('hdr-ring-$fid'),
                    face: face,
                    mode: together
                        ? RingMode.together
                        : (playing && _onSameSong(fid))
                            ? RingMode.sameSong
                            : music
                                ? RingMode.listening
                                : RingMode.none,
                    color: together
                        ? scheme.primary
                        : (c != null ? Color(c) : scheme.primary),
                    color2: const Color(0xFFF2A541),
                    // Quiet bonded partner: the thin breathing theme ring.
                    glow: !music && _isHarmonyPartner(fid),
                    paused: paused,
                    showProgress: true,
                    progress: (playing || paused)
                        ? () => presence.progressFor(fid)
                        : null,
                    gapColor: scheme.surface,
                    child: photo,
                  );
                },
              ),
            )),
          ),
          SizedBox(width: gap),
          Expanded(
            // Tap the friend's name to open their profile details (phone, etc.).
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openActiveFriendProfile,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(
                        _contactDisplayName(
                            _activeFriendPhone, _activeFriendName ?? ''),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Our Space's "your song": ♪ — tap to play it. Tight
                    // phones keep the room for the name (it's in Our Space).
                    Builder(builder: (_) {
                      final ys = _yourSongWith(
                          int.tryParse(_activeFriendId ?? '') ?? -1);
                      // Web plays from its own queue (no file paths), so
                      // "play your song" can't find it there.
                      if (ys == null || tight || kIsWeb) {
                        return const SizedBox.shrink();
                      }
                      return Tooltip(
                        message: 'Your song · $ys',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _playYourSong(ys),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text('♪',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: accentInk(scheme))),
                          ),
                        ),
                      );
                    }),
                    // "In tune" streak with a bonded partner: 🔥 N.
                    Builder(builder: (_) {
                      final n =
                          _streakFor(int.tryParse(_activeFriendId ?? '') ?? -1);
                      if (n == null || n < 2) return const SizedBox.shrink();
                      return Tooltip(
                        message: '$n days in tune',
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text('🔥$n',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: accentInk(scheme))),
                        ),
                      );
                    }),
                  ]),
                  // One line, always: when it doesn't fit (tight screens) it
                  // glides as a marquee so it can still be read in full.
                  // When they're playing music right now, that's the status:
                  // "🎧 Listening to …" in the theme colour — tap to tune in.
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      NowPlayingPresence.instance,
                      QuickStatus.instance,
                      HeartbeatLog.instance,
                      BondLive.instance,
                      _minuteTick,
                    ]),
                    builder: (context, _) {
                      final fid = int.tryParse(_activeFriendId ?? '') ?? -1;
                      // In a Listen Together session with them right now —
                      // same rule as their photo's ring.
                      final ls = activeLiveSession?.controller;
                      final together = ls != null &&
                          ls.isPrivatePair &&
                          ls.partnerIds.contains(fid);
                      final np = together
                          ? null
                          : NowPlayingPresence.instance.trackFor(fid);
                      final t = (np?['title'] ?? '').toString().trim();
                      final a = (np?['artist'] ?? '').toString().trim();
                      final listening = np != null && t.isNotEmpty;
                      final who = _contactDisplayName(
                          _activeFriendPhone, _activeFriendName ?? '');
                      // Typing or recording a voice note to me leads.
                      final typingKind = _typingTimers.containsKey(fid)
                          ? (_typingKind[fid] ?? 'typing')
                          : null;
                      // Their quick status leads ("📞 Free to talk · Online").
                      final qs = QuickStatus.instance.lineFor(fid);
                      final offline = _activeFriendOnline != true;
                      // No last seen (not known yet, or they keep it
                      // private): say nothing — never "Offline", which would
                      // tell you it's hidden.
                      final seen = _activeFriendLastSeen?.isNotEmpty == true
                          ? 'Last seen ${formatLastSeen(_activeFriendLastSeen!)}'
                          : '';
                      // What they last played, when they let me see it.
                      final lt = (_activeFriendLastTrack?['title'] ?? '')
                          .toString()
                          .trim();
                      // Bonded partner: heartbeat, milestone, dedication.
                      final space = _bondWith(fid);
                      final hb = space == null
                          ? null
                          : HeartbeatLog.instance.recent(fid);
                      final milestone = _milestoneWhisper(space);
                      final dedWaiting =
                          ((space?['dedication_unopened'] as num?)?.toInt() ??
                                  0) >
                              0;
                      // Their local time, when it's not mine.
                      final there = _theirLocalTime();
                      final base = !offline
                          ? 'Online'
                          : [
                              if (seen.isNotEmpty) seen,
                              if (seen.isNotEmpty && lt.isNotEmpty)
                                'was listening to “$lt”',
                              // Only alongside a visible last seen, so a
                              // private one stays private.
                              if (hb != null && seen.isNotEmpty)
                                '💓 thought of you '
                                    '${formatLastSeen(hb.toUtc().toIso8601String())}',
                            ].join(' · ');
                      // Music states.
                      final same = listening && _onSameSong(fid);
                      final remain = listening
                          ? NowPlayingPresence.instance.remainingMsFor(fid)
                          : null;
                      final ending =
                          remain != null && remain > 0 && remain <= 20000;
                      final songC = NowPlayingPresence.instance.colorFor(fid);
                      final songInk = songC == null
                          ? accentInk(scheme)
                          : _readableInk(Color(songC), scheme);
                      const lead = '🎧 Listening to ';
                      const bothLead = '🎶 You’re both listening to “';
                      final String text;
                      (int, int)? bold;
                      final Color color;
                      if (typingKind != null) {
                        text = typingKind == 'recording'
                            ? '🎤 recording a voice note…'
                            : 'typing…';
                        color = accentInk(scheme);
                      } else if (together) {
                        final lt2 = (activeLiveSession?.title ?? '').trim();
                        const tLead = '🎧 Listening together';
                        text = lt2.isEmpty ? tLead : '$tLead · “$lt2”';
                        if (lt2.isNotEmpty) {
                          bold = (tLead.length + 4, tLead.length + 4 + lt2.length);
                        }
                        color = accentInk(scheme);
                      } else if (BondLive.instance.togetherWith(fid)) {
                        // Both of us in our chat right now.
                        text = '💞 Here together';
                        color = accentInk(scheme);
                      } else if (same) {
                        text = '$bothLead$t” ❤️';
                        bold = (bothLead.length, bothLead.length + t.length);
                        color = songInk;
                      } else if (ending) {
                        // Only the last ~20 s speak up: the moment to act.
                        text = '🎧 “$t” is ending — tune in for the next one';
                        color = songInk;
                      } else if (listening) {
                        text = '$lead$t${a.isEmpty ? '' : ' — $a'}';
                        bold = (lead.length, lead.length + t.length);
                        color = songInk;
                      } else {
                        text = [
                          // The day we planned to meet, counting down.
                          ?BondLive.countdownLine(
                              BondLive.instance.dateWith(fid)),
                          if (qs.isNotEmpty) qs,
                          if (base.isNotEmpty) base,
                          if (dedWaiting) '💝 left you a song',
                          ?milestone,
                          ?there,
                        ].join(' · ');
                        color = _activeFriendOnline == true
                            ? Colors.green
                            : textColor.withAlpha(130);
                      }
                      final line = SizedBox(
                        height: 15,
                        // Changes (online → last seen, typing, listening,
                        // a minute older) fade instead of snapping.
                        child: AnimatedSwitcher(
                          duration: Motion.standard,
                          layoutBuilder: (cur, prev) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...prev, ?cur],
                          ),
                          child: _ScrollingText(
                            key: ValueKey(text),
                            text: text,
                            // The song title stands out.
                            bold: bold,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.normal,
                              color: color,
                            ),
                          ),
                        ),
                      );
                      if (typingKind == null && together) {
                        // Tap → back into the session.
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _reopenLiveSession,
                          child: line,
                        );
                      }
                      if (typingKind == null && listening) {
                        // Tap: tune in (same song → sync up together).
                        // Long-press: where they are in the song.
                        final f = _allFriends.firstWhere(
                            (x) => (x['id'] as num?)?.toInt() == fid,
                            orElse: () => <String, dynamic>{});
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _tuneInto(fid, who),
                          onLongPress: f.isEmpty
                              ? null
                              : () =>
                                  _showPhotoPeek(f, who, !offline, held: true),
                          child: line,
                        );
                      }
                      // Away: tap the line for "tell me when they're
                      // online / play music" right where you're wondering.
                      if (typingKind == null &&
                          offline &&
                          fid > 0 &&
                          _isMutual(fid)) {
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showAwayWatchSheet(fid, who),
                          child: line,
                        );
                      }
                      return line;
                    },
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
          // Three layers: on tight phones only the lit pill keeps its label
          // (the others go icon-only) so the row never overflows.
          ...() {
            final tight = constraints.maxWidth < 400;
            return [
              _layerTab(scheme, 'harmony', 'Harmony', Icons.favorite_rounded,
                  _harmonyBadge(), compact: tight),
              SizedBox(width: tight ? 6 : 10),
              _layerTab(scheme, 'circle', 'Circle', Icons.forum_rounded,
                  _circleBadge(), compact: tight),
              SizedBox(width: tight ? 6 : 10),
              _layerTab(scheme, 'glow', 'Glow', Icons.auto_awesome_rounded, 0,
                  compact: tight),
            ];
          }(),
          const Spacer(),
        ] else ...[
          _PanelToggleBtn(
            isFullScreen: _isChatFullScreen,
            tooltip: '${_isChatFullScreen ? 'Exit full screen' : 'Full screen'}'
                '  (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘⇧F' : 'Ctrl+Shift+F'})',
            onTap: _toggleChatFullScreen,
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
                color: accentInk(scheme),
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Desktop: Glow takes over the panel; tap again to return.
          Builder(
            builder: (bctx) => _layerTab(
                scheme, 'glow', 'Glow', Icons.auto_awesome_rounded, 0,
                onTap: () => _toggleGlowFrom(bctx)),
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
                  borderRadius: BorderRadius.circular(Radii.lg),
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
                duration: Motion.standard,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(Radii.lg),
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
              duration: Motion.standard,
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
              // Whole-pixel origin + own layer: no 1px twitch on desktop /
              // web at fractional scaling, and repaints stay inside.
              child: PixelSnap(
                key: ValueKey('rb_${_activeGroup?['id']}_$_activeFriendId'),
                child: RepaintBoundary(
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
                  ? _withCircleBanner(ChatPage(
                      key: ValueKey(_activeFriendId),
                      friendId: int.parse(_activeFriendId!),
                      friendName: _contactDisplayName(
                          _activeFriendPhone, _activeFriendName!),
                      friendAvatar: _activeFriendAvatar ?? '',
                      textColor: textColor,
                      showAppBar: false,
                      onFriendTz: (tz) {
                        if (mounted && tz != _activeFriendTz) {
                          setState(() => _activeFriendTz = tz);
                        }
                      },
                      onFriendLastTrack: (t) {
                        if (!mounted) return;
                        final was = _activeFriendLastTrack;
                        if ((was?['title'] ?? '') == (t?['title'] ?? '') &&
                            (was?['artist'] ?? '') == (t?['artist'] ?? '')) {
                          return;
                        }
                        setState(() => _activeFriendLastTrack = t);
                      },
                      onFriendOnlineStatusChanged: (online, lastSeen) {
                        if (mounted) {
                          final key = _activeFriendId;
                          if (key != null) {
                            if (lastSeen != null && lastSeen.isNotEmpty) {
                              _lastSeenCache[key] = lastSeen;
                            } else {
                              _lastSeenCache.remove(key); // hidden now
                            }
                          }
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
                      initialReplyTo: _pendingReplyTo,
                    ))
                  : _buildFriendList(context),
                ),
                ),
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
          duration: Motion.quick,
          width: 14,
          color: _isDragging
              ? scheme.primary.withAlpha(30)
              : Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.quick,
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
    // Also re-read the phone book: anyone in it who has joined Aluta since is
    // added to the circle (quietly — no prompt, no toast unless someone new).
    final fromContacts = _findFriendsFromContacts(quiet: true);
    // Statuses too — the same pull refreshes every Circle section.
    final stories = _fetchStories();
    await _fetchFriends();
    _loadSpaces();
    _loadPlan();
    await fromContacts;
    await stories;
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
    for (final s in spaces) {
      ContactNames.instance.rememberAll(s['members'] as List?);
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
      _outgoingBondRequests = ((data['outgoing'] as List?) ?? const [])
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
      color: accentInk(scheme),
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
          borderRadius: BorderRadius.circular(Radii.xl),
          border: Border.all(color: scheme.primary.withAlpha(90)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note_rounded, size: 15, color: accentInk(scheme)),
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

  Widget _barIcon(IconData icon, Color color, String tip, VoidCallback onTap,
      {double size = 20}) {
    return Tooltip(
      message: tip,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: color),
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
              const BorderRadius.vertical(top: Radius.circular(Radii.xl)),
          border: Border(
            top: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(28),
              blurRadius: Depth.md,
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
            // Same parts as the playlist's mini player, packed into ONE slim
            // row so the bar stays as short as before (the chat reserves a
            // fixed strip for it — a taller bar covered the composer):
            // spinning record · title over a slim waveform · share · prev ·
            // play key · next · close. Swipe sideways to skip.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 4, 6),
              child: LayoutBuilder(builder: (ctx, cons) {
                final a = scheme.primary;
                final artist = np.artist.trim();
                final title = np.track.isEmpty ? 'No track' : np.track;
                final line = (artist.isNotEmpty && artist != '<unknown>')
                    ? '$title  ·  $artist'
                    : title;
                final timeStyle = TextStyle(
                  fontSize: 9.5,
                  height: 1.0,
                  color: scheme.onSurface.withAlpha(150),
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                );
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -250) playbackBus.onNext?.call();
                    if (v > 250) playbackBus.onPrev?.call();
                  },
                  child: Row(
                    children: [
                      // A little record that turns while music plays.
                      SpinArt(
                        spinning: np.playing,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(colors: [
                              Color.lerp(a, Colors.white, 0.25)!,
                              a,
                              Color.lerp(a, Colors.black, 0.45)!,
                            ], stops: const [0.0, 0.45, 1.0]),
                            border:
                                Border.all(color: Colors.white.withAlpha(60)),
                          ),
                          child: Icon(Icons.music_note_rounded,
                              size: 16,
                              color: a.computeLuminance() > 0.5
                                  ? const Color(0xFF111111)
                                  : Colors.white),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 16,
                              child: _ScrollingText(
                                text: line,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 3),
                            ValueListenableBuilder<PlayClock>(
                              valueListenable: playClockNotifier,
                              builder: (_, clock, _) {
                                final total = clock.duration.inMilliseconds;
                                final frac = total > 0
                                    ? (clock.position.inMilliseconds / total)
                                        .clamp(0.0, 1.0)
                                        .toDouble()
                                    : 0.0;
                                return Row(children: [
                                  Text(_fmtClock(clock.position),
                                      style: timeStyle),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5),
                                      child: WaveformSeekBar(
                                        height: 18,
                                        fraction: frac,
                                        accent: a,
                                        inactive: a.withAlpha(48),
                                        enabled: total > 0,
                                        seed: np.track.hashCode,
                                        onSeek: (f) => playbackBus
                                            .onSeekFraction
                                            ?.call(f),
                                        labelFor: (f) => _fmtClock(Duration(
                                            milliseconds:
                                                (f * total).round())),
                                      ),
                                    ),
                                  ),
                                  Text(_fmtClock(clock.duration),
                                      style: timeStyle),
                                ]);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 2),
                      _barIcon(Icons.share_rounded, a, 'Share to chat',
                          () => playbackBus.onShareToChat?.call(),
                          size: 19),
                      _barIcon(Icons.skip_previous_rounded, scheme.onSurface,
                          'Previous', () => playbackBus.onPrev?.call(),
                          size: 22),
                      PlayKey(
                        playing: np.playing,
                        buffering: false,
                        accent: a,
                        onTap: () => playbackBus.onToggle?.call(),
                        diameter: 34,
                      ),
                      _barIcon(Icons.skip_next_rounded, scheme.onSurface,
                          'Next', () => playbackBus.onNext?.call(),
                          size: 22),
                      // Close → genies down into the footer pill.
                      _barIcon(
                          Icons.close_rounded,
                          scheme.onSurface.withAlpha(140),
                          'Hide player',
                          () => setState(() => _barDismissed = true),
                          size: 17),
                    ],
                  ),
                );
              }),
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

    // Back from a chat (any route: header back, system back, a closed
    // panel) → the list returns as I left it: same scroll position (the
    // lists' PageStorageKeys) and the same search, if I'd searched.
    final inChat = _activeFriendId != null || _activeGroup != null;
    if (_wasInChat && !inChat) {
      final q = _searchBeforeChat;
      _searchBeforeChat = '';
      final came = _openedKey;
      _openedKey = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _activeFriendId != null || _activeGroup != null) {
          return;
        }
        if (q.isNotEmpty) {
          _searchCtrl.text = q;
          _filterFriends(q);
        }
        // The row I came back from blinks softly, so my eye lands on it —
        // and, at the top of the list, so do chats that got news meanwhile.
        final c = _circleScroll;
        if (_newWhileAway.isNotEmpty &&
            _circleListVisible &&
            (!c.hasClients || _offsetOf(c) <= 40)) {
          final fresh = Set<String>.of(_newWhileAway);
          setState(_newWhileAway.clear);
          _flashRows({?came, ...fresh});
        } else if (came != null) {
          _flashRows({came});
        }
      });
    }
    _wasInChat = inChat;

    // Back / swipe-back should step DOWN the view stack (close an open chat →
    // collapse a full-screen panel → then exit), not jump off the app.
    // A maximised Circle section (Status / Listening / chats) on the list
    // screen: back minimises it first.
    // (Desktop / tablet shows the Circle column beside Harmony, so there it's
    // on screen unless Glow has the panel.)
    final circleShown = _friendLayer == 'circle' ||
        (MediaQuery.sizeOf(context).width >= 600 && _friendLayer != 'glow');
    final circleMax = _circleView != 'all' &&
        circleShown &&
        _activeGroup == null &&
        _activeFriendId == null &&
        !_playerExpanded &&
        !_isMusicFullScreen;
    // On Harmony or Glow (with nothing open), Back first returns to Circle —
    // the chat screen's home layer — before leaving the app.
    // (Wide screens show Harmony and Circle together — only Glow is "away".)
    final layerAway = _friendLayer != 'circle' &&
        (_friendLayer == 'glow' || MediaQuery.sizeOf(context).width < 600) &&
        _activeGroup == null &&
        _activeFriendId == null &&
        !_playerExpanded &&
        !_isMusicFullScreen &&
        !circleMax;
    // An open Circle search (nothing else open): Back closes it first.
    final circleSearch = (_circleSearching || _searchQuery.isNotEmpty) &&
        _activeGroup == null &&
        _activeFriendId == null &&
        !_playerExpanded &&
        !_isMusicFullScreen;
    final canLeave = !(_isMusicFullScreen ||
        circleSearch ||
        _isChatFullScreen ||
        _playerExpanded ||
        circleMax ||
        layerAway ||
        _activeGroup != null ||
        _activeFriendId != null);

    // Listener sits above the whole app and is passive (it never consumes
    // events), so every touch also nudges the session back online if needed.
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (circleSearch) {
          _closeCircleSearch();
          return;
        }
        if (circleMax) {
          _setCircleView(_circleView); // same key again → back to all
          return;
        }
        if (layerAway) {
          _setFriendLayer('circle');
          return;
        }
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
            _activeFriendLastTrack = null;
            _activeFriendTz = null;
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
            onPressed: () => _openMessageSearch(MessageSearchScreen(
                      // Names match → the chat itself, in the chat panel.
                      people: _allFriends,
                      groups: _groups,
                      onOpenChat: (f) => openChat(f),
                      onOpenGroup: (g) => openGroupInPanel(g),
                      avatarOf: _avatarFull,
                      myUserId: _myUserId,
                      // Open in the normal chat panel + land with the rings.
                      onOpen: (r) => _handleMessageTap({
                        'message_id': r['id'],
                        if (r['is_group'] == true)
                          'conversation_id': r['conversation_id'],
                        'group_title': r['group_title'],
                        'friend_id': r['friend_id'],
                        'sender_name': r['friend_name'],
                      }),
                    )),
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
                duration: Motion.emphasized,
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
                  duration: Motion.instant,
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
                blurRadius: Depth.md,
                spreadRadius: 1),
          ],
        ),
        child: const Center(child: PlayingBars(color: Colors.white, scale: 0.85)),
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
                // Pill, like every search box (theme borders are 12 px boxes).
                border: pillSearchBorder(scheme),
                enabledBorder: pillSearchBorder(scheme),
                focusedBorder: pillSearchBorder(scheme, focused: true),
                // One compact height for every search pill (38 px, like Circle's).
                isDense: true,
                constraints: const BoxConstraints(minHeight: 38, maxHeight: 38),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 38, maxHeight: 38),
                suffixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38, maxHeight: 38),
                hintText: 'Search tracks…',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor:
                    scheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                        // Hold a song to share it (as on Android / Windows).
                        onLongPress: playbackBus.webShareAt == null
                            ? null
                            : () {
                                Haptics.holdInk();
                                playbackBus.webShareAt?.call(i);
                              },
                        trailing: GeniePopupMenuButton<String>(
                          tooltip: 'More',
                          icon: Icon(Icons.more_vert_rounded,
                              color: scheme.onSurfaceVariant),
                          onSelected: (v) {
                            switch (v) {
                              case 'play':
                                playbackBus.webPlayAt?.call(i);
                              case 'next':
                                playbackBus.webPlayNextAt?.call(i);
                              case 'partner':
                                playbackBus.webSendToPartnerAt?.call(i);
                              case 'share':
                                playbackBus.webShareAt?.call(i);
                              case 'dedicate':
                                playbackBus.webDedicateAt?.call(i);
                              case 'remove':
                                playbackBus.webRemoveAt?.call(i);
                            }
                          },
                          itemBuilder: (_) {
                            PopupMenuItem<String> row(
                                    String v, IconData icon, String label,
                                    {Color? color}) =>
                                PopupMenuItem<String>(
                                  value: v,
                                  child: Row(children: [
                                    Icon(icon, size: 20, color: color),
                                    const SizedBox(width: 10),
                                    Text(label),
                                  ]),
                                );
                            final partner =
                                SongBridge.instance.partnerId?.call() != null;
                            return [
                              if (!isNow)
                                row('play', Icons.play_arrow_rounded, 'Play'),
                              if (!isNow && i != current + 1)
                                row('next', Icons.playlist_play_rounded,
                                    'Play next'),
                              if (partner)
                                row('partner', Icons.favorite_rounded,
                                    'Send to my partner',
                                    color: accent),
                              row('share', Icons.send_rounded,
                                  'Share with friends'),
                              row('dedicate',
                                  Icons.volunteer_activism_rounded,
                                  'Dedicate to…'),
                              row('remove', Icons.close_rounded,
                                  'Remove from queue'),
                            ];
                          },
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
                              blurRadius: Depth.md,
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
