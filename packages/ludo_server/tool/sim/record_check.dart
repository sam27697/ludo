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

/// Fetches and checks the record for one finished game. Throws
/// [ScenarioFailure] naming exactly what broke on the first thing that does
/// not hold; returns normally only once every check in docs/VERIFY.md
/// sections 1.1 and 4 that the work order asks for has passed.
Future<void> fetchAndVerifyRecord({
  required String verifyUrl,
  required String gameId,
  required String chainCommit,
  required String clientSeeds,
  required int winner,
  required List<SeenRoll> rolls,
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

  final Set<String> actualKeys = record.keys.toSet();
  if (!actualKeys.containsAll(recordKeys) ||
      !recordKeys.containsAll(actualKeys)) {
    final List<String> missing = recordKeys.difference(actualKeys).toList()
      ..sort();
    final List<String> extra = actualKeys.difference(recordKeys).toList()
      ..sort();
    throw ScenarioFailure(
      'the record at $jsonUri has key set ${(actualKeys.toList()..sort())}, '
      'expected exactly the ten keys of docs/VERIFY.md section 1.1 '
      '${(recordKeys.toList()..sort())}; missing $missing, unexpected '
      '$extra',
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
