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

/// Builds the landing page a person lands on after tapping a shared
/// `https://ludo.provefair.app/r/<CODE>` link without the app installed.
///
/// [code] must already be validated (uppercased, checked against
/// `isWellFormedRoomCode`) by the caller; this function does not consult a
/// room registry and does not know or care whether the room named by [code]
/// still exists -- it renders the same document either way, which is the
/// whole point: the room code is the only thing protecting a private room,
/// and a page that answered differently for a live code than a dead one
/// would turn code-guessing into a working attack.
///
/// English and Arabic both appear on the one page, the Arabic marked
/// `dir="rtl"` so it renders right-to-left rather than being merely
/// transliterated left-to-right text.
String buildRoomLandingPageHtml(String code) {
  final String escapedCode = _escaper.convert(code);

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ludo RNG - Room $escapedCode</title>
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
h1 {
  font-size: 1.3em;
}
p.room-code {
  font-size: 1.4em;
  letter-spacing: 0.1em;
}
section.ar {
  margin-top: 2em;
  padding-top: 1.5em;
  border-top: 1px solid #ccc;
}
a {
  color: #1a1a1a;
}
</style>
</head>
<body>
<section class="en" lang="en" dir="ltr">
<h1>Join room $escapedCode</h1>
<p>This link opens the Ludo RNG app directly if it is installed. If it is
not, install it and then enter the room code below.</p>
<p class="room-code">Room code: <strong>$escapedCode</strong></p>
<p><a href="$playStoreListingUrl">Get Ludo RNG on Google Play</a></p>
</section>
<section class="ar" lang="ar" dir="rtl">
<h1>انضم إلى الغرفة $escapedCode</h1>
<p>يفتح هذا الرابط تطبيق Ludo RNG مباشرة إذا كان مثبتا. إن لم يكن مثبتا،
ثبته ثم أدخل رمز الغرفة أدناه.</p>
<p class="room-code">رمز الغرفة: <strong>$escapedCode</strong></p>
<p><a href="$playStoreListingUrl">احصل على Ludo RNG من Google Play</a></p>
</section>
</body>
</html>
''';
}
