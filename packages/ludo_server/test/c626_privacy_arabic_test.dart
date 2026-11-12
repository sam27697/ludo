// Proof for order 626 / C-626 (work/ludo/orders/626-privacy-page-arabic.md),
// decisions D1 to D6, written from the contract and not from the
// implementation: the privacy page in Arabic, picked the way every other
// plain page picks its language, with the language switch every other page
// has.
//
// Every case is deterministic: no clock, no randomness, no sleeps. There is
// no seed to report; a failure message names the scenario and the command
// that re-runs it. The page builder is reached through `Function.apply`, so
// this file compiles against the base commit, where `buildPrivacyPageHtml`
// has no `language` parameter yet, and the cases fail there at the call, not
// at compile time.
//
// The English wording below is copied from `privacy_page.dart` as it stood on
// base 494c912. The Arabic wording is copied from decision D4. Neither is
// imported from the source under test, so a rewording of either document
// fails here.
//
// Interpretations the contract leaves open are listed where they are made:
//
// - "Last element of body" is checked twice: the body's markup ends with the
//   switch link, and nothing but the h1/h2/p elements and the switch link
//   is in the body at all.
// - D2 says the `.switch` rule is "equal to" the home page's; it is read as
//   the same five declarations and no others.
// - HEAD is compared to GET header by header except `content-length`, which
//   is the length of the (empty) HEAD body.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ludo_server/ludo_server.dart';
import 'package:ludo_server/src/link_pages.dart' show buildHomePageHtml;
import 'package:test/test.dart';

const String _testFile = 'test/c626_privacy_arabic_test.dart';

String _repro(String scenario) => 'scenario: "$scenario". Deterministic, no '
    'seed. Re-run from packages/ludo_server: dart test $_testFile -N '
    '"$scenario"';

/// The room page's policy, verbatim, which D5 says `/privacy` now carries.
const String _expectedCsp = "default-src 'none'; script-src 'self'; "
    "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

const String _arabicLabel = 'العربية';

const String _switchToArabic =
    '<a id="lang-switch" class="switch" href="?lang=ar" hreflang="ar" '
    'lang="ar">$_arabicLabel</a>';
const String _switchToEnglish =
    '<a id="lang-switch" class="switch" href="?lang=en" hreflang="en" '
    'lang="en">English</a>';

/// Built from code points so this file itself carries neither character.
final String _emDash = String.fromCharCode(0x2014);
final String _enDash = String.fromCharCode(0x2013);

const String _hostileEmail = 'a<b>@x.test';
const String _hostileEmailEscaped = 'a&lt;b&gt;@x.test';
const String _plainEmail = 'privacy-test@example.invalid';

// ---------------------------------------------------------------------------
// The Arabic text, decision D4, in section order.
// ---------------------------------------------------------------------------

const String _arH1 = 'سياسة الخصوصية - Ludo RNG';
const String _arUpdatedPrefix = 'آخر تحديث: ';
const String _arUpdated =
    '$_arUpdatedPrefix<span dir="ltr">$privacyLastUpdated</span>';
const String _arIntro =
    'Ludo RNG لعبة تلعبها عبر الإنترنت مع أشخاص تدعوهم أنت. '
    'توضّح هذه السياسة ما يتعامل معه التطبيق وخادمه من '
    'بيانات، وما لا يتعامل معه.';
const String _arH2Collect = 'لا نجمع معلومات شخصية.';
const String _arPCollect = 'لا يوجد في Ludo RNG حساب، ولا تسجيل دخول، ولا بريد '
    'إلكتروني، ولا كلمة مرور، ولا ملف شخصي. لا تخبرنا من أنت، '
    'ولا نسألك.';
const String _arH2Ads = 'لا إعلانات، ولا تحليلات، ولا تتبّع.';
const String _arPAds =
    'لا يحتوي التطبيق على أي شبكة إعلانات، ولا مكتبة تحليلات، '
    'ولا أداة تقارير أعطال من طرف ثالث. لا نشارك أي شيء عن '
    'استخدامك للتطبيق مع أي شركة أخرى. لا نجمع معرّف '
    'الإعلانات ولا أي معرّف للجهاز.';
const String _arH2Typed = 'ما تكتبه، وإلى أين يذهب.';
const String _arPTyped =
    'لتلعب، تنشئ غرفة أو تنضم إلى غرفة برمزها. يمكنك أن تكتب '
    'اسمًا يظهر على مقعدك. يُرسَل هذا الاسم ورمز الغرفة إلى '
    'خادمنا حتى يراهما باقي اللاعبين في غرفتك، ويظهران لكل من '
    'في تلك الغرفة. اختر اسمًا لا تمانع أن يراه من دعوتهم. '
    'الغرف مؤقتة: تُحذف الغرفة وكل ما فيها، بما في ذلك أي '
    'اسم، من الخادم عندما تنتهي الغرفة أو تنقضي مدتها.';
const String _arH2Logs = 'ما يسجّله الخادم تلقائيًا.';
const String _arPLogs =
    'مثل أي خادم على الإنترنت، يسجّل خادمنا التفاصيل التقنية '
    'للاتصال حتى تبقى الخدمة تعمل ويمكن إيقاف إساءة '
    'الاستخدام: عنوان IP للجهاز المتصل، ووقت الاتصال، '
    'ومعلومات الأخطاء. تُحفظ هذه السجلات لفترة قصيرة، ولا '
    'تُستخدم لبناء ملف عنك، ولا تُباع، ولا تُشارك مع أحد إلا '
    'حيث يفرض القانون ذلك.';
const String _arH2Rolls = 'رميات قابلة للتحقق.';
const String _arPRolls =
    'ترافق كل رمية نرد معلوماتٌ تتيح لك التحقق من أن الرمية '
    'لم تُغيَّر بعد وقوعها. هذه المعلومات تخص اللعبة لا تخصك، '
    'ولا تحتوي أي بيانات شخصية. عندما تنتهي اللعبة، يُحفظ سجل '
    'رمياتها على خادمنا لمدة 90 يومًا على عنوان ويب لا يُعطى '
    'إلا للاعبي تلك اللعبة، فيستطيع كل من يملك الرابط التحقق '
    'من كل رمية. يذكر السجل اللاعبين برقم المقعد فقط، لا '
    'بأسمائهم أبدًا، ولا يحتوي أي عنوان IP.';
const String _arH2Children = 'الأطفال.';
const String _arPChildren =
    'Ludo RNG غير موجّهة للأطفال دون 13 عامًا. لا نجمع عن علم '
    'أي معلومات شخصية من أي أحد، بمن في ذلك الأطفال.';
const String _arH2Ask = 'بيانات يمكنك السؤال عنها.';
const String _arPAskWith =
    'لأننا لا نحتفظ بأي حساب ولا ملف شخصي، فعادةً لا يوجد ما '
    'نعطيك نسخة منه أو نحذفه. إذا كنت تعتقد أننا نحتفظ بشيء '
    'عنك وتريد إزالته، راسلنا على العنوان أدناه وسنتصرف بناءً '
    'على طلبك.';
const String _arPAskWithout =
    'لأننا لا نحتفظ بأي حساب ولا ملف شخصي، فعادةً لا يوجد ما '
    'نعطيك نسخة منه أو نحذفه.';
const String _arH2Changes = 'التغييرات على هذه السياسة.';
const String _arPChanges = 'إذا تغيّرت هذه السياسة، تظهر النسخة الجديدة في هذه '
    'الصفحة مع تاريخ جديد في أعلاها.';
const String _arH2Contact = 'التواصل.';

// ---------------------------------------------------------------------------
// The English text, as on base 494c912, in section order.
// ---------------------------------------------------------------------------

const String _enH1 = 'Privacy Policy - Ludo RNG';
const String _enIntro =
    'Ludo RNG is a game you play online with people you invite. '
    'This policy explains what the app and its server handle, and what '
    'they do not.';
const String _enH2Collect = 'We do not collect personal information.';
const String _enPCollect =
    'Ludo RNG has no account, no sign-in, no email address, no '
    'password and no profile. You do not tell us who you are and we do '
    'not ask.';
const String _enH2Ads = 'No advertising, no analytics, no tracking.';
const String _enPAds =
    'The app contains no advertising network, no analytics library '
    'and no third-party crash reporting. Nothing about your use of the '
    'app is shared with any other company. There is no advertising '
    'identifier and no device identifier collected.';
const String _enH2Typed = 'What you type, and where it goes.';
const String _enPTyped =
    'To play, you create a room or join one with a room code. You '
    'may enter a display name for your seat. That name and the room '
    'code are sent to our server so the other players in your room can '
    'see them, and they are visible to everyone in that room. Choose a '
    'display name you are comfortable showing to the people you '
    'invited. Rooms are temporary: the room and everything in it, '
    'including any display name, is deleted from the server when the '
    'room ends or expires.';
const String _enH2Logs = 'What the server records automatically.';
const String _enPLogs =
    'Like any server on the internet, ours records the technical '
    'details of a connection so the service can be kept working and '
    'abuse can be stopped: the IP address of the connecting device, the '
    'time of the connection, and error information. These records are '
    'kept for a short period and are not used to build a profile of '
    'you, are not sold, and are not shared with anyone except where the '
    'law requires it.';
const String _enH2Rolls = 'Verifiable rolls.';
const String _enPRolls =
    'Every dice roll is accompanied by information that lets you '
    'check the roll was not altered after the fact. That information '
    'is about the game, not about you, and contains no personal '
    'data. When a game ends, a record of its rolls is kept on our '
    'server for 90 days at a web address given only to the players of '
    'that game, so anyone holding the link can check every roll. The '
    'record names players by seat number only, never by display name, '
    'and holds no IP address.';
const String _enH2Children = 'Children.';
const String _enPChildren =
    'Ludo RNG is not directed at children under 13. We do not '
    'knowingly collect any personal information from anyone, including '
    'children.';
const String _enH2Ask = 'Data you can ask about.';
const String _enPAskWith =
    'Because we hold no account and no personal profile, there is '
    'normally nothing to give you a copy of or to delete. If you '
    'believe we hold something about you and you want it removed, '
    'write to the address below and we will act on it.';
const String _enPAskWithout =
    'Because we hold no account and no personal profile, there is '
    'normally nothing to give you a copy of or to delete.';
const String _enH2Changes = 'Changes to this policy.';
const String _enPChanges =
    'If this policy changes, the new version appears on this page '
    'with a new date at the top.';
const String _enH2Contact = 'Contact.';

/// Every h1, h2 and p of the English document, as markup, in order.
List<String> _expectedEnglish({String? escapedEmail}) => <String>[
      '<h1>$_enH1</h1>',
      '<p class="updated">Last updated: $privacyLastUpdated</p>',
      '<p>$_enIntro</p>',
      '<h2>$_enH2Collect</h2>',
      '<p>$_enPCollect</p>',
      '<h2>$_enH2Ads</h2>',
      '<p>$_enPAds</p>',
      '<h2>$_enH2Typed</h2>',
      '<p>$_enPTyped</p>',
      '<h2>$_enH2Logs</h2>',
      '<p>$_enPLogs</p>',
      '<h2>$_enH2Rolls</h2>',
      '<p>$_enPRolls</p>',
      '<h2>$_enH2Children</h2>',
      '<p>$_enPChildren</p>',
      '<h2>$_enH2Ask</h2>',
      '<p>${escapedEmail != null ? _enPAskWith : _enPAskWithout}</p>',
      '<h2>$_enH2Changes</h2>',
      '<p>$_enPChanges</p>',
      if (escapedEmail != null) ...<String>[
        '<h2>$_enH2Contact</h2>',
        '<p>$escapedEmail</p>',
      ],
    ];

/// Every h1, h2 and p of the Arabic document, as markup, in order.
List<String> _expectedArabic({String? escapedEmail}) => <String>[
      '<h1>$_arH1</h1>',
      '<p class="updated">$_arUpdated</p>',
      '<p>$_arIntro</p>',
      '<h2>$_arH2Collect</h2>',
      '<p>$_arPCollect</p>',
      '<h2>$_arH2Ads</h2>',
      '<p>$_arPAds</p>',
      '<h2>$_arH2Typed</h2>',
      '<p>$_arPTyped</p>',
      '<h2>$_arH2Logs</h2>',
      '<p>$_arPLogs</p>',
      '<h2>$_arH2Rolls</h2>',
      '<p>$_arPRolls</p>',
      '<h2>$_arH2Children</h2>',
      '<p>$_arPChildren</p>',
      '<h2>$_arH2Ask</h2>',
      '<p>${escapedEmail != null ? _arPAskWith : _arPAskWithout}</p>',
      '<h2>$_arH2Changes</h2>',
      '<p>$_arPChanges</p>',
      if (escapedEmail != null) ...<String>[
        '<h2>$_arH2Contact</h2>',
        '<p><span dir="ltr">$escapedEmail</span></p>',
      ],
    ];

// ---------------------------------------------------------------------------
// Reading a document.
// ---------------------------------------------------------------------------

/// Calls `buildPrivacyPageHtml` with only the arguments given, so a call
/// without [language] compiles and runs on the base commit too.
String _build({String? language, String? email, bool emailGiven = false}) {
  final Map<Symbol, Object?> named = <Symbol, Object?>{};
  if (language != null) {
    named[#language] = language;
  }
  if (email != null || emailGiven) {
    named[#contactEmail] = email;
  }
  return Function.apply(buildPrivacyPageHtml, <Object?>[], named) as String;
}

final RegExp _bodyPattern = RegExp(r'<body[^>]*>(.*)</body>', dotAll: true);
final RegExp _elementPattern =
    RegExp(r'<(h1|h2|p)\b[^>]*>.*?</\1>', dotAll: true);
final RegExp _stylePattern = RegExp(r'<style>(.*?)</style>', dotAll: true);

String _bodyOf(String doc) {
  final RegExpMatch? m = _bodyPattern.firstMatch(doc);
  if (m == null) {
    fail('no <body>...</body> in the document: $doc');
  }
  return m.group(1)!;
}

List<String> _elementsOf(String doc) => _elementPattern
    .allMatches(_bodyOf(doc))
    .map((RegExpMatch m) => m.group(0)!)
    .toList();

/// What is left of the body once every h1, h2 and p is taken out.
String _bodyRemainder(String doc) =>
    _bodyOf(doc).replaceAll(_elementPattern, '').trim();

String _styleOf(String doc) {
  final RegExpMatch? m = _stylePattern.firstMatch(doc);
  if (m == null) {
    fail('no <style> block in the document: $doc');
  }
  return m.group(1)!;
}

void _expectDocument(
  String doc,
  String language,
  List<String> expected,
  String scenario,
) {
  final bool ar = language == 'ar';
  expect(
    doc.contains(ar ? '<html lang="ar" dir="rtl">' : '<html lang="en">'),
    isTrue,
    reason: 'expected ${ar ? '<html lang="ar" dir="rtl">' : '<html lang="en">'}'
        '. ${_repro(scenario)}. Got: $doc',
  );
  if (!ar) {
    expect(
      doc.contains('dir="rtl"'),
      isFalse,
      reason: 'the English document must not carry dir="rtl". '
          '${_repro(scenario)}. Got: $doc',
    );
  }
  expect(
    doc.contains('<title>${ar ? _arH1 : _enH1}</title>'),
    isTrue,
    reason: 'expected <title>${ar ? _arH1 : _enH1}</title>. '
        '${_repro(scenario)}. Got: $doc',
  );
  expect(
    _elementsOf(doc),
    equals(expected),
    reason: 'the h1/h2/p sequence of the $language document differs from '
        'the contract, in wording, markup or order. ${_repro(scenario)}',
  );
  final String switchLink = ar ? _switchToEnglish : _switchToArabic;
  expect(
    _bodyRemainder(doc),
    switchLink,
    reason: 'outside the h1/h2/p elements the body must hold exactly the '
        'switch link $switchLink. ${_repro(scenario)}. Got: $doc',
  );
  expect(
    _bodyOf(doc).trimRight().endsWith(switchLink),
    isTrue,
    reason: 'the switch link must be the last element of <body>. '
        '${_repro(scenario)}. Got: $doc',
  );
  expect(
    'id="lang-switch"'.allMatches(doc).length,
    1,
    reason: 'exactly one #lang-switch expected. ${_repro(scenario)}',
  );
}

// ---------------------------------------------------------------------------
// HTTP plumbing.
// ---------------------------------------------------------------------------

class _Res {
  _Res(this.method, this.target, this.status, this.headers, this.body);

  final String method;
  final String target;
  final int status;
  final Map<String, String> headers;
  final String body;

  String? header(String name) => headers[name.toLowerCase()];

  String describe() => 'request $method $target answered $status with '
      'headers $headers and body of ${body.length} characters: '
      '${body.length > 400 ? '${body.substring(0, 400)}...' : body}';
}

Future<_Res> _request(
  HttpClient client,
  int port,
  String method,
  String pathAndQuery, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClientRequest request = await client.openUrl(
      method, Uri.parse('http://127.0.0.1:$port$pathAndQuery'));
  headers.forEach(request.headers.set);
  final HttpClientResponse response = await request.close();
  final Map<String, String> seen = <String, String>{};
  response.headers.forEach((String name, List<String> values) {
    seen[name.toLowerCase()] = values.join(', ');
  });
  final String body = await response.transform(utf8.decoder).join();
  return _Res(method, pathAndQuery, response.statusCode, seen, body);
}

WireServer _server({String? privacyContactEmail}) {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 11));
  return WireServer(
    registry: RoomRegistry(clock: clock, secure: Random.secure()),
    rateLimiter: RateLimiter(clock: clock),
    clock: clock,
    privacyContactEmail: privacyContactEmail,
  );
}

String _langOf(_Res res) {
  if (res.body.contains('<html lang="ar" dir="rtl">')) {
    return 'ar';
  }
  if (res.body.contains('<html lang="en">')) {
    return 'en';
  }
  return 'neither';
}

void main() {
  // -------------------------------------------------------------------------
  // (a) the Arabic document
  // -------------------------------------------------------------------------
  group('(a) the Arabic document', () {
    test('(a1) without an address: head, sequence, short paragraph, switch',
        () {
      const String scenario = '(a1) Arabic document, no address';
      final String doc = _build(language: 'ar');
      _expectDocument(doc, 'ar', _expectedArabic(), scenario);
      expect(
        doc.contains(_arH2Contact),
        isFalse,
        reason: 'no contact heading without an address. ${_repro(scenario)}',
      );
      expect(
        doc.contains('@'),
        isFalse,
        reason: 'no address, so no "@" anywhere. ${_repro(scenario)}',
      );
      expect(
        doc.contains(_arPAskWith),
        isFalse,
        reason: 'the "write to the address below" sentence must not point at '
            'nothing. ${_repro(scenario)}',
      );
    });

    test('(a2) with an address: contact section, ltr span, sequence', () {
      const String scenario = '(a2) Arabic document, plain address';
      final String doc = _build(language: 'ar', email: _plainEmail);
      _expectDocument(
        doc,
        'ar',
        _expectedArabic(escapedEmail: _plainEmail),
        scenario,
      );
      expect(
        doc.contains('<h2>$_arH2Contact</h2>'),
        isTrue,
        reason: 'contact heading expected with an address. ${_repro(scenario)}',
      );
    });

    test('(a3) a hostile address is escaped inside the ltr span', () {
      const String scenario = '(a3) Arabic document, address a<b>@x.test';
      final String doc = _build(language: 'ar', email: _hostileEmail);
      expect(
        doc.contains('<span dir="ltr">$_hostileEmailEscaped</span>'),
        isTrue,
        reason: 'expected <span dir="ltr">$_hostileEmailEscaped</span>. '
            '${_repro(scenario)}. Got: $doc',
      );
      expect(
        doc.contains(_hostileEmail),
        isFalse,
        reason: 'the raw address must not reach the page. ${_repro(scenario)}',
      );
      _expectDocument(
        doc,
        'ar',
        _expectedArabic(escapedEmail: _hostileEmailEscaped),
        scenario,
      );
    });

    test('(a4) the date sits in an ltr span and is the exported date', () {
      const String scenario = '(a4) Arabic date span';
      final String doc = _build(language: 'ar');
      expect(
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(privacyLastUpdated),
        isTrue,
        reason: 'privacyLastUpdated must stay YYYY-MM-DD, got '
            '"$privacyLastUpdated". ${_repro(scenario)}',
      );
      expect(
        doc.contains(
          '<p class="updated">$_arUpdatedPrefix<span dir="ltr">'
          '$privacyLastUpdated</span></p>',
        ),
        isTrue,
        reason: 'expected the date inside <span dir="ltr">. '
            '${_repro(scenario)}. Got: $doc',
      );
    });

    test('(a5) empty and blank addresses are the no-address document', () {
      const String scenario = '(a5) Arabic document, empty and blank address';
      final String none = _build(language: 'ar');
      for (final String blank in <String>['', '   ', '\t\n']) {
        expect(
          _build(language: 'ar', email: blank),
          none,
          reason: 'address ${jsonEncode(blank)} must render exactly as no '
              'address. ${_repro(scenario)}',
        );
      }
    });

    test('(a6) the Arabic document is self-contained', () {
      const String scenario = '(a6) Arabic document, no script or external '
          'resource';
      final String lower =
          _build(language: 'ar', email: _plainEmail).toLowerCase();
      for (final String tag in <String>['<script', '<link', '<img', '<form']) {
        expect(
          lower.contains(tag),
          isFalse,
          reason: 'found $tag in the Arabic document. ${_repro(scenario)}',
        );
      }
      expect(
        lower.contains('http://') || lower.contains('https://'),
        isFalse,
        reason: 'the Arabic document names an external URL. '
            '${_repro(scenario)}',
      );
    });

    test('(a7) the Arabic document shares the English <style> block', () {
      const String scenario = '(a7) Arabic and English CSS identical';
      expect(
        _styleOf(_build(language: 'ar')),
        _styleOf(_build(language: 'en')),
        reason: 'D3: the same CSS as English. ${_repro(scenario)}',
      );
    });
  });

  // -------------------------------------------------------------------------
  // (b) the English document
  // -------------------------------------------------------------------------
  group('(b) the English document', () {
    test('(b1) without an address: today\'s text, order, plus the switch', () {
      const String scenario = '(b1) English document, no address';
      final String doc = _build();
      _expectDocument(doc, 'en', _expectedEnglish(), scenario);
      expect(
        doc.contains('Contact.') || doc.contains('address below'),
        isFalse,
        reason: 'no contact section and no "address below" without an '
            'address. ${_repro(scenario)}',
      );
    });

    test('(b2) with an address: contact section, escaped', () {
      const String scenario = '(b2) English document, plain address';
      _expectDocument(
        _build(email: _plainEmail),
        'en',
        _expectedEnglish(escapedEmail: _plainEmail),
        scenario,
      );
    });

    test('(b3) a hostile address is escaped as before, no ltr span', () {
      const String scenario = '(b3) English document, address a<b>@x.test';
      final String doc = _build(email: _hostileEmail);
      _expectDocument(
        doc,
        'en',
        _expectedEnglish(escapedEmail: _hostileEmailEscaped),
        scenario,
      );
      expect(
        doc.contains(_hostileEmail),
        isFalse,
        reason: 'the raw address must not reach the page. ${_repro(scenario)}',
      );
    });

    test('(b4) empty and blank addresses are the no-address document', () {
      const String scenario = '(b4) English document, empty and blank address';
      final String none = _build();
      for (final String blank in <String>['', '   ', '\t\n']) {
        expect(
          _build(email: blank),
          none,
          reason: 'address ${jsonEncode(blank)} must render exactly as no '
              'address. ${_repro(scenario)}',
        );
      }
    });

    test('(b5) the default language equals language: en', () {
      const String scenario = '(b5) default language is English';
      expect(
        _build(),
        _build(language: 'en'),
        reason: 'D1: language defaults to en. ${_repro(scenario)}',
      );
      expect(
        _build(email: _plainEmail),
        _build(language: 'en', email: _plainEmail),
        reason: 'D1: language defaults to en, with an address. '
            '${_repro(scenario)}',
      );
    });

    test('(b6) any language other than exactly ar renders English', () {
      const String scenario = '(b6) unknown language renders English';
      final String english = _build(language: 'en');
      for (final String other in <String>['fr', 'AR', 'ar ', 'ar-AE', '']) {
        expect(
          _build(language: other),
          english,
          reason: 'language ${jsonEncode(other)} must render the English '
              'document. ${_repro(scenario)}',
        );
      }
    });

    test('(b7) the document is the same on every call', () {
      const String scenario = '(b7) builder is a pure function';
      expect(_build(language: 'ar'), _build(language: 'ar'),
          reason: 'two calls differ. ${_repro(scenario)}');
      expect(_build(), _build(),
          reason: 'two calls differ. ${_repro(scenario)}');
    });
  });

  // -------------------------------------------------------------------------
  // (c) both documents
  // -------------------------------------------------------------------------
  group('(c) both documents', () {
    for (final String language in <String>['en', 'ar']) {
      test(
          '(c1) $language: a .switch rule of the home page\'s five '
          'declarations, min-height 3rem', () {
        final String scenario = '(c1) $language .switch rule';
        final String doc = _build(language: language, email: _plainEmail);
        final RegExpMatch? rule =
            RegExp(r'\.switch\s*\{([^}]*)\}').firstMatch(_styleOf(doc));
        expect(
          rule,
          isNotNull,
          reason: 'no .switch rule in the $language document. '
              '${_repro(scenario)}. Got: ${_styleOf(doc)}',
        );
        final Map<String, String> declarations = <String, String>{};
        for (final String part in rule!.group(1)!.split(';')) {
          if (part.trim().isEmpty) {
            continue;
          }
          final int colon = part.indexOf(':');
          declarations[part.substring(0, colon).trim()] =
              part.substring(colon + 1).trim();
        }
        expect(
          declarations,
          <String, String>{
            'display': 'inline-flex',
            'align-items': 'center',
            'min-height': '3rem',
            'padding': '0 0.75rem',
            'color': '#0F6B5F',
          },
          reason: 'the .switch rule of the $language document must equal '
              'the home page rule (a tap target of at least 3 rem). '
              '${_repro(scenario)}',
        );
      });

      test('(c2) $language: no em-dash, en-dash, "provably" or "absolute"', () {
        final String scenario = '(c2) $language banned characters and words';
        final String doc = _build(language: language, email: _plainEmail);
        expect(
          doc.contains(_emDash),
          isFalse,
          reason: 'em-dash (U+2014) in the $language document. '
              '${_repro(scenario)}',
        );
        expect(
          doc.contains(_enDash),
          isFalse,
          reason: 'en-dash (U+2013) in the $language document. '
              '${_repro(scenario)}',
        );
        final RegExpMatch? word =
            RegExp(r'provably|absolute', caseSensitive: false).firstMatch(doc);
        expect(
          word?.group(0),
          isNull,
          reason: 'banned word in the $language document. '
              '${_repro(scenario)}',
        );
      });
    }
  });

  // -------------------------------------------------------------------------
  // (d), (e) the route
  // -------------------------------------------------------------------------
  group('(d) (e) GET /privacy', () {
    late WireServer server;
    late int port;
    late HttpClient client;

    setUpAll(() async {
      server = _server();
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      port = server.port;
      client = HttpClient();
    });

    tearDownAll(() async {
      client.close(force: true);
      await server.close();
    });

    Future<_Res> req(
      String method,
      String target, {
      String? acceptLanguage,
    }) =>
        _request(
          client,
          port,
          method,
          target,
          headers: <String, String>{
            if (acceptLanguage != null) 'accept-language': acceptLanguage,
          },
        );

    final List<List<String?>> choices = <List<String?>>[
      // path, accept-language, expected language
      <String?>['/privacy?lang=ar', null, 'ar'],
      <String?>['/privacy/?lang=ar', null, 'ar'],
      <String?>['/privacy?lang=ar', 'en', 'ar'],
      <String?>['/privacy?lang=en', 'ar', 'en'],
      <String?>['/privacy/?lang=en', 'ar', 'en'],
      <String?>['/privacy', 'ar-AE,ar;q=0.9,en;q=0.8', 'ar'],
      <String?>['/privacy/', 'ar-AE,ar;q=0.9,en;q=0.8', 'ar'],
      <String?>['/privacy', 'ar;q=0, en', 'en'],
      <String?>['/privacy', 'ar;q=0.5, en;q=0.9', 'en'],
      <String?>['/privacy', 'ar', 'ar'],
      <String?>['/privacy', 'fr, de', 'en'],
      <String?>['/privacy', null, 'en'],
      <String?>['/privacy/', null, 'en'],
      <String?>['/privacy?lang=fr', 'ar', 'ar'],
      <String?>['/privacy?lang=fr', null, 'en'],
      <String?>['/privacy?lang=AR', 'ar', 'ar'],
      <String?>['/privacy?lang=AR', null, 'en'],
      <String?>['/privacy?lang=', 'ar', 'ar'],
    ];

    for (final List<String?> c in choices) {
      final String target = c[0]!;
      final String? accept = c[1];
      final String expected = c[2]!;
      final String name = '(d) GET $target, Accept-Language '
          '${accept ?? "(none)"} -> $expected';
      test(name, () async {
        final _Res res = await req('GET', target, acceptLanguage: accept);
        expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
        expect(
          _langOf(res),
          expected,
          reason: 'expected the $expected document. ${_repro(name)}. '
              '${res.describe()}',
        );
        expect(
          res.body.contains(
            expected == 'ar' ? _switchToEnglish : _switchToArabic,
          ),
          isTrue,
          reason: 'the $expected document must carry its switch link. '
              '${_repro(name)}. ${res.describe()}',
        );
      });
    }

    test('(d) both languages, no address: the whole document is served',
        () async {
      const String name = '(d) served bodies are the built documents';
      final _Res ar = await req('GET', '/privacy?lang=ar');
      _expectDocument(ar.body, 'ar', _expectedArabic(), name);
      final _Res en = await req('GET', '/privacy?lang=en');
      _expectDocument(en.body, 'en', _expectedEnglish(), name);
    });

    test('(d) the served Arabic page is read as UTF-8 and stays intact',
        () async {
      const String name = '(d) Arabic bytes round trip';
      final HttpClientRequest request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/privacy?lang=ar'),
      );
      final HttpClientResponse response = await request.close();
      final List<int> bytes = await response.fold<List<int>>(
        <int>[],
        (List<int> all, List<int> chunk) => all..addAll(chunk),
      );
      expect(
        utf8.decode(bytes),
        _build(language: 'ar'),
        reason: 'served bytes decoded as UTF-8 must equal the Arabic '
            'document. ${_repro(name)}',
      );
    });

    test('(d) forty parallel requests, alternating language, never cross',
        () async {
      const String name = '(d) parallel requests keep their language';
      final List<Future<_Res>> pending = <Future<_Res>>[];
      final List<String> wanted = <String>[];
      for (int i = 0; i < 40; i++) {
        final bool ar = i.isEven;
        wanted.add(ar ? 'ar' : 'en');
        pending.add(
          req('GET', i % 4 < 2 ? '/privacy' : '/privacy/',
              acceptLanguage: ar ? 'ar' : 'en'),
        );
      }
      final List<_Res> done = await Future.wait(pending);
      for (int i = 0; i < done.length; i++) {
        expect(
          _langOf(done[i]),
          wanted[i],
          reason: 'request $i wanted ${wanted[i]}. ${_repro(name)}. '
              '${done[i].describe()}',
        );
      }
    });

    test('(d) one document is served again and again, byte for byte', () async {
      const String name = '(d) repeated GET is identical';
      for (final String target in <String>[
        '/privacy?lang=ar',
        '/privacy?lang=en',
      ]) {
        final _Res first = await req('GET', target);
        final _Res second = await req('GET', target);
        expect(
          second.body,
          first.body,
          reason: 'two GETs of $target differ. ${_repro(name)}',
        );
      }
    });

    final List<List<String?>> headerRequests = <List<String?>>[
      <String?>['/privacy', null],
      <String?>['/privacy/', null],
      <String?>['/privacy?lang=ar', null],
      <String?>['/privacy/?lang=ar', null],
      <String?>['/privacy', 'ar'],
      <String?>['/privacy?lang=en', 'ar'],
    ];

    for (final List<String?> h in headerRequests) {
      final String target = h[0]!;
      final String? accept = h[1];
      final String name = '(e) GET $target, Accept-Language '
          '${accept ?? "(none)"}: the D5 header set';
      test(name, () async {
        final _Res res = await req('GET', target, acceptLanguage: accept);
        expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
        final Map<String, String> expected = <String, String>{
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'public, max-age=3600',
          'vary': 'accept-language',
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
          'content-security-policy': _expectedCsp,
        };
        expected.forEach((String header, String value) {
          expect(
            res.header(header),
            value,
            reason: 'header $header expected "$value", got '
                '"${res.header(header)}". ${_repro(name)}. ${res.describe()}',
          );
        });
      });
    }

    for (final List<String?> h in headerRequests) {
      final String target = h[0]!;
      final String? accept = h[1];
      final String name = '(e) HEAD $target, Accept-Language '
          '${accept ?? "(none)"}: same headers as GET, empty body';
      test(name, () async {
        final _Res get = await req('GET', target, acceptLanguage: accept);
        final _Res head = await req('HEAD', target, acceptLanguage: accept);
        expect(head.status, 200, reason: '${_repro(name)}. ${head.describe()}');
        expect(head.body, isEmpty,
            reason: 'HEAD body must be empty. ${_repro(name)}. '
                '${head.describe()}');
        for (final String header in <String>[
          'content-type',
          'cache-control',
          'vary',
          'x-content-type-options',
          'referrer-policy',
          'content-security-policy',
        ]) {
          expect(
            head.header(header),
            isNotNull,
            reason: 'HEAD is missing $header. ${_repro(name)}. '
                '${head.describe()}',
          );
          expect(
            head.header(header),
            get.header(header),
            reason: 'HEAD $header "${head.header(header)}" differs from GET '
                '"${get.header(header)}". ${_repro(name)}',
          );
        }
      });
    }

    test('(e) the CSP lets the page\'s inline <style> through', () async {
      const String name = '(e) CSP allows inline style';
      final _Res res = await req('GET', '/privacy?lang=ar');
      final String csp = res.header('content-security-policy') ?? '';
      expect(
        csp.contains("style-src 'unsafe-inline'"),
        isTrue,
        reason: 'the page has an inline <style>; its policy must allow it. '
            'Got "$csp". ${_repro(name)}',
      );
      expect(
        res.body.contains('<style>'),
        isTrue,
        reason: 'the Arabic page has no <style> block. ${_repro(name)}',
      );
    });

    for (final String method in <String>['POST', 'PUT', 'DELETE', 'PATCH']) {
      for (final String target in <String>[
        '/privacy',
        '/privacy/',
        '/privacy?lang=ar',
      ]) {
        final String name = '(e) $method $target -> 405, allow: GET, HEAD';
        test(name, () async {
          final _Res res = await req(method, target, acceptLanguage: 'ar');
          expect(res.status, 405, reason: '${_repro(name)}. ${res.describe()}');
          expect(
            res.header('allow'),
            'GET, HEAD',
            reason: 'allow must be exactly "GET, HEAD". ${_repro(name)}. '
                '${res.describe()}',
          );
          expect(
            res.body.contains('<html'),
            isFalse,
            reason: 'a 405 must not carry the policy document. '
                '${_repro(name)}. ${res.describe()}',
          );
        });
      }
    }

    test('(e) /Privacy is still not the page, with or without ?lang', () async {
      const String name = '(e) /Privacy stays unrouted';
      final _Res res = await req('GET', '/Privacy?lang=ar');
      expect(
        res.body.contains(_arH1),
        isFalse,
        reason: 'the privacy page answered for /Privacy. ${_repro(name)}. '
            '${res.describe()}',
      );
    });
  });

  group('(d) (e) GET /privacy with a contact address configured', () {
    late WireServer server;
    late int port;
    late HttpClient client;

    setUpAll(() async {
      server = _server(privacyContactEmail: _hostileEmail);
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      port = server.port;
      client = HttpClient();
    });

    tearDownAll(() async {
      client.close(force: true);
      await server.close();
    });

    test('(d) the Arabic route carries the escaped address in an ltr span',
        () async {
      const String name = '(d) Arabic route, address a<b>@x.test';
      final _Res res = await _request(client, port, 'GET', '/privacy?lang=ar');
      _expectDocument(
        res.body,
        'ar',
        _expectedArabic(escapedEmail: _hostileEmailEscaped),
        name,
      );
    });

    test('(d) the English route carries the escaped address', () async {
      const String name = '(d) English route, address a<b>@x.test';
      final _Res res = await _request(client, port, 'GET', '/privacy?lang=en');
      _expectDocument(
        res.body,
        'en',
        _expectedEnglish(escapedEmail: _hostileEmailEscaped),
        name,
      );
    });
  });

  // -------------------------------------------------------------------------
  // (f) the home page
  // -------------------------------------------------------------------------
  group('(f) the home page links to the page it came from', () {
    final RegExp privacyTag = RegExp(r'<a id="privacy"[^>]*>');

    String hrefOf(String html, String scenario) {
      final Iterable<RegExpMatch> tags = privacyTag.allMatches(html);
      expect(
        tags.length,
        1,
        reason: 'expected exactly one #privacy link. ${_repro(scenario)}',
      );
      final RegExpMatch? href =
          RegExp(r'href="([^"]*)"').firstMatch(tags.first.group(0)!);
      return href?.group(1) ?? '(no href)';
    }

    test('(f1) the English home page links /privacy?lang=en', () {
      const String name = '(f1) English home privacy link';
      final String html = buildHomePageHtml(language: 'en');
      expect(
        html.contains('href="/privacy?lang=en"'),
        isTrue,
        reason: 'expected href="/privacy?lang=en"; the link is '
            '"${hrefOf(html, name)}". ${_repro(name)}',
      );
    });

    test('(f2) the Arabic home page links /privacy?lang=ar', () {
      const String name = '(f2) Arabic home privacy link';
      final String html = buildHomePageHtml(language: 'ar');
      expect(
        html.contains('href="/privacy?lang=ar"'),
        isTrue,
        reason: 'expected href="/privacy?lang=ar"; the link is '
            '"${hrefOf(html, name)}". ${_repro(name)}',
      );
    });

    test('(f3) nothing else on the home page changed', () {
      const String name = '(f3) home page digest, link put back';
      // sha256 of the home page on base 494c912, whose privacy link is the
      // bare /privacy.
      const Map<String, String> baseDigest = <String, String>{
        'en':
            '4ab1013d8aa417057aac34aed860424ae6d8b9614525f5f1cdf027eac45c6013',
        'ar':
            'a8f7d5fe81dede644f3db8987430f651ab852d8312149a44d2a98e9efafb445f',
      };
      for (final String lang in <String>['en', 'ar']) {
        // C-633: the base digest is of the public-listing page; the
        // closed-test install block is pinned in c633_tester_path_test.dart.
        final String html = buildHomePageHtml(language: lang, closedTest: false)
            .replaceFirst('href="/privacy?lang=$lang"', 'href="/privacy"');
        expect(
          sha256.convert(utf8.encode(html)).toString(),
          baseDigest[lang],
          reason: 'the $lang home page differs from base in more than the '
              'privacy link. ${_repro(name)}',
        );
      }
    });

    group('served', () {
      late WireServer server;
      late int port;
      late HttpClient client;

      setUpAll(() async {
        server = _server();
        await server.start(address: InternetAddress.loopbackIPv4, port: 0);
        port = server.port;
        client = HttpClient();
      });

      tearDownAll(() async {
        client.close(force: true);
        await server.close();
      });

      final List<List<String?>> cases = <List<String?>>[
        // home path, accept-language of the home request, home language
        <String?>['/?lang=en', 'ar', 'en'],
        <String?>['/?lang=ar', 'en', 'ar'],
        <String?>['/', 'ar-AE,ar;q=0.9', 'ar'],
        <String?>['/', null, 'en'],
      ];

      for (final List<String?> c in cases) {
        final String home = c[0]!;
        final String? accept = c[1];
        final String lang = c[2]!;
        final String name = '(f4) GET $home, Accept-Language '
            '${accept ?? "(none)"}: the link opens the $lang policy even '
            'when the browser asks for the other';
        test(name, () async {
          final _Res page = await _request(
            client,
            port,
            'GET',
            home,
            headers: <String, String>{
              if (accept != null) 'accept-language': accept,
            },
          );
          final RegExpMatch? tag = privacyTag.firstMatch(page.body);
          expect(tag, isNotNull,
              reason: 'no #privacy link. ${_repro(name)}. ${page.describe()}');
          final String href =
              RegExp(r'href="([^"]*)"').firstMatch(tag!.group(0)!)!.group(1)!;
          expect(
            href,
            '/privacy?lang=$lang',
            reason: 'home link for $lang. ${_repro(name)}. ${page.describe()}',
          );
          // Follow the link with the opposite browser preference.
          final _Res policy = await _request(
            client,
            port,
            'GET',
            href,
            headers: <String, String>{
              'accept-language': lang == 'ar' ? 'en' : 'ar',
            },
          );
          expect(policy.status, 200,
              reason: '${_repro(name)}. ${policy.describe()}');
          expect(
            _langOf(policy),
            lang,
            reason: 'following $href with the opposite Accept-Language must '
                'still give the $lang policy. ${_repro(name)}. '
                '${policy.describe()}',
          );
        });
      }
    });
  });
}
