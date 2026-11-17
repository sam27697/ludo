// Order 217, `--fetch-record`: fetches the stored verification record at
// `<verify_url>.json` and the page at `<verify_url>`, and checks both
// against docs/VERIFY.md sections 1.1 and 4 and against what the simulator
// itself already verified on the wire for this game. Off unless the
// simulator was invoked with --fetch-record: a locally started server hands
// out verify_url values built from the default production base
// (docs/VERIFY.md section 8), and fetching that against the real internet
// from a local run would be checking the wrong machine.
//
// Uses dart:io's HttpClient directly, no new dependency, per the work
// order.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'game.dart';
import 'scenario.dart';

/// How long any single step of a fetch -- connecting, getting the response
/// headers, or reading the body -- is allowed to take before this file
/// gives up on it. Applied to `HttpClient.connectionTimeout` and to each
/// of `client.getUrl(uri)`, `request.close()` and each body read
/// individually, so a verify host that accepts the TCP connection and then
/// never answers cannot keep this process alive past its own overall
/// budget.
const Duration _fetchTimeout = Duration(seconds: 15);

/// The ten keys docs/VERIFY.md section 1.1 says a format-1 record has,
/// exactly -- no more, no fewer.
const Set<String> recordKeys = <String>{
  'format',
  'game_id',
  'chain_commit',
  'chain_index',
  'chain_length',
  'client_seeds',
  'seeds',
  'rolls',
  'winner',
  'finished_at',
};

/// The four keys docs/VERIFY.md section 1.1 adds under the 2026-11 ruleset
/// (docs/PROTOCOL.md section 28 rules 2 and 3), present together or not at
/// all: a record without `ruleset` is a 2026-10 record and has none of them.
const Set<String> recordKeys202611 = <String>{
  'ruleset',
  'releases',
  'placings',
  'retired',
};

/// The `ruleset` value of a 2026-11 record and of a room frame's
/// `rules.ruleset` under it (docs/PROTOCOL.md section 28 rule 1).
const String _ruleset202611 = '2026-11';

/// What a room under the 2026-10 ruleset shows on the wire and in its
/// record: the key is absent, and this is the name for that.
const String _ruleset202610 = '2026-10';

/// Fetches and checks the record for one finished game. Throws
/// [ScenarioFailure] naming exactly what broke on the first thing that does
/// not hold; returns normally only once every check in docs/VERIFY.md
/// sections 1.1 and 4 that the work order asks for has passed.
///
/// [wireRuleset] is the ruleset the scenario saw in the `room` frame's
/// `rules.ruleset` (docs/PROTOCOL.md section 28 rule 1), `'2026-10'` when
/// the key was absent; the record's own ruleset must be the same. Null
/// means the caller did not capture it and the comparison is skipped.
Future<void> fetchAndVerifyRecord({
  required String verifyUrl,
  required String gameId,
  required String chainCommit,
  required String clientSeeds,
  required int winner,
  required List<SeenRoll> rolls,
  String? wireRuleset,
}) async {
  final HttpClient client = HttpClient();
  client.connectionTimeout = _fetchTimeout;
  try {
    await _checkJsonRecord(
      client: client,
      verifyUrl: verifyUrl,
      gameId: gameId,
      chainCommit: chainCommit,
      clientSeeds: clientSeeds,
      winner: winner,
      rolls: rolls,
      wireRuleset: wireRuleset,
    );
    await _checkHtmlPage(client: client, verifyUrl: verifyUrl);
  } finally {
    client.close(force: true);
  }
}

Future<void> _checkJsonRecord({
  required HttpClient client,
  required String verifyUrl,
  required String gameId,
  required String chainCommit,
  required String clientSeeds,
  required int winner,
  required List<SeenRoll> rolls,
  required String? wireRuleset,
}) async {
  final Uri jsonUri = Uri.parse('$verifyUrl.json');
  final HttpClientResponse response = await _get(client, jsonUri);
  final String body = await _readBody(response, jsonUri);

  if (response.statusCode != 200) {
    throw ScenarioFailure(
      'GET $jsonUri returned status ${response.statusCode}, expected 200: '
      '$body',
    );
  }
  final String? contentType = response.headers.value('content-type');
  if (contentType == null || !contentType.startsWith('application/json')) {
    throw ScenarioFailure(
      'GET $jsonUri returned content-type "$contentType", expected it to '
      'start with "application/json"',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw ScenarioFailure(
      'GET $jsonUri returned a body that does not parse as JSON: $error; '
      'body was: $body',
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw ScenarioFailure(
      'GET $jsonUri returned JSON that is not an object: $body',
    );
  }
  final Map<String, Object?> record = decoded;

  // R2: a `ruleset` key makes this a 2026-11 record, and its value must
  // say exactly that; any other value is named, not guessed at.
  final bool has202611Key = record.containsKey('ruleset');
  if (has202611Key && record['ruleset'] != _ruleset202611) {
    throw ScenarioFailure(
      'the record at $jsonUri has ruleset=${jsonEncode(record['ruleset'])}, '
      'expected "$_ruleset202611" (docs/VERIFY.md section 1.1: the key is '
      'absent under $_ruleset202610)',
    );
  }
  final String recordRuleset = has202611Key ? _ruleset202611 : _ruleset202610;
  final Set<String> wantedKeys =
      has202611Key ? <String>{...recordKeys, ...recordKeys202611} : recordKeys;

  final Set<String> actualKeys = record.keys.toSet();
  if (!actualKeys.containsAll(wantedKeys) ||
      !wantedKeys.containsAll(actualKeys)) {
    final List<String> missing = wantedKeys.difference(actualKeys).toList()
      ..sort();
    final List<String> extra = actualKeys.difference(wantedKeys).toList()
      ..sort();
    final String which = has202611Key
        ? 'the fourteen keys of docs/VERIFY.md section 1.1 under ruleset '
            '$_ruleset202611'
        : 'the ten keys of docs/VERIFY.md section 1.1';
    throw ScenarioFailure(
      'the record at $jsonUri has key set ${(actualKeys.toList()..sort())}, '
      'expected exactly $which '
      '${(wantedKeys.toList()..sort())}; missing $missing, unexpected '
      '$extra',
    );
  }

  // R4: the room frame the scenario saw named a ruleset; the record is
  // for that room and must say the same.
  if (wireRuleset != null && wireRuleset != recordRuleset) {
    throw ScenarioFailure(
      'the record at $jsonUri has ruleset=$recordRuleset'
      '${has202611Key ? '' : ' (key absent)'}, the room frame on the wire '
      'had rules.ruleset=$wireRuleset',
    );
  }

  final Object? format = record['format'];
  if (format != 1) {
    throw ScenarioFailure(
      'the record at $jsonUri has format=$format, expected 1',
    );
  }
  final Object? recordGameId = record['game_id'];
  if (recordGameId != gameId) {
    throw ScenarioFailure(
      'the record at $jsonUri has game_id=$recordGameId, expected '
      '$gameId (from this game\'s game_started on the wire)',
    );
  }
  final Object? recordChainCommit = record['chain_commit'];
  if (recordChainCommit != chainCommit) {
    throw ScenarioFailure(
      'the record at $jsonUri has chain_commit=$recordChainCommit, '
      'expected $chainCommit (from this game\'s room frame on the wire)',
    );
  }
  final Object? recordClientSeeds = record['client_seeds'];
  if (recordClientSeeds != clientSeeds) {
    throw ScenarioFailure(
      'the record at $jsonUri has client_seeds=$recordClientSeeds, '
      'expected $clientSeeds (from this game\'s game_started on the wire)',
    );
  }
  final Object? recordWinner = record['winner'];
  if (recordWinner != winner) {
    throw ScenarioFailure(
      'the record at $jsonUri has winner=$recordWinner, expected $winner '
      '(from this game\'s game_over on the wire)',
    );
  }

  final Object? recordRollsRaw = record['rolls'];
  if (recordRollsRaw is! List<Object?>) {
    throw ScenarioFailure(
      'the record at $jsonUri has a non-list "rolls" field: $recordRollsRaw',
    );
  }
  if (recordRollsRaw.length != rolls.length) {
    throw ScenarioFailure(
      'the record at $jsonUri has ${recordRollsRaw.length} rolls, but the '
      'simulator verified ${rolls.length} rolled frames on the wire for '
      'this game',
    );
  }
  for (int i = 0; i < rolls.length; i++) {
    final SeenRoll expected = rolls[i];
    final Object? entryRaw = recordRollsRaw[i];
    if (entryRaw is! Map<String, Object?>) {
      throw ScenarioFailure(
        'k=${expected.k}: the record at $jsonUri has a non-object entry at '
        'rolls[$i]: $entryRaw',
      );
    }
    final Map<String, Object?> entry = entryRaw;
    final Object? recordK = entry['k'];
    if (recordK != expected.k) {
      throw ScenarioFailure(
        'k=${expected.k}: the record at $jsonUri has rolls[$i].k=$recordK, '
        'the wire had k=${expected.k}',
      );
    }
    final Object? recordSeat = entry['seat'];
    if (recordSeat != expected.seat) {
      throw ScenarioFailure(
        'k=${expected.k}: the record at $jsonUri has seat=$recordSeat, the '
        'wire had seat=${expected.seat}',
      );
    }
    final Object? recordReveal = entry['reveal'];
    if (recordReveal != expected.reveal) {
      throw ScenarioFailure(
        'k=${expected.k}: the record at $jsonUri has reveal=$recordReveal, '
        'the wire had reveal=${expected.reveal}',
      );
    }
    final Object? recordDie = entry['die'];
    if (recordDie != expected.die) {
      throw ScenarioFailure(
        'k=${expected.k}: the record at $jsonUri has die=$recordDie, the '
        'wire had value=${expected.die}',
      );
    }
  }

  if (has202611Key) {
    _check202611Fields(record, jsonUri, winner, recordRollsRaw.length);
  }
}

/// R3: the 2026-11 fields of a record whose key set has already been
/// checked. [winner] is the seat the wire's `game_over` named and
/// [rollCount] the number of rolls in the record.
void _check202611Fields(
  Map<String, Object?> record,
  Uri jsonUri,
  int winner,
  int rollCount,
) {
  final Set<int> gameSeats = _seatsOfGame(record, jsonUri);

  final Object? placings = record['placings'];
  final List<int> placingSeats = _seatList(
    key: 'placings',
    value: placings,
    gameSeats: gameSeats,
    jsonUri: jsonUri,
  );
  if (placingSeats.isEmpty) {
    throw ScenarioFailure(
      'the record at $jsonUri has placings=${jsonEncode(placings)}, '
      'expected a non-empty list of seats (docs/VERIFY.md section 1.1: the '
      'last seat standing is included)',
    );
  }
  if (placingSeats.first != winner) {
    throw ScenarioFailure(
      'the record at $jsonUri has placings=${jsonEncode(placings)}, '
      'expected placings[0] to be the winner, seat $winner (from this '
      'game\'s game_over on the wire)',
    );
  }

  _seatList(
    key: 'retired',
    value: record['retired'],
    gameSeats: gameSeats,
    jsonUri: jsonUri,
  );

  final Object? releases = record['releases'];
  if (releases is! List<Object?>) {
    throw ScenarioFailure(
      'the record at $jsonUri has releases=${jsonEncode(releases)}, '
      'expected a list of roll numbers',
    );
  }
  int previous = 0;
  for (final Object? k in releases) {
    if (k is! int || k < 1 || k > rollCount || k <= previous) {
      throw ScenarioFailure(
        'the record at $jsonUri has releases=${jsonEncode(releases)}, '
        'expected a strictly ascending list of ints each in 1..$rollCount '
        '(the record has $rollCount rolls); the entry '
        '${jsonEncode(k)} breaks that',
      );
    }
    previous = k;
  }
}

/// The seats of the game, from the `seeds` list of the record: one object
/// per seat in the game (docs/VERIFY.md section 1.1).
Set<int> _seatsOfGame(Map<String, Object?> record, Uri jsonUri) {
  final Object? seeds = record['seeds'];
  final Set<int> seats = <int>{};
  if (seeds is List<Object?>) {
    for (final Object? entry in seeds) {
      final Object? seat = entry is Map<String, Object?> ? entry['seat'] : null;
      if (seat is int) {
        seats.add(seat);
        continue;
      }
      seats.clear();
      break;
    }
  }
  if (seats.isEmpty) {
    throw ScenarioFailure(
      'the record at $jsonUri has seeds=${jsonEncode(seeds)}, expected one '
      'object with an int "seat" per seat of the game, which the 2026-11 '
      'checks measure placings and retired against',
    );
  }
  return seats;
}

/// [value] as a list of distinct seats that all belong to [gameSeats], or a
/// [ScenarioFailure] naming [key] and the value.
List<int> _seatList({
  required String key,
  required Object? value,
  required Set<int> gameSeats,
  required Uri jsonUri,
}) {
  if (value is! List<Object?>) {
    throw ScenarioFailure(
      'the record at $jsonUri has $key=${jsonEncode(value)}, expected a '
      'list of seats',
    );
  }
  final List<int> seen = <int>[];
  for (final Object? seat in value) {
    if (seat is! int || !gameSeats.contains(seat)) {
      throw ScenarioFailure(
        'the record at $jsonUri has $key=${jsonEncode(value)}, expected '
        'seats of this game ${(gameSeats.toList()..sort())}; the entry '
        '${jsonEncode(seat)} is not one',
      );
    }
    if (seen.contains(seat)) {
      throw ScenarioFailure(
        'the record at $jsonUri has $key=${jsonEncode(value)}, expected '
        'distinct seats; seat $seat appears more than once',
      );
    }
    seen.add(seat);
  }
  return seen;
}

Future<void> _checkHtmlPage({
  required HttpClient client,
  required String verifyUrl,
}) async {
  final Uri htmlUri = Uri.parse(verifyUrl);
  final HttpClientResponse response = await _get(client, htmlUri);
  await _drainBody(response, htmlUri);

  if (response.statusCode != 200) {
    throw ScenarioFailure(
      'GET $htmlUri returned status ${response.statusCode}, expected 200',
    );
  }
  final String? contentType = response.headers.value('content-type');
  if (contentType == null || !contentType.startsWith('text/html')) {
    throw ScenarioFailure(
      'GET $htmlUri returned content-type "$contentType", expected it to '
      'start with "text/html"',
    );
  }
}

Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
  try {
    final HttpClientRequest request =
        await client.getUrl(uri).timeout(_fetchTimeout);
    return await request.close().timeout(_fetchTimeout);
  } on TimeoutException {
    throw ScenarioFailure(_noResponseWithinLimit(uri));
  } catch (error) {
    throw ScenarioFailure('fetching the verification record failed: GET '
        '$uri: $error');
  }
}

/// Reads the whole body of [response] as UTF-8 text, bounded by
/// [_fetchTimeout], for a fetch of [uri].
Future<String> _readBody(HttpClientResponse response, Uri uri) async {
  try {
    return await response.transform(utf8.decoder).join().timeout(
          _fetchTimeout,
        );
  } on TimeoutException {
    throw ScenarioFailure(_noResponseWithinLimit(uri));
  }
}

/// Reads and discards the whole body of [response], bounded by
/// [_fetchTimeout], for a fetch of [uri].
Future<void> _drainBody(HttpClientResponse response, Uri uri) async {
  try {
    await response.drain<void>().timeout(_fetchTimeout);
  } on TimeoutException {
    throw ScenarioFailure(_noResponseWithinLimit(uri));
  }
}

String _noResponseWithinLimit(Uri uri) =>
    'fetching the verification record failed: GET $uri: no response '
    'within the ${_fetchTimeout.inSeconds}-second timeout';
