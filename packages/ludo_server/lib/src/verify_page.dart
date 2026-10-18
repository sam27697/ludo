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
//
// C-396: the page now picks a language -- `en` or `ar` -- and renders a
// full mirror of itself in the other script. [resolveVerifyLanguage] is the
// one place that decides which; everything downstream of it just renders
// the language it was told. The two render branches below are kept apart
// on purpose rather than built from one interpolated template: the English
// branch is still the exact wording `buildVerifyPageHtml` wrote before this
// contract, line break for line break, because a handful of English
// sentences are pinned verbatim by tests older than this file's Arabic
// half, and folding both languages through one shared template invites a
// future edit to drift one language's wrapping onto the other's.

import 'dart:convert';

const HtmlEscape _escaper = HtmlEscape();

const String _sourceUrl = 'https://github.com/sam27697/ludo';

/// Decision 4's lead line, English. A plain Dart constant rather than text
/// written straight into the template below so that wrapping this comment
/// block (or the template itself) for line length can never fold a stray
/// newline into the middle of the sentence -- the adjacent string literals
/// below concatenate with nothing inserted between them.
const String _enLeadLine =
    'Every roll of this game is verifiable: the server committed to '
    'all of them before the game began, and this page checks each one '
    'in your browser.';

/// Default language for every caller that does not ask for one -- today's
/// English, unchanged.
const String defaultVerifyLanguage = 'en';

/// Picks the page's language per C-396 decision 1: an explicit `lang` entry
/// in [query] wins outright when it is exactly `ar` or `en`; any other
/// value there (including absent) is treated as if no query parameter had
/// been given at all, and the choice falls through to [acceptLanguageHeader]
/// -- the highest-`q` tag whose primary subtag (the part before the first
/// `-`, compared case-insensitively) is `ar` or `en`, ties broken by
/// whichever such tag appeared first in the header. With no query match and
/// no such tag in the header, English.
String resolveVerifyLanguage({
  required Map<String, String> query,
  required String? acceptLanguageHeader,
}) {
  final String? queryLang = query['lang'];
  if (queryLang == 'ar' || queryLang == 'en') {
    return queryLang!;
  }
  return _languageFromAcceptLanguage(acceptLanguageHeader);
}

class _AcceptedTag {
  _AcceptedTag(this.primary, this.q, this.order);

  final String primary;
  final double q;
  final int order;
}

String _languageFromAcceptLanguage(String? header) {
  if (header == null) {
    return defaultVerifyLanguage;
  }
  final List<_AcceptedTag> accepted = <_AcceptedTag>[];
  int order = 0;
  for (final String rawEntry in header.split(',')) {
    final String entry = rawEntry.trim();
    if (entry.isEmpty) {
      continue;
    }
    final List<String> parts = entry.split(';');
    final String tag = parts[0].trim();
    if (tag.isEmpty) {
      continue;
    }
    final String primary = tag.split('-').first.toLowerCase();
    if (primary != 'ar' && primary != 'en') {
      continue;
    }
    double q = 1.0;
    for (final String param in parts.skip(1)) {
      final String trimmed = param.trim();
      if (trimmed.startsWith('q=')) {
        final double? parsed = double.tryParse(trimmed.substring(2));
        if (parsed != null) {
          q = parsed;
        }
      }
    }
    accepted.add(_AcceptedTag(primary, q, order));
    order++;
  }
  if (accepted.isEmpty) {
    return defaultVerifyLanguage;
  }
  accepted.sort((_AcceptedTag a, _AcceptedTag b) {
    final int byQ = b.q.compareTo(a.q);
    if (byQ != 0) {
      return byQ;
    }
    return a.order.compareTo(b.order);
  });
  return accepted.first.primary;
}

/// Builds the page for a game whose stored record is [recordJson] -- the
/// exact string `VerifyStore.load` returned. Readable with JavaScript off:
/// every table below is rendered from the record server-side, and the two
/// "not checked" check columns and the summary line are the only things
/// `/v/verify.js` fills in afterwards. [language] is whatever
/// [resolveVerifyLanguage] picked; anything other than `'ar'` renders
/// English, so a caller that never heard of this contract keeps compiling
/// and keeps getting the English page it always got.
String buildVerifyPageHtml(
  String recordJson, {
  String language = defaultVerifyLanguage,
}) {
  final bool isAr = language == 'ar';
  final Map<String, Object?> record =
      jsonDecode(recordJson) as Map<String, Object?>;

  final String gameId = record['game_id'] as String;
  final String finishedAt = record['finished_at'] as String;
  final Object? winner = record['winner'];
  final String chainCommit = record['chain_commit'] as String;
  final Object? chainLength = record['chain_length'];
  final List<Object?> seeds = record['seeds'] as List<Object?>;
  final List<Object?> rolls = record['rolls'] as List<Object?>;

  final String ltrAttr = isAr ? ' dir="ltr"' : '';
  final String notCheckedCell = isAr ? 'لم يُفحص' : 'not checked';

  final StringBuffer seedRows = StringBuffer();
  for (final Object? entry in seeds) {
    final Map<String, Object?> seed = entry as Map<String, Object?>;
    final String origin = (seed['origin'] as String?) ?? '';
    final String originText = origin == 'player'
        ? (isAr ? 'اختارها هذا اللاعب' : 'chosen by this player')
        : (isAr
            ? 'سحبها الخادم: هذا المقعد لم يضف عشوائية من عنده'
            : 'drawn by the server: this seat added no randomness of its '
                'own');
    seedRows
      ..write('<tr><td$ltrAttr>')
      ..write(_esc(seed['seat']))
      ..write('</td><td$ltrAttr>')
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
      ..write('<tr><td$ltrAttr>')
      ..write(kEsc)
      ..write('</td><td$ltrAttr>')
      ..write(_esc(roll['seat']))
      ..write('</td><td$ltrAttr>')
      ..write(_esc(roll['die']))
      ..write('</td><td class="reveal"$ltrAttr>')
      ..write(_esc(roll['reveal']))
      ..write('</td><td id="chain-')
      ..write(kEsc)
      ..write('">$notCheckedCell</td><td id="die-')
      ..write(kEsc)
      ..write('">$notCheckedCell</td></tr>\n');
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

  if (isAr) {
    const String leadLine =
        'كل رمية في هذه اللعبة قابلة للتحقق: الخادم ثبّتها كلها قبل أن '
        'تبدأ اللعبة، وهذه الصفحة تفحص كل واحدة منها في متصفحك.';
    const String dataOk = 'تم التحقق: كل الرميات ({n}) سليمة';
    const String dataFail = 'تم التحقق: فشل ({reason})';
    const String dataMatch = 'تم الفحص: مطابق';
    const String dataMismatch = 'تم الفحص: غير مطابق';
    const String notCheckedSummary = 'لم يتم التحقق بعد';
    const String proves2 =
        'ثبّت الخادم كل رميات هذه اللعبة قبل أن تبدأ، ولم يكن بإمكانه '
        'تغيير أي منها بعد ذلك.';
    const String proves3 =
        'بعد هذا التثبيت دُمجت بذور اللاعبين أنفسهم في كل رمية، فلم يكن '
        'بإمكان الخادم أن يختار النتائج التي يريدها.';
    const String proves4 = 'لم يُنشر سرّ أي رمية قبل أن تحدث.';
    const String notProves =
        'أن سرّ الخادم نفسه جاء من مصدر عشوائية جيد. الحل الوحيد لذلك '
        'منارة عشوائية من طرف ثالث أو نسخة خاضعة للتدقيق، ولا يوجد أي '
        'منهما هنا.';
    const String checkYourselfBody =
        'لا تأخذ كلام هذه الصفحة على أي مما سبق. شغّل الفحوص نفسها على '
        'جهازك، من الكود المنشور، دون الاعتماد على أي شيء من هذه الصفحة:';

    return '''
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>التحقق من اللعبة ${_esc(gameId)} - Ludo RNG</title>
<style>
$_sharedStyle
</style>
</head>
<body>
<p class="lang-switch"><a href="?lang=en">English</a></p>
<h1>اللعبة ${_esc(gameId)}</h1>
<p>$leadLine</p>
<p id="summary" data-ok="$dataOk" data-fail="$dataFail">$notCheckedSummary</p>

<p>انتهت في ${_esc(finishedAt)} UTC. الفائز: المقعد ${_esc(winner)}.</p>

<h2>ما الذي تثبته هذه الصفحة</h2>
<ul>
<li>$proves2</li>
<li>$proves3</li>
<li>$proves4</li>
</ul>

<h2>ما الذي لا تثبته</h2>
<ul>
<li>$notProves</li>
</ul>

<h2>التثبيت</h2>
<p>تثبيت السلسلة: <code$ltrAttr>${_esc(chainCommit)}</code></p>
<p>طول السلسلة: <span$ltrAttr>${_esc(chainLength)}</span></p>

<h2>البذور</h2>
<table>
<thead><tr><th>المقعد</th><th>البذرة</th><th>المصدر</th></tr></thead>
<tbody>
$seedRows</tbody>
</table>

<h2>الرميات</h2>
<table id="rolls-table" data-match="$dataMatch" data-mismatch="$dataMismatch">
<thead><tr><th>k</th><th>المقعد</th><th>النرد</th><th>الكشف</th>
<th>فحص السلسلة</th><th>فحص النرد</th></tr></thead>
<tbody>
$rollRows</tbody>
</table>

<h2>تحقق بنفسك</h2>
<p>$checkYourselfBody</p>
<p><code$ltrAttr>curl -sO https://provefair.app/v/verify.py &amp;&amp; python3
verify.py ${_esc(gameId)}</code></p>
<p>الكود: <a href="$_sourceUrl"$ltrAttr>$_sourceUrl</a></p>

<p>يُحفظ هذا السجل 90 يومًا بعد انتهاء اللعبة.</p>

<script type="application/json" id="record">$scriptSafeRecordJson</script>
<script src="/v/verify.js"></script>
</body>
</html>
''';
  }

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Verify game ${_esc(gameId)} - Ludo RNG</title>
<style>
$_sharedStyle
</style>
</head>
<body>
<p class="lang-switch"><a href="?lang=ar">العربية</a></p>
<h1>Game ${_esc(gameId)}</h1>
<p>$_enLeadLine</p>
<p id="summary" data-ok="checked: all {n} rolls verified" data-fail="checked: failed ({reason})">not checked</p>

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
<p>Chain commitment: <code$ltrAttr>${_esc(chainCommit)}</code></p>
<p>Chain length: <span$ltrAttr>${_esc(chainLength)}</span></p>

<h2>Seeds</h2>
<table>
<thead><tr><th>Seat</th><th>Seed</th><th>Origin</th></tr></thead>
<tbody>
$seedRows</tbody>
</table>

<h2>Rolls</h2>
<table id="rolls-table" data-match="checked: matches" data-mismatch="checked: does not match">
<thead><tr><th>k</th><th>Seat</th><th>Die</th><th>Reveal</th>
<th>Chain check</th><th>Die check</th></tr></thead>
<tbody>
$rollRows</tbody>
</table>

<h2>Check it yourself</h2>
<p>Do not take this page's word for any of the above. Run the same checks
on your own machine, from the published source, with nothing borrowed from
this page:</p>
<p><code$ltrAttr>curl -sO https://provefair.app/v/verify.py &amp;&amp; python3
verify.py ${_esc(gameId)}</code></p>
<p>Source: <a href="$_sourceUrl"$ltrAttr>$_sourceUrl</a></p>

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
/// [language] follows the same rule as [buildVerifyPageHtml].
String buildVerifyNotFoundHtml({String language = defaultVerifyLanguage}) {
  final bool isAr = language == 'ar';
  if (isAr) {
    return '''
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>السجل غير موجود - Ludo RNG</title>
<style>
$_sharedNotFoundStyle
</style>
</head>
<body>
<p class="lang-switch"><a href="?lang=en">English</a></p>
<h1>لا يوجد سجل بهذا المعرّف</h1>
<p>لا يوجد سجل تحقق بهذا المعرّف. تُحفظ السجلات 90 يومًا بعد انتهاء اللعبة التي تخصها.</p>
</body>
</html>
''';
  }

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Record not found - Ludo RNG</title>
<style>
$_sharedNotFoundStyle
</style>
</head>
<body>
<p class="lang-switch"><a href="?lang=ar">العربية</a></p>
<h1>No record for this id</h1>
<p>There is no verification record for this id. Records are kept for 90 days after the game they belong to ends.</p>
</body>
</html>
''';
}

/// Shared between both languages of [buildVerifyPageHtml]: nothing below
/// depends on text direction except `text-align: start`, which already
/// means "left in `ltr`, right in `rtl`" without a per-language rule --
/// `docs/VERIFY.md`'s "table cells aligned to the start side" for free.
///
/// A chain commitment or a seed is one long hex run, not a word, so it has
/// to be allowed to break anywhere. `anywhere` (not `break-word`) is the
/// value that also counts those breaks in a table's min-content width:
/// with `break-word` the seeds table still grows to the unbreakable seed
/// and sticks out past the phone.
const String _sharedStyle = '''
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  max-width: 48em;
  margin: 0 auto;
  padding: 1.5em;
  line-height: 1.5;
  color: #1a1a1a;
  overflow-wrap: anywhere;
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
  text-align: start;
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
.lang-switch {
  text-align: end;
  margin: 0 0 1em;
  font-size: 0.9em;
}''';

const String _sharedNotFoundStyle = '''
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  max-width: 32em;
  margin: 0 auto;
  padding: 1.5em;
  line-height: 1.5;
  color: #1a1a1a;
}
.lang-switch {
  text-align: end;
  margin: 0 0 1em;
  font-size: 0.9em;
}''';

String _esc(Object? value) => _escaper.convert(value.toString());
