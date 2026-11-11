// The privacy policy page served at `GET /privacy`. The document is built
// once, at compile time, from the blessed-pending draft text in
// `work/ludo/PRIVACY_DRAFT.md` (the section headed `## The text`). Nothing
// here reads a file at request time: [buildPrivacyPageHtml] is a pure
// function of one optional string, called once by `WireServer.start` and
// cached, per order 049.
//
// The wording below is the draft's wording, unchanged, with one exception
// forced by the contact address being configuration and not always present:
// the "Data you can ask about" paragraph's second sentence ("If you believe
// we hold something about you ... write to the address below") is a promise
// that only holds when there is an address below, so it is omitted along
// with the contact section rather than left pointing at nothing. The other
// edits made converting the draft to HTML are: the bold lead-ins became
// `<h2>` headings, the publication date replaced the `[DATE OF
// PUBLICATION]` placeholder, and the one em-dash in the draft's title
// ("Privacy Policy - Ludo RNG") was rewritten as a hyphen, because hard rule
// 5 of the mission forbids an em-dash reaching a public page. Nothing else
// was added, and nothing else was dropped.
//
// The Arabic document is a translation of the same text, kept in this file
// beside the English, and a change to either language's wording changes
// both and bumps `privacyLastUpdated`.

import 'dart:convert';

/// `YYYY-MM-DD`, matching the "Last updated" line in the rendered page.
/// Bump this string, and only this string, the day the policy text changes.
const String privacyLastUpdated = '2026-09-30';

const HtmlEscape _escaper = HtmlEscape();

/// Builds the complete privacy policy document.
///
/// [contactEmail] is the operator-supplied contact address, read from the
/// `PRIVACY_CONTACT_EMAIL` environment variable by `bin/server.dart` and
/// passed in here as configuration -- this function never reads the
/// environment itself. Null or empty omits the contact section entirely
/// rather than shipping an invented or a placeholder address; the value is
/// HTML-escaped before it is interpolated, since it arrives from the
/// environment and lands in a public page. [language] `'ar'` renders the
/// Arabic document; anything else renders English.
String buildPrivacyPageHtml({String? contactEmail, String language = 'en'}) {
  final String? trimmedEmail =
      (contactEmail != null && contactEmail.trim().isNotEmpty)
          ? contactEmail
          : null;

  final bool isAr = language == 'ar';
  final StringBuffer body =
      isAr ? _arabicBody(trimmedEmail) : _englishBody(trimmedEmail);
  final String switchLink = isAr
      ? '<a id="lang-switch" class="switch" href="?lang=en" hreflang="en" '
          'lang="en">English</a>'
      : '<a id="lang-switch" class="switch" href="?lang=ar" hreflang="ar" '
          'lang="ar">العربية</a>';
  body.writeln(switchLink);
  final String htmlTag =
      isAr ? '<html lang="ar" dir="rtl">' : '<html lang="en">';
  final String title =
      isAr ? 'سياسة الخصوصية - Ludo RNG' : 'Privacy Policy - Ludo RNG';

  return '''
<!DOCTYPE html>
$htmlTag
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  max-width: 40em;
  margin: 0 auto;
  padding: 1.5em;
  line-height: 1.5;
  color: #1a1a1a;
}
h1 {
  font-size: 1.4em;
}
h2 {
  font-size: 1.1em;
  margin-top: 1.5em;
}
p.updated {
  color: #555;
}
.switch {
  display: inline-flex;
  align-items: center;
  min-height: 3rem;
  padding: 0 0.75rem;
  color: #0F6B5F;
}
</style>
</head>
<body>
$body</body>
</html>
''';
}

StringBuffer _englishBody(String? trimmedEmail) {
  final StringBuffer body = StringBuffer()
    ..writeln('<h1>Privacy Policy - Ludo RNG</h1>')
    ..writeln('<p class="updated">Last updated: $privacyLastUpdated</p>')
    ..writeln(
      '<p>Ludo RNG is a game you play online with people you invite. '
      'This policy explains what the app and its server handle, and what '
      'they do not.</p>',
    )
    ..writeln('<h2>We do not collect personal information.</h2>')
    ..writeln(
      '<p>Ludo RNG has no account, no sign-in, no email address, no '
      'password and no profile. You do not tell us who you are and we do '
      'not ask.</p>',
    )
    ..writeln('<h2>No advertising, no analytics, no tracking.</h2>')
    ..writeln(
      '<p>The app contains no advertising network, no analytics library '
      'and no third-party crash reporting. Nothing about your use of the '
      'app is shared with any other company. There is no advertising '
      'identifier and no device identifier collected.</p>',
    )
    ..writeln('<h2>What you type, and where it goes.</h2>')
    ..writeln(
      '<p>To play, you create a room or join one with a room code. You '
      'may enter a display name for your seat. That name and the room '
      'code are sent to our server so the other players in your room can '
      'see them, and they are visible to everyone in that room. Choose a '
      'display name you are comfortable showing to the people you '
      'invited. Rooms are temporary: the room and everything in it, '
      'including any display name, is deleted from the server when the '
      'room ends or expires.</p>',
    )
    ..writeln('<h2>What the server records automatically.</h2>')
    ..writeln(
      '<p>Like any server on the internet, ours records the technical '
      'details of a connection so the service can be kept working and '
      'abuse can be stopped: the IP address of the connecting device, the '
      'time of the connection, and error information. These records are '
      'kept for a short period and are not used to build a profile of '
      'you, are not sold, and are not shared with anyone except where the '
      'law requires it.</p>',
    )
    ..writeln('<h2>Verifiable rolls.</h2>')
    ..writeln(
      '<p>Every dice roll is accompanied by information that lets you '
      'check the roll was not altered after the fact. That information '
      'is about the game, not about you, and contains no personal '
      'data. When a game ends, a record of its rolls is kept on our '
      'server for 90 days at a web address given only to the players of '
      'that game, so anyone holding the link can check every roll. The '
      'record names players by seat number only, never by display name, '
      'and holds no IP address.</p>',
    )
    ..writeln('<h2>Children.</h2>')
    ..writeln(
      '<p>Ludo RNG is not directed at children under 13. We do not '
      'knowingly collect any personal information from anyone, including '
      'children.</p>',
    )
    ..writeln('<h2>Data you can ask about.</h2>')
    ..writeln(
      trimmedEmail != null
          ? '<p>Because we hold no account and no personal profile, there is '
              'normally nothing to give you a copy of or to delete. If you '
              'believe we hold something about you and you want it removed, '
              'write to the address below and we will act on it.</p>'
          : '<p>Because we hold no account and no personal profile, there is '
              'normally nothing to give you a copy of or to delete.</p>',
    )
    ..writeln('<h2>Changes to this policy.</h2>')
    ..writeln(
      '<p>If this policy changes, the new version appears on this page '
      'with a new date at the top.</p>',
    );

  if (trimmedEmail != null) {
    final String escapedEmail = _escaper.convert(trimmedEmail);
    body
      ..writeln('<h2>Contact.</h2>')
      ..writeln('<p>$escapedEmail</p>');
  }

  return body;
}

StringBuffer _arabicBody(String? trimmedEmail) {
  final bool hasEmail = trimmedEmail != null;
  final StringBuffer body = StringBuffer()
    ..writeln(
      '<h1>سياسة الخصوصية - Ludo RNG</h1>',
    )
    ..writeln(
      '<p class="updated">آخر تحديث: '
      '<span dir="ltr">$privacyLastUpdated</span></p>',
    )
    ..writeln(
      '<p>Ludo RNG لعبة تلعبها عبر الإنترنت مع أشخاص تدعوهم أنت. '
      'توضّح هذه السياسة ما يتعامل معه التطبيق وخادمه من '
      'بيانات، وما لا يتعامل معه.</p>',
    )
    ..writeln(
      '<h2>لا نجمع معلومات شخصية.</h2>',
    )
    ..writeln(
      '<p>لا يوجد في Ludo RNG حساب، ولا تسجيل دخول، ولا بريد '
      'إلكتروني، ولا كلمة مرور، ولا ملف شخصي. لا تخبرنا من أنت، '
      'ولا نسألك.</p>',
    )
    ..writeln(
      '<h2>لا إعلانات، ولا تحليلات، ولا تتبّع.</h2>',
    )
    ..writeln(
      '<p>لا يحتوي التطبيق على أي شبكة إعلانات، ولا مكتبة تحليلات، '
      'ولا أداة تقارير أعطال من طرف ثالث. لا نشارك أي شيء عن '
      'استخدامك للتطبيق مع أي شركة أخرى. لا نجمع معرّف '
      'الإعلانات ولا أي معرّف للجهاز.</p>',
    )
    ..writeln(
      '<h2>ما تكتبه، وإلى أين يذهب.</h2>',
    )
    ..writeln(
      '<p>لتلعب، تنشئ غرفة أو تنضم إلى غرفة برمزها. يمكنك أن تكتب '
      'اسمًا يظهر على مقعدك. يُرسَل هذا الاسم ورمز الغرفة إلى '
      'خادمنا حتى يراهما باقي اللاعبين في غرفتك، ويظهران لكل من '
      'في تلك الغرفة. اختر اسمًا لا تمانع أن يراه من دعوتهم. '
      'الغرف مؤقتة: تُحذف الغرفة وكل ما فيها، بما في ذلك أي '
      'اسم، من الخادم عندما تنتهي الغرفة أو تنقضي مدتها.</p>',
    )
    ..writeln(
      '<h2>ما يسجّله الخادم تلقائيًا.</h2>',
    )
    ..writeln(
      '<p>مثل أي خادم على الإنترنت، يسجّل خادمنا التفاصيل التقنية '
      'للاتصال حتى تبقى الخدمة تعمل ويمكن إيقاف إساءة '
      'الاستخدام: عنوان IP للجهاز المتصل، ووقت الاتصال، '
      'ومعلومات الأخطاء. تُحفظ هذه السجلات لفترة قصيرة، ولا '
      'تُستخدم لبناء ملف عنك، ولا تُباع، ولا تُشارك مع أحد إلا '
      'حيث يفرض القانون ذلك.</p>',
    )
    ..writeln(
      '<h2>رميات قابلة للتحقق.</h2>',
    )
    ..writeln(
      '<p>ترافق كل رمية نرد معلوماتٌ تتيح لك التحقق من أن الرمية '
      'لم تُغيَّر بعد وقوعها. هذه المعلومات تخص اللعبة لا تخصك، '
      'ولا تحتوي أي بيانات شخصية. عندما تنتهي اللعبة، يُحفظ سجل '
      'رمياتها على خادمنا لمدة 90 يومًا على عنوان ويب لا يُعطى '
      'إلا للاعبي تلك اللعبة، فيستطيع كل من يملك الرابط التحقق '
      'من كل رمية. يذكر السجل اللاعبين برقم المقعد فقط، لا '
      'بأسمائهم أبدًا، ولا يحتوي أي عنوان IP.</p>',
    )
    ..writeln(
      '<h2>الأطفال.</h2>',
    )
    ..writeln(
      '<p>Ludo RNG غير موجّهة للأطفال دون 13 عامًا. لا نجمع عن علم '
      'أي معلومات شخصية من أي أحد، بمن في ذلك الأطفال.</p>',
    )
    ..writeln(
      '<h2>بيانات يمكنك السؤال عنها.</h2>',
    )
    ..writeln(
      hasEmail
          ? '<p>لأننا لا نحتفظ بأي حساب ولا ملف شخصي، فعادةً لا يوجد ما '
              'نعطيك نسخة منه أو نحذفه. إذا كنت تعتقد أننا نحتفظ بشيء '
              'عنك وتريد إزالته، راسلنا على العنوان أدناه وسنتصرف بناءً '
              'على طلبك.</p>'
          : '<p>لأننا لا نحتفظ بأي حساب ولا ملف شخصي، فعادةً لا يوجد ما '
              'نعطيك نسخة منه أو نحذفه.</p>',
    )
    ..writeln(
      '<h2>التغييرات على هذه السياسة.</h2>',
    )
    ..writeln(
      '<p>إذا تغيّرت هذه السياسة، تظهر النسخة الجديدة في هذه '
      'الصفحة مع تاريخ جديد في أعلاها.</p>',
    );

  if (trimmedEmail != null) {
    final String escapedEmail = _escaper.convert(trimmedEmail);
    body
      ..writeln('<h2>التواصل.</h2>')
      ..writeln('<p><span dir="ltr">$escapedEmail</span></p>');
  }
  return body;
}
