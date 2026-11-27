// The socket layer proper: the `shelf` pipeline, the WebSocket upgrade, the
// `RoomHub` implementation `connection.dart` declares and depends on, client
// IP extraction (including the trusted-proxy rule for a forwarded header),
// and the once-a-minute housekeeping timer that drives both
// `RoomRegistry.reap()` and `RateLimiter.prune()`. Nothing here touches room
// state directly; it only wires sockets to `Connection` and `Connection` to
// the registry, exactly the split `connection.dart`'s own header comment
// describes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'account_page.dart';
import 'account_store.dart';
import 'client_build.dart';
import 'clock.dart';
import 'connection.dart';
import 'envelope.dart' show logSafeError;
import 'google_token.dart';
import 'link_id.dart';
import 'link_pages.dart';
import 'privacy_page.dart';
import 'rate_limit.dart';
import 'registry.dart';
import 'room.dart';
import 'snapshot.dart';
import 'verify_page.dart';
import 'verify_scripts.dart';
import 'verify_store.dart';

/// How often the housekeeping timer fires: `RoomRegistry.reap()` and
/// `RateLimiter.prune()` both run on this cadence. `docs/PROTOCOL.md` does
/// not pin an exact number; the work order asks for "around once a minute"
/// and this is that.
const Duration housekeepingInterval = Duration(minutes: 1);

/// How often the turn timer sweeps for expired segments. Separate from
/// [housekeepingInterval] on purpose: reaping an idle room a minute late
/// costs nothing, but a turn budget of `rules.turn_seconds` swept once a
/// minute would overrun by up to a further minute, which is the same stall
/// this timer exists to end, only shorter. One second is the coarsest sweep
/// whose worst-case overrun a player would not notice against a 45-second
/// budget, and the sweep itself only walks the room map.
const Duration turnExpiryInterval = Duration(seconds: 1);

/// How often a WebSocket ping control frame is sent on every accepted socket
/// (`docs/PROTOCOL.md` section 24). A ping not answered by a pong within one
/// further interval closes the socket with code 1001, which runs the same
/// disconnect handling as any other close, so a link that has silently died
/// is noticed within twice this interval.
const Duration defaultKeepaliveInterval = Duration(seconds: 10);

/// The header a reverse proxy is expected to set with the real client
/// address. Only trusted when the immediate peer address is in the
/// configured proxy list.
const String forwardedForHeader = 'x-forwarded-for';

/// The exact, case-sensitive path of the operational health endpoint. Not a
/// game protocol message: it is answered before the WebSocket upgrade is
/// ever attempted, and it is the only path this server treats specially.
const String _healthPath = '/health';

/// The exact, case-sensitive path of the privacy policy page. Matched
/// alongside its trailing-slash form by the same pre-upgrade check
/// [_healthPath] uses; see order 049.
const String _privacyPath = '/privacy';

/// The trailing-slash form of [_privacyPath]. A separate constant rather
/// than a computed one so both paths read as literal strings at every call
/// site.
const String _privacyPathWithSlash = '/privacy/';

/// The exact, case-sensitive path of the Digital Asset Links document.
/// Matched, like [_healthPath] and [_privacyPath], before the WebSocket
/// upgrade is ever attempted. See order 076 and `docs/RELEASE.md:139-159`:
/// the fingerprint this document carries has to be the Play App Signing
/// key's, never the upload key's.
const String _assetLinksPath = '/.well-known/assetlinks.json';

/// Section 36.4 and 36.5: the sign-in routes and the deletion page.
const String _authConfigPath = '/auth/config';
const String _authGooglePath = '/auth/google';
const String _accountDeletePath = '/account/delete';
const String _accountDeletePathWithSlash = '/account/delete/';

/// Section 36.4: request bodies over this many bytes are refused with 413.
const int _maxAccountBodyBytes = 8192;

/// Section 36.4: more than [_accountRateLimit] requests to the two POST routes
/// from one IP inside [_accountRateWindow] are refused with 429.
const int _accountRateLimit = 10;
const Duration _accountRateWindow = Duration(seconds: 60);

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
};

/// Matches `/r/<anything with no further slash>`, the shared-room landing
/// page. The captured group is looked up as a link id by [_handleRoomLink];
/// this pattern alone says nothing about whether it names a live room.
final RegExp _roomLinkPathPattern = RegExp(r'^/r/([^/]+)$');

/// Matches `/v/<anything>`, deliberately including further slashes: unlike
/// [_roomLinkPathPattern], `docs/VERIFY.md` section 4 requires this route to
/// answer a well-defined not-found response for a trailing slash, an
/// encoded slash or a `..` in the id, rather than falling through to the
/// WebSocket upgrade attempt every other unmatched path reaches. Capturing
/// everything after `/v/` here and letting [_handleVerify] sort the result
/// out is what makes that possible: every one of those shapes fails
/// [isWellFormedGameId] and is answered as not found, and none of them ever
/// reaches [VerifyStore.load] or [VerifyStore.save] to build a path from.
final RegExp _verifyPathPattern = RegExp(r'^/v/(.*)$');

/// The room page's `content-security-policy`, verbatim, which is the verify
/// page's policy too. The C-615 pages carry it as well.
const String _pageContentSecurityPolicy = "default-src 'none'; "
    "script-src 'self'; style-src 'unsafe-inline'; "
    "base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

const String _verifyJsonSuffix = '.json';

/// Builds the `assetlinks.json` body for [rawFingerprint], or returns null
/// when [rawFingerprint] is null, empty, or does not match
/// [appSigningFingerprintShape]. A shape mismatch is treated exactly like an
/// absent value -- served as a 404, never as the malformed value itself --
/// because a misconfigured fingerprint fails Android's verification exactly
/// as silently as an absent one does, and there is no way to tell from the
/// string alone whether it is the app signing key or, wrongly, the upload
/// key; see `docs/RELEASE.md:139-159`. The value itself is never logged.
///
/// [rawFingerprint] is trimmed of surrounding whitespace and upper-cased
/// before the shape check, so a value that is otherwise valid is accepted
/// regardless of how it was typed or pasted; the normalised value is what
/// gets checked against [appSigningFingerprintShape] and what is passed to
/// [buildAssetLinksJson], so the served document always carries the
/// canonical upper-case form.
int _checkedMinClientBuild(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'minClientBuild', 'must not be negative');
  }
  return value;
}

String? _buildAssetLinksJsonOrNull(String? rawFingerprint) {
  if (rawFingerprint == null || rawFingerprint.isEmpty) {
    return null;
  }
  final String normalisedFingerprint = rawFingerprint.trim().toUpperCase();
  if (!isValidAppSigningFingerprintShape(normalisedFingerprint)) {
    return null;
  }
  return buildAssetLinksJson(normalisedFingerprint);
}

/// Owns the listening socket and everything that turns an accepted
/// connection into a [Connection]. Built once per running server; `start`
/// opens the port, `close` shuts it down along with the housekeeping timer.
class WireServer {
  WireServer({
    required this.registry,
    required this.rateLimiter,
    required this.clock,
    Random? random,
    Set<String> trustedProxies = const <String>{},
    this.version = 'dev',
    String? privacyContactEmail,
    String? appSigningSha256,
    this.automaticTurnExpiry = true,
    Duration? keepaliveInterval,
    int minClientBuild = 0,
    GoogleTokenVerifier? googleVerifier,
    AccountStore? accountStore,
    String? googleClientId,
  })  : _privacyContactEmail = privacyContactEmail,
        _googleVerifier = googleVerifier,
        _accountStore = accountStore,
        _googleClientId = googleClientId,
        keepaliveInterval = keepaliveInterval ?? defaultKeepaliveInterval,
        minClientBuild = _checkedMinClientBuild(minClientBuild),
        _random = random ?? Random.secure(),
        _trustedProxies = trustedProxies,
        _hub = _ConnectionHub(registry),
        _privacyHtml = buildPrivacyPageHtml(contactEmail: privacyContactEmail),
        _privacyHtmlAr = buildPrivacyPageHtml(
          contactEmail: privacyContactEmail,
          language: 'ar',
        ),
        _assetLinksJson = _buildAssetLinksJsonOrNull(
          // `bin/server.dart` is the entry point that reads every other
          // piece of environment-driven configuration (PORT,
          // TRUSTED_PROXIES, LUDO_VERSION, PRIVACY_CONTACT_EMAIL) and passes
          // each down as an explicit constructor argument here -- but that
          // file is out of scope for order 076, so this one value falls
          // back to reading LUDO_APP_SIGNING_SHA256 from the process
          // environment directly when no caller supplies it explicitly.
          // Every existing call site (bin/server.dart unmodified, and every
          // test harness that does not pass this argument) keeps working
          // exactly as it does today, with the fallback taking effect only
          // in the running process's own environment, read once here and
          // never again.
          appSigningSha256 ?? Platform.environment['LUDO_APP_SIGNING_SHA256'],
        ) {
    // Section 31 item 12 (b): whoever calls reap(), the knockers of a reaped
    // room are told at once.
    registry.onKnocksReaped = failReapedKnocks;
    registry.onLobbiesClosed = _announceClosedLobbies;
    // Section 34 item 4: what the computer sweep does is published here.
    registry.onComputerAction = _publishComputerStep;
  }

  /// Section 36: sign-in is on only when all three of these are set and the
  /// client id is not empty; otherwise every sign-in route answers
  /// `SIGN_IN_OFF` and `GET /auth/config` answers null.
  final GoogleTokenVerifier? _googleVerifier;
  final AccountStore? _accountStore;
  final String? _googleClientId;

  /// The `PRIVACY_CONTACT_EMAIL` value, shown on the deletion page too.
  final String? _privacyContactEmail;

  bool get _signInOn =>
      _googleVerifier != null &&
      _accountStore != null &&
      _googleClientId != null &&
      _googleClientId.isNotEmpty;

  /// Section 36.4's per-IP window, one list of hit times per IP.
  final Map<String, List<DateTime>> _accountHits = <String, List<DateTime>>{};

  final RoomRegistry registry;
  final RateLimiter rateLimiter;
  final Clock clock;
  final Random _random;

  /// Test seam. When false, [start] does not create the periodic turn-expiry
  /// timer, and the sweep runs only when [runTurnExpiryOnce] is called.
  /// Always true in production: `bin/server.dart` never passes it, and a
  /// server built without this timer never ends a turn on its own.
  final bool automaticTurnExpiry;

  /// The WebSocket ping interval applied to every accepted socket, passed as
  /// `pingInterval` to `webSocketHandler`. Defaults to
  /// [defaultKeepaliveInterval]; a test passes a shorter one.
  final Duration keepaliveInterval;

  /// Section 27 rule 3: the lowest app build this server lets play. `0`
  /// turns the check off. Deliberately not reported by `GET /health`.
  final int minClientBuild;

  /// The build identifier reported by `GET /health`. Not otherwise used;
  /// this server does not act differently for one version than another.
  final String version;

  /// Addresses (as `InternetAddress.address` strings) allowed to set
  /// [forwardedForHeader] and be believed. Empty by default: with no
  /// configured proxy, every connection's IP is the immediate TCP peer
  /// address and any `X-Forwarded-For` header an untrusted client sends is
  /// ignored outright, never inspected at all.
  final Set<String> _trustedProxies;

  /// The complete `/privacy` document, built once from the constructor's
  /// `privacyContactEmail` argument at construction time so serving it never
  /// touches the filesystem or re-renders anything at request time.
  final String _privacyHtml;

  /// The Arabic twin of [_privacyHtml], built at the same moment.
  final String _privacyHtmlAr;

  /// The complete `assetlinks.json` body, built once at construction time,
  /// or null when no shape-valid fingerprint was available. Null means
  /// `GET /.well-known/assetlinks.json` answers 404 with an empty body --
  /// never `[]`, which would be the different and much stronger claim that
  /// no application is associated with this domain at all.
  final String? _assetLinksJson;

  final _ConnectionHub _hub;

  HttpServer? _httpServer;
  Timer? _housekeeping;
  Timer? _turnExpiry;

  /// The instant [start] completed, per the injected [clock]. Null before
  /// [start] has returned, in which case reported uptime is zero.
  DateTime? _startedAt;

  /// Starts listening. [address] is anything `HttpServer.bind` accepts
  /// (`InternetAddress` or a host string); [port] `0` binds an ephemeral
  /// port, readable back afterwards from [port].
  Future<void> start({required Object address, required int port}) async {
    final shelf.Handler handler = (shelf.Request request) {
      final String path = request.requestedUri.path;
      if (path == _healthPath) {
        return _handleHealth(request);
      }
      if (path == _privacyPath || path == _privacyPathWithSlash) {
        return _handlePrivacy(request);
      }
      if (path == _assetLinksPath) {
        return _handleAssetLinks(request);
      }
      if (path == _authConfigPath) {
        return _handleAuthConfig(request);
      }
      if (path == _authGooglePath) {
        return _handleAuthGoogle(request);
      }
      if (path == _accountDeletePath || path == _accountDeletePathWithSlash) {
        return _handleAccountDelete(request);
      }
      final RegExpMatch? roomLinkMatch = _roomLinkPathPattern.firstMatch(path);
      if (roomLinkMatch != null) {
        return _handleRoomLink(request, roomLinkMatch.group(1)!);
      }
      final RegExpMatch? verifyMatch = _verifyPathPattern.firstMatch(path);
      if (verifyMatch != null) {
        return _handleVerify(request, verifyMatch.group(1)!);
      }
      if (!_isUpgradeRequest(request)) {
        return _handlePlainRequest(request, path);
      }
      final String ip = _clientIp(request);
      final int build = parseClientBuildHeader(
        request.headers[clientBuildHeader],
      );
      final shelf.Handler upgrade = webSocketHandler(
        (
          WebSocketChannel channel,
          String? protocol,
        ) {
          _accept(channel, ip, build);
        },
        pingInterval: keepaliveInterval,
      );
      return upgrade(request);
    };

    _httpServer = await shelf_io.serve(handler, address, port);
    _housekeeping = Timer.periodic(housekeepingInterval, (_) {
      _runHousekeeping();
    });
    if (automaticTurnExpiry) {
      _turnExpiry = Timer.periodic(turnExpiryInterval, (_) {
        _runTurnExpiry();
      });
    }
    _startedAt = clock.now;
  }

  /// The bound port. Only meaningful after [start] has completed.
  int get port => _httpServer!.port;

  /// Stops accepting new connections and cancels the housekeeping timer.
  /// `force: true` because a server answering SIGTERM is expected to go
  /// away promptly rather than wait out whatever sockets are still open.
  Future<void> close() async {
    _housekeeping?.cancel();
    _housekeeping = null;
    _turnExpiry?.cancel();
    _turnExpiry = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  /// Runs one housekeeping pass synchronously, exactly as the periodic timer
  /// created by [start] does: reap (which announces closed lobbies and fails
  /// reaped knocks), then pruning. Exists so a test with an injected [Clock]
  /// can observe the pass at a chosen instant. Never called by production
  /// code.
  @visibleForTesting
  void runHousekeepingOnce() => _runHousekeeping();

  /// Runs one turn-expiry sweep synchronously, exactly as the periodic timer
  /// created by [start] does -- the same call, the same guards, the same
  /// broadcasts. Exists so a test that has advanced its injected [Clock] past
  /// a segment's budget can observe the sweep act on that instant instead of
  /// waiting out a real second. Never called by production code.
  @visibleForTesting
  void runTurnExpiryOnce() => _runTurnExpiry();

  /// Runs one computer-seat sweep synchronously, exactly as the 100 ms timer
  /// in `bin/server.dart` does: the registry's own
  /// [RoomRegistry.runComputerSeatsOnce], whose steps this server publishes.
  /// Exists so a test that moved its injected [Clock] can land every due
  /// computer action at once.
  @visibleForTesting
  void runComputerSeatsOnce() {
    registry.runComputerSeatsOnce();
  }

  /// Section 34 item 4: publishes one action taken for a computer seat to
  /// every socket in its room, with no `re` (no request is answered) and no
  /// `by` (section 22 marks the timer, and this is not the timer): the frames
  /// are the ones a player's own `roll` or `move` makes.
  void _publishComputerStep(ComputerStep step) {
    final RollOk? rolled = step.roll;
    final MoveOk? moved = step.move;
    final List<OutFrame> frames =
        rolled != null ? buildRollFrames(rolled) : buildMoveFrames(moved!);
    for (final OutFrame frame in frames) {
      _hub.broadcast(code: step.code, type: frame.type, data: frame.data);
    }
    if (moved != null) {
      detachFreedSeats(_hub, step.code, moved.freed);
    }
    final Object? lastSeq = frames.isEmpty ? null : frames.last.data['seq'];
    // ignore: avoid_print
    print('room=${step.code} type=${rolled != null ? 'roll' : 'move'} '
        'id=computer seat=${step.seat} bot=${step.bot} outcome=ok '
        'frames=${frames.map((OutFrame f) => f.type).join('+')} '
        'seq=${lastSeq is int ? lastSeq : '-'}');
  }

  /// `docs/RULES.md` section 3.3. The registry decides and applies; this
  /// only publishes what it decided, to every socket in the room, with no
  /// `re` on any frame because no request is being answered. Two separate
  /// guards protect two separate failures, and they must not be collapsed
  /// into one: the outer `try` protects `registry.expireTurns()` itself, so
  /// a throw computing which rooms expired cannot escape this periodic
  /// timer and take every room in the process down with it; the inner `try`
  /// protects one room's publish, so a throw broadcasting one room's expiry
  /// cannot stop the publish for every other room this same sweep decided
  /// on.
  void _runTurnExpiry() {
    _runKnockExpiry();
    _runAbsentRetirement();
    _runWaitingLine();
    final List<ExpiredTurn> expired;
    try {
      expired = registry.expireTurns();
    } catch (error, stack) {
      // ignore: avoid_print
      print('turn-expiry sweep failed error=${logSafeError(error)}\n$stack');
      return;
    }
    for (final ExpiredTurn one in expired) {
      try {
        final List<OutFrame> frames = buildExpiryFrames(one);
        for (final OutFrame frame in frames) {
          _hub.broadcast(
            code: one.code,
            type: frame.type,
            data: frame.data,
          );
        }
        final MoveOk? timerMove = one.move;
        if (timerMove != null) {
          detachFreedSeats(_hub, one.code, timerMove.freed);
        }
        final String phase = one.roll != null
            ? 'await_roll'
            : one.move != null
                ? 'await_move'
                : 'unknown';
        final String framesJoined = frames.isEmpty
            ? 'none'
            : frames.map((OutFrame frame) => frame.type).join('+');
        final Object? lastSeq = frames.isEmpty ? null : frames.last.data['seq'];
        final String seq = lastSeq is int ? '$lastSeq' : '-';
        // ignore: avoid_print
        print('turn-expiry applied room=${one.code} seat=${one.seat} '
            'phase=$phase frames=$framesJoined seq=$seq');
      } catch (error, stack) {
        // ignore: avoid_print
        print('turn-expiry publish failed room=${one.code} '
            'seat=${one.seat} error=${logSafeError(error)}\n$stack');
      }
    }
  }

  /// `docs/PROTOCOL.md` section 31 item 4: closes every knock that has gone 60
  /// seconds unanswered on the injected clock, `timeout`, and publishes what
  /// that sends. Guarded like the other sweeps: a throw is logged and does not
  /// stop the timer.
  void _runKnockExpiry() {
    try {
      registry.sweepStrikes();
    } catch (error, stack) {
      // ignore: avoid_print
      print('strike sweep failed error=$error\n$stack');
    }
    try {
      failReapedKnocks(registry.drainReapedKnocks());
    } catch (error, stack) {
      // ignore: avoid_print
      print('knock reaped-notice failed error=$error\n$stack');
    }
    final List<KnockEvent> events;
    try {
      events = registry.expireKnocks();
    } catch (error, stack) {
      // ignore: avoid_print
      print('knock-expiry sweep failed error=$error\n$stack');
      return;
    }
    // Section 31 item 12 (c): one event failing to publish must not drop the
    // ones after it.
    for (final KnockEvent event in events) {
      try {
        publishKnockEvents(_hub, <KnockEvent>[event]);
        // ignore: avoid_print
        print('room=${event.room.code} type=- id=- seat=- '
            'outcome=knock_closed knock=${event.knock.id} '
            'reason=${(event as KnockClosed).outcome} seq=${event.seq}');
      } catch (error, stack) {
        // ignore: avoid_print
        print('knock-expiry publish failed room=${event.room.code} '
            'knock=${event.knock.id} error=$error\n$stack');
      }
    }
  }

  /// `docs/PROTOCOL.md` section 33 item 4: drops the tickets detached for
  /// 30 000 ms on the injected clock, then serves the line, so the positions
  /// an expiry changed are told at once. Guarded like the other sweeps.
  void _runWaitingLine() {
    try {
      expireWaitingLine(registry);
      serveWaitingLine(registry, _hub);
    } catch (error, stack) {
      // ignore: avoid_print
      print('waiting-line sweep failed error=$error\n$stack');
    }
  }

  /// `docs/PROTOCOL.md` section 28 rule 4 "absent", the other half of the
  /// 1 s sweep: retires every playing seat of a 2026-11 game whose socket has
  /// been down for 120 s, and publishes what the engine's events say follows,
  /// to every socket in the room with no `re` (no request is answered). Run
  /// first, so a seat that has just become due is retired rather than played
  /// for by the timer one more time. The registry hands over each retirement
  /// as it is made, so every one is published from the state it left. Guarded
  /// per room: a throw retiring in one room, or publishing one retirement, is
  /// logged with the room and the seat and the other rooms go on.
  void _runAbsentRetirement() {
    try {
      registry.retireAbsentSeats(
        publish: _publishAbsentRetirement,
        onError: (String code, int? seat, Object error, StackTrace stack) {
          // ignore: avoid_print
          print('absent-retire failed room=$code seat=${seat ?? '-'} '
              'error=${logSafeError(error)}\n$stack');
        },
      );
    } catch (error, stack) {
      // ignore: avoid_print
      print('absent-retire sweep failed error=${logSafeError(error)}\n$stack');
    }
  }

  void _publishAbsentRetirement(RetireOk one) {
    final List<OutFrame> frames = buildRetireFrames(one);
    for (final OutFrame frame in frames) {
      _hub.broadcast(
        code: one.room.code,
        type: frame.type,
        data: frame.data,
      );
    }
    detachFreedSeats(_hub, one.room.code, one.freed);
    // ignore: avoid_print
    print('room=${one.room.code} type=- id=- seat=${one.seat.seat} '
        'outcome=seat_retired reason=${one.reason} '
        'seq=${one.gameOverSeq ?? one.turnSeq ?? one.retiredSeq}');
  }

  void _runHousekeeping() {
    final int reaped = registry.reap();
    try {
      failReapedKnocks(registry.drainReapedKnocks());
    } catch (error, stack) {
      // ignore: avoid_print
      print('knock reaped-notice failed error=$error\n$stack');
    }
    if (reaped > 0) {
      // ignore: avoid_print
      print('housekeeping reaped=$reaped');
    }
    _announceLobbyWarnings();
    rateLimiter.prune();
    _pruneAccountHits();
  }

  /// Section 38 item 1: every LOBBY past the 8 minute mark that has not been
  /// warned sends `lobby_closing` to each attached socket, once per lifetime.
  /// Runs after the reap, so a room that just closed is never warned.
  void _announceLobbyWarnings() {
    try {
      for (final Room room in registry.takeLobbyWarnings()) {
        final int closesInS = registry.lobbyClosesInS(room);
        _hub.broadcast(
          code: room.code,
          type: 'lobby_closing',
          data: <String, Object?>{'closes_in_s': closesInS},
        );
        // ignore: avoid_print
        print('room=${room.code} type=- id=- seat=- '
            'outcome=lobby_closing closes_in_s=$closesInS');
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print('lobby_closing sweep failed error=${logSafeError(error)}\n$stack');
    }
  }

  /// Section 37 item 2: every socket still attached to a lobby that timed
  /// out gets one `room_closed`, then is detached with its identity cleared.
  /// Runs in the same synchronous sweep as the reap, so the frame is sent
  /// before the code can be handed out again.
  void _announceClosedLobbies(List<ClosedLobby> closed) {
    for (final ClosedLobby lobby in closed) {
      final List<Connection> sockets = _hub.detachRoom(lobby.code);
      for (final Connection conn in sockets) {
        clearConnectionIdentity(conn);
        try {
          conn.sendPush(
            type: 'room_closed',
            data: const <String, Object?>{'reason': 'lobby_timeout'},
          );
        } catch (error, stack) {
          // One dead socket must not keep the others from being told.
          // ignore: avoid_print
          print('room_closed send failed room=${lobby.code} error=$error\n'
              '$stack');
        }
      }
      // ignore: avoid_print
      print('room_closed room=${lobby.code} reason=lobby_timeout '
          'sockets=${sockets.length}');
    }
  }

  // --- section 36: sign-in routes -----------------------------------------

  /// Records one hit for [ip] and says whether it is within the limit. A
  /// refused hit is not recorded, so it does not push the window out.
  bool _admitAccountRequest(String ip) {
    final DateTime now = clock.now;
    final List<DateTime> hits =
        _accountHits.putIfAbsent(ip, () => <DateTime>[]);
    hits.removeWhere((DateTime t) => now.difference(t) >= _accountRateWindow);
    if (hits.length >= _accountRateLimit) {
      return false;
    }
    hits.add(now);
    return true;
  }

  void _pruneAccountHits() {
    final DateTime now = clock.now;
    _accountHits.removeWhere((String ip, List<DateTime> hits) {
      hits.removeWhere((DateTime t) => now.difference(t) >= _accountRateWindow);
      return hits.isEmpty;
    });
  }

  shelf.Response _accountJson(int status, Map<String, Object?> body) =>
      shelf.Response(status, body: jsonEncode(body), headers: _jsonHeaders);

  shelf.Response _accountError(int status, String code) =>
      _accountJson(status, <String, Object?>{'code': code});

  /// One structured line per decision; never the token, the hash, the name,
  /// the address or the IP.
  void _logAccount(String route, String outcome, {String? error}) {
    // ignore: avoid_print
    print('account route=$route outcome=$outcome'
        '${error == null ? '' : ' error=$error'}');
  }

  /// `GET /auth/config`: the client id the app asks Google for a token with,
  /// null when sign-in is off.
  shelf.Response _handleAuthConfig(shelf.Request request) {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return shelf.Response(405, headers: const <String, String>{
        'allow': 'GET, HEAD',
      });
    }
    final Map<String, Object?> body = <String, Object?>{
      'google_client_id': _signInOn ? _googleClientId : null,
    };
    return shelf.Response.ok(
      request.method == 'HEAD' ? '' : jsonEncode(body),
      headers: _jsonHeaders,
    );
  }

  /// What reading a JSON request body came to: the token, or the response to
  /// send instead.
  Future<({String? token, shelf.Response? refusal})> _readTokenBody(
    shelf.Request request,
  ) async {
    final List<int>? bytes = await _readCapped(request);
    if (bytes == null) {
      return (token: null, refusal: _accountError(413, 'TOO_LARGE'));
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return (token: null, refusal: _accountError(400, 'BAD_REQUEST'));
    }
    if (decoded is! Map<String, Object?> ||
        decoded.length != 1 ||
        decoded['id_token'] is! String) {
      return (token: null, refusal: _accountError(400, 'BAD_REQUEST'));
    }
    return (token: decoded['id_token'] as String, refusal: null);
  }

  /// The request body, or null when it is over [_maxAccountBodyBytes]. The
  /// declared length is checked first, and reading stops at the cap, so an
  /// oversize body is never held whole.
  Future<List<int>?> _readCapped(shelf.Request request) async {
    final int? declared = request.contentLength;
    if (declared != null && declared > _maxAccountBodyBytes) {
      return null;
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      bytes.add(chunk);
      if (bytes.length > _maxAccountBodyBytes) {
        return null;
      }
    }
    return bytes.takeBytes();
  }

  /// `POST /auth/google`.
  Future<shelf.Response> _handleAuthGoogle(shelf.Request request) async {
    if (request.method != 'POST') {
      return shelf.Response(405, headers: const <String, String>{
        'allow': 'POST',
      });
    }
    if (!_admitAccountRequest(_clientIp(request))) {
      _logAccount('auth_google', 'rate_limited');
      return _accountError(429, 'RATE_LIMITED');
    }
    if (!_signInOn) {
      _logAccount('auth_google', 'sign_in_off');
      return _accountError(503, 'SIGN_IN_OFF');
    }
    final body = await _readTokenBody(request);
    if (body.refusal != null) {
      _logAccount('auth_google', 'refused_${body.refusal!.statusCode}');
      return body.refusal!;
    }
    final TokenCheck check = await _googleVerifier!.verify(body.token!);
    switch (check) {
      case TokenBad():
        _logAccount('auth_google', 'bad_token');
        return _accountError(401, 'BAD_TOKEN');
      case TokenUnavailable():
        _logAccount('auth_google', 'unavailable');
        return _accountError(503, 'SIGN_IN_UNAVAILABLE');
      case TokenOk():
        try {
          _accountStore!.upsert(check.sub, check.name);
        } on FileSystemException catch (error) {
          _logAccount('auth_google', 'store_failed',
              error: '${error.runtimeType}');
          return _accountError(500, 'STORE_FAILED');
        } on ProcessException catch (error) {
          _logAccount('auth_google', 'store_failed',
              error: '${error.runtimeType}');
          return _accountError(500, 'STORE_FAILED');
        }
        _logAccount('auth_google', 'ok');
        return _accountJson(200, <String, Object?>{'name': check.name});
    }
  }

  /// `GET /account/delete` (the page) and `POST /account/delete`: JSON from
  /// the app, or the form Google's button posts, told apart by content type.
  Future<shelf.Response> _handleAccountDelete(shelf.Request request) async {
    switch (request.method) {
      case 'GET':
      case 'HEAD':
        return _accountDeletePage(request);
      case 'POST':
        break;
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD, POST',
        });
    }
    final String type = (request.headers['content-type'] ?? '').toLowerCase();
    final bool isForm = type.startsWith('application/x-www-form-urlencoded');
    if (!_admitAccountRequest(_clientIp(request))) {
      _logAccount('account_delete', 'rate_limited');
      return isForm
          ? _accountResultPage(request, AccountResult.rateLimited)
          : _accountError(429, 'RATE_LIMITED');
    }
    if (!_signInOn) {
      _logAccount('account_delete', 'sign_in_off');
      return isForm
          ? _accountResultPage(request, AccountResult.signInOff)
          : _accountError(503, 'SIGN_IN_OFF');
    }
    if (isForm) {
      return _handleAccountDeleteForm(request);
    }
    final body = await _readTokenBody(request);
    if (body.refusal != null) {
      _logAccount('account_delete', 'refused_${body.refusal!.statusCode}');
      return body.refusal!;
    }
    final TokenCheck check = await _googleVerifier!.verify(body.token!);
    switch (check) {
      case TokenBad():
        _logAccount('account_delete', 'bad_token');
        return _accountError(401, 'BAD_TOKEN');
      case TokenUnavailable():
        _logAccount('account_delete', 'unavailable');
        return _accountError(503, 'SIGN_IN_UNAVAILABLE');
      case TokenOk():
        try {
          final bool deleted = _accountStore!.delete(check.sub);
          _logAccount('account_delete', deleted ? 'deleted' : 'none');
          return _accountJson(200, <String, Object?>{'deleted': deleted});
        } on FileSystemException catch (error) {
          _logAccount('account_delete', 'store_failed',
              error: '${error.runtimeType}');
          return _accountError(500, 'STORE_FAILED');
        }
    }
  }

  /// The form Google posts in redirect mode: `credential` and
  /// `g_csrf_token`, with a cookie of the same name. Accepted only when the
  /// cookie and the field are both present and equal.
  Future<shelf.Response> _handleAccountDeleteForm(shelf.Request request) async {
    final List<int>? bytes = await _readCapped(request);
    if (bytes == null) {
      _logAccount('account_delete', 'refused_413');
      return _accountResultPage(request, AccountResult.tooLarge);
    }
    final Map<String, String> fields;
    try {
      fields = Uri.splitQueryString(utf8.decode(bytes));
    } on FormatException {
      return _accountResultPage(request, AccountResult.badRequest);
    } on ArgumentError {
      return _accountResultPage(request, AccountResult.badRequest);
    }
    final String? field = fields['g_csrf_token'];
    final String? cookie = _cookie(request, 'g_csrf_token');
    final String? credential = fields['credential'];
    if (field == null ||
        field.isEmpty ||
        cookie == null ||
        cookie != field ||
        credential == null) {
      _logAccount('account_delete', 'form_refused');
      return _accountResultPage(request, AccountResult.badRequest);
    }
    final TokenCheck check = await _googleVerifier!.verify(credential);
    switch (check) {
      case TokenBad():
        _logAccount('account_delete', 'bad_token');
        return _accountResultPage(request, AccountResult.badToken);
      case TokenUnavailable():
        _logAccount('account_delete', 'unavailable');
        return _accountResultPage(request, AccountResult.unavailable);
      case TokenOk():
        try {
          final bool deleted = _accountStore!.delete(check.sub);
          _logAccount('account_delete', deleted ? 'deleted' : 'none');
          return _accountResultPage(
            request,
            deleted ? AccountResult.deleted : AccountResult.noAccount,
          );
        } on FileSystemException catch (error) {
          _logAccount('account_delete', 'store_failed',
              error: '${error.runtimeType}');
          return _accountResultPage(request, AccountResult.storeFailed);
        }
    }
  }

  /// The value of cookie [name] in the request's `cookie` header, or null.
  String? _cookie(shelf.Request request, String name) {
    final String? header = request.headers['cookie'];
    if (header == null) {
      return null;
    }
    for (final String pair in header.split(';')) {
      final int eq = pair.indexOf('=');
      if (eq > 0 && pair.substring(0, eq).trim() == name) {
        return pair.substring(eq + 1).trim();
      }
    }
    return null;
  }

  static final RegExp _hostShape = RegExp(r'^[A-Za-z0-9.\-]+(:\d{1,5})?$');

  /// `GET /account/delete`: the page, with Google's button only when sign-in
  /// is on and the request's host is one a URL can safely carry.
  shelf.Response _accountDeletePage(shelf.Request request) {
    final String language = resolveVerifyLanguage(
      query: request.url.queryParameters,
      acceptLanguageHeader: request.headers['accept-language'],
    );
    final Uri requested = request.requestedUri;
    final String authority = requested.hasPort
        ? '${requested.host}:${requested.port}'
        : requested.host;
    final bool hostOk = _hostShape.hasMatch(authority);
    final bool loopback =
        requested.host == '127.0.0.1' || requested.host == 'localhost';
    final bool button = _signInOn && hostOk;
    final String? loginUri = button
        ? '${loopback ? requested.scheme : 'https'}://$authority'
            '$_accountDeletePath'
        : null;
    final String html = buildAccountDeletePageHtml(
      language: language,
      googleClientId: button ? _googleClientId : null,
      loginUri: loginUri,
      contactEmail: _privacyContactEmail,
    );
    return shelf.Response.ok(
      request.method == 'HEAD' ? '' : html,
      headers: <String, String>{
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'vary': 'accept-language',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'content-security-policy': button
            ? signInPageContentSecurityPolicy
            : basePageContentSecurityPolicy,
      },
    );
  }

  shelf.Response _accountResultPage(
    shelf.Request request,
    AccountResult result,
  ) {
    final String language = resolveVerifyLanguage(
      query: request.url.queryParameters,
      acceptLanguageHeader: request.headers['accept-language'],
    );
    return shelf.Response(
      accountResultStatus(result),
      body: buildAccountResultPageHtml(language: language, result: result),
      headers: <String, String>{
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'vary': 'accept-language',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'content-security-policy': basePageContentSecurityPolicy,
      },
    );
  }

  void _accept(WebSocketChannel channel, String ip, int build) {
    // Section 27 rule 5: one line per accepted upgrade, before anything else
    // happens on the socket. The build only; no address, code or name.
    // ignore: avoid_print
    print('connect build=$build');
    final Connection conn = Connection(
      channel: channel,
      ip: ip,
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
      hub: _hub,
      random: _random,
      clientBuild: build,
    );
    if (minClientBuild > 0 && build < minClientBuild) {
      // Sent before the first inbound frame is read. `_pump` still runs so
      // the close handshake completes; `Connection.handleFrame` drops what
      // the peer sends.
      unawaited(conn.refuseUpdateRequired(minBuild: minClientBuild));
    }
    unawaited(_pump(channel, conn));
  }

  /// Reads frames off [channel] one at a time, awaiting each before the
  /// next is handled, so two frames from the same socket are never
  /// processed concurrently against the same connection's mutable seat
  /// identity. Any stream error is treated the same as an ordinary close.
  Future<void> _pump(WebSocketChannel channel, Connection conn) async {
    try {
      await for (final Object? frame in channel.stream) {
        if (frame == null) {
          continue;
        }
        await conn.handleFrame(frame);
      }
    } catch (_) {
      // A transport-level failure ends the connection exactly like a clean
      // close does; the seat survives regardless, per docs/PROTOCOL.md
      // section 8.
    } finally {
      conn.handleDisconnect();
    }
  }

  /// `GET /health` never reaches the WebSocket upgrade path: the path check
  /// in [start]'s handler runs first, always, regardless of what upgrade
  /// headers the request carries. The body is aggregate counts only -- never
  /// a room code, a seat token, a client IP, or a configuration value --
  /// because this hostname is public.
  shelf.Response _handleHealth(shelf.Request request) {
    if (request.method != 'GET') {
      return shelf.Response(405, headers: const <String, String>{
        'allow': 'GET',
      });
    }
    final Map<String, Object?> body = <String, Object?>{
      'status': 'ok',
      'version': version,
      'uptime_s': _uptimeSeconds,
      'rooms': registry.roomCount,
      'rooms_lobby': registry.lobbyRoomCount,
      'rooms_playing': registry.playingRoomCount,
      'rooms_finished': registry.finishedRoomCount,
      'oldest_lobby_s': registry.oldestLobbyAgeSeconds,
    };
    return shelf.Response.ok(
      jsonEncode(body),
      headers: const <String, String>{
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  }

  /// `GET /privacy` and `HEAD /privacy` (and their trailing-slash forms,
  /// which are matched identically, not redirected) never reach the
  /// WebSocket upgrade path either, for the same reason [_handleHealth]
  /// doesn't. The language is picked per request by
  /// `resolveVerifyLanguage` between two documents built at construction, so
  /// the response varies on `Accept-Language`. Any other method is a `405`
  /// naming `GET` and `HEAD` in `allow`.
  shelf.Response _handlePrivacy(shelf.Request request) {
    const Map<String, String> headers = <String, String>{
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'public, max-age=3600',
      'vary': 'accept-language',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'content-security-policy': _pageContentSecurityPolicy,
    };
    switch (request.method) {
      case 'GET':
        final String language = resolveVerifyLanguage(
          query: request.url.queryParameters,
          acceptLanguageHeader: request.headers['accept-language'],
        );
        return shelf.Response.ok(
          language == 'ar' ? _privacyHtmlAr : _privacyHtml,
          headers: headers,
        );
      case 'HEAD':
        return shelf.Response.ok('', headers: headers);
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
    }
  }

  /// `GET /.well-known/assetlinks.json` and `HEAD` of the same, never
  /// reaching the WebSocket upgrade path either. With no shape-valid
  /// fingerprint configured, answers `404` with an empty body -- see
  /// [_assetLinksJson]'s doc comment for why that, and not `[]`, is the
  /// honest answer. Any other method is a `405` naming `GET` and `HEAD`.
  shelf.Response _handleAssetLinks(shelf.Request request) {
    switch (request.method) {
      case 'GET':
      case 'HEAD':
        final String? body = _assetLinksJson;
        if (body == null) {
          return shelf.Response(404, body: '');
        }
        const Map<String, String> headers = <String, String>{
          'content-type': 'application/json',
        };
        return shelf.Response.ok(
          request.method == 'HEAD' ? '' : body,
          headers: headers,
        );
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
    }
  }

  /// True when [request] asks for a WebSocket upgrade: its `upgrade` header
  /// contains `websocket`, in any casing. Such a request is the game socket
  /// on whatever path it names -- the client connects to path `/` -- and is
  /// handed to `webSocketHandler` untouched. Everything else reaching
  /// [_handlePlainRequest] is an ordinary HTTP request.
  bool _isUpgradeRequest(shelf.Request request) {
    final String? upgrade = request.headers['upgrade'];
    return upgrade != null && upgrade.toLowerCase().contains('websocket');
  }

  /// C-615. Answers an ordinary (non-upgrade) request for a path no other
  /// route matched: the home page at `/`, the generic not-found page
  /// anywhere else. `HEAD` carries the status and headers of `GET` with an
  /// empty body. Never reached by a WebSocket upgrade, see
  /// [_isUpgradeRequest].
  shelf.Response _handlePlainRequest(shelf.Request request, String path) {
    final bool isGet = request.method == 'GET';
    final bool isHead = request.method == 'HEAD';
    if (path == '/') {
      if (!isGet && !isHead) {
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
      }
      return _htmlPage(
        request,
        status: 200,
        cacheControl: 'public, max-age=300',
        build: (String language) => buildHomePageHtml(language: language),
      );
    }
    if (!isGet && !isHead) {
      return shelf.Response(404, body: '');
    }
    return _htmlPage(
      request,
      status: 404,
      cacheControl: 'no-store',
      build: (String language) =>
          buildLinkNotFoundHtml(cutInvite: false, language: language),
    );
  }

  /// One of the C-615 pages: [build] renders it in the language
  /// `resolveVerifyLanguage` picks from the query and `Accept-Language`, so
  /// the response varies on that header. `HEAD` gets the same status and
  /// headers and an empty body.
  shelf.Response _htmlPage(
    shelf.Request request, {
    required int status,
    required String cacheControl,
    required String Function(String language) build,
  }) {
    final String language = resolveVerifyLanguage(
      query: request.url.queryParameters,
      acceptLanguageHeader: request.headers['accept-language'],
    );
    return shelf.Response(
      status,
      body: request.method == 'HEAD' ? '' : build(language),
      headers: <String, String>{
        'content-type': 'text/html; charset=utf-8',
        'vary': 'accept-language',
        'cache-control': cacheControl,
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'content-security-policy': _pageContentSecurityPolicy,
      },
    );
  }

  /// `GET /r/<id>` and `HEAD` of the same, never reaching the WebSocket
  /// upgrade path either (`docs/PROTOCOL.md` section 31 item 9). [rawCode] is
  /// whatever text matched the path pattern in [start]'s handler; it is a
  /// link id, matched exactly and never upper-cased. A live room's link id
  /// serves the invite page, which carries the link id and never the room
  /// code. Everything else answers the same `404` page. A six-character room
  /// code is no longer a room link: it is just an unknown id here.
  ///
  /// `room.js`, the page's one script, is matched first. The page's language
  /// is resolved once by [resolveVerifyLanguage], from the query and
  /// `Accept-Language`; the body depends on that header, hence `vary`.
  shelf.Response _handleRoomLink(shelf.Request request, String rawCode) {
    switch (request.method) {
      case 'GET':
      case 'HEAD':
        final bool isHead = request.method == 'HEAD';
        if (rawCode == 'room.js') {
          return shelf.Response.ok(
            isHead ? '' : roomLinkJsSource,
            headers: const <String, String>{
              'content-type': 'application/javascript; charset=utf-8',
              'cache-control': 'public, max-age=300',
              'x-content-type-options': 'nosniff',
            },
          );
        }
        // Section 31 item 9: the id is a link id, matched exactly. A live one
        // gets the invite page; anything else -- a finished or reaped room, a
        // former code, garbage -- gets the same not-found page, never a room.
        final Room? room = registry.lookupByLink(rawCode);
        if (room == null) {
          // Section 31 item 11 (c): a link-shaped id that is not live gets what
          // a well-formed unknown code gets, a 200; any other shape, a 404.
          return _htmlPage(
            request,
            status: isWellFormedLinkId(rawCode) ? 200 : 404,
            cacheControl: 'no-store',
            build: (String language) =>
                buildLinkNotFoundHtml(cutInvite: true, language: language),
          );
        }
        final String language = resolveVerifyLanguage(
          query: request.url.queryParameters,
          acceptLanguageHeader: request.headers['accept-language'],
        );
        return shelf.Response.ok(
          isHead
              ? ''
              : buildRoomLandingPageHtml(room.linkId, language: language),
          headers: const <String, String>{
            'content-type': 'text/html; charset=utf-8',
            'vary': 'accept-language',
            'cache-control': 'no-store',
            'x-content-type-options': 'nosniff',
            'referrer-policy': 'no-referrer',
            'content-security-policy': _pageContentSecurityPolicy,
          },
        );
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
    }
  }

  /// `GET`/`HEAD /v/verify.js`, `/v/verify.py`, `/v/<id>` and
  /// `/v/<id>.json`, never reaching the WebSocket upgrade path either.
  /// `docs/VERIFY.md` section 4: every one of these is `GET`/`HEAD` only,
  /// any other method a `405` naming `GET, HEAD`, and every response here
  /// carries `x-content-type-options: nosniff` and
  /// `referrer-policy: no-referrer` regardless of which of the four this
  /// turns out to be. [rest] is everything the path pattern matched after
  /// `/v/`, unvalidated -- deciding what it names, and whether that name is
  /// well-formed, is entirely this method's job from here on.
  shelf.Response _handleVerify(shelf.Request request, String rest) {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return shelf.Response(405, headers: const <String, String>{
        'allow': 'GET, HEAD',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
      });
    }
    final bool isHead = request.method == 'HEAD';

    if (rest == 'verify.js') {
      return _verifyScriptResponse(
        body: verifyJsSource,
        contentType: 'text/javascript; charset=utf-8',
        isHead: isHead,
      );
    }
    if (rest == 'verify.py') {
      return _verifyScriptResponse(
        body: verifyPySource,
        contentType: 'text/x-python; charset=utf-8',
        isHead: isHead,
      );
    }
    // `docs/VERIFY.md` section 4: anything under `/v/` that is not
    // `verify.js` or `verify.py` is answered as the row it most resembles --
    // a path ending in `.json` in any casing resembles the `.json` row, not
    // the page row, even though only an exact lowercase `.json` suffix on a
    // well-formed id can ever actually be found. So the case-insensitive
    // check below decides which row's not-found shape a mismatched case
    // gets; only the exact-case suffix is ever allowed to reach the store.
    if (rest.toLowerCase().endsWith(_verifyJsonSuffix)) {
      final bool exactSuffix = rest.endsWith(_verifyJsonSuffix);
      final String id = exactSuffix
          ? rest.substring(0, rest.length - _verifyJsonSuffix.length)
          : '';
      return _verifyJsonResponse(id: id, isHead: isHead);
    }
    return _verifyPageResponse(request: request, id: rest, isHead: isHead);
  }

  /// `verify.js` and `verify.py` never change once this process is running
  /// and never depend on any id, so both are always the "found" row of
  /// `docs/VERIFY.md` section 4's table: `200` and the five-minute cache,
  /// never a 404.
  shelf.Response _verifyScriptResponse({
    required String body,
    required String contentType,
    required bool isHead,
  }) {
    final Map<String, String> headers = <String, String>{
      'content-type': contentType,
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'cache-control': 'public, max-age=300',
    };
    return shelf.Response.ok(isHead ? '' : body, headers: headers);
  }

  /// `GET`/`HEAD /v/<id>.json`. [id] is whatever preceded the `.json` suffix
  /// in the matched path -- not yet checked against [isWellFormedGameId],
  /// which is the very next thing this method does, before anything of
  /// [id] ever reaches [RoomRegistry.verifyStore].
  shelf.Response _verifyJsonResponse(
      {required String id, required bool isHead}) {
    final String? stored =
        isWellFormedGameId(id) ? registry.verifyStore.load(id) : null;
    final Map<String, String> shared = <String, String>{
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'access-control-allow-origin': '*',
      'content-type': 'application/json',
    };
    if (stored == null) {
      return shelf.Response.notFound(
        isHead ? '' : '{"error":"not_found"}',
        headers: <String, String>{...shared, 'cache-control': 'no-store'},
      );
    }
    return shelf.Response.ok(
      isHead ? '' : stored,
      headers: <String, String>{
        ...shared,
        'cache-control': 'public, max-age=300',
      },
    );
  }

  /// `GET`/`HEAD /v/<id>`. Same validate-before-load rule as
  /// [_verifyJsonResponse], and the same not-found answer whether [id]
  /// failed [isWellFormedGameId] outright or was well-formed but has no
  /// record -- `docs/VERIFY.md` section 4 does not distinguish the two, and
  /// [buildVerifyNotFoundHtml] does not need to know which one happened.
  /// C-396: the page's language is resolved once here, from [request]'s own
  /// query and `Accept-Language` header, straight through to
  /// [resolveVerifyLanguage] -- this method does no language logic of its
  /// own beyond that handoff and the `vary` header every response here now
  /// carries, since the body depends on that header.
  shelf.Response _verifyPageResponse(
      {required shelf.Request request,
      required String id,
      required bool isHead}) {
    final String? stored =
        isWellFormedGameId(id) ? registry.verifyStore.load(id) : null;
    final String language = resolveVerifyLanguage(
      query: request.url.queryParameters,
      acceptLanguageHeader: request.headers['accept-language'],
    );
    final Map<String, String> shared = <String, String>{
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'content-type': 'text/html; charset=utf-8',
      'vary': 'accept-language',
      'content-security-policy': "default-src 'none'; script-src 'self'; "
          "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
          "frame-ancestors 'none'",
    };
    if (stored == null) {
      return shelf.Response.notFound(
        isHead ? '' : buildVerifyNotFoundHtml(language: language),
        headers: <String, String>{...shared, 'cache-control': 'no-store'},
      );
    }
    return shelf.Response.ok(
      isHead ? '' : buildVerifyPageHtml(stored, language: language),
      headers: <String, String>{
        ...shared,
        'cache-control': 'public, max-age=300',
      },
    );
  }

  /// Whole seconds since [start] completed, from the injected [clock]. Zero
  /// before [start] has completed and never negative afterwards, even if the
  /// clock is a test double that has not strictly advanced.
  int get _uptimeSeconds {
    final DateTime? startedAt = _startedAt;
    if (startedAt == null) {
      return 0;
    }
    final int seconds = clock.now.difference(startedAt).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  /// The client's IP, section 7's rate limits being scoped by it. The
  /// immediate TCP peer address unless that peer is a configured trusted
  /// proxy, in which case the leftmost address in `X-Forwarded-For` is
  /// believed instead -- trusting that header from an arbitrary peer would
  /// let anyone forge their way around every IP-scoped limit.
  String _clientIp(shelf.Request request) {
    final HttpConnectionInfo? info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final String remote = info?.remoteAddress.address ?? 'unknown';
    if (!_trustedProxies.contains(remote)) {
      return remote;
    }
    final String? forwarded = request.headers[forwardedForHeader];
    if (forwarded == null || forwarded.trim().isEmpty) {
      return remote;
    }
    return forwarded.split(',').first.trim();
  }
}

/// The `RoomHub` `connection.dart` depends on. Tracks, per room code, the
/// sockets currently attached to it, and the reverse mapping so a connection
/// can find its own room on detach without `connection.dart` exposing any
/// private state for that purpose.
class _ConnectionHub implements RoomHub {
  _ConnectionHub(this._registry);

  final RoomRegistry _registry;
  final Map<String, Set<Connection>> _byRoom = <String, Set<Connection>>{};
  final Map<Connection, String> _roomByConnection = <Connection, String>{};

  @override
  Connection? attach({required String code, required Connection conn}) {
    final String? previousRoom = _roomByConnection[conn];
    if (previousRoom != null && previousRoom != code) {
      _removeFromRoom(previousRoom, conn);
    }

    Connection? displaced;
    final Set<Connection>? current = _byRoom[code];
    if (current != null) {
      for (final Connection other in current) {
        if (!identical(other, conn) &&
            other.seatToken != null &&
            other.seatToken == conn.seatToken) {
          displaced = other;
          break;
        }
      }
    }
    if (displaced != null) {
      _removeFromRoom(code, displaced);
    }

    // Looked up only now, after the takeover removal: when the displaced
    // socket was the room's last one, _removeFromRoom has just dropped the
    // emptied set from _byRoom, and a set fetched before that would take
    // the new socket while no longer being the one broadcast reads.
    _byRoom.putIfAbsent(code, () => <Connection>{}).add(conn);
    _roomByConnection[conn] = code;
    return displaced;
  }

  @override
  void detach(Connection conn) {
    final String? code = _roomByConnection[conn];
    if (code == null) {
      return;
    }
    _removeFromRoom(code, conn);
  }

  @override
  void broadcast({
    required String code,
    required String type,
    required Map<String, Object?> data,
    Connection? exceptConn,
  }) {
    final Room? room = _registry.lookup(code);
    if (room != null) {
      if (type == 'game_started') {
        room.gameLog.clear();
        room.gameLog.add(<String, Object?>{
          't': type,
          'd': Map<String, Object?>.of(data),
        });
      } else if (type != 'emote' &&
          room.game != null &&
          room.state != RoomState.lobby) {
        // docs/PROTOCOL.md section 25 rule 5: an `emote` is not game
        // history, so section 17's log never holds one.
        room.gameLog.add(<String, Object?>{
          't': type,
          'd': Map<String, Object?>.of(data),
        });
      }
    }

    final Set<Connection>? sockets = _byRoom[code];
    if (sockets == null) {
      return;
    }
    // Copied because sendPush can, transitively, never mutate this set
    // itself, but iterating a live Set while a caller elsewhere detaches
    // from it is exactly the kind of concurrent-modification bug worth
    // paying one allocation to rule out.
    for (final Connection conn in List<Connection>.of(sockets)) {
      if (identical(conn, exceptConn)) {
        continue;
      }
      conn.sendPush(type: type, data: data);
    }
  }

  @override
  void sendToSeatToken({
    required String code,
    required String seatToken,
    required String type,
    required Map<String, Object?> data,
  }) {
    final Set<Connection>? sockets = _byRoom[code];
    if (sockets == null) {
      return;
    }
    for (final Connection conn in sockets) {
      if (conn.seatToken == seatToken) {
        conn.sendPush(type: type, data: data);
        return;
      }
    }
  }

  @override
  Connection? detachSeatToken({
    required String code,
    required String seatToken,
  }) {
    final Set<Connection>? sockets = _byRoom[code];
    if (sockets == null) {
      return null;
    }
    for (final Connection conn in sockets) {
      if (conn.seatToken == seatToken) {
        _removeFromRoom(code, conn);
        return conn;
      }
    }
    return null;
  }

  /// Section 37 item 2: detaches every socket attached to [code], seated or
  /// not, and returns them. Not on [RoomHub]: test doubles implement that
  /// interface, and only this class holds the sockets.
  List<Connection> detachRoom(String code) {
    final Set<Connection>? sockets = _byRoom.remove(code);
    if (sockets == null) {
      return <Connection>[];
    }
    for (final Connection conn in sockets) {
      _roomByConnection.remove(conn);
    }
    return List<Connection>.of(sockets);
  }

  void _removeFromRoom(String code, Connection conn) {
    final Set<Connection>? sockets = _byRoom[code];
    if (sockets == null) {
      return;
    }
    sockets.remove(conn);
    _roomByConnection.remove(conn);
    if (sockets.isEmpty) {
      _byRoom.remove(code);
    }
  }
}
