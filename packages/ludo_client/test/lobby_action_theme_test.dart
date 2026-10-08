// Lobby action theme gates: the full-room host Start control must stay a
// theme ElevatedButton (including an explicit disabled foreground on the
// theme), copy-link and copy-code must stay theme Outlined or Text buttons,
// and the host's lobby-waiting line (the count, once the room is short of
// full) must meet WCAG AA contrast against the lobby surface.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _startKey = Key('lobby-start-button');
const Key _waitingKey = Key('lobby-waiting');
const Key _copyLinkKey = Key('lobby-copy-link-button');
const Key _copyCodeKey = Key('lobby-copy-code-button');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'lobby-theme-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, {String name = 'Sam'}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport queued',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _localizations({required Widget home}) {
  return MaterialApp(
    theme: buildAppTheme(),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

Future<void> _pumpConnectedHostLobby(
  WidgetTester tester, {
  int seated = 1,
  int players = 4,
  bool expectStartButton = true,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    _localizations(
      home: LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: players,
      ),
    ),
  );
  await tester.pump();
  expect(transport.sentRaw, isNotEmpty);
  final String requestId = _idOf(transport.sentRaw.last);

  final List<Map<String, Object?>> seats = List<Map<String, Object?>>.generate(
    seated,
    (int i) => _seatJson(i, name: 'p$i'),
  );
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(players: players, hostSeat: 0, seats: seats),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(controller.phase, RoomPhase.connected);
  if (expectStartButton) {
    expect(find.byKey(_startKey), findsOneWidget);
  }
}

double _relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrastRatio(Color a, Color b) {
  final double lumA = _relativeLuminance(a);
  final double lumB = _relativeLuminance(b);
  final double lighter = lumA > lumB ? lumA : lumB;
  final double darker = lumA > lumB ? lumB : lumA;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Composites [foreground] over [background] when the label colour is
/// translucent (Material's default disabled opacity), so WCAG contrast is
/// measured on the colour a person actually sees.
Color _compositeOver(Color foreground, Color background) {
  final double a = foreground.a;
  if (a >= 1.0) {
    return foreground;
  }
  return Color.from(
    alpha: 1.0,
    red: foreground.r * a + background.r * (1.0 - a),
    green: foreground.g * a + background.g * (1.0 - a),
    blue: foreground.b * a + background.b * (1.0 - a),
  );
}

Color _waitingLabelForeground(WidgetTester tester) {
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byKey(_waitingKey),
      matching: find.byType(RichText),
    ),
  );
  final Color? color = paragraph.text.style?.color;
  if (color == null) {
    fail('lobby-waiting paragraph resolved no text colour');
  }
  return color;
}

Color _lobbySurface(WidgetTester tester) {
  final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
  final Color? background = scaffold.backgroundColor;
  if (background != null && background.a == 1.0) {
    return background;
  }
  return LudoColors.paper;
}

void main() {
  testWidgets(
    'host short of full: lobby-waiting contrast is at least 4.5:1 against '
    'surface, and lobby-start-button is absent',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(
        tester,
        seated: 3,
        players: 4,
        expectStartButton: false,
      );

      expect(
        find.byKey(_startKey),
        findsNothing,
        reason:
            'C-274: with 3 of 4 seats filled there is no lobby-start-button',
      );
      final Finder waiting = find.byKey(_waitingKey);
      expect(
        waiting,
        findsOneWidget,
        reason: 'C-274: a host short of full shows lobby-waiting',
      );
      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      final Text waitingText = tester.widget<Text>(waiting);
      expect(
        waitingText.data,
        loc.lobbyWaitingForPlayers(3, 4),
        reason:
            'lobby-waiting must read loc.lobbyWaitingForPlayers(3, 4); got '
            '"${waitingText.data}"',
      );

      final Color surface = _lobbySurface(tester);
      final Color rawForeground = _waitingLabelForeground(tester);
      final Color foreground = _compositeOver(rawForeground, surface);
      final double ratio = _contrastRatio(foreground, surface);

      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'lobby-waiting foreground $rawForeground '
            '(composited $foreground) on surface $surface measures '
            '$ratio:1, below the WCAG AA minimum of 4.5:1',
      );
    },
  );

  testWidgets(
    'full-room lobby Start uses theme ElevatedButton; copy actions use '
    'theme Outlined or TextButton styles',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(tester, seated: 4, players: 4);

      final Widget start = tester.widget(find.byKey(_startKey));
      expect(
        start,
        isA<ElevatedButton>(),
        reason:
            'lobby-start-button must be an ElevatedButton; found '
            '${start.runtimeType}',
      );

      for (final Key key in <Key>[_copyLinkKey, _copyCodeKey]) {
        final Widget action = tester.widget(find.byKey(key));
        expect(
          action is OutlinedButton || action is TextButton,
          isTrue,
          reason:
              '$key must be an OutlinedButton or TextButton; found '
              '${action.runtimeType}',
        );
      }

      final BuildContext context = tester.element(find.byKey(_startKey));
      final ButtonStyle? themeStyle = Theme.of(context)
          .elevatedButtonTheme
          .style;
      final Color? disabledForeground = themeStyle?.foregroundColor?.resolve(
        const <WidgetState>{WidgetState.disabled},
      );
      expect(
        disabledForeground,
        isNotNull,
        reason:
            'Theme elevatedButtonTheme must declare an explicit disabled '
            'foreground so lobby Start stays theme-aligned instead of the '
            'Material default faded onSurface',
      );

      final Color surface = Theme.of(context).colorScheme.surface;
      final double ratio = _contrastRatio(disabledForeground!, surface);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'theme elevatedButtonTheme disabled foreground '
            '$disabledForeground on surface $surface measures $ratio:1, '
            'below 4.5:1',
      );
    },
  );
}
