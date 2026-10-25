// The two Android App Links surfaces: the `assetlinks.json` document served
// at `GET /.well-known/assetlinks.json`, and the landing page served at
// `GET /r/<CODE>` for a person who taps a shared room link without the app
// installed. Modelled on `privacy_page.dart`: every function below is pure,
// nothing here reads a file or the environment at request time, and the
// caller (`wire_server.dart`) builds each document once and caches it.
//
// Order 076 pins the fingerprint source at length: it must be the Play
// App Signing key's SHA-256, never the upload key's, and the failure mode of
// getting that wrong produces no error anywhere -- see
// `docs/RELEASE.md:139-159`. This file only formats a fingerprint it is
// given; it has no way to tell which key a caller's value came from, which
// is exactly why the shape check below is the only defence available here.

import 'dart:convert';

/// The registered Android package name. Matches `applicationId` in
/// `packages/ludo_client/android/app/build.gradle.kts`. Permanent, and
/// therefore not a parameter of anything below.
const String androidPackageName = 'app.fayad.ludo';

/// The Play Store listing a person without the app is sent to from the
/// `/r/<CODE>` landing page.
const String playStoreListingUrl =
    'https://play.google.com/store/apps/details?id=$androidPackageName';

/// The shape a Play App Signing SHA-256 fingerprint must have: 32 hex byte
/// pairs, uppercase, colon-separated -- `AB:CD:...`, 95 characters. A value
/// read from `LUDO_APP_SIGNING_SHA256` that does not match this is treated
/// as unset rather than served, because a malformed value would fail to
/// verify on every phone exactly as silently as an upload-key value would.
final RegExp appSigningFingerprintShape = RegExp(
  r'^[0-9A-F]{2}(:[0-9A-F]{2}){31}$',
);

/// True only for a value with the exact shape [appSigningFingerprintShape]
/// describes. Does not and cannot check that the value is actually the app
/// signing key rather than the upload key -- that distinction is not visible
/// in the string itself, which is why `docs/RELEASE.md:139-159` is the
/// warning, not this function.
bool isValidAppSigningFingerprintShape(String value) =>
    appSigningFingerprintShape.hasMatch(value);

const HtmlEscape _escaper = HtmlEscape();

/// Builds the `assetlinks.json` body for [fingerprint], which the caller
/// must already have validated with [isValidAppSigningFingerprintShape].
/// This function does not validate or reject; it only formats. The document
/// is exactly the standard single-statement Digital Asset Links file naming
/// `handle_all_urls` for [androidPackageName].
String buildAssetLinksJson(String fingerprint) {
  final List<Object?> document = <Object?>[
    <String, Object?>{
      'relation': <String>['delegate_permission/common.handle_all_urls'],
      'target': <String, Object?>{
        'namespace': 'android_app',
        'package_name': androidPackageName,
        'sha256_cert_fingerprints': <String>[fingerprint],
      },
    },
  ];
  return jsonEncode(document);
}

/// The host the App Links intent filter in the client manifest claims. The
/// open-in-app URL below must name exactly this host and a path under
/// `/r/`, or Chrome builds an intent the app does not answer.
const String _roomLinkHost = 'ludo.provefair.app';

/// Builds the `intent://` URL behind the page's "Open in Ludo RNG" button
/// for [code], which the caller must already have validated. Chrome turns
/// it into a VIEW intent for `https://ludo.provefair.app/r/<CODE>` with the
/// package set, so the installed app gets the room even while the domain is
/// still unverified; with the app absent Chrome follows
/// `S.browser_fallback_url` to the Play listing instead. This function does
/// not validate or reject; it only formats.
String buildOpenInAppUrl(String code) {
  final String fallback = Uri.encodeComponent(playStoreListingUrl);
  return 'intent://$_roomLinkHost/r/$code#Intent;scheme=https;'
      'package=$androidPackageName;S.browser_fallback_url=$fallback;end';
}

/// Escapes the five characters that matter inside a double-quoted
/// attribute, and nothing else: the default escaper above would also turn
/// every `/` into `&#47;`, which is harmless to a browser but makes the
/// `href` in the served document differ from the string it was built from.
const HtmlEscape _attributeEscaper = HtmlEscape(HtmlEscapeMode.attribute);

/// One language's worth of words for the room page. Every user-facing
/// string on the page comes from here, in the table C-457 decision 4 pins.
class _RoomPageWords {
  const _RoomPageWords({
    required this.title,
    required this.lead,
    required this.open,
    required this.codeLabel,
    required this.copy,
    required this.copied,
    required this.newHere,
    required this.get,
    required this.fair,
  });

  /// The heading and `<title>` text, up to the room code, which follows
  /// after one space.
  final String title;
  final String lead;
  final String open;
  final String codeLabel;
  final String copy;
  final String copied;
  final String newHere;
  final String get;
  final String fair;
}

const _RoomPageWords _enWords = _RoomPageWords(
  title: 'Join room',
  lead: 'Your friend is waiting for you in Ludo RNG.',
  open: 'Open in Ludo RNG',
  codeLabel: 'Room code',
  copy: 'Copy code',
  copied: 'Copied',
  newHere: 'New to Ludo RNG? Install it, then type this code on the home '
      'screen.',
  get: 'Get Ludo RNG on Google Play',
  fair: 'Every roll in Ludo RNG is verifiable.',
);

const _RoomPageWords _arWords = _RoomPageWords(
  title: 'انضم إلى الغرفة',
  lead: 'صديقك بانتظارك في Ludo RNG.',
  open: 'افتح في Ludo RNG',
  codeLabel: 'رمز الغرفة',
  copy: 'انسخ الرمز',
  copied: 'تم النسخ',
  newHere: 'جديد على Ludo RNG؟ ثبّته، ثم اكتب هذا الرمز في الشاشة الرئيسية.',
  get: 'احصل على Ludo RNG من Google Play',
  fair: 'كل رمية في Ludo RNG قابلة للتحقق.',
);

/// Builds the landing page a person lands on after tapping a shared
/// `https://ludo.provefair.app/r/<CODE>` link.
///
/// On Android 12 and later a web link whose domain is not yet verified
/// resolves to the browser even with the app installed, so the page does
/// not claim the link opens the app on its own. It carries one large
/// button, [buildOpenInAppUrl], that hands the room to the installed app,
/// and a copy button for the code for the person who has to install first.
///
/// [code] must already be validated (uppercased, checked against
/// `isWellFormedRoomCode`) by the caller; this function does not consult a
/// room registry and does not know or care whether the room named by [code]
/// still exists -- it renders the same document either way, which is the
/// whole point: the room code is the only thing protecting a private room,
/// and a page that answered differently for a live code than a dead one
/// would turn code-guessing into a working attack.
///
/// One language per page: [language] is whatever `resolveVerifyLanguage`
/// picked, and anything other than `'ar'` renders English. The Arabic page
/// is the same layout mirrored by `dir="rtl"`, not a patched copy.
String buildRoomLandingPageHtml(String code, {String language = 'en'}) {
  final bool isAr = language == 'ar';
  final _RoomPageWords words = isAr ? _arWords : _enWords;
  final String escapedCode = _escaper.convert(code);
  final String openUrl = _attributeEscaper.convert(buildOpenInAppUrl(code));
  final String playUrl = _attributeEscaper.convert(playStoreListingUrl);
  final String copyWord = _attributeEscaper.convert(words.copy);
  final String copiedWord = _attributeEscaper.convert(words.copied);
  final String heading = '${words.title} $escapedCode';
  final String htmlOpen =
      isAr ? '<html lang="ar" dir="rtl">' : '<html lang="en">';
  final String switchLink = isAr
      ? '<a id="lang-switch" class="switch" href="?lang=en" '
          'hreflang="en" lang="en">English</a>'
      : '<a id="lang-switch" class="switch" href="?lang=ar" '
          'hreflang="ar" lang="ar">العربية</a>';

  return '''
<!DOCTYPE html>
$htmlOpen
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ludo RNG - $heading</title>
<style>
html {
  background: #0A3D38;
}
body {
  margin: 0;
  min-height: 100vh;
  box-sizing: border-box;
  padding: 1rem;
  background: linear-gradient(160deg, #0A3D38, #14665C);
  color: #0A2A27;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  line-height: 1.5;
  overflow-wrap: anywhere;
}
.card {
  box-sizing: border-box;
  max-width: 28rem;
  margin: 0 auto;
  padding: 1.5rem 1.25rem;
  background: #F7FBFA;
  border-radius: 1.25rem;
  text-align: center;
}
.seats {
  display: flex;
  justify-content: center;
  gap: 0.5rem;
}
.seats span {
  width: 0.875rem;
  height: 0.875rem;
  border-radius: 50%;
}
.seats .red { background: #D32F2F; }
.seats .green { background: #388E3C; }
.seats .yellow { background: #FBC02D; }
.seats .blue { background: #1976D2; }
h1 {
  margin: 1rem 0 0.25rem;
  font-size: 1.5rem;
  line-height: 1.25;
}
.lead {
  margin: 0 0 1.25rem;
  font-size: 1.0625rem;
}
.btn {
  display: flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  width: 100%;
  min-height: 3rem;
  padding: 0.5rem 1rem;
  border-radius: 0.75rem;
  font: inherit;
  font-weight: 700;
  text-decoration: none;
  cursor: pointer;
}
.btn:focus-visible, .switch:focus-visible {
  outline: 3px solid #1976D2;
  outline-offset: 2px;
}
#open-app {
  min-height: 3.5rem;
  background: #0F6B5F;
  border: 2px solid #0F6B5F;
  color: #F7FBFA;
  font-size: 1.25rem;
}
.label {
  margin: 1.5rem 0 0.25rem;
  font-size: 0.875rem;
}
#room-code {
  -webkit-user-select: all;
  user-select: all;
  margin: 0 0 0.75rem;
  font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
  font-size: 2rem;
  font-size: min(2.25rem, 11vw);
  font-weight: 700;
  letter-spacing: 0.15em;
  padding-inline-start: 0.15em;
}
#copy-code {
  background: transparent;
  border: 2px solid #0F6B5F;
  color: #0F6B5F;
  font-size: 1rem;
}
.hint {
  margin: 1.5rem 0 0.25rem;
  font-size: 0.9375rem;
}
#get-app {
  color: #0F6B5F;
  font-size: 0.9375rem;
  text-decoration: underline;
}
.fair {
  margin: 1rem 0 0;
  font-size: 0.875rem;
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
<main class="card">
<div class="seats" aria-hidden="true"><span class="red"></span><span class="green"></span><span class="yellow"></span><span class="blue"></span></div>
<h1>$heading</h1>
<p class="lead">${words.lead}</p>
<a id="open-app" class="btn" href="$openUrl">${words.open}</a>
<p class="label">${words.codeLabel}</p>
<div id="room-code" dir="ltr">$escapedCode</div>
<button type="button" id="copy-code" class="btn" data-copy="$copyWord" data-copied="$copiedWord" aria-live="polite">${words.copy}</button>
<p class="hint">${words.newHere}</p>
<a id="get-app" class="btn" href="$playUrl">${words.get}</a>
<p class="fair">${words.fair}</p>
$switchLink
</main>
<script src="/r/room.js" defer></script>
</body>
</html>
''';
}

/// The complete text of `/r/room.js`, the page's one script. A raw string,
/// not a template: nothing in it is filled in at request time, and it holds
/// no user-facing text. The button carries the words it needs as
/// `data-copy` and `data-copied`, so the page's language never reaches this
/// file. Neither path out of the click handler throws: a missing or
/// rejecting clipboard falls back to selecting the code so a long-press
/// copy works, and that fallback shows no confirmation because nothing was
/// copied.
const String roomLinkJsSource = r'''
'use strict';

(function () {
  var button = document.getElementById('copy-code');
  var code = document.getElementById('room-code');
  if (!button || !code) {
    return;
  }
  var timer = null;

  function selectCode() {
    try {
      var range = document.createRange();
      range.selectNodeContents(code);
      var selection = window.getSelection();
      if (selection) {
        selection.removeAllRanges();
        selection.addRange(range);
      }
    } catch (ignored) {
      // Nothing left to try; the code is still on screen to read.
    }
  }

  function showConfirmation() {
    button.textContent = button.getAttribute('data-copied');
    if (timer !== null) {
      clearTimeout(timer);
    }
    timer = setTimeout(function () {
      button.textContent = button.getAttribute('data-copy');
      timer = null;
    }, 2000);
  }

  button.addEventListener('click', function () {
    var text = (code.textContent || '').trim();
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(showConfirmation, selectCode);
        return;
      }
    } catch (ignored) {
      // Fall through to the selection below.
    }
    selectCode();
  });
})();
''';
