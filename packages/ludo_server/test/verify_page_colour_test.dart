// Tests for contract C-542 (work/ludo/orders/C-542-verify-page-seat-colours.md):
// the verify page names seats by their colour, never by the bare 0-based
// seat number. Drives a real WireServer the way test/verify_route_test.dart
// and test/verify_page_lang_test.dart do -- its own harness is copied by
// hand below, never imported. The returned HTML is parsed with RegExp and
// plain string checks only: package:html is not a dependency of this
// package. Assertions go at the winner line, the header cells and the seat
// cells; no case compares a whole pasted page.
//
// Written from the contract text alone, on origin/main ad1a97d, where none
// of D1, D2 or D3 exists yet: every case under those headings is red by
// design. The JSON byte-identity group, the wording group and the theme
// guard already hold on that commit and are green there; they pin what the
// contract says must not move.
//
// Every failure message carries a scenario line (page language, record
// seats, winner) and the offending fragment. The fixtures are fixed values,
// there is no seed: the scenario line is the whole reproduction.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// A well-formed (16 lowercase hex) id that a fixture record is saved
/// under, distinct from the ids the sibling verify tests use.
const String _foundId = 'c542c542c542c542';

const String _finishedAt = '2026-03-02T00:00:00Z';

/// The mapping C-542 fixes, from LudoColors.seats in the client theme:
/// seat index -> swatch, English word, Arabic word.
const List<String> _hex = <String>['#d32f2f', '#388e3c', '#fbc02d', '#1976d2'];
const List<String> _en = <String>['Red', 'Green', 'Yellow', 'Blue'];
const List<String> _ar = <String>['الأحمر', 'الأخضر', 'الأصفر', 'الأزرق'];

/// Words the page must never carry, taken from the sibling route test.
const List<String> _forbidden = <String>[
  'provably fair',
  'absolutely random',
  'odds',
  'bet ',
  'wager',
];

String _hexRun(String ch, int n) => List<String>.filled(n, ch).join();

/// A record in the shape docs/VERIFY.md section 1.1 pins. [seats] are the
/// values written into the seeds table, in order; the first seat is a
/// player seed and every other one is server-drawn. Rolls go round the
/// seats twice, so every seat has two rows in the rolls table. [winner]
/// and [seats] take any Object so a case can plant an out-of-range or
/// hostile value, the way test/verify_route_test.dart plants its seed.
Map<String, Object?> _record({
  required Object winner,
  List<Object> seats = const <Object>[0, 1, 2, 3],
}) {
  final List<Map<String, Object?>> seeds = <Map<String, Object?>>[
    for (var i = 0; i < seats.length; i++)
      <String, Object?>{
        'seat': seats[i],
        'seed': 'colour-seed-$i',
        'origin': i == 0 ? 'player' : 'server',
      },
  ];
  final List<Map<String, Object?>> rolls = <Map<String, Object?>>[
    for (var k = 1; k <= seats.length * 2; k++)
      <String, Object?>{
        'k': k,
        'seat': seats[(k - 1) % seats.length],
        'reveal': _hexRun('abcdef'[k % 6], 64),
        'die': (k % 6) + 1,
      },
  ];
  return <String, Object?>{
    'format': 1,
    'game_id': _foundId,
    'chain_commit': _hexRun('a', 64),
    'chain_index': 0,
    'chain_length': 2048,
    'client_seeds': <String>[
      for (var i = 0; i < seats.length; i++) '${seats[i]}:colour-seed-$i',
    ].join('|'),
    'seeds': seeds,
    'rolls': rolls,
    'winner': winner,
    'finished_at': _finishedAt,
  };
}

/// One running WireServer, its FakeClock, registry and VerifyStore. Built
/// fresh per test; nothing here is shared with, or edits, test/support/.
class _Harness {
  _Harness._(this.clock, this.registry, this.verifyStore, this.server);

  final FakeClock clock;
  final RoomRegistry registry;
  final VerifyStore verifyStore;
  final WireServer server;

  static _Harness build() {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 3, 2));
    final MemoryVerifyStore store = MemoryVerifyStore(clock);
    final RoomRegistry registry = RoomRegistry(
      clock: clock,
      secure: Random.secure(),
      verifyStore: store,
      verifyUrlBase: defaultVerifyUrlBase,
    );
    final RateLimiter rateLimiter = RateLimiter(clock: clock);
    final WireServer server = WireServer(
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
    );
    return _Harness._(clock, registry, store, server);
  }

  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  Uri uri(String path, {Map<String, String>? query}) => Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: path,
        queryParameters: query,
      );

  Future<void> close() => server.close();
}

class _Reply {
  _Reply(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final String body;
}

Future<_Reply> _get(
  HttpClient client,
  Uri uri, {
  Map<String, String>? headers,
}) async {
  final HttpClientRequest request = await client.getUrl(uri);
  headers?.forEach((String name, String value) {
    request.headers.set(name, value);
  });
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  return _Reply(response.statusCode, response.headers, body);
}

/// Tags removed, whitespace collapsed: what a reader sees on one line.
String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// A table cell: the attributes of its opening tag and its inner HTML.
class _Cell {
  _Cell(this.attrs, this.inner);

  final String attrs;
  final String inner;

  String get text => _text(inner);

  /// Every `<span aria-hidden="true" ...>` opening tag in the cell.
  List<String> get swatches => RegExp(
        r'<span\b[^>]*aria-hidden="true"[^>]*>',
        caseSensitive: false,
      ).allMatches(inner).map((Match m) => m.group(0)!).toList();

  @override
  String toString() => '<td$attrs>$inner</td>';
}

/// From [heading] to the next `</table>`, or a failure naming the heading.
String _tableAfter(String body, String heading, String scenario) {
  final int start = body.indexOf(heading);
  if (start == -1) {
    fail('expected the heading $heading on the page; $scenario');
  }
  final int end = body.indexOf('</table>', start);
  if (end == -1) {
    fail('expected a </table> after $heading; $scenario');
  }
  return body.substring(start, end);
}

List<String> _headers(String table) => RegExp(
      r'<th\b[^>]*>(.*?)</th>',
      dotAll: true,
    ).allMatches(table).map((Match m) => _text(m.group(1)!)).toList();

List<List<_Cell>> _rows(String table) {
  final List<List<_Cell>> rows = <List<_Cell>>[];
  for (final Match row
      in RegExp(r'<tr\b[^>]*>(.*?)</tr>', dotAll: true).allMatches(table)) {
    final List<_Cell> cells = RegExp(
      r'<td\b([^>]*)>(.*?)</td>',
      dotAll: true,
    ).allMatches(row.group(1)!).map((Match m) {
      return _Cell(m.group(1)!, m.group(2)!);
    }).toList();
    if (cells.isNotEmpty) {
      rows.add(cells);
    }
  }
  return rows;
}

/// The one paragraph that carries the winner line.
String _winnerParagraph(String body, String marker, String scenario) {
  for (final Match m
      in RegExp(r'<p\b[^>]*>(.*?)</p>', dotAll: true).allMatches(body)) {
    if (_text(m.group(1)!).contains(marker)) {
      return m.group(1)!;
    }
  }
  fail('expected a <p> carrying "$marker" (the winner line); $scenario');
}

/// Checks [tag] is the swatch of seat [seat]: its colour, a 1 px border.
void _expectSwatch(String tag, int seat, String scenario) {
  final String lower = tag.toLowerCase();
  expect(lower.contains(_hex[seat]), isTrue,
      reason: 'expected the swatch to be ${_hex[seat]} (seat $seat, '
          '${_en[seat]}); got $tag; $scenario');
  expect(lower.contains('border') && lower.contains('1px'), isTrue,
      reason: 'expected the swatch to carry a 1px border so yellow shows on '
          'the page background; got $tag; $scenario');
}

/// Reads the four `LudoColors.seats` hex values out of the client theme as
/// text, in order, lower-cased with a leading hash.
List<String> _themeSeatHex() {
  const List<String> candidates = <String>[
    '../ludo_client/lib/src/theme.dart',
    'packages/ludo_client/lib/src/theme.dart',
  ];
  File? file;
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      file = File(path);
      break;
    }
  }
  if (file == null) {
    fail('could not find the client theme from ${Directory.current.path}; '
        'tried $candidates');
  }
  final String source = file.readAsStringSync();
  final Match? list = RegExp(
    r'List<Color>\s+seats\s*=\s*<Color>\[(.*?)\];',
    dotAll: true,
  ).firstMatch(source);
  if (list == null) {
    fail('expected "List<Color> seats = <Color>[...];" in ${file.path}');
  }
  return RegExp(r'Color\(0xFF([0-9A-Fa-f]{6})\)')
      .allMatches(list.group(1)!)
      .map((Match m) => '#${m.group(1)!.toLowerCase()}')
      .toList();
}

void main() {
  late HttpClient client;
  _Harness? active;

  setUp(() {
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    if (active != null) {
      await active!.close();
      active = null;
    }
  });

  /// Saves [record] and fetches its page in [lang] ('en' or 'ar').
  Future<String> page(Map<String, Object?> record, String lang) async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();
    harness.verifyStore.save(_foundId, jsonEncode(record));
    final _Reply reply = await _get(
      client,
      harness.uri('/v/$_foundId', query: <String, String>{'lang': lang}),
    );
    expect(reply.status, 200,
        reason: 'expected 200 for the found page; lang=$lang, '
            'winner=${record['winner']}; body: ${reply.body}');
    return reply.body;
  }

  String scenario(String lang, Map<String, Object?> record) =>
      'scenario: lang=$lang, winner=${record['winner']}, seats='
      '${(record['seeds']! as List<Object?>).map((Object? s) => (s! as Map<String, Object?>)['seat']).toList()}';

  const Map<String, String> winnerMarker = <String, String>{
    'en': 'Winner',
    'ar': 'الفائز',
  };
  const Map<String, String> seedsHeading = <String, String>{
    'en': '<h2>Seeds</h2>',
    'ar': '<h2>البذور</h2>',
  };
  const Map<String, String> rollsHeading = <String, String>{
    'en': '<h2>Rolls</h2>',
    'ar': '<h2>الرميات</h2>',
  };
  const Map<String, List<String>> words = <String, List<String>>{
    'en': _en,
    'ar': _ar,
  };

  // ---------------------------------------------------------------------
  // D1: the winner line names the colour.
  // ---------------------------------------------------------------------
  group('D1: the winner line names the colour', () {
    for (final String lang in <String>['en', 'ar']) {
      for (var winner = 0; winner < 4; winner++) {
        final String word = words[lang]![winner];
        final String line = lang == 'en'
            ? 'Finished $_finishedAt UTC. Winner: $word.'
            : 'انتهت في $_finishedAt UTC. الفائز: $word.';

        test(
            '$lang, winner $winner: the line reads "$word" and keeps the '
            'finish time', () async {
          final Map<String, Object?> record = _record(winner: winner);
          final String body = await page(record, lang);
          final String sc = scenario(lang, record);
          final String paragraph =
              _winnerParagraph(body, winnerMarker[lang]!, sc);

          expect(_text(paragraph), line,
              reason: 'D1: expected the winner line to read "$line" (the '
                  'colour word for seat $winner, finish time unchanged); '
                  'got "${_text(paragraph)}"; $sc');
        });

        test(
            '$lang, winner $winner: the word is preceded by one decorative '
            'swatch in the seat colour', () async {
          final Map<String, Object?> record = _record(winner: winner);
          final String body = await page(record, lang);
          final String sc = scenario(lang, record);
          final String paragraph =
              _winnerParagraph(body, winnerMarker[lang]!, sc);

          final List<Match> swatches = RegExp(
            r'<span\b[^>]*aria-hidden="true"[^>]*>',
            caseSensitive: false,
          ).allMatches(paragraph).toList();
          expect(swatches.length, 1,
              reason: 'D1: expected exactly one aria-hidden="true" swatch '
                  'in the winner line; got ${swatches.length} in '
                  '$paragraph; $sc');
          _expectSwatch(swatches.single.group(0)!, winner, sc);
          expect(
            paragraph.indexOf(swatches.single.group(0)!),
            lessThan(paragraph.indexOf(word)),
            reason: 'D1: expected the swatch before the word "$word" in '
                '$paragraph; $sc',
          );
        });

        test(
            '$lang, winner $winner: no "Seat" and no المقعد anywhere in the '
            'page', () async {
          final Map<String, Object?> record = _record(winner: winner);
          final String body = await page(record, lang);
          final String sc = scenario(lang, record);

          expect(body.contains('Seat'), isFalse,
              reason: 'D1/D2/D3: expected no "Seat" text anywhere in the '
                  'page; found it at index ${body.indexOf('Seat')}: '
                  '"${body.substring(max(0, body.indexOf('Seat') - 40), min(body.length, body.indexOf('Seat') + 40))}"; $sc');
          expect(body.contains('المقعد'), isFalse,
              reason: 'D1/D2/D3: expected no "المقعد" text anywhere in the '
                  'page; $sc');
        });
      }
    }
  });

  // ---------------------------------------------------------------------
  // D2: both tables name the colour, carry data-seat, say Player.
  // ---------------------------------------------------------------------
  group('D2: the seeds and rolls tables name the colour', () {
    const List<int> twoSeats = <int>[0, 2];
    const Map<String, List<String>> playerHeader = <String, List<String>>{
      'en': <String>['Player'],
      'ar': <String>['اللاعب'],
    };

    for (final String lang in <String>['en', 'ar']) {
      test(
          '$lang: header cell of the seeds table is "${playerHeader[lang]!.single}"',
          () async {
        final Map<String, Object?> record = _record(winner: 0, seats: twoSeats);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);
        final List<String> headers =
            _headers(_tableAfter(body, seedsHeading[lang]!, sc));

        final List<String> expected = lang == 'en'
            ? <String>['Player', 'Seed', 'Origin']
            : <String>['اللاعب', 'البذرة', 'المصدر'];
        expect(headers, expected,
            reason: 'D2: expected the seeds table headers $expected (the '
                'Seat column becomes ${playerHeader[lang]!.single}, the '
                'others stay); got $headers; $sc');
      });

      test(
          '$lang: header cell of the rolls table is "${playerHeader[lang]!.single}"',
          () async {
        final Map<String, Object?> record = _record(winner: 0, seats: twoSeats);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);
        final List<String> headers =
            _headers(_tableAfter(body, rollsHeading[lang]!, sc));

        final List<String> expected = lang == 'en'
            ? <String>['k', 'Player', 'Die', 'Reveal']
            : <String>['k', 'اللاعب', 'النرد', 'الكشف'];
        expect(headers.take(4).toList(), expected,
            reason: 'D2: expected the rolls table headers to start with '
                '$expected (the Seat column becomes '
                '${playerHeader[lang]!.single}, the others stay); got '
                '$headers; $sc');
      });

      test(
          '$lang: two-seat record, seeds rows read ${words[lang]![0]} and '
          '${words[lang]![2]} with data-seat 0 and 2', () async {
        final Map<String, Object?> record = _record(winner: 0, seats: twoSeats);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);
        final List<List<_Cell>> rows =
            _rows(_tableAfter(body, seedsHeading[lang]!, sc));

        expect(rows.length, 2,
            reason: 'expected two rows in the seeds table; got '
                '${rows.length}; $sc');
        final List<_Cell> seatCells =
            rows.map((List<_Cell> r) => r.first).toList();
        expect(
          seatCells.map((_Cell c) => c.text).toList(),
          <String>[words[lang]![0], words[lang]![2]],
          reason: 'D2: expected the seat cells to read '
              '${words[lang]![0]} and ${words[lang]![2]}; got '
              '$seatCells; $sc',
        );
        expect(seatCells[0].attrs.contains('data-seat="0"'), isTrue,
            reason: 'D2: expected data-seat="0" on the first seat cell; '
                'got $seatCells; $sc');
        expect(seatCells[1].attrs.contains('data-seat="2"'), isTrue,
            reason: 'D2: expected data-seat="2" on the second seat cell; '
                'got $seatCells; $sc');
        for (var i = 0; i < 2; i++) {
          final List<String> swatches = seatCells[i].swatches;
          expect(swatches.length, 1,
              reason: 'D2: expected one swatch in seat cell $i; got '
                  '${seatCells[i]}; $sc');
          _expectSwatch(swatches.single, twoSeats[i], sc);
        }
      });

      test(
          '$lang: two-seat record, every rolls row names its seat and '
          'carries data-seat', () async {
        final Map<String, Object?> record = _record(winner: 0, seats: twoSeats);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);
        final List<List<_Cell>> rows =
            _rows(_tableAfter(body, rollsHeading[lang]!, sc));
        final List<Map<String, Object?>> rolls =
            (record['rolls']! as List<Object?>).cast<Map<String, Object?>>();

        expect(rows.length, rolls.length,
            reason: 'expected ${rolls.length} rows in the rolls table; '
                'got ${rows.length}; $sc');
        for (var i = 0; i < rolls.length; i++) {
          final int seat = rolls[i]['seat']! as int;
          final _Cell cell = rows[i][1];
          expect(cell.text, words[lang]![seat],
              reason: 'D2: expected rolls row $i (k=${rolls[i]['k']}) to '
                  'read ${words[lang]![seat]}; got $cell; $sc');
          expect(cell.attrs.contains('data-seat="$seat"'), isTrue,
              reason: 'D2: expected data-seat="$seat" on rolls row $i; '
                  'got $cell; $sc');
          expect(cell.swatches.length, 1,
              reason: 'D2: expected one swatch on rolls row $i; got '
                  '$cell; $sc');
          _expectSwatch(cell.swatches.single, seat, sc);
        }
      });

      test(
          '$lang: the colour cell follows the page direction, no dir="ltr" '
          'on it, in either table', () async {
        final Map<String, Object?> record = _record(winner: 0, seats: twoSeats);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);
        final List<_Cell> seedCells =
            _rows(_tableAfter(body, seedsHeading[lang]!, sc))
                .map((List<_Cell> r) => r.first)
                .toList();
        final List<_Cell> rollCells =
            _rows(_tableAfter(body, rollsHeading[lang]!, sc))
                .map((List<_Cell> r) => r[1])
                .toList();

        for (final _Cell cell in <_Cell>[...seedCells, ...rollCells]) {
          expect(cell.text, isIn(words[lang]!),
              reason: 'D2: expected a colour word in the seat cell, so the '
                  'dir check below is about the right cell; got $cell; $sc');
          expect(cell.attrs.contains('dir="ltr"'), isFalse,
              reason: 'D2: the colour word cell must follow the page '
                  'direction, not carry dir="ltr"; got $cell; $sc');
        }
      });

      test(
          '$lang: four-seat record, the seeds table names all four colours '
          'in seat order with their data-seat', () async {
        final Map<String, Object?> record = _record(winner: 3);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);
        final List<_Cell> cells =
            _rows(_tableAfter(body, seedsHeading[lang]!, sc))
                .map((List<_Cell> r) => r.first)
                .toList();

        expect(cells.map((_Cell c) => c.text).toList(), words[lang]!,
            reason: 'D2: expected ${words[lang]!} down the seeds table; got '
                '$cells; $sc');
        for (var seat = 0; seat < 4; seat++) {
          expect(cells[seat].attrs.contains('data-seat="$seat"'), isTrue,
              reason: 'D2: expected data-seat="$seat" on row $seat; got '
                  '${cells[seat]}; $sc');
        }
      });
    }
  });

  // ---------------------------------------------------------------------
  // D3: the server-drawn seed line says player, not seat.
  // ---------------------------------------------------------------------
  group('D3: the server-drawn seed line says player', () {
    const Map<String, String> drawn = <String, String>{
      'en': 'drawn by the server: this player added no randomness of their '
          'own',
      'ar': 'سحبها الخادم: هذا اللاعب لم يضف عشوائية من عنده',
    };
    const Map<String, String> oldDrawn = <String, String>{
      'en': 'drawn by the server: this seat added no randomness of its own',
      'ar': 'سحبها الخادم: هذا المقعد لم يضف عشوائية من عنده',
    };
    const Map<String, String> chosen = <String, String>{
      'en': 'chosen by this player',
      'ar': 'اختارها هذا اللاعب',
    };

    for (final String lang in <String>['en', 'ar']) {
      test(
          '$lang: the server-drawn row carries the player wording and not '
          'the seat wording', () async {
        final Map<String, Object?> record =
            _record(winner: 0, seats: const <int>[0, 2]);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);

        expect(_text(body).contains(drawn[lang]!), isTrue,
            reason: 'D3: expected the line "${drawn[lang]}" for the '
                'server-drawn seed; $sc');
        expect(_text(body).contains(oldDrawn[lang]!), isFalse,
            reason: 'D3: the old line "${oldDrawn[lang]}" must be gone; '
                '$sc');
      });

      test('$lang: the player-chosen origin line is unchanged', () async {
        final Map<String, Object?> record =
            _record(winner: 0, seats: const <int>[0, 2]);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);

        expect(_text(body).contains(chosen[lang]!), isTrue,
            reason: 'expected the other origin line "${chosen[lang]}" to '
                'stay as it was; $sc');
      });
    }
  });

  // ---------------------------------------------------------------------
  // Defence: a seat outside 0..3 prints its escaped value, no swatch.
  // ---------------------------------------------------------------------
  group('a seat value outside 0..3 prints as it is, with no swatch', () {
    for (final String lang in <String>['en', 'ar']) {
      for (final int odd in <int>[4, 7, -1]) {
        test('$lang: seat $odd in both tables and as the winner', () async {
          final Map<String, Object?> record =
              _record(winner: odd, seats: <int>[0, odd]);
          final String body = await page(record, lang);
          final String sc = scenario(lang, record);

          final String paragraph =
              _winnerParagraph(body, winnerMarker[lang]!, sc);
          final String expectedLine = lang == 'en'
              ? 'Finished $_finishedAt UTC. Winner: $odd.'
              : 'انتهت في $_finishedAt UTC. الفائز: $odd.';
          expect(_text(paragraph), expectedLine,
              reason: 'expected the winner line to print the bare value '
                  '$odd; got "${_text(paragraph)}"; $sc');
          expect(paragraph.contains('aria-hidden'), isFalse,
              reason: 'expected no swatch in the winner line for seat '
                  '$odd; got $paragraph; $sc');

          final List<_Cell> seedCells =
              _rows(_tableAfter(body, seedsHeading[lang]!, sc))
                  .map((List<_Cell> r) => r.first)
                  .toList();
          expect(seedCells.length, 2,
              reason: 'expected two seeds rows; got $seedCells; $sc');
          expect(seedCells[1].text, '$odd',
              reason: 'expected the seeds cell to print $odd; got '
                  '${seedCells[1]}; $sc');
          expect(seedCells[1].swatches, isEmpty,
              reason: 'expected no swatch on seat $odd; got '
                  '${seedCells[1]}; $sc');
          // The in-range neighbour still gets its colour, so a page that
          // dropped every swatch does not pass the case above by accident.
          expect(seedCells[0].text, words[lang]![0],
              reason: 'expected seat 0 beside it to read '
                  '${words[lang]![0]}; got ${seedCells[0]}; $sc');
          expect(seedCells[0].swatches.length, 1,
              reason: 'expected seat 0 to keep its swatch; got '
                  '${seedCells[0]}; $sc');

          final List<_Cell> rollCells =
              _rows(_tableAfter(body, rollsHeading[lang]!, sc))
                  .map((List<_Cell> r) => r[1])
                  .toList();
          expect(rollCells.length, 4,
              reason: 'expected four rolls rows; got $rollCells; $sc');
          for (var i = 0; i < rollCells.length; i++) {
            if (i.isEven) {
              expect(rollCells[i].text, words[lang]![0],
                  reason: 'expected rolls row $i to read '
                      '${words[lang]![0]}; got ${rollCells[i]}; $sc');
            } else {
              expect(rollCells[i].text, '$odd',
                  reason: 'expected rolls row $i to print $odd; got '
                      '${rollCells[i]}; $sc');
              expect(rollCells[i].swatches, isEmpty,
                  reason: 'expected no swatch on rolls row $i; got '
                      '${rollCells[i]}; $sc');
            }
          }
        });
      }

      test(
          '$lang: a hostile seat value is escaped, in the cell and the '
          'attribute', () async {
        const String hostile = '"><i>x</i>';
        final Map<String, Object?> record =
            _record(winner: 0, seats: <Object>[0, hostile]);
        final String body = await page(record, lang);
        final String sc = scenario(lang, record);

        expect(body.contains('<i>x</i>'), isFalse,
            reason: 'the planted markup must not survive unescaped '
                'anywhere in the page; $sc');
        expect(body.contains('"><i>'), isFalse,
            reason: 'the planted attribute break-out must not survive; '
                '$sc');
        final List<_Cell> seedCells =
            _rows(_tableAfter(body, seedsHeading[lang]!, sc))
                .map((List<_Cell> r) => r.first)
                .toList();
        expect(seedCells[1].swatches, isEmpty,
            reason: 'expected no swatch on a non-numeric seat; got '
                '${seedCells[1]}; $sc');
        expect(seedCells[1].inner.contains('&lt;i&gt;x'), isTrue,
            reason: 'expected the escaped value in the seat cell; got '
                '${seedCells[1]}; $sc');
      });
    }
  });

  // ---------------------------------------------------------------------
  // What does not move.
  // ---------------------------------------------------------------------
  group('the JSON route and the record do not move', () {
    for (final int winner in <int>[0, 1, 2, 3, 7]) {
      test(
          '/v/<id>.json for a record won by seat $winner is the encoder '
          'output, with and without a language', () async {
        final Map<String, Object?> record = _record(winner: winner);
        final String encoded = jsonEncode(record);
        final _Harness harness = _Harness.build();
        active = harness;
        await harness.start();
        harness.verifyStore.save(_foundId, encoded);
        final String sc = scenario('json', record);

        final _Reply plain =
            await _get(client, harness.uri('/v/$_foundId.json'));
        final _Reply arabic = await _get(
          client,
          harness
              .uri('/v/$_foundId.json', query: <String, String>{'lang': 'ar'}),
          headers: <String, String>{'Accept-Language': 'ar'},
        );

        expect(plain.body, encoded,
            reason: 'the .json body must be byte-identical to the record '
                'encoder output; $sc');
        expect(arabic.body, encoded,
            reason: 'the .json body must not change with ?lang=ar or '
                'Accept-Language: ar; $sc');
        final Map<String, Object?> decoded =
            jsonDecode(plain.body)! as Map<String, Object?>;
        expect(decoded['winner'], winner,
            reason: 'the record keeps the winner as an integer; $sc');
        for (final Object? seed in decoded['seeds']! as List<Object?>) {
          expect((seed! as Map<String, Object?>)['seat'], isA<int>(),
              reason: 'the record keeps every seeds seat as an integer; '
                  '$sc');
        }
        for (final Object? roll in decoded['rolls']! as List<Object?>) {
          expect((roll! as Map<String, Object?>)['seat'], isA<int>(),
              reason: 'the record keeps every rolls seat as an integer; '
                  '$sc');
        }
      });
    }

    for (final String lang in <String>['en', 'ar']) {
      test(
          '$lang: the record embedded in the page still decodes to the '
          'record', () async {
        final Map<String, Object?> record = _record(winner: 2);
        final String body = await page(record, lang);
        final Match? match = RegExp(
          r'<script type="application/json" id="record">(.*?)</script>',
          dotAll: true,
        ).firstMatch(body);

        expect(match, isNotNull,
            reason:
                'expected the embedded record script; ${scenario(lang, record)}');
        expect(jsonDecode(match!.group(1)!.replaceAll('&lt;', '<')), record,
            reason: 'the embedded record must be the record, unchanged; '
                '${scenario(lang, record)}');
      });

      test(
          '$lang: the wording rule still holds with the colour words on '
          'the page', () async {
        final Map<String, Object?> record = _record(winner: 1);
        final String body = await page(record, lang);
        final String lower = body.toLowerCase();

        for (final String word in _forbidden) {
          expect(lower.contains(word), isFalse,
              reason: 'the forbidden word "$word" must never appear; '
                  '${scenario(lang, record)}');
        }
      });
    }
  });

  group('the page cannot drift from the board', () {
    test(
        'LudoColors.seats in the client theme, in order, are the swatch '
        'colours', () {
      expect(_themeSeatHex(), _hex,
          reason: 'C-542 fixes the swatches to the four LudoColors.seats '
              'values of packages/ludo_client/lib/src/theme.dart, in seat '
              'order; if the theme changed, the contract table and the '
              'page swatches change with it');
    });
  });
}
