// Unit tests for work/ludo/orders/C-457-room-link-page.md: the new pure
// `buildOpenInAppUrl` and the new `language:` parameter of
// `buildRoomLandingPageHtml`, called directly. These do not compile on the
// commit before the contract was implemented, because neither exists there;
// the route cases that run on that commit are in
// room_link_page_route_test.dart.
//
// Everything here is deterministic. Reproduce a single case with:
//   cd packages/ludo_server && dart test test/room_link_page_unit_test.dart -n "<case name>"

import 'package:ludo_server/src/link_pages.dart';
import 'package:test/test.dart';

const String _code = 'K7M2QP';

const String _playListing =
    'https://play.google.com/store/apps/details?id=app.fayad.ludo';

String _expectedIntent(String code) =>
    'intent://ludo.provefair.app/r/$code#Intent;scheme=https;'
    'package=app.fayad.ludo;'
    'S.browser_fallback_url=${Uri.encodeComponent(_playListing)};end';

String _unescape(String input) {
  return input
      .replaceAllMapped(
        RegExp(r'&#[xX]([0-9a-fA-F]+);'),
        (Match m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// The unescaped href of the element with id="open-app", or null.
String? _openAppHref(String html) {
  for (final RegExpMatch m in RegExp(r'<a\b([^>]*)>').allMatches(html)) {
    final String attrs = m.group(1)!;
    if (RegExp(r'''\sid=(?:"open-app"|'open-app')''').hasMatch(attrs)) {
      final RegExpMatch? href =
          RegExp(r'''\shref=(?:"([^"]*)"|'([^']*)')''').firstMatch(attrs);
      return href == null ? null : _unescape(href.group(1) ?? href.group(2)!);
    }
  }
  return null;
}

void main() {
  group('buildOpenInAppUrl', () {
    test('equals the literal intent URL for K7M2QP', () {
      expect(
        buildOpenInAppUrl(_code),
        _expectedIntent(_code),
        reason: 'D1: intent://ludo.provefair.app/r/<CODE>#Intent;'
            'scheme=https;package=app.fayad.ludo;'
            'S.browser_fallback_url=<ENC>;end with <ENC> the '
            'encodeComponent of the Play listing',
      );
    });

    test('the fallback is the percent-encoded Play listing', () {
      final String url = buildOpenInAppUrl(_code);
      expect(
        url,
        contains(
          'S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2F'
          'apps%2Fdetails%3Fid%3Dapp.fayad.ludo;end',
        ),
        reason: 'the fallback URL must be encoded so its ? and / cannot end '
            'the intent early; got $url',
      );
    });

    test('puts the code it is given in the path, unchanged', () {
      expect(buildOpenInAppUrl('ABCDEF'), _expectedIntent('ABCDEF'));
      expect(buildOpenInAppUrl('Z98765'), _expectedIntent('Z98765'));
    });

    test('is pure: the same code gives the same string', () {
      expect(buildOpenInAppUrl(_code), buildOpenInAppUrl(_code));
    });

    test('uses the shared constants for package and listing', () {
      final String url = buildOpenInAppUrl(_code);
      expect(url, contains('package=$androidPackageName;'),
          reason: 'package must be androidPackageName, got $url');
      expect(url, contains(Uri.encodeComponent(playStoreListingUrl)),
          reason: 'fallback must be playStoreListingUrl encoded, got $url');
    });
  });

  group('buildRoomLandingPageHtml language', () {
    test('the default language is English', () {
      expect(
        buildRoomLandingPageHtml(_code),
        buildRoomLandingPageHtml(_code, language: 'en'),
        reason: 'omitting language: must equal language: "en"',
      );
    });

    test('an unknown language renders English', () {
      final String english = buildRoomLandingPageHtml(_code, language: 'en');
      for (final String other in <String>['xx', '', 'AR', 'ar-AE', 'fr']) {
        expect(
          buildRoomLandingPageHtml(_code, language: other),
          english,
          reason: 'language: "$other" is not exactly "ar", so D3 says it '
              'renders English',
        );
      }
    });

    test('ar renders the Arabic page and en does not', () {
      final String ar = buildRoomLandingPageHtml(_code, language: 'ar');
      final String en = buildRoomLandingPageHtml(_code, language: 'en');
      expect(ar, isNot(en), reason: 'ar and en pages must differ');
      expect(ar, contains('<html lang="ar" dir="rtl">'));
      expect(en, contains('<html lang="en">'));
      expect(ar, contains('انضم إلى الغرفة $_code'));
      expect(en, contains('Join room $_code'));
    });

    test('both languages carry the same open-app href', () {
      for (final String language in <String>['en', 'ar']) {
        final String html = buildRoomLandingPageHtml(_code, language: language);
        expect(
          _openAppHref(html),
          buildOpenInAppUrl(_code),
          reason: 'the $language page open-app href must equal '
              'buildOpenInAppUrl(code) once HTML-unescaped',
        );
      }
    });

    test('is pure: the same arguments give the same page', () {
      expect(
        buildRoomLandingPageHtml(_code, language: 'ar'),
        buildRoomLandingPageHtml(_code, language: 'ar'),
      );
    });

    test('a hostile code cannot break out of markup or of the href', () {
      const String hostile = 'A"><script>x</script>';
      for (final String language in <String>['en', 'ar']) {
        final String html =
            buildRoomLandingPageHtml(hostile, language: language);
        expect(html, isNot(contains('<script>x</script>')),
            reason: 'the $language page let a code inject a script element');
        expect(html, isNot(contains('A">')),
            reason: 'the $language page let a code close an attribute');
        expect(_openAppHref(html), isNotNull,
            reason: 'the $language page lost its open-app link when the code '
                'held markup characters');
      }
    });
  });
}
