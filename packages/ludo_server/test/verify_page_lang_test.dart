// Tests for contract C-396 (work/ludo/orders/C-396-verify-page-arabic.md):
// the verify page picks a language and says the verdict first. Drives a
// real WireServer the way test/verify_route_test.dart does -- its own
// harness is copied by hand below, never imported, per the order's own
// instruction. The returned HTML is parsed with RegExp and plain string
// checks only, the same way that file does: package:html is not a
// dependency of this package.
//
// Cut from ffe63fd. On that commit decisions 1, 2, 4, 6 and the
// data-attribute half of 5 do not exist yet, so every case grouped under
// those headings below is red by design; decisions 3, the fallback half of
// 5, 7 and 8 already hold on ffe63fd and are green there. See
// work/ludo/orders/396-verify-page-arabic-tests.md for the full red/green
// split this file is meant to produce.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// A well-formed (16 lowercase hex) id that a fixture record is saved
/// under. Distinct from every id test/verify_route_test.dart uses, though
/// that would not matter either way -- each test here gets its own
/// in-process server and store.
const String _foundId = 'c396c396c396c396';

/// A well-formed id that is never saved under.
const String _unknownId = 'eeeeeeeeeeeeeeee';

String _hexRun(String ch, int n) => List<String>.filled(n, ch).join();

/// A record in the shape docs/VERIFY.md section 1.1 pins. Two rolls, one
/// per seat, so "each reveal" (decision 2) has more than one value to
/// check. Nothing here needs to be cryptographically real -- this file
/// never asks a checker to verify it, only renders it.
Map<String, Object?> _record({required String gameId, required int winner}) {
  return <String, Object?>{
    'format': 1,
    'game_id': gameId,
    'chain_commit': _hexRun('a', 64),
    'chain_index': 0,
    'chain_length': 2048,
    'client_seeds': '0:lang-seed-alpha|1:lang-seed-beta',
    'seeds': <Map<String, Object?>>[
      <String, Object?>{
        'seat': 0,
        'seed': 'lang-seed-alpha',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'lang-seed-beta',
        'origin': 'server',
      },
    ],
    'rolls': <Map<String, Object?>>[
      <String, Object?>{
        'k': 1,
        'seat': 0,
        'reveal': _hexRun('b', 64),
        'die': 4,
      },
      <String, Object?>{
        'k': 2,
        'seat': 1,
        'reveal': _hexRun('c', 64),
        'die': 2,
      },
    ],
    'winner': winner,
    'finished_at': '2026-03-02T00:00:00Z',
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

  static _Harness build({String verifyUrlBase = defaultVerifyUrlBase}) {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 3, 2));
    final MemoryVerifyStore store = MemoryVerifyStore(clock);
    final RoomRegistry registry = RoomRegistry(
      clock: clock,
      secure: Random.secure(),
      verifyStore: store,
      verifyUrlBase: verifyUrlBase,
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

Future<HttpClientResponse> _send(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  Map<String, String>? headers,
}) async {
  final HttpClientRequest request = await client.openUrl(method, uri);
  headers?.forEach((String name, String value) {
    request.headers.set(name, value);
  });
  return request.close();
}

Future<String> _bodyOf(HttpClientResponse response) =>
    response.transform(utf8.decoder).join();

// ---------------------------------------------------------------------
// Decision 2: strings from "The Arabic text" table in C-396, split by
// which page they belong to. Only the rows that belong on the found page
// (buildVerifyPageHtml) are listed under `_arabicOnFoundPage` /
// `_englishReplacedOnFoundPage`; the not-found-only rows are listed
// separately for the decision-1/decision-6 not-found checks.
// ---------------------------------------------------------------------

/// Arabic strings the contract's table pins for the found page, decision
/// 2's "every Arabic string in the contract's table that belongs on the
/// page". `{id}`, `{time}` and `{n}` placeholders are filled with this
/// file's own fixture values where the sentence embeds one.
List<String> _arabicOnFoundPage(String gameId) => <String>[
      'التحقق من اللعبة $gameId - Ludo RNG',
      'اللعبة $gameId',
      'انتهت في 2026-03-02T00:00:00Z UTC. الفائز: المقعد 1.',
      'ما الذي تثبته هذه الصفحة',
      'ثبّت الخادم كل رميات هذه اللعبة قبل أن تبدأ، ولم يكن بإمكانه تغيير '
          'أي منها بعد ذلك.',
      'بعد هذا التثبيت دُمجت بذور اللاعبين أنفسهم في كل رمية، فلم يكن '
          'بإمكان الخادم أن يختار النتائج التي يريدها.',
      'لم يُنشر سرّ أي رمية قبل أن تحدث.',
      'ما الذي لا تثبته',
      'أن سرّ الخادم نفسه جاء من مصدر عشوائية جيد. الحل الوحيد لذلك منارة '
          'عشوائية من طرف ثالث أو نسخة خاضعة للتدقيق، ولا يوجد أي منهما هنا.',
      'التثبيت',
      'تثبيت السلسلة:',
      'طول السلسلة:',
      'البذور',
      'اختارها هذا اللاعب',
      'سحبها الخادم: هذا المقعد لم يضف عشوائية من عنده',
      'الرميات',
      'لم يُفحص',
      'لم يتم التحقق بعد',
      'تحقق بنفسك',
      'لا تأخذ كلام هذه الصفحة على أي مما سبق. شغّل الفحوص نفسها على '
          'جهازك، من الكود المنشور، دون الاعتماد على أي شيء من هذه الصفحة:',
      'الكود:',
      'يُحفظ هذا السجل 90 يومًا بعد انتهاء اللعبة.',
    ];

/// The English sentence each entry of [_arabicOnFoundPage] replaces, same
/// order, for decision 2's "none of the English sentences it replaces
/// appears".
List<String> _englishReplacedOnFoundPage(String gameId) => <String>[
      'Verify game $gameId - Ludo RNG',
      'Game $gameId',
      'Finished 2026-03-02T00:00:00Z UTC. Winner: Seat 1.',
      'What this proves',
      'The server fixed every roll of this game before the game began, and\n'
          'could not change any of them afterwards.',
      "The players' own seeds were mixed into every roll after that\n"
          'commitment, so the server could not have chosen the outcomes it '
          'wanted.',
      "No roll's secret was published before that roll happened.",
      'What this does not prove',
      "That the server's own secret came from a good source of randomness. "
          'The\n'
          'only fixes for that are a third-party randomness beacon or an '
          'audited\n'
          'build, and neither is in place here.',
      'Commitment',
      'Chain commitment:',
      'Chain length:',
      'Seeds',
      'chosen by this player',
      'drawn by the server: this seat added no randomness of its own',
      'Rolls',
      'not checked',
      // "not checked" (summary) is the same literal string as the cell
      // text above on ffe63fd, so it is not repeated as a second entry;
      // the ar-side list below also lists its one Arabic counterpart only
      // once per distinct English source string.
      'Check it yourself',
      'Do not take this page\'s word for any of the above. Run the same '
          'checks\n'
          'on your own machine, from the published source, with nothing '
          'borrowed from\n'
          'this page:',
      'Source:',
      'This record is kept for 90 days after the game ends.',
    ];

/// Every English sentence buildVerifyPageHtml renders on ffe63fd, read
/// off packages/ludo_server/lib/src/verify_page.dart verbatim, for
/// decision 3 ("the English page keeps every sentence it has today, word
/// for word").
List<String> _englishSentencesOnFfe63fd(String gameId) => <String>[
      'Verify game $gameId - Ludo RNG',
      'Game $gameId',
      'Finished 2026-03-02T00:00:00Z UTC. Winner: Seat 1.',
      'What this proves',
      'The server fixed every roll of this game before the game began, and\n'
          'could not change any of them afterwards.',
      "The players' own seeds were mixed into every roll after that\n"
          'commitment, so the server could not have chosen the outcomes it '
          'wanted.',
      "No roll's secret was published before that roll happened.",
      'What this does not prove',
      "That the server's own secret came from a good source of randomness. "
          'The\n'
          'only fixes for that are a third-party randomness beacon or an '
          'audited\n'
          'build, and neither is in place here.',
      'Commitment',
      'Chain commitment:',
      'Chain length:',
      'Seeds',
      'chosen by this player',
      'drawn by the server: this seat added no randomness of its own',
      'Rolls',
      'not checked',
      'Check it yourself',
      'Do not take this page\'s word for any of the above. Run the same '
          'checks\n'
          'on your own machine, from the published source, with nothing '
          'borrowed from\n'
          'this page:',
      'curl -sO https://provefair.app/v/verify.py &amp;&amp; python3\n'
          'verify.py $gameId',
      'Source:',
      'https://github.com/sam27697/ludo',
      'This record is kept for 90 days after the game ends.',
    ];

/// Finds every `<tag ... dir="ltr" ...>INNER</tag>` run (no nested tags
/// inside INNER) in [html] and returns the INNER texts, for decision 2's
/// "stay left-to-right inside the RTL page, each in an element with
/// dir="ltr"".
List<String> _ltrElementContents(String html) {
  final RegExp pattern = RegExp(
    r'<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*\bdir="ltr"[^>]*>([^<]*)</\1>',
  );
  return pattern
      .allMatches(html)
      .map((Match m) => m.group(2)!)
      .toList(growable: false);
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

  Future<_Harness> harnessWithFixture() async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();
    harness.verifyStore.save(
        _foundId,
        jsonEncode(_record(
          gameId: _foundId,
          winner: 1,
        )));
    return harness;
  }

  // ---------------------------------------------------------------------
  // Decision 1: language choice.
  // ---------------------------------------------------------------------
  group('decision 1: the page picks its language', () {
    test('no lang query, no Accept-Language header: en', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="en">'), isTrue,
          reason: 'decision 1: with no lang query and no Accept-Language '
              'header the page must default to English '
              '(<html lang="en">); body: $body');
    });

    test('?lang=ar with no Accept-Language header: ar', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 1: ?lang=ar must select the Arabic page '
              '(<html lang="ar" dir="rtl">) regardless of Accept-Language; '
              'body: $body');
    });

    test('?lang=en overrides Accept-Language: ar', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'en'}),
        headers: <String, String>{'Accept-Language': 'ar'},
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="en">'), isTrue,
          reason: 'decision 1: an explicit ?lang=en must win over an '
              'Accept-Language: ar header, since the query parameter is '
              'checked first; body: $body');
    });

    test(
        'Accept-Language: ar-AE,ar;q=0.9,en;q=0.8 (no query): ar, highest-q '
        'ar tag wins', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId'),
        headers: <String, String>{
          'Accept-Language': 'ar-AE,ar;q=0.9,en;q=0.8',
        },
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 1: "ar-AE,ar;q=0.9,en;q=0.8" has its '
              'highest-q acceptable tag ("ar-AE", q=1 implicit) with '
              'primary subtag ar, so the page must be Arabic; body: $body');
    });

    test('Accept-Language: fr-FR,en;q=0.5 (no query): en, fr is not ar/en',
        () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId'),
        headers: <String, String>{'Accept-Language': 'fr-FR,en;q=0.5'},
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="en">'), isTrue,
          reason: 'decision 1: "fr-FR,en;q=0.5" has no ar tag at all and '
              'its only ar/en-primary tag is en, so the page must be '
              'English; body: $body');
    });

    test(
        'Accept-Language: en;q=0.2,ar;q=0.8 (no query): ar, the higher-q '
        'tag wins even though it is listed second', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId'),
        headers: <String, String>{'Accept-Language': 'en;q=0.2,ar;q=0.8'},
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 1: q-values, not list order, must decide -- '
              '"en;q=0.2,ar;q=0.8" must pick ar (q=0.8) over en (q=0.2) '
              'even though en is listed first; body: $body');
    });

    test('?lang=xx (unrecognised) falls through to Accept-Language: ar',
        () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'xx'}),
        headers: <String, String>{'Accept-Language': 'ar'},
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 1: "anything else ignored" for ?lang means '
              '?lang=xx must be treated as if no query parameter were '
              'given at all, falling through to Accept-Language: ar; '
              'body: $body');
    });

    test('the not-found page follows the same rule: ?lang=ar selects ar',
        () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_unknownId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 1: the not-found page picks its language by '
              'the same rule as the found page, so ?lang=ar must select '
              '<html lang="ar" dir="rtl"> here too; body: $body');
    });

    test(
        'the not-found page follows the same rule: Accept-Language: '
        'ar-AE,ar;q=0.9,en;q=0.8 selects ar with no query', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_unknownId'),
        headers: <String, String>{
          'Accept-Language': 'ar-AE,ar;q=0.9,en;q=0.8',
        },
      );
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 1: the not-found page must honour '
              'Accept-Language the same way the found page does; body: '
              '$body');
    });

    test(
        'found page: vary: accept-language is present (header name '
        'compared case-insensitively)', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      await _bodyOf(response);

      final String? vary = response.headers.value('vary');
      expect(vary, isNotNull,
          reason: 'decision 1: the found page must carry a vary header');
      expect(vary!.toLowerCase(), 'accept-language',
          reason: 'decision 1: vary must name accept-language (case '
              'folded for comparison); got vary: "$vary"');
    });

    test(
        'not-found page: vary: accept-language is present (header name '
        'compared case-insensitively)', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_unknownId'));
      await _bodyOf(response);

      final String? vary = response.headers.value('vary');
      expect(vary, isNotNull,
          reason: 'decision 1: the not-found page must carry a vary '
              'header too');
      expect(vary!.toLowerCase(), 'accept-language',
          reason: 'decision 1: vary must name accept-language (case '
              'folded for comparison); got vary: "$vary"');
    });

    test('HEAD /v/<id>?lang=ar has an empty body', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
        method: 'HEAD',
      );
      final String body = await _bodyOf(response);

      expect(body, isEmpty,
          reason: 'decision 1: HEAD must answer as today -- no body -- '
              'even when a language is selected; got "$body"');
    });
  });

  // ---------------------------------------------------------------------
  // Decision 2: the Arabic page, mirrored.
  // ---------------------------------------------------------------------
  group('decision 2: the Arabic page is a whole page, mirrored', () {
    test('<html lang="ar" dir="rtl">', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      expect(body.contains('<html lang="ar" dir="rtl">'), isTrue,
          reason: 'decision 2: the ar page\'s <html> tag must carry '
              'lang="ar" and dir="rtl"; body: $body');
    });

    test('every Arabic sentence the contract pins for this page appears',
        () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      for (final String arabic in _arabicOnFoundPage(_foundId)) {
        expect(body.contains(arabic), isTrue,
            reason: 'decision 2: expected the Arabic text "$arabic" '
                '(C-396, "The Arabic text" table) somewhere on the ar '
                'page; a mutation that drops or mistranslates one row of '
                'that table must fail here; body: $body');
      }
    });

    test(
        'none of the English sentences the Arabic text replaces appears '
        'on the ar page', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      for (final String english in _englishReplacedOnFoundPage(_foundId)) {
        expect(body.contains(english), isFalse,
            reason: 'decision 2: the English sentence "$english" must not '
                'survive on the ar page -- a mutation that falls back to '
                'English for one row while claiming to have translated it '
                'must fail here; body: $body');
      }
    });

    test(
        'the game id, chain commitment and each reveal are each inside an '
        'element carrying dir="ltr"', () async {
      final _Harness harness = await harnessWithFixture();
      final Map<String, Object?> record = _record(gameId: _foundId, winner: 1);
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);
      final List<String> ltrContents = _ltrElementContents(body);

      expect(
        ltrContents.any((String c) => c.contains(_foundId)),
        isTrue,
        reason: 'decision 2: the game id ($_foundId) must appear inside '
            'an element carrying dir="ltr" so it never reorders inside '
            'the RTL page; ltr element contents found: $ltrContents; '
            'full body: $body',
      );
      expect(
        ltrContents.any(
          (String c) => c.contains(record['chain_commit']! as String),
        ),
        isTrue,
        reason: 'decision 2: the chain commitment must appear inside a '
            'dir="ltr" element; ltr element contents found: $ltrContents; '
            'full body: $body',
      );
      for (final Map<String, Object?> roll
          in (record['rolls']! as List<Object?>).cast<Map<String, Object?>>()) {
        final String reveal = roll['reveal']! as String;
        expect(
          ltrContents.any((String c) => c.contains(reveal)),
          isTrue,
          reason: 'decision 2: reveal for k=${roll['k']} ($reveal) must '
              'appear inside a dir="ltr" element; ltr element contents '
              'found: $ltrContents; full body: $body',
        );
      }
    });
  });

  // ---------------------------------------------------------------------
  // Decision 3: the English page keeps every sentence it has today.
  // ---------------------------------------------------------------------
  group('decision 3: the English page keeps every sentence word for word', () {
    test(
        'every English sentence on ffe63fd\'s buildVerifyPageHtml is '
        'still present verbatim', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      for (final String sentence in _englishSentencesOnFfe63fd(_foundId)) {
        expect(body.contains(sentence), isTrue,
            reason: 'decision 3: the English sentence "$sentence", '
                'present in verify_page.dart on ffe63fd, must still '
                'appear verbatim -- a mutation that reworded or dropped '
                'it while adding the Arabic page must fail here; body: '
                '$body');
      }
    });
  });

  // ---------------------------------------------------------------------
  // Decision 4: order -- lead line, then #summary, both before any table.
  // ---------------------------------------------------------------------
  group('decision 4: a plain lead line comes first, then the verdict', () {
    void checkOrder(String body, String leadLine) {
      final int h1Close = body.indexOf('</h1>');
      expect(h1Close, isNot(-1),
          reason: 'decision 4: expected a closing </h1> somewhere on the '
              'page; body: $body');

      final int leadIndex = body.indexOf(leadLine);
      expect(leadIndex, isNot(-1),
          reason: 'decision 4: expected the lead line "$leadLine" '
              'somewhere on the page, directly under <h1>; body: $body');
      expect(leadIndex, greaterThan(h1Close),
          reason: 'decision 4: the lead line must come after </h1>; lead '
              'line found at index $leadIndex, </h1> at index $h1Close; '
              'body: $body');

      final int summaryIndex = body.indexOf('id="summary"');
      expect(summaryIndex, isNot(-1),
          reason: 'decision 4: expected an element with id="summary"; '
              'body: $body');
      expect(summaryIndex, greaterThan(leadIndex),
          reason: 'decision 4: id="summary" must come after the lead '
              'line; lead line at index $leadIndex, id="summary" at '
              'index $summaryIndex; body: $body');

      final int firstTable = body.indexOf('<table');
      expect(firstTable, isNot(-1),
          reason: 'decision 4: expected at least one <table on the page; '
              'body: $body');
      expect(leadIndex, lessThan(firstTable),
          reason: 'decision 4: the lead line must come before any '
              '<table; lead line at index $leadIndex, first <table at '
              'index $firstTable; body: $body');
      expect(summaryIndex, lessThan(firstTable),
          reason: 'decision 4: id="summary" must come before any '
              '<table; id="summary" at index $summaryIndex, first '
              '<table at index $firstTable; body: $body');

      final int occurrences = RegExp('id="summary"').allMatches(body).length;
      expect(occurrences, 1,
          reason: 'decision 4: id="summary" must occur exactly once; '
              'found $occurrences occurrences; body: $body');
    }

    test('en page order', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      checkOrder(
        body,
        'Every roll of this game is verifiable: the server committed to '
        'all of them before the game began, and this page checks each '
        'one in your browser.',
      );
    });

    test('ar page order', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      checkOrder(
        body,
        'كل رمية في هذه اللعبة قابلة للتحقق: الخادم ثبّتها كلها قبل أن '
        'تبدأ اللعبة، وهذه الصفحة تفحص كل واحدة منها في متصفحك.',
      );
    });
  });

  // ---------------------------------------------------------------------
  // Decision 5 (data-attribute half): the page carries the words as data
  // attributes for the script to read. The fallback half (the script's own
  // behaviour when the attributes are absent) is tested in
  // verify_script_lang_test.dart, against the real script, not the page.
  // ---------------------------------------------------------------------
  group(
      'decision 5 (data-attribute half): the page carries the words as '
      'data attributes', () {
    test(
        "en page's #summary carries data-ok and data-fail with today's "
        'English strings', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      final RegExp summaryTag = RegExp(r'<[^>]*id="summary"[^>]*>');
      final Match? match = summaryTag.firstMatch(body);
      expect(match, isNotNull,
          reason: 'decision 5: expected an element with id="summary"; '
              'body: $body');
      final String tag = match!.group(0)!;

      expect(tag.contains('data-ok="checked: all {n} rolls verified"'), isTrue,
          reason: 'decision 5: #summary must carry '
              'data-ok="checked: all {n} rolls verified" (today\'s '
              'English, with the {n} placeholder literal); summary tag: '
              '$tag');
      expect(tag.contains('data-fail="checked: failed ({reason})"'), isTrue,
          reason: 'decision 5: #summary must carry '
              'data-fail="checked: failed ({reason})" (today\'s English, '
              'with the {reason} placeholder literal); summary tag: $tag');
    });

    test(
        "en page's rolls table carries data-match and data-mismatch with "
        "today's English strings", () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      // decision 4's "Rolls" heading precedes the rolls table; search only
      // from there on so a data-match/data-mismatch pair on the seeds
      // table (if one were ever added there by mistake) cannot satisfy
      // this by accident.
      final int rollsHeading = body.indexOf('<h2>Rolls</h2>');
      expect(rollsHeading, isNot(-1),
          reason: 'decision 5: expected a "Rolls" heading before the '
              'rolls table; body: $body');
      final String afterRollsHeading = body.substring(rollsHeading);
      final RegExp tableTag = RegExp(r'<table[^>]*>');
      final Match? match = tableTag.firstMatch(afterRollsHeading);
      expect(match, isNotNull,
          reason: 'decision 5: expected a <table after the "Rolls" '
              'heading; body: $body');
      final String tag = match!.group(0)!;

      expect(tag.contains('data-match="checked: matches"'), isTrue,
          reason: 'decision 5: the rolls table must carry '
              'data-match="checked: matches"; table tag: $tag');
      expect(tag.contains('data-mismatch="checked: does not match"'), isTrue,
          reason: 'decision 5: the rolls table must carry '
              'data-mismatch="checked: does not match"; table tag: $tag');
    });

    test("ar page's #summary carries the Arabic data-ok and data-fail",
        () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      final RegExp summaryTag = RegExp(r'<[^>]*id="summary"[^>]*>');
      final Match? match = summaryTag.firstMatch(body);
      expect(match, isNotNull,
          reason: 'decision 5: expected an element with id="summary" on '
              'the ar page; body: $body');
      final String tag = match!.group(0)!;

      expect(
        tag.contains('data-ok="تم التحقق: كل الرميات ({n}) سليمة"'),
        isTrue,
        reason: 'decision 5: the ar page\'s #summary must carry the '
            'Arabic data-ok string with the {n} placeholder literal; '
            'summary tag: $tag',
      );
      expect(
        tag.contains('data-fail="تم التحقق: فشل ({reason})"'),
        isTrue,
        reason: 'decision 5: the ar page\'s #summary must carry the '
            'Arabic data-fail string with the {reason} placeholder '
            'literal; summary tag: $tag',
      );
    });

    test(
        "ar page's rolls table carries the Arabic data-match and "
        'data-mismatch', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      // The bare word also sits in #summary's data-ok, which decision 4
      // places above every table; anchor on the heading itself.
      final int rollsHeading = body.indexOf('<h2>الرميات</h2>');
      expect(rollsHeading, isNot(-1),
          reason: 'decision 5: expected the "الرميات" heading before the '
              'rolls table on the ar page; body: $body');
      final String afterRollsHeading = body.substring(rollsHeading);
      final RegExp tableTag = RegExp(r'<table[^>]*>');
      final Match? match = tableTag.firstMatch(afterRollsHeading);
      expect(match, isNotNull,
          reason: 'decision 5: expected a <table after the "الرميات" '
              'heading; body: $body');
      final String tag = match!.group(0)!;

      expect(tag.contains('data-match="تم الفحص: مطابق"'), isTrue,
          reason: 'decision 5: the ar page\'s rolls table must carry '
              'data-match="تم الفحص: مطابق"; table tag: $tag');
      expect(tag.contains('data-mismatch="تم الفحص: غير مطابق"'), isTrue,
          reason: 'decision 5: the ar page\'s rolls table must carry '
              'data-mismatch="تم الفحص: غير مطابق"; table tag: $tag');
    });
  });

  // ---------------------------------------------------------------------
  // Decision 6: one link to the other language.
  // ---------------------------------------------------------------------
  group('decision 6: one link to the other language', () {
    test('en page links ?lang=ar with text العربية', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      final RegExp link = RegExp(
        r'<a href="\?lang=ar"[^>]*>العربية</a>',
      );
      expect(link.hasMatch(body), isTrue,
          reason: 'decision 6: the en page must link a relative '
              '"?lang=ar" with the visible text "العربية"; body: $body');
    });

    test('ar page links ?lang=en with text English', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      final String body = await _bodyOf(response);

      final RegExp link = RegExp(r'<a href="\?lang=en"[^>]*>English</a>');
      expect(link.hasMatch(body), isTrue,
          reason: 'decision 6: the ar page must link a relative '
              '"?lang=en" with the visible text "English"; body: $body');
    });

    test('not-found page (en) links ?lang=ar with text العربية', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_unknownId'));
      final String body = await _bodyOf(response);

      final RegExp link = RegExp(r'<a href="\?lang=ar"[^>]*>العربية</a>');
      expect(link.hasMatch(body), isTrue,
          reason: 'decision 6: the not-found page must carry the same '
              'language link as the found page; body: $body');
    });

    test('links never carry a host (relative only)', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      final RegExp absoluteLangLink = RegExp(r'<a href="https?://[^"]*\?lang=');
      expect(absoluteLangLink.hasMatch(body), isFalse,
          reason: 'decision 6: the language link must be relative, '
              'never carrying a host, so the CSP and the two hosts stay '
              'untouched; body: $body');
    });
  });

  // ---------------------------------------------------------------------
  // Decision 7: wording rule (P7), both languages.
  // ---------------------------------------------------------------------
  group('decision 7: wording rule, neither language', () {
    const List<String> forbidden = <String>[
      'provably fair',
      'absolute random',
      'odds',
      'stake',
      'wager',
      'gambl',
    ];

    void checkNoneForbidden(String body, String label) {
      final String lower = body.toLowerCase();
      for (final String word in forbidden) {
        expect(lower.contains(word), isFalse,
            reason: 'decision 7 / P7: "$word" must never appear '
                '(case-insensitively) on the $label page; body: $body');
      }
    }

    test('found page, en', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      checkNoneForbidden(await _bodyOf(response), 'found/en');
    });

    test('found page, ar', () async {
      final _Harness harness = await harnessWithFixture();
      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      checkNoneForbidden(await _bodyOf(response), 'found/ar');
    });

    test('not-found page, en', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_unknownId'));
      checkNoneForbidden(await _bodyOf(response), 'not-found/en');
    });

    test('not-found page, ar', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response = await _send(
        client,
        harness.uri(
          '/v/$_unknownId',
          query: <String, String>{'lang': 'ar'},
        ),
      );
      checkNoneForbidden(await _bodyOf(response), 'not-found/ar');
    });
  });

  // ---------------------------------------------------------------------
  // Decision 8: nothing else moves.
  // ---------------------------------------------------------------------
  group('decision 8: nothing else moves', () {
    test(
        '/v/<id>.json body is byte-identical with and without '
        'Accept-Language: ar', () async {
      final _Harness harness = await harnessWithFixture();

      final HttpClientResponse withoutHeader =
          await _send(client, harness.uri('/v/$_foundId.json'));
      final String withoutBody = await _bodyOf(withoutHeader);

      final HttpClientResponse withHeader = await _send(
        client,
        harness.uri('/v/$_foundId.json'),
        headers: <String, String>{'Accept-Language': 'ar'},
      );
      final String withBody = await _bodyOf(withHeader);

      expect(withBody, withoutBody,
          reason: 'decision 8: the .json route must never branch on '
              'Accept-Language -- a change that made it page-aware would '
              'break a non-browser checker that never sends the header; '
              'without header: "$withoutBody", with header: "$withBody"');
    });

    test(
        'the CSP header on the found page is exactly today\'s, regardless '
        'of language', () async {
      final _Harness harness = await harnessWithFixture();
      const String expectedCsp = "default-src 'none'; script-src 'self'; "
          "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
          "frame-ancestors 'none'";

      final HttpClientResponse en =
          await _send(client, harness.uri('/v/$_foundId'));
      await _bodyOf(en);
      expect(en.headers.value('content-security-policy'), expectedCsp,
          reason: 'decision 8: the CSP header must not move for the en '
              'page');

      final HttpClientResponse ar = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      await _bodyOf(ar);
      expect(ar.headers.value('content-security-policy'), expectedCsp,
          reason: 'decision 8: the CSP header must not move for the ar '
              'page either');
    });

    test(
        'cache-control values are exactly today\'s for the found page, '
        'the not-found page and the .json routes, regardless of '
        'language', () async {
      final _Harness harness = await harnessWithFixture();

      final HttpClientResponse foundEn =
          await _send(client, harness.uri('/v/$_foundId'));
      await _bodyOf(foundEn);
      expect(foundEn.headers.value('cache-control'), 'public, max-age=300',
          reason: 'decision 8: found page (en) cache-control must stay '
              'public, max-age=300');

      final HttpClientResponse foundAr = await _send(
        client,
        harness.uri('/v/$_foundId', query: <String, String>{'lang': 'ar'}),
      );
      await _bodyOf(foundAr);
      expect(foundAr.headers.value('cache-control'), 'public, max-age=300',
          reason: 'decision 8: found page (ar) cache-control must stay '
              'public, max-age=300');

      final HttpClientResponse notFound =
          await _send(client, harness.uri('/v/$_unknownId'));
      await _bodyOf(notFound);
      expect(notFound.headers.value('cache-control'), 'no-store',
          reason: 'decision 8: not-found page cache-control must stay '
              'no-store');

      final HttpClientResponse jsonFound =
          await _send(client, harness.uri('/v/$_foundId.json'));
      await _bodyOf(jsonFound);
      expect(jsonFound.headers.value('cache-control'), 'public, max-age=300',
          reason: 'decision 8: .json found cache-control must stay '
              'public, max-age=300');

      final HttpClientResponse jsonNotFound =
          await _send(client, harness.uri('/v/$_unknownId.json'));
      await _bodyOf(jsonNotFound);
      expect(jsonNotFound.headers.value('cache-control'), 'no-store',
          reason: 'decision 8: .json not-found cache-control must stay '
              'no-store');
    });
  });
}
