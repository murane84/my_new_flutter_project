part of '../home_page.dart';

// Split out of home_page.dart (pure code movement, no behaviour change):
// helper methods of HomePageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

// The Listen Together session we're joining right now (so a re-delivered
// invite for it doesn't prompt again).
String? _joiningLiveSession;
DateTime? _joiningLiveAt;

extension _HomePageHelpers1 on HomePageState {
  GlobalKey _spaceTileKey(int id) =>
      _spaceTileKeys.putIfAbsent(id, () => GlobalKey());

  // Build a full avatar URL from a stored relative ref (/attachments/<id>).
  String? _avatarFull(dynamic rel) {
    final s = rel?.toString() ?? '';
    if (s.isEmpty) return null;
    return s.startsWith('http') ? s : '$_apiBase$s';
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

  // Nudge the user to link a recovery key (Ozilane Key) if they have none, so a
  // slow/unpaid email can never lock them out. One-time, dismissible, snoozable;
  // yields to the add-phone prompt so the two never stack.
  Future<void> _maybePromptRecoverySetup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('recovery_prompt_never') == true) return;
      final until = prefs.getInt('recovery_prompt_snooze_until') ?? 0;
      if (DateTime.now().millisecondsSinceEpoch < until) return;

      // Let the add-phone prompt take this launch if it still applies.
      if (prefs.getBool('phone_prompt_dismissed') != true) {
        final me = await ApiService().getUserData();
        if ((me['phone'] ?? '').toString().trim().isEmpty) return;
      }

      if (!await ApiService().ozilaneAvailable()) return;
      final status = await ApiService().ozilaneStatus();
      if (status['enrolled'] == true) return; // already has a key linked
      if (!mounted) return;
      _showRecoverySetupDialog();
    } catch (_) {/* never block the app on this */}
  }

  void _showRecoverySetupDialog() {
    showDialog<void>(
      context: context,
      builder: (dctx) {
        final scheme = Theme.of(dctx).colorScheme;
        Future<void> close({int? snoozeDays, bool never = false}) async {
          final prefs = await SharedPreferences.getInstance();
          if (never) {
            await prefs.setBool('recovery_prompt_never', true);
          } else if (snoozeDays != null) {
            await prefs.setInt(
                'recovery_prompt_snooze_until',
                DateTime.now()
                    .add(Duration(days: snoozeDays))
                    .millisecondsSinceEpoch);
          }
          if (dctx.mounted) Navigator.pop(dctx);
        }

        Widget feature(IconData icon, String text) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, size: 17, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(text,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurface)),
                    ),
                  ),
                ],
              ),
            );

        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          clipBehavior: Clip.antiAlias,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            // Caps the width so it reads as a tidy card on tablet/desktop
            // instead of stretching across the screen; full-width (minus the
            // inset) on phones.
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Accent header band with a shield badge.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        scheme.primary.withValues(alpha: 0.16),
                        scheme.primary.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.shield_moon_rounded,
                            color: scheme.primary, size: 32),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Secure your account',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Link your Ozilane Key so you can always get back into '
                        'your account — even when an email code is slow.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.4,
                            color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      feature(Icons.lock_reset_rounded,
                          'Recover your account anytime'),
                      feature(Icons.verified_user_rounded,
                          'Approve sign-ins right from your phone'),
                      feature(Icons.bolt_rounded,
                          'Works even when email is delayed'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          onPressed: () async {
                            // Snooze briefly so backing out doesn't re-prompt.
                            await close(snoozeDays: 3);
                            if (!mounted) return;
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const LinkOzilaneScreen()));
                          },
                          child: const Text('Set up now'),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: () => close(never: true),
                            child: Text("Don't ask again",
                                style: TextStyle(
                                    color: scheme.onSurfaceVariant)),
                          ),
                          TextButton(
                            onPressed: () => close(snoozeDays: 7),
                            child: const Text('Later'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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

  /// Web: the "lite" player holds its queue in memory, so from a chat we show a
  /// live bottom sheet of that queue — with a full transport strip (seek +
  /// shuffle/repeat/prev/play/next) and tap-to-jump — mirroring how the native
  /// playlist drawer is reachable from a chat.
  void _showWebQueueSheet() {
    final queue = playbackBus.webQueue?.call() ?? const [];
    if (queue.isEmpty) {
      showToast(
        context,
        'No music loaded yet — add songs in the Music panel first.',
        type: ToastType.info,
      );
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _WebQueueSheet(),
    );
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

  void _saveLayoutState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('musicPanelWidth', _musicPanelWidth);
    await prefs.setBool('isMusicFullScreen', _isMusicFullScreen);
    await prefs.setBool('isChatFullScreen', _isChatFullScreen);
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
    // Group (mesh) calling rides the same socket.
    GroupCallService.instance.sendSignal = (msg) => _notifyWs?.sendEvent(msg);
    GroupCallService.instance.onShowUI = _openGroupCallScreen;
    // Live "now playing" presence rides the same socket: emit what I'm playing
    // (server fans it to friends only) and begin watching local playback.
    NowPlayingPresence.instance.emitSink = (msg) => _notifyWs?.sendEvent(msg);
    NowPlayingPresence.instance.start();
    // "Tune in" requests ride it too.
    TuneInService.instance.sendSignal = (msg) => _notifyWs?.sendEvent(msg);
    TuneInService.instance.onTimeout = (id) {
      if (!mounted) return;
      showToast(context, "${_nameForUser(id)} didn't answer — maybe later 💛",
          type: ToastType.info);
    };
    // The mesh's "smaller id offers" rule needs our OWN id on every entry
    // path. startGroupCall()/joinRoom() set it, but accept() (answering an
    // incoming ring) does not — so on a fresh launch the acceptor's myId was
    // null, _maybeOffer() bailed out, and any peer with a higher id sat
    // waiting for an offer that never came → no audio. Set it here once the
    // user is known; _reset() deliberately preserves it across calls.
    GroupCallService.instance.myId = id;
    // Group-call signaling carries only bare user ids, so the call service
    // resolves each participant's name/phone/avatar through this from our own
    // friend list + group rosters — proper identities on every entry path
    // (start/join/accept), on mobile, desktop and web.
    GroupCallService.instance.resolveIdentity = _identityForUser;

    // Bridge calls to the system telecom stack so a car / Bluetooth device can
    // answer & hang up (and route call audio over hands-free). Android-only and
    // fully additive — a system answer/end just drives the existing engine.
    TelecomService.instance.init();
    // A call answered past the fingerprint lock (opened from the ringing
    // notification) → back to the lock screen once it's over.
    relockAfterCall = () {
      lockBypassedForCall = false;
      navigatorKey.currentState
          ?.pushNamedAndRemoveUntil(LockScreen.routeName, (_) => false);
    };
    // Safety net: if the call that opened us never got going (it ended
    // before we connected, or the launch carried no caller), lock anyway.
    if (lockBypassedForCall) {
      Future<void>.delayed(const Duration(seconds: 60), () {
        if (lockBypassedForCall && !CallService.instance.isActive) {
          relockAfterCall?.call();
        }
      });
    }
    TelecomService.instance.onAnswer = (id) {
      if (id.startsWith('grp_')) {
        GroupCallService.instance.accept();
      } else {
        CallService.instance.acceptCall();
      }
    };
    // Ongoing-call notification buttons / tap.
    TelecomService.instance.onToggleMute = CallService.instance.toggleMute;
    TelecomService.instance.onToggleSpeaker =
        () => CallService.instance.toggleSpeaker();
    TelecomService.instance.onOpenCall = () {
      if (CallService.instance.isActive) _openCallScreen();
    };
    TelecomService.instance.onDisconnect = (id) {
      if (id.startsWith('grp_')) {
        GroupCallService.instance.leave();
      } else {
        CallService.instance.hangUp();
      }
    };

    // Accept/Decline tapped on the ringing NOTIFICATION (app backgrounded but
    // still running): route it into the live call engine. This is what gives
    // the receiver working call controls without opening the app first.
    onCallAction = _handleCallNotificationAction;
    // Tapping a message notification (app alive/backgrounded) → open that thread.
    onMessageTap = _handleMessageTap;
    // Listen Together / tune-in / Our Space / reactions / team replies.
    onAlutaTap = _handleAlutaTap;
    // If the app was launched cold by tapping Accept on a call notification
    // (app was killed), pick that up once and reconnect the call — after the
    // first frame so the root navigator exists. Guarded so socket reconnects
    // don't re-trigger it.
    if (!_callLaunchConsumed) {
      _callLaunchConsumed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _consumeCallLaunch();
        // …and if it was a message notification that launched us, open its thread.
        _consumeMessageLaunch();
        _consumeAlutaLaunch();
      });
    }
  }

  Future<void> _consumeAlutaLaunch() async {
    final l = await consumeAlutaLaunchAction();
    if (l != null) _handleAlutaTap(l.actionId, l.payload);
  }

  /// A tap on an Aluta notification (or one of its buttons).
  void _handleAlutaTap(String? action, Map<String, dynamic> p) {
    if (!mounted) return;
    switch (p['kind']) {
      case 'live_invite':
        final sid = (p['session_id'] ?? '').toString();
        final host = (p['host_name'] ?? 'Your friend').toString();
        if (action == kLiveJoin && sid.isNotEmpty) {
          _joinLive(sid, {'title': (p['track_title'] ?? '').toString()}, host);
        } else {
          // Their chat; the invite prompt re-appears there if still open.
          _handleMessageTap({
            'type': 'message',
            'friend_id': p['host_id'],
            'sender_name': host,
          });
        }
      case 'tune_in':
        final from = int.tryParse('${p['from']}');
        if (from == null) return;
        _answerTuneIn(from, (p['from_name'] ?? 'Your friend').toString(),
            p['title']?.toString(),
            preApproved: action == kTuneLet);
      case 'feedback':
        showAppPopup(context, const FeedbackScreen());
      case 'space':
        final from = int.tryParse('${p['from']}');
        final space = from == null ? null : _spaceWithFriend(from);
        if (space != null) _openSpace(space);
      case 'reaction' || 'live_missed':
        _handleMessageTap({...p, 'type': 'message'});
    }
  }

  Future<void> _consumeMessageLaunch() async {
    final payload = await consumeMessageLaunchAction();
    if (payload != null) _handleMessageTap(payload);
  }

  /// Cold-start: the app was launched by tapping a call notification (killed
  /// app, so the WebRTC offer was missed). Depending on WHAT was tapped:
  ///   • Accept  → reconnect and auto-answer (prepareAcceptFromNotification).
  ///   • Decline → hang up.
  ///   • the body (no action) → show the in-app ringing screen with
  ///     Accept/Decline, since tapping the body dismisses the notification and
  ///     the full-screen intent was blocked (MIUI etc.).
  Future<void> _consumeCallLaunch() async {
    final launch = await consumeCallLaunchAction();
    if (launch == null) return;
    final isGroup = launch.payload['group'] == true;
    if (isGroup) {
      // Group: opening the group shows the "call in progress · Join" banner.
      return;
    }
    final cid = int.tryParse('${launch.payload['caller_id'] ?? ''}');
    if (cid == null) return;
    final action = launch.actionId;
    if (action == kCallDecline) {
      CallService.instance.showIncomingFromNotification(
          cid, (launch.payload['caller_name'] ?? '').toString());
      CallService.instance.declineCall();
      return;
    }
    _openCallScreen();
    if (action == kCallAccept) {
      // Answered from the banner with Aluta closed: once connected, go back
      // to where they were — the call continues from the notification.
      CallService.instance.tuckAwayOnConnect = true;
      CallService.instance.prepareAcceptFromNotification(cid,
          callerName: (launch.payload['caller_name'] ?? '').toString());
    } else {
      // Body tap → show the ring screen so the user can act on the call.
      CallService.instance.showIncomingFromNotification(
          cid, (launch.payload['caller_name'] ?? '').toString());
    }
  }

  Future<void> _startGroupCall(Map g) async {
    final room = (g['id'] as num?)?.toInt();
    final myId = _myUserId;
    if (room == null || myId == null) return;
    if (!ConnectionStatus.instance.isOnline) {
      if (mounted) {
        showToast(context, 'No internet — can’t start a group call',
            type: ToastType.info);
      }
      return;
    }
    final members = <GroupParticipant>[];
    for (final m in (g['members'] as List?) ?? const []) {
      if (m is! Map) continue;
      final id = (m['user_id'] as num?)?.toInt();
      if (id == null || id == myId) continue;
      members.add(GroupParticipant(
        id,
        ContactNames.instance.displayName(of: m, registered: (m['username'] ?? '').toString()),
        m['avatar_url'] as String?,
        phone: m['phone'] as String?,
      ));
    }
    final ok = await GroupCallService.instance.startGroupCall(
      room: room,
      title: (g['title'] ?? 'Group').toString(),
      myId: myId,
      myName: _username.isNotEmpty ? _username : 'Aluta user',
      members: members,
    );
    if (!ok && mounted) {
      showToast(context, 'You’re already in a call', type: ToastType.info);
    }
  }

  /// Join an ONGOING group call from the "call in progress · Join" banner — a
  /// member who missed or declined the ring reconnecting. Same member wiring as
  /// [_startGroupCall] but routes to joinRoom() (announces a join, not a start).
  Future<void> _joinGroupCall(Map g) async {
    final room = (g['id'] as num?)?.toInt();
    final myId = _myUserId;
    if (room == null || myId == null) return;
    if (GroupCallService.instance.isActive) {
      // Already in a call — just resurface the screen.
      _openGroupCallScreen();
      return;
    }
    if (!ConnectionStatus.instance.isOnline) {
      if (mounted) {
        showToast(context, 'No internet — can’t join the call',
            type: ToastType.info);
      }
      return;
    }
    final members = <GroupParticipant>[];
    for (final m in (g['members'] as List?) ?? const []) {
      if (m is! Map) continue;
      final id = (m['user_id'] as num?)?.toInt();
      if (id == null || id == myId) continue;
      members.add(GroupParticipant(
        id,
        ContactNames.instance.displayName(of: m, registered: (m['username'] ?? '').toString()),
        m['avatar_url'] as String?,
        phone: m['phone'] as String?,
      ));
    }
    final title = (g['title'] ??
            GroupCallService.instance.ongoingCalls.value[room] ??
            'Group')
        .toString();
    await GroupCallService.instance.joinRoom(
      room: room,
      title: title,
      myId: myId,
      myName: _username.isNotEmpty ? _username : 'Aluta user',
      members: members,
    );
  }

  /// One row inside the group header's ⋮ options menu.
  Widget _groupMenuRow(IconData icon, String label, ColorScheme scheme) => Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Text(label),
        ],
      );

  /// Show the "Listen together?" prompt anywhere in the app and, on accept,
  /// open the live session popup as a listener.
  Future<void> _showLiveInvite(Map<String, dynamic> event) async {
    final data = (event['data'] as Map?)?.cast<String, dynamic>();
    if (data == null) return;
    final sessionId = data['session_id']?.toString();
    if (sessionId == null) return;
    final track =
        (data['track'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    // Already joining / in this very session (e.g. Join tapped on the
    // notification, then the socket re-delivered the invite) → no prompt.
    final justJoined = sessionId == _joiningLiveSession &&
        _joiningLiveAt != null &&
        DateTime.now().difference(_joiningLiveAt!) <
            const Duration(seconds: 30);
    if (justJoined) return;
    if (activeLiveSession?.controller.sessionId == sessionId) {
      _reopenLiveSession(); // a re-invite for the room we're in
      return;
    }
    final rawHostName = data['host_username']?.toString() ?? 'Someone';
    // Show the host by the name the user has for them in their friend list /
    // phone book (saved contact name), falling back to the app username — so the
    // "listening with …" label matches everything else the user sees.
    final hostName =
        _contactDisplayName(_friendPhoneById(data['host_id']), rawHostName);

    // The invite I asked for ("Tune in") → straight in, no second prompt.
    final hostId = int.tryParse('${data['host_id']}');
    final asked = TuneInService.instance.consumeIfPending(hostId);

    final bool? accept = asked ? true : await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withAlpha(120),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => _LiveInviteDialog(
        hostName: hostName,
        hostAvatar: _allFriends
            .firstWhere((f) => f['id']?.toString() == data['host_id']?.toString(),
                orElse: () => const <String, dynamic>{})['avatar_url'] as String?,
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
    if (accept != true) {
      // Explicit Decline (false) → tell the host so they can end or keep
      // waiting. Barrier-dismiss (null) leaves it pending, no notification.
      if (accept == false) {
        ApiService().declineLiveSession(sessionId);
      }
      return;
    }
    // The banner for this invite has done its job.
    cancelAlutaNotification(alutaNotifId('live', '${data['host_id']}'));
    await _joinLive(sessionId, track, hostName);
  }

  /// Join a Listen Together session as a listener (from the invite prompt
  /// or the notification's Join button).
  Future<void> _joinLive(
      String sessionId, Map<String, dynamic> track, String hostName) async {
    _joiningLiveSession = sessionId;
    _joiningLiveAt = DateTime.now();
    final token = await getToken();
    final myUserId = _myUserId;
    if (token == null || myUserId == null || !mounted) return;

    // Guard against ending up with two listener controllers fighting over the
    // same user socket. If a session is already active (e.g. a previous screen
    // is stuck reconnecting after a network drop):
    //   • same session → this is a re-invite for the room we're already in.
    //     Just surface the existing screen; its own reconnect handles rejoining
    //     — spinning up a second controller would make the two sockets duel
    //     (empty queue, no audio).
    //   • different session → leave the stale one cleanly first.
    if (activeLiveSession != null) {
      final already = activeLiveSession!.controller.sessionId;
      if (already != null && already == sessionId) {
        _reopenLiveSession();
        return;
      }
      await endActiveLiveSession();
      ref.read(liveSessionProvider.notifier).stop();
      if (!mounted) return;
    }

    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.listener(
        token: token,
        myUserId: myUserId,
        sessionId: sessionId,
        track: track,
        peerName: hostName,
        myName: _username.isNotEmpty ? _username : null,
      ),
    ));
  }

  /// A friend's display name by id (contact name, else username).
  String _nameForUser(int id) {
    final f = _allFriends.firstWhere(
        (f) => (f['id'] as num?)?.toInt() == id,
        orElse: () => const <String, dynamic>{});
    return _contactDisplayName(
        _friendPhoneById(id), (f['username'] ?? 'Your friend').toString());
  }

  /// "Tune in" signaling — see TuneInService for the message flow.
  Future<void> _onTuneInSignal(Map<String, dynamic> event) async {
    final type = event['type']?.toString();
    final from = (event['from'] as num?)?.toInt();
    if (from == null || !mounted) return;
    final svc = TuneInService.instance;
    final known = _allFriends.any((f) => (f['id'] as num?)?.toInt() == from);
    final name = known
        ? _nameForUser(from)
        : (event['name'] ?? 'Your friend').toString();
    switch (type) {
      case 'tune_in_request':
        await _answerTuneIn(from, name, event['title']?.toString());
        return;
      case 'tune_in_accept':
        svc.answered(from, accepted: true);
        return;
      case 'tune_in_decline':
        if (svc.pending.value != from) return;
        svc.answered(from, accepted: false);
        final reason = event['reason']?.toString();
        showToast(
            context,
            switch (reason) {
              'busy' => '$name is in another session right now',
              'not_playing' => '$name just stopped the music',
              'unreadable' => "$name's song can't be shared from their device",
              _ => '$name is keeping this one to themselves for now 💛',
            },
            type: ToastType.info);
        return;
      case 'tune_in_pushed':
        // They weren't in Aluta — the ask went to their phone instead.
        svc.markPushed(from);
        return;
      case 'tune_in_unreachable':
        if (svc.pending.value != from) return;
        svc.answered(from, accepted: false);
        showToast(context, "$name isn't online right now — try again in a bit",
            type: ToastType.info);
        return;
      case 'tune_in_cancel':
        // Close an open "let them in?" prompt for this friend.
        svc.cancelledBy.value = null;
        svc.cancelledBy.value = from;
        return;
    }
  }

  /// Someone asked to listen along to MY song. Yes → I host what I'm playing,
  /// from where I am, and invite them; my music never changes.
  Future<void> _answerTuneIn(int from, String name, String? askedTitle,
      {bool preApproved = false}) async {
    final svc = TuneInService.instance;
    cancelAlutaNotification(alutaNotifId('tune', '$from'));
    // Opened from the notification: the socket may still be connecting.
    for (var i = 0; i < 40 && !svc.canSend; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted) return;
    if (activeLiveSession != null) {
      svc.reply(from, accept: false, reason: 'busy');
      return;
    }
    if (!(playbackBus.isPlaying?.call() ?? false)) {
      svc.reply(from, accept: false, reason: 'not_playing');
      return;
    }
    final mine = (playbackBus.currentTitle?.call() ?? '').trim();
    final shown =
        mine.isNotEmpty ? mine : ((askedTitle ?? '').isNotEmpty ? askedTitle! : 'your song');
    final avatar = _allFriends.firstWhere(
        (f) => (f['id'] as num?)?.toInt() == from,
        orElse: () => const <String, dynamic>{})['avatar_url'] as String?;
    svc.cancelledBy.value = null;
    final accept = preApproved ? true : await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withAlpha(120),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => _TuneInPromptGate(
        from: from,
        child: _LiveInviteDialog(
          hostName: name,
          hostAvatar: avatar,
          trackTitle: shown,
          heading: 'Can I tune in?',
          verb: ' wants to listen along to your song.',
          note: 'Your music keeps playing — they join right where you are.',
          declineLabel: 'Not now',
          acceptLabel: 'Let them in',
        ),
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
    if (!mounted) return;
    if (accept != true) {
      // They gave up already → no answer needed; otherwise a polite no.
      if (svc.cancelledBy.value != from) {
        svc.reply(from, accept: false, reason: 'no');
      }
      return;
    }
    final token = await getToken();
    final myUserId = _myUserId;
    if (token == null || myUserId == null || !mounted) return;
    // The song exactly as it plays here (file on device, bytes on web).
    Uint8List bytes = Uint8List(0);
    final path = playbackBus.currentPath?.call();
    try {
      if (!kIsWeb && path != null && path.isNotEmpty) {
        bytes = Uint8List.fromList(await readFileBytes(path));
      } else {
        bytes = playbackBus.currentBytes?.call() ?? Uint8List(0);
      }
    } catch (_) {}
    if (!mounted) return;
    if (bytes.isEmpty) {
      svc.reply(from, accept: false, reason: 'unreadable');
      showToast(context, "Couldn't share this song from here",
          type: ToastType.error);
      return;
    }
    final pos = playbackBus.currentPositionMs?.call() ?? 0;
    // What comes after this song in MY player, so the session keeps my
    // rhythm instead of stopping when the first song ends.
    final upNext = _myUpNext(path, 5);
    svc.reply(from, accept: true);
    // The session carries the music on from here — no double playback.
    playbackBus.onPause?.call();
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: from,
        audioBytes: bytes,
        title: shown,
        peerName: name,
        startPositionMs: pos,
      ),
    ));
    _carryUpNext(upNext);
  }

  /// My next [n] songs after the one playing (title + byte loader) — device
  /// playlist on Android / Windows, the web queue on web.
  List<({String title, Future<List<int>> Function() load})> _myUpNext(
      String? path, int n) {
    if (kIsWeb || path == null || path.isEmpty) {
      final q = playbackBus.webQueue?.call() ?? const [];
      final at = playbackBus.webCurrentIndex?.call() ?? -1;
      if (at < 0) return const [];
      return [
        for (final t in q.skip(at + 1).take(n))
          (title: t.title, load: () async => t.load()),
      ];
    }
    final list = playlistNotifier.value;
    final at = list.indexOf(path);
    if (at < 0) return const [];
    return [
      for (final p in list.skip(at + 1).take(n))
        (
          title: metadataStore.title(
              p, p.replaceAll('\\', '/').split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '')),
          load: () => readFileBytes(p),
        ),
    ];
  }

  /// Queue [next] into the session once it's up (it's created by the screen
  /// I just opened). Best-effort: a song that can't be read is skipped.
  Future<void> _carryUpNext(
      List<({String title, Future<List<int>> Function() load})> next) async {
    if (next.isEmpty) return;
    for (var i = 0; i < 60 && activeLiveSession == null; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final c = activeLiveSession?.controller;
    if (c == null) return;
    for (final t in next) {
      try {
        final b = await t.load();
        if (b.isEmpty || activeLiveSession?.controller != c) continue;
        await c.addTrack(LiveTrack(bytes: Uint8List.fromList(b), title: t.title));
      } catch (_) {}
    }
  }

  /// Host side: a friend declined our Listen Together invite. Let the host
  /// decide whether to end the (still-open) session or keep waiting.
  Future<void> _showLiveDeclined(Map<String, dynamic> event) async {
    if (!mounted || activeLiveSession == null) return;
    // Record the decline on the thread (and suppress the end-of-session log).
    activeLiveSession?.controller.markDeclined();
    final data =
        (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final who = (data['listener_username'] ?? 'Your friend').toString();
    final end = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Invite declined'),
        content: Text('$who declined your Listen Together invite.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (end == true) await _endLiveSession();
  }

  /// Keep a good last-message preview when a fetch returns an EMPTY one — e.g.
  /// the last message was purged server-side after both devices cached it
  /// (store-and-forward). Without this, a background refresh blanks the preview
  /// under a friend's / group's name even though the message still lives in the
  /// local chat cache.
  void _preservePreviews(List<Map<String, dynamic>> fresh,
      List<Map<String, dynamic>> prev) {
    if (prev.isEmpty) return;
    final byId = {for (final p in prev) p['id'].toString(): p};
    for (final f in fresh) {
      final lm = (f['last_message'] ?? '').toString().trim();
      if (lm.isNotEmpty) continue;
      final p = byId[f['id'].toString()];
      if (p == null) continue;
      final plm = (p['last_message'] ?? '').toString().trim();
      if (plm.isEmpty) continue;
      f['last_message'] = p['last_message'];
      if ((f['last_timestamp'] ?? '').toString().trim().isEmpty) {
        f['last_timestamp'] = p['last_timestamp'];
      }
    }
  }

  /// A friend-list preview string for a cached chat message.
  String _previewFromCachedMessage(Map<String, dynamic> m) {
    final type = (m['message_type'] ?? 'text').toString();
    final text = (m['content'] ?? '').toString().trim();
    final name = (m['media_name'] ?? '').toString().trim();
    String withText(String label) => text.isEmpty ? label : '$label · $text';
    if (m['is_deleted'] == true) return 'This message was deleted';
    switch (type) {
      case 'heart':
        // Never peek a secret heart's note.
        return '❤️ Secret message';
      case 'song':
        // Content carries "Title — Artist"; fall back to the file name.
        if (text.isNotEmpty) return '🎵 $text';
        if (name.isNotEmpty) {
          final dot = name.lastIndexOf('.');
          return '🎵 ${dot > 0 ? name.substring(0, dot) : name}';
        }
        return '🎵 Song';
      case 'image':
        final mime = (m['media_mime'] ?? '').toString();
        return withText(mime.contains('gif') ? '🎞️ GIF' : '📷 Photo');
      case 'audio':
        return withText('🎤 Voice note');
      case 'video':
        return withText('🎬 Video');
      case 'gif':
        return '🎞️ GIF';
      case 'file':
        return name.isNotEmpty ? '📎 $name' : '📎 File';
      case 'poll':
        return text.isEmpty ? '📊 Poll' : '📊 $text';
      case 'location':
        return '📍 Location';
      case 'contact':
        return '👤 Contact';
      case 'live':
        return _livePreview((m['content'] ?? '').toString().trim());
      case 'call':
        return _callPreview((m['content'] ?? '').toString().trim(),
            (m['media_duration'] as num?)?.toInt() ?? 0);
      default:
        return (m['content'] ?? '').toString().trim();
    }
  }

  // Friendly friend-list label for a "listen together" (live) outcome token.
  String _livePreview(String outcome) {
    switch (outcome) {
      case 'listened':
        return '🎧 Listened together';
      case 'declined':
        return '🎧 Listen together declined';
      case 'noanswer':
        return '🎧 Listen together — no answer';
      default:
        return '🎧 Listen together';
    }
  }

  // Friendly friend-list label for a call-log outcome. A connected call
  // (secs > 0) just reads "Call"; otherwise the reason is spelled out.
  String _callPreview(String outcome, int secs) {
    if (secs > 0) return '📞 Call';
    switch (outcome) {
      case 'declined':
        return '📞 Call declined';
      case 'busy':
        return '📞 Line busy';
      case 'unreachable':
        return '📞 Unreachable';
      case 'failed':
        return '📞 Call failed';
      case 'cancelled':
        return '📞 Call cancelled';
      case 'noanswer':
        return '📞 No answer';
      default: // 'missed' / unknown
        return '📞 Missed call';
    }
  }

  /// Parse a timestamp on an absolute scale. DM rows come from the server as a
  /// NAIVE "YYYY-MM-DD HH:MM" in UTC; Dart would read that as LOCAL time and
  /// shift it by the phone's offset (3 h in Dar), making a newer server message
  /// look older than the cached one. No zone → treat as UTC.
  DateTime? _absTime(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final dt = DateTime.tryParse(t);
    if (dt == null) return null;
    final hasZone = t.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(t);
    if (hasZone || dt.isUtc) return dt;
    return DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute,
        dt.second, dt.millisecond);
  }

  /// Make the DURABLE LOCAL chat cache the primary source of each row's
  /// last-message preview. The server copy is only used when it carries a
  /// strictly NEWER message (a fresh message to a chat that isn't open, which
  /// the local cache hasn't seen yet) — so previews survive server purge and
  /// offline, yet still update live. Mutates [items] in place.
  Future<void> _hydratePreviewsFromCache(
      List<Map<String, dynamic>> items, {required bool group}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final myId = prefs.getString('my_user_id');
      if (myId == null) return;
      for (final f in items) {
        final id = f['id'];
        final key =
            group ? 'chat_cache_${myId}_g$id' : 'chat_cache_${myId}_$id';
        final raw = prefs.getString(key);
        if (raw == null) continue;
        dynamic list;
        try {
          list = jsonDecode(raw);
        } catch (_) {
          continue;
        }
        if (list is! List || list.isEmpty) continue;
        // Newest cached message that yields a preview. A server-purged row
        // still counts when its TYPE says what it was (a song / photo / voice
        // note keeps its card locally) — skipping those used to fall back to
        // an older text, e.g. "Good morning" under four songs sent after it.
        Map? m;
        String localPrev = '';
        for (int i = list.length - 1; i >= 0; i--) {
          final x = list[i];
          if (x is! Map) continue;
          final p = _previewFromCachedMessage(Map<String, dynamic>.from(x));
          if (p.trim().isEmpty) continue;
          m = x;
          localPrev = p;
          break;
        }
        if (m == null) continue;
        final localTs = _absTime(
            (m['timestamp'] ?? m['created_at'] ?? '').toString());
        final serverPrev = (f['last_message'] ?? '').toString().trim();
        final serverTs = _absTime((f['last_timestamp'] ?? '').toString());
        // Prefer local unless the server clearly has a newer message.
        final serverIsNewer = serverPrev.isNotEmpty &&
            serverTs != null &&
            (localTs == null || serverTs.isAfter(localTs));
        if (serverIsNewer) continue;
        f['last_message'] = localPrev;
        final ts = (m['timestamp'] ?? m['created_at'] ?? '').toString();
        if (ts.isNotEmpty) f['last_timestamp'] = ts;
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> _applyGroupQuery(
      List<Map<String, dynamic>> groups, String query) {
    final q = query.toLowerCase();
    if (q.isEmpty) return groups;
    return groups
        .where((g) => (g['title'] as String? ?? '').toLowerCase().contains(q))
        .toList();
  }

  /// Filter the friend list by the search query. Matches the app username AND
  /// the SHOWN name (saved phone-book name) so searching by how you know them
  /// works even if their app username differs. Empty query → the full list.
  List<Map<String, dynamic>> _applyFriendQuery(
      List<Map<String, dynamic>> friends, String query) {
    final q = query.toLowerCase();
    if (q.isEmpty) return friends;
    return friends.where((f) {
      final username = (f['username'] as String? ?? '').toLowerCase();
      final shown = _contactDisplayName(
              f['phone']?.toString(), f['username'] as String? ?? '')
          .toLowerCase();
      return username.contains(q) || shown.contains(q);
    }).toList();
  }

  /// Clear the search so BOTH friends and groups return to their full lists and
  /// the search box empties. Called when a chat is opened, so coming back shows
  /// the whole list (and groups don't stay filtered out by a stale query). The
  /// caller wraps this in setState.
  void _clearSearchState() {
    _searchQuery = '';
    _searchCtrl.clear();
    _filteredFriends = _allFriends;
    _filteredGroups = _groups;
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

  /// The name to SHOW for a friend/contact: their SAVED phone-book name when we
  /// have that number saved on this device, otherwise their app username. Same
  /// priority the group message headers use, now applied to the friend list and
  /// DMs so a person reads the same everywhere.
  String _contactDisplayName(String? phone, String username) {
    // Resolve the saved phone-book name by the friend's phone; if that's not
    // set, fall back to the username — for phone-registered users the username
    // IS a number, so a saved contact still matches. nameFor ignores strings
    // with too few digits, so a real-name username safely returns null.
    final p = (phone ?? '').trim();
    final saved = ContactNames.instance.nameFor(p.isNotEmpty ? p : username);
    if (saved != null && saved.isNotEmpty) return saved;
    return username;
  }

  /// Friendly one-line preview for a conversation's last message. Location and
  /// contact shares store JSON in the message body; show a label in the chat
  /// list instead of the raw JSON.
  String _previewText(String raw) {
    final s = raw.trim();
    // Safety net: a call / listen-together log whose raw outcome token leaked
    // into the preview (e.g. a server last_message that carries no type).
    final mapped = mapOutcomeToken(s);
    if (mapped != null) return mapped;
    if (s.startsWith('{') && s.endsWith('}')) {
      try {
        final j = jsonDecode(s);
        if (j is Map) {
          if (j['lat'] is num && j['lng'] is num) return '📍 Location';
          if (j.containsKey('phones') &&
              (j.containsKey('name') || j.containsKey('phone'))) {
            return '👤 Contact';
          }
        }
      } catch (_) {/* not our JSON — show as-is */}
    }
    return raw;
  }

  /// The saved phone number for a friend by their user id, looked up in the
  /// loaded friend list — so a live-session host (identified only by id/username
  /// in the invite) can still be shown by the user's saved contact name.
  String? _friendPhoneById(dynamic id) {
    if (id == null) return null;
    final key = id.toString();
    for (final f in _allFriends) {
      if (f['id']?.toString() == key) return f['phone'] as String?;
    }
    return null;
  }

  /// Drop expired stories (past 24h) so a cached feed clears on time; keep my
  /// own group even when empty so the "Your story" tile still shows.
  List<StoryGroup> _activeStoryGroups(List<StoryGroup> groups) {
    final now = DateTime.now();
    final out = <StoryGroup>[];
    for (final g in groups) {
      final live = g.stories.where((s) {
        final exp = s.expiresAt ?? s.createdAt?.add(const Duration(hours: 24));
        return exp == null || exp.isAfter(now);
      }).toList();
      if (live.isEmpty && !g.isMe) continue;
      out.add(StoryGroup(
        authorId: g.authorId,
        username: g.username,
        avatarUrl: g.avatarUrl,
        phone: g.phone,
        isMe: g.isMe,
        hasUnseen: g.hasUnseen,
        stories: live,
      ));
    }
    return out;
  }

  /// Hybrid status pre-download: cache PHOTOS eagerly (small, instant + offline)
  /// and VIDEOS only on Wi-Fi when the user allows it — so viewing a status is
  /// instant and works offline without burning mobile data on unopened videos.
  void _prefetchStories(List<StoryGroup> groups) async {
    if (kIsWeb) return;
    try {
      final conn = await Connectivity().checkConnectivity();
      final onWifi = conn.contains(ConnectivityResult.wifi);
      final hasNet = conn.any((r) => r != ConnectivityResult.none);
      if (!hasNet) return;
      final prefs = await SharedPreferences.getInstance();
      final videoOnWifi = prefs.getBool('status_dl_videos_wifi') ?? true;
      int budget = 24; // cap downloads per pass
      for (final g in groups) {
        if (g.isMe) continue;
        for (final st in g.stories) {
          if (budget <= 0) return;
          final rel = st.mediaUrl;
          if (rel == null || rel.trim().isEmpty) continue;
          final url = rel.startsWith('http') ? rel : '$_apiBase$rel';
          final isVideo = st.kind == 'video';
          // Videos: only when enabled AND on Wi-Fi. Photos: any connection.
          if (isVideo && (!videoOnWifi || !onWifi)) continue;
          if (await MediaStore.instance.cached(url) != null) continue;
          budget--;
          MediaStore.instance.getFile(url, mediaAuthHeaders(url)).ignore();
        }
      }
    } catch (_) {}
  }

  /// Manual add-friend — works everywhere, including desktop/web with no
  /// phone-book to scan: look someone up by their exact username or phone and
  /// add them to your circle, then refresh the list.
  void _showAddFriend() {
    showAddFriendSheet(
      context,
      onAdded: () {
        if (mounted) _fetchFriends();
      },
    );
  }

  /// The single contextual line under a friend's name, in priority order:
  /// live track → typing… → last message (styled for unread).
  Widget _tileSubtitle(ColorScheme scheme, Color textColor, String? npLine,
      bool typing, String lastMsg, bool hasUnread) {
    if (npLine != null) {
      final npStyle = TextStyle(
          fontSize: 12.5,
          color: scheme.primary,
          fontWeight: FontWeight.w600);
      return Row(
        children: [
          Icon(Icons.graphic_eq_rounded, size: 14, color: scheme.primary),
          const SizedBox(width: 5),
          Expanded(child: _scrollingText(npLine, npStyle)),
        ],
      );
    }
    if (typing) {
      return Text(
        'typing…',
        style: TextStyle(
            fontSize: 12.5,
            color: scheme.primary,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w600),
      );
    }
    final base = TextStyle(
      fontSize: 12.5,
      color: hasUnread ? textColor.withAlpha(200) : textColor.withAlpha(110),
      fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
    );
    // Render the message's formatting (*bold* _italic_ …) right in the preview.
    return Text.rich(
      TextSpan(
          style: base,
          children: previewSpans(lastMsg, base,
              codeBg: textColor.withValues(alpha: 0.12),
              highlightBg: const Color(0x66FFC107))),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  /// A single-line label that gently scrolls (marquee) ONLY when the text is too
  /// long to fit — short titles render as plain, still text. Used for the live
  /// track under a friend in the "Listening now" zone so long "Title — Artist"
  /// strings are fully readable without truncation.
  Widget _scrollingText(String text, TextStyle style) {
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
        return SizedBox(
          height: (style.fontSize ?? 13) + 5,
          child: Marquee(
            text: text,
            style: style,
            blankSpace: 44,
            velocity: 26,
            startPadding: 0,
            pauseAfterRound: const Duration(seconds: 1),
            accelerationDuration: const Duration(milliseconds: 350),
            decelerationDuration: const Duration(milliseconds: 350),
            showFadingOnlyWhenScrolling: true,
            fadingEdgeStartFraction: 0.06,
            fadingEdgeEndFraction: 0.12,
          ),
        );
      },
    );
  }

  /// One-shot: ask the server whether the signed-in user must (re-)accept the
  /// current Privacy Policy + Terms, and if so present the blocking consent
  /// gate. Fails OPEN — a null/failed status never blocks entry to the app.
  Future<void> _ensurePolicyAccepted() async {
    if (_policyChecked) return;
    _policyChecked = true;
    final status = await ApiService().fetchPolicyStatus();
    if (!mounted || status == null) return;
    if (status['needs_acceptance'] != true) return;
    await showPolicyGate(
      context,
      status: status,
      onLogout: _signOutFromGate,
    );
  }

  /// The active story group for a friend id (null if none), used to draw the
  /// coloured "unseen" / grey "seen" ring on their conversation tile.
  StoryGroup? _friendStory(dynamic id) {
    if (id == null) return null;
    final key = id.toString();
    for (final g in _storyGroups) {
      if (!g.isMe && g.authorId.toString() == key) return g;
    }
    return null;
  }

  /// Open a friend's story straight from their conversation tile.
  Future<void> _openFriendStory(StoryGroup g) async {
    await Navigator.push(
      navigatorKey.currentContext ?? context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoryViewerScreen(
          groups: [g],
          startGroup: 0,
          apiBase: _apiBase,
          myUserId: _myUserId,
        ),
      ),
    );
    _fetchStories();
  }

  /// A friend-list avatar, wrapped in a story ring when they have an active
  /// status: a colourful gradient while unseen, a neutral grey once viewed.
  /// Tapping the ring opens their story (the rest of the tile opens the chat).
  /// Wrap [avatar] in a status ring for [story] — a colourful gradient while
  /// unseen, a neutral grey once viewed — or return it unchanged when there's
  /// no active story. Shared by the friend-list tiles and the DM chat header.
  Widget _statusRing(Widget avatar, StoryGroup? story) {
    if (story == null) return avatar;
    final scheme = Theme.of(context).colorScheme;
    final gradient = story.hasUnseen
        ? const LinearGradient(
            colors: [Color(0xFFF9A825), Color(0xFFE91E63), Color(0xFF7B1FA2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : null;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: gradient,
        color: gradient == null ? Colors.grey.shade400 : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration:
            BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
        child: avatar,
      ),
    );
  }

  Widget _storyRingAvatar(
      Map<String, dynamic> f, String name, bool isOnline) {
    final avatar = InitialsAvatar(
      name: name,
      radius: 22,
      isOnline: isOnline,
      imageUrl: _avatarFull(f['avatar_url']),
    );
    final story = _friendStory(f['id']);
    Widget core = story == null
        ? avatar
        : GestureDetector(
            onTap: () => _openFriendStory(story),
            child: _statusRing(avatar, story),
          );
    // Listening right now → wrap in a slowly spinning coral "record" ring.
    final id = (f['id'] as num?)?.toInt();
    if (id != null && NowPlayingPresence.instance.trackFor(id) != null) {
      core = SpinningVinylRing(key: ValueKey('np-$id'), child: core);
    }
    return core;
  }

  /// Poll the backend for whether a group call is live in [conv] and seed the
  /// ongoing-call flag (drives the in-group Join banner).
  Future<void> _refreshGroupCallState(Map<String, dynamic> conv) async {
    final cid = (conv['id'] as num?)?.toInt();
    if (cid == null) return;
    final state = await ApiService().getGroupCallState(cid);
    if (state == null) return;
    final active = state['active'] == true;
    final title =
        (state['title'] ?? conv['title'] ?? 'Group call').toString();
    GroupCallService.instance.setOngoingFromServer(cid, title, active);
  }

  /// Read the phone's address book, match numbers against registered users, and
  /// auto-add the matches as friends. Android/iOS only.
  ///
  /// [quiet] (pull-to-refresh): never asks for the contacts permission, shows
  /// no progress toasts, and only speaks up when someone new was added. The
  /// saved-name map is re-read too, so newly saved names show at once.
  Future<void> _findFriendsFromContacts({bool quiet = false}) async {
    final mobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (quiet) {
      if (!mobile) return;
      try {
        final st = await ph.Permission.contacts.status;
        if (st != ph.PermissionStatus.granted &&
            st != ph.PermissionStatus.limited) {
          return;
        }
      } catch (_) {
        return;
      }
    }
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
        if (mounted && !quiet) {
          showToast(context, 'Contacts permission denied.',
              type: ToastType.error);
        }
        return;
      }
      if (mounted && !quiet) {
        showToast(context, 'Checking your contacts…', type: ToastType.info);
      }
      final contacts =
          await FlutterContacts.getContacts(withProperties: true);
      // Contacts are authorised now — populate the phonebook-name map too so
      // group headers immediately show saved names (a pull re-reads it so a
      // freshly saved name appears without restarting).
      if (quiet) {
        // (Home repaints on ContactNames.revision when the re-read lands.)
        unawaited(ContactNames.instance.refresh());
      } else {
        ContactNames.instance.ensureLoaded();
      }
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
        if (mounted && !quiet) {
          showToast(context, 'No phone numbers found in your contacts.',
              type: ToastType.info);
        }
        return;
      }
      final res = await ApiService().syncContacts(phones);
      final added = (res['added'] as num?)?.toInt() ?? 0;
      final matched = (res['matched'] as List?)?.length ?? 0;
      if (!mounted) return;
      if (quiet) {
        if (added > 0) {
          showToast(
              context,
              added == 1
                  ? '1 contact joined Aluta — added to your circle 🎉'
                  : '$added contacts joined Aluta — added to your circle 🎉',
              type: ToastType.success);
          await _fetchFriends();
        }
        return;
      }
      showToast(
        context,
        matched == 0
            ? 'None of your contacts are on Aluta yet.'
            : 'Found $matched on Aluta · added $added new friend${added == 1 ? '' : 's'}.',
        type: ToastType.success,
      );
      _fetchFriends(); // refresh the list with any newly-added friends
      // The user has just opted into contact features → NOW (on demand, never at
      // launch) set up the Android "Connected apps" rows (Aluta call/message
      // under matched contacts). Runs once per session; a no-op off Android.
      ConnectedContactsService.instance.refresh();
    } catch (e) {
      if (mounted && !quiet) {
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
      // No theme outline — this sheet draws its own card.
      shape: const RoundedRectangleBorder(),
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
}
