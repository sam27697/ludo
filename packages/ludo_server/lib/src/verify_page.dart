// The page at `/v/<game_id>`, docs/VERIFY.md section 5. Modelled on
// link_pages.dart and privacy_page.dart: every function here is pure, reads
// nothing at request time, and the caller (`wire_server.dart`) builds and
// serves the result per request from the stored record string -- there is
// nothing here worth caching across requests the way those two files cache
// their one fixed document, because the record differs per game.
//
// [buildVerifyPageHtml] takes the stored record as a string, not as a
// decoded map, because the page has to embed exactly what `/v/<id>.json`
// serves -- byte for byte the same value a checker fetching the `.json`
// route would see. It is decoded here only to pull out the handful of
// values the human-readable tables need; the embedded `<script
// type="application/json">` block holds the original string, untouched
// apart from the `<` guard described below.

import 'dart:convert';

const HtmlEscape _escaper = HtmlEscape();

const String _sourceUrl = 'https://github.com/sam27697/ludo';

/// Builds the page for a game whose stored record is [recordJson] -- the
/// exact string `VerifyStore.load` returned. Readable with JavaScript off:
/// every table below is rendered from the record server-side, and the two
/// "not checked" check columns and the summary line are the only things
/// `/v/verify.js` fills in afterwards.
String buildVerifyPageHtml(String recordJson) {
  final Map<String, Object?> record =
      jsonDecode(recordJson) as Map<String, Object?>;

  final String gameId = record['game_id'] as String;
  final String finishedAt = record['finished_at'] as String;
  final Object? winner = record['winner'];
  final String chainCommit = record['chain_commit'] as String;
  final Object? chainLength = record['chain_length'];
  final List<Object?> seeds = record['seeds'] as List<Object?>;
  final List<Object?> rolls = record['rolls'] as List<Object?>;

  final StringBuffer seedRows = StringBuffer();
  for (final Object? entry in seeds) {
    final Map<String, Object?> seed = entry as Map<String, Object?>;
    final String origin = (seed['origin'] as String?) ?? '';
    final String originText = origin == 'player'
        ? 'chosen by this player'
        : 'drawn by the server: this seat added no randomness of its own';
    seedRows
      ..write('<tr><td>')
      ..write(_esc(seed['seat']))
      ..write('</td><td>')
      ..write(_esc(seed['seed']))
      ..write('</td><td>')
      ..write(_esc(originText))
      ..write('</td></tr>\n');
  }

  final StringBuffer rollRows = StringBuffer();
  for (final Object? entry in rolls) {
    final Map<String, Object?> roll = entry as Map<String, Object?>;
    final Object? k = roll['k'];
    final String kEsc = _esc(k);
    rollRows
      ..write('<tr><td>')
      ..write(kEsc)
      ..write('</td><td>')
      ..write(_esc(roll['seat']))
      ..write('</td><td>')
      ..write(_esc(roll['die']))
      ..write('</td><td class="reveal">')
      ..write(_esc(roll['reveal']))
      ..write('</td><td id="chain-')
      ..write(kEsc)
      ..write('">not checked</td><td id="die-')
      ..write(kEsc)
      ..write('">not checked</td></tr>\n');
  }

  // The `<script type="application/json">` block below is not parsed as
  // HTML, so its content does not need HTML escaping -- it needs exactly
  // one guard instead: a literal "<" (byte 0x3c) could otherwise start a
  // "</script>" sequence inside a seed or a reveal and truncate the element
  // early. The standard fix, used the same way by every framework that
  // embeds JSON in a script tag, is to write "<" as the six-character JSON
  // unicode escape backslash, u, 0, 0, 3, c: a JSON parser reads it back as
  // the original character, but the browser's HTML tokenizer never sees the
  // byte 0x3c and so can never close the tag on it. The replacement string
  // below is deliberately split across two Dart string literals so the six
  // characters are never contiguous in this file -- at least one editing
  // tool on this box turns the contiguous form back into a literal "<",
  // which would make the guard a no-op again.
  final String scriptSafeRecordJson = recordJson.replaceAll('<', r'\u' '003c');

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Verify game ${_esc(gameId)} - Ludo RNG</title>
<style>
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  max-width: 48em;
  margin: 0 auto;
  padding: 1.5em;
  line-height: 1.5;
  color: #1a1a1a;
}
h1 {
  font-size: 1.3em;
}
h2 {
  font-size: 1.05em;
  margin-top: 1.5em;
}
table {
  border-collapse: collapse;
  width: 100%;
  margin-top: 0.5em;
  font-size: 0.9em;
}
th, td {
  border: 1px solid #ccc;
  padding: 0.3em 0.5em;
  text-align: left;
  vertical-align: top;
}
td.reveal {
  font-family: monospace;
  word-break: break-all;
}
code {
  font-family: monospace;
  background: #f2f2f2;
  padding: 0.1em 0.3em;
}
</style>
</head>
<body>
<h1>Game ${_esc(gameId)}</h1>
<p>Finished ${_esc(finishedAt)} UTC. Winner: Seat ${_esc(winner)}.</p>

<h2>What this proves</h2>
<ul>
<li>The server fixed every roll of this game before the game began, and
could not change any of them afterwards.</li>
<li>The players' own seeds were mixed into every roll after that
commitment, so the server could not have chosen the outcomes it wanted.</li>
<li>No roll's secret was published before that roll happened.</li>
</ul>

<h2>What this does not prove</h2>
<ul>
<li>That the server's own secret came from a good source of randomness. The
only fixes for that are a third-party randomness beacon or an audited
build, and neither is in place here.</li>
</ul>

<h2>Commitment</h2>
<p>Chain commitment: <code>${_esc(chainCommit)}</code></p>
<p>Chain length: ${_esc(chainLength)}</p>

<h2>Seeds</h2>
<table>
<thead><tr><th>Seat</th><th>Seed</th><th>Origin</th></tr></thead>
<tbody>
$seedRows</tbody>
</table>

<h2>Rolls</h2>
<table>
<thead><tr><th>k</th><th>Seat</th><th>Die</th><th>Reveal</th>
<th>Chain check</th><th>Die check</th></tr></thead>
<tbody>
$rollRows</tbody>
</table>

<p id="summary">not checked</p>

<h2>Check it yourself</h2>
<p>Do not take this page's word for any of the above. Run the same checks
on your own machine, from the published source, with nothing borrowed from
this page:</p>
<p><code>curl -sO https://provefair.app/v/verify.py &amp;&amp; python3
verify.py ${_esc(gameId)}</code></p>
<p>Source: <a href="$_sourceUrl">$_sourceUrl</a></p>

<p>This record is kept for 90 days after the game ends.</p>

<script type="application/json" id="record">$scriptSafeRecordJson</script>
<script src="/v/verify.js"></script>
</body>
</html>
''';
}

/// Builds the short page served for `/v/<id>` when [id] is well-formed but
/// no record exists for it, or when [id] is not well-formed at all -- the
/// two cases docs/VERIFY.md section 4 answers identically, since a route
/// that told the two apart would be telling a caller which ids are real.
String buildVerifyNotFoundHtml() {
  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Record not found - Ludo RNG</title>
<style>
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  max-width: 32em;
  margin: 0 auto;
  padding: 1.5em;
  line-height: 1.5;
  color: #1a1a1a;
}
</style>
</head>
<body>
<h1>No record for this id</h1>
<p>There is no verification record for this id. Records are kept for 90 days after the game they belong to ends.</p>
</body>
</html>
''';
}

String _esc(Object? value) => _escaper.convert(value.toString());
