// docs/PROTOCOL.md section 36.5: the web deletion page at `/account/delete`
// and the page that answers its form POST. The look is the privacy page's:
// the same type, width and colours, English and Arabic, RTL for Arabic.
//
// With sign-in off the page loads no script and carries the same
// Content-Security-Policy as every other page. With it on, the policy is
// widened by the origins Google documents for its button and nothing else.
// The client id and the host are escaped before they reach an attribute.

import 'dart:convert';

const HtmlEscape _escaper = HtmlEscape(HtmlEscapeMode.attribute);

/// The policy every other page carries.
const String basePageContentSecurityPolicy = "default-src 'none'; "
    "script-src 'self'; style-src 'unsafe-inline'; "
    "base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

/// The base policy widened by Google Identity Services' documented origins:
/// `script-src`, `frame-src`, `connect-src` and `style-src`, section 36.5.
const String signInPageContentSecurityPolicy = "default-src 'none'; "
    "script-src 'self' https://accounts.google.com/gsi/client; "
    'frame-src https://accounts.google.com/gsi/; '
    'connect-src https://accounts.google.com/gsi/; '
    "style-src 'unsafe-inline' https://accounts.google.com/gsi/style; "
    "base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

/// What a form POST to `/account/delete` came to.
enum AccountResult {
  deleted,
  noAccount,
  badToken,
  badRequest,
  tooLarge,
  rateLimited,
  signInOff,
  unavailable,
  storeFailed,
}

/// The status line each [AccountResult] is answered with.
int accountResultStatus(AccountResult result) => switch (result) {
      AccountResult.deleted => 200,
      AccountResult.noAccount => 200,
      AccountResult.badToken => 401,
      AccountResult.badRequest => 400,
      AccountResult.tooLarge => 413,
      AccountResult.rateLimited => 429,
      AccountResult.signInOff => 503,
      AccountResult.unavailable => 503,
      AccountResult.storeFailed => 500,
    };

class _Words {
  const _Words({
    required this.title,
    required this.holdsHeading,
    required this.holds,
    required this.deleteHeading,
    required this.deleteText,
    required this.recordsHeading,
    required this.records,
    required this.inAppHeading,
    required this.inApp,
    required this.signInHeading,
    required this.signInText,
    required this.contactHeading,
    required this.contactText,
    required this.switchLabel,
    required this.switchLang,
  });

  final String title;
  final String holdsHeading;
  final String holds;
  final String deleteHeading;
  final String deleteText;
  final String recordsHeading;
  final String records;
  final String inAppHeading;
  final String inApp;
  final String signInHeading;
  final String signInText;
  final String contactHeading;
  final String contactText;
  final String switchLabel;
  final String switchLang;
}

const _Words _en = _Words(
  title: 'Delete your account - Ludo RNG',
  holdsHeading: 'What an account holds.',
  holds: 'If you signed in with Google, your account holds your display name, '
      'a coded form of your Google account number that cannot be turned back '
      'into it, the time the account was first created and the time you '
      'last signed in. It holds nothing else. We never keep your email '
      'address.',
  deleteHeading: 'What deleting does.',
  deleteText: 'Deleting your account removes all of that at once. It cannot '
      'be undone. You can still play every game without an account.',
  recordsHeading: 'Game records.',
  records: 'Records of finished games, at ludo.provefair.app/v/, hold no '
      'account. They are removed after 90 days anyway.',
  inAppHeading: 'Delete inside the app.',
  inApp: 'In the app, choose the delete account option next to the Google '
      'sign-in on the home screen.',
  signInHeading: 'Delete here.',
  signInText: 'Sign in with the Google account you used in the game. The '
      'account is deleted as soon as Google confirms it is you.',
  contactHeading: 'If you cannot sign in.',
  contactText: 'Write to the address below and we will act on it.',
  switchLabel: 'العربية',
  switchLang: 'ar',
);

const _Words _ar = _Words(
  title: 'حذف حسابك - Ludo RNG',
  holdsHeading: 'ما يحتويه الحساب.',
  holds: 'إذا سجّلت الدخول بحساب Google، يحتفظ حسابك باسمك الظاهر، وبصيغة '
      'مرمّزة من رقم حساب Google لا يمكن إرجاعها إليه، ووقت إنشاء الحساب '
      'أول مرة، ووقت آخر تسجيل دخول. لا يحتفظ بأي شيء غير ذلك. ولا نحتفظ '
      'ببريدك الإلكتروني أبدًا.',
  deleteHeading: 'ما يفعله الحذف.',
  deleteText: 'حذف حسابك يزيل ذلك كله فورًا، ولا يمكن التراجع عنه. وتبقى '
      'قادرًا على لعب كل الألعاب من دون حساب.',
  recordsHeading: 'سجلات الألعاب.',
  records: 'سجلات الألعاب المنتهية، على ludo.provefair.app/v/، لا تحتوي أي '
      'حساب، وتُزال بعد 90 يومًا على كل حال.',
  inAppHeading: 'الحذف من داخل التطبيق.',
  inApp: 'في التطبيق، اختر خيار حذف الحساب بجانب تسجيل الدخول بحساب Google '
      'في الشاشة الرئيسية.',
  signInHeading: 'الحذف من هنا.',
  signInText: 'سجّل الدخول بحساب Google الذي استخدمته في اللعبة. يُحذف الحساب '
      'فور أن تؤكد Google أنك صاحبه.',
  contactHeading: 'إذا تعذّر عليك تسجيل الدخول.',
  contactText: 'راسلنا على العنوان أدناه وسنتصرف بناءً على طلبك.',
  switchLabel: 'English',
  switchLang: 'en',
);

const String _style = '''
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
.switch {
  display: inline-flex;
  align-items: center;
  min-height: 3rem;
  padding: 0 0.75rem;
  color: #0F6B5F;
}
</style>''';

String _document({
  required bool isAr,
  required String title,
  required String body,
  String head = '',
}) {
  final String htmlTag =
      isAr ? '<html lang="ar" dir="rtl">' : '<html lang="en">';
  return '''
<!DOCTYPE html>
$htmlTag
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
$head$_style
</head>
<body>
$body</body>
</html>
''';
}

String _switchLink(_Words words) =>
    '<a id="lang-switch" class="switch" href="?lang=${words.switchLang}" '
    'hreflang="${words.switchLang}" lang="${words.switchLang}">'
    '${words.switchLabel}</a>';

/// `GET /account/delete`. [googleClientId] and [loginUri] both non-null show
/// Google's sign-in button in redirect mode, posting back to [loginUri]; with
/// either null the page has no button and loads no script. [contactEmail] is
/// the `PRIVACY_CONTACT_EMAIL` value, null or empty for none.
String buildAccountDeletePageHtml({
  required String language,
  String? googleClientId,
  String? loginUri,
  String? contactEmail,
}) {
  final bool isAr = language == 'ar';
  final _Words words = isAr ? _ar : _en;
  final bool signIn = googleClientId != null && loginUri != null;
  final StringBuffer body = StringBuffer()
    ..writeln('<h1>${words.title}</h1>')
    ..writeln('<h2>${words.holdsHeading}</h2>')
    ..writeln('<p>${words.holds}</p>')
    ..writeln('<h2>${words.deleteHeading}</h2>')
    ..writeln('<p>${words.deleteText}</p>')
    ..writeln('<h2>${words.recordsHeading}</h2>')
    ..writeln('<p>${words.records}</p>')
    ..writeln('<h2>${words.inAppHeading}</h2>')
    ..writeln('<p>${words.inApp}</p>');
  if (signIn) {
    body
      ..writeln('<h2>${words.signInHeading}</h2>')
      ..writeln('<p>${words.signInText}</p>')
      ..writeln(
        '<div id="g_id_onload" '
        'data-client_id="${_escaper.convert(googleClientId)}" '
        'data-ux_mode="redirect" '
        'data-login_uri="${_escaper.convert(loginUri)}" '
        'data-auto_prompt="false"></div>',
      )
      ..writeln(
        '<div class="g_id_signin" data-type="standard" '
        'data-text="signin_with" '
        'data-locale="${isAr ? 'ar' : 'en'}"></div>',
      );
  }
  final String? contact =
      (contactEmail != null && contactEmail.trim().isNotEmpty)
          ? contactEmail
          : null;
  if (contact != null) {
    body
      ..writeln('<h2>${words.contactHeading}</h2>')
      ..writeln('<p>${words.contactText}</p>')
      ..writeln(
        isAr
            ? '<p><span dir="ltr">${_escaper.convert(contact)}</span></p>'
            : '<p>${_escaper.convert(contact)}</p>',
      );
  }
  body.writeln(_switchLink(words));
  return _document(
    isAr: isAr,
    title: words.title,
    body: body.toString(),
    head: signIn
        ? '<script src="https://accounts.google.com/gsi/client" async></script>\n'
        : '',
  );
}

class _ResultWords {
  const _ResultWords(this.en, this.ar);
  final String en;
  final String ar;
}

const Map<AccountResult, _ResultWords> _resultWords =
    <AccountResult, _ResultWords>{
  AccountResult.deleted: _ResultWords(
    'Your account is deleted.',
    'تم حذف حسابك.',
  ),
  AccountResult.noAccount: _ResultWords(
    'There was no account for this Google account.',
    'لم يكن هناك حساب لحساب Google هذا.',
  ),
  AccountResult.badToken: _ResultWords(
    'Google could not confirm who you are, so nothing was deleted. Try '
        'signing in again.',
    'تعذّر على Google تأكيد هويتك، فلم يُحذف شيء. حاول تسجيل الدخول مرة أخرى.',
  ),
  AccountResult.badRequest: _ResultWords(
    'The request was not understood, so nothing was deleted. Go back to the '
        'page and sign in again.',
    'لم نفهم الطلب، فلم يُحذف شيء. ارجع إلى الصفحة وسجّل الدخول مرة أخرى.',
  ),
  AccountResult.tooLarge: _ResultWords(
    'The request was too large, so nothing was deleted.',
    'الطلب كبير جدًا، فلم يُحذف شيء.',
  ),
  AccountResult.rateLimited: _ResultWords(
    'Too many requests. Wait a minute and try again.',
    'طلبات كثيرة جدًا. انتظر دقيقة ثم حاول مرة أخرى.',
  ),
  AccountResult.signInOff: _ResultWords(
    'Signing in is not available on this server, so there are no accounts '
        'here to delete.',
    'تسجيل الدخول غير متاح على هذا الخادم، فلا توجد حسابات هنا لتُحذف.',
  ),
  AccountResult.unavailable: _ResultWords(
    'Sign-in is not available right now, so nothing was deleted. Try again '
        'later.',
    'تسجيل الدخول غير متاح الآن، فلم يُحذف شيء. حاول مرة أخرى لاحقًا.',
  ),
  AccountResult.storeFailed: _ResultWords(
    'Something went wrong on our side and the account was not deleted. Try '
        'again later, or write to us.',
    'حدث خلل من جهتنا ولم يُحذف الحساب. حاول مرة أخرى لاحقًا، أو راسلنا.',
  ),
};

/// The page answering a form POST to `/account/delete`, in the same style.
String buildAccountResultPageHtml({
  required String language,
  required AccountResult result,
}) {
  final bool isAr = language == 'ar';
  final _Words words = isAr ? _ar : _en;
  final _ResultWords text = _resultWords[result]!;
  final String sentence = isAr ? text.ar : text.en;
  final StringBuffer body = StringBuffer()
    ..writeln('<h1>${words.title}</h1>')
    ..writeln('<p id="result">$sentence</p>')
    ..writeln(
      isAr
          ? '<p><a href="/account/delete?lang=ar">العودة</a></p>'
          : '<p><a href="/account/delete?lang=en">Back</a></p>',
    );
  return _document(isAr: isAr, title: words.title, body: body.toString());
}
