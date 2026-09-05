// Home screen join-code error conformance suite, work order 122, written as
// the other hand for work order 121.
//
// Written blind, from the description of the defect in
// work/orders/122-join-code-error-proof.md alone, against
// lib/src/home_screen.dart as it stands on `main` -- the version with the
// two defects order 121 is fixing:
//
//   1. _handleLink (home_screen.dart:105-119) treats every Uri that
//      roomCodeFromUri (deep_link.dart:24-39) could not turn into a code as
//      a bad room code, even when the reason was "not a room link at all"
//      (wrong scheme, wrong host, wrong path shape) rather than "a room
//      link whose code is invalid".
//   2. Nothing listens to the code field's TextEditingController, so
//      _errorText, once set at home_screen.dart:116 or :171, survives every
//      keystroke until a successful link or a successful submit clears it.
//
// Most tests below are expected to fail on `main` for exactly one of those
// two reasons; the group comment above each one says which.
//
// This file deliberately does not repeat ground already covered by
// test/deep_link_test.dart or test/home_screen_link_error_test.dart (order
// forbids touching either). What was found there and not repeated here:
//
//   * A valid room link pre-filling the code field, showing no error, and
//     not navigating -- cold path: test/deep_link_test.dart item 10 (twice,
//     through HomeScreen and through LudoApp) and
//     test/home_screen_link_error_test.dart's "a valid initial link still
//     pre-fills the code field". Warm path: test/deep_link_test.dart item
//     13, and item 14 for a second link replacing the first. Requirement 3
//     of this order ("a valid room link still pre-fills ... and does not
//     navigate ... existing documented behaviour") is exactly this, on both
//     paths, already pinned twice over; a fix that broke it would already
//     fail those files, so it is not repeated here.
//   * "Nothing ever pushes or pops a route" for a whole sequence of cold and
//     warm links, valid and invalid: test/deep_link_test.dart item 19. The
//     per-scenario push/pop assertions in this file's own tests are kept
//     anyway, in line, because each of those tests is also asserting
//     something else (no error text, or an error text) that item 19 does
//     not check, and a shared _NavigatorProbe fixture costs nothing to
//     carry along.
//
// What test/deep_link_test.dart item 11 and
// test/home_screen_link_error_test.dart's "an invalid initial link still
// sets the existing error text" do *not* cover, and this file exists to
// cover: both of those drive their "invalid link" case with a wrong-host
// Uri (https://example.com/r/AB23CD) and assert that it *shows* the error.
// That is exactly branch 1 of this order's defect description -- "not this
// app's room-link space at all" -- which this order specifies must show no
// error. Those two frozen files therefore pin the pre-fix behaviour for
// that exact input shape, and a correct fix under this order's
// specification will make them fail; this file does not touch them, does
// not weaken them, and reports that conflict in the run's report rather
// than resolving it here. Neither file was written blind to this order (093
// and 088 predate it), so this is not this file's call to make.
//
// Right-host links whose /r/<code> segment carries an invalid code are not
// covered by either frozen file for a right-host Uri: deep_link_test.dart's
// "invalid" fixtures are wrong-host (item 11) or wrong-scheme (item 15),
// never right-host-bad-code. That is genuinely new ground, and it matters
// most: this order's requirement 2 exists specifically so a fix that
// silences every link error is caught.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';

// --- shared fixtures --------------------------------------------------

/// An [InitialLinkReader] whose future is held open by a [Completer] until
/// the test completes it, so the cold-start read can be driven after the
/// first frame the same way a real platform channel response would arrive.
class _FakeInitialLinkReader {
  final Completer<Uri?> _completer = Completer<Uri?>();

  Future<Uri?> call() => _completer.future;

  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }
}

/// A [LinkStreamOpener] backed by a broadcast [StreamController], so a test
/// can push a warm-start link onto the exact stream HomeScreen already
/// subscribed to.
class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  Stream<Uri> call() => _controller.stream;

  void add(Uri uri) => _controller.add(uri);
}

/// Records every push/pop a [Navigator] reports, so "nothing navigated" is
/// asserted against a count rather than assumed from the absence of a
/// screen that happens to be easy to find.
class _NavigatorProbe extends NavigatorObserver {
  int pushCount = 0;
  int popCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

/// Pumps [HomeScreen] the same way [LudoApp] assembles one (same
/// localizationsDelegates and supportedLocales), with a substitutable
/// [initialLinkReader] and [linkStream].
Widget _homeScreenApp({
  InitialLinkReader initialLinkReader = noInitialLink,
  LinkStreamOpener linkStream = noLinkStream,
  required _NavigatorProbe observer,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: <NavigatorObserver>[observer],
    home: HomeScreen(
      onToggleLocale: () {},
      initialLinkReader: initialLinkReader,
      linkStream: linkStream,
    ),
  );
}

TextField _codeField(WidgetTester tester) {
  return tester.widget<TextField>(find.byKey(const Key('room-code-field')));
}

String _codeFieldText(WidgetTester tester) =>
    _codeField(tester).controller!.text;

String? _codeFieldError(WidgetTester tester) =>
    _codeField(tester).decoration?.errorText;

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(HomeScreen)));

/// A well-formed https link on this app's own host, `/r/<code>`, built from
/// a code that is already normalised.
Uri _appLink(String code) => Uri.parse('https://$kAppLinkHost/r/$code');

/// One case in the "not a room link at all" table: a human-readable label
/// for the failure message, and the Uri that must trip that branch of
/// roomCodeFromUri.
class _NotARoomLinkCase {
  const _NotARoomLinkCase(this.description, this.uri);

  final String description;
  final Uri uri;
}

final List<_NotARoomLinkCase> _notARoomLinkCases = <_NotARoomLinkCase>[
  _NotARoomLinkCase(
    'plain http scheme on the right host and a well-shaped /r/<code> path',
    Uri.parse('http://$kAppLinkHost/r/AB23CD'),
  ),
  _NotARoomLinkCase(
    'a wholly different host',
    Uri.parse('https://example.com/r/AB23CD'),
  ),
  _NotARoomLinkCase(
    'the right host with an unrelated path (/privacy)',
    Uri.parse('https://$kAppLinkHost/privacy'),
  ),
  _NotARoomLinkCase(
    'the right host with no path at all (/)',
    Uri.parse('https://$kAppLinkHost/'),
  ),
  _NotARoomLinkCase(
    'the right host, /r with no second segment at all (too few segments)',
    Uri.parse('https://$kAppLinkHost/r'),
  ),
  _NotARoomLinkCase(
    'the right host, /r/AB/CD with an extra segment (too many segments)',
    Uri.parse('https://$kAppLinkHost/r/AB/CD'),
  ),
];

/// One case in the "right host, invalid code" table.
class _InvalidCodeLinkCase {
  const _InvalidCodeLinkCase(this.description, this.uri);

  final String description;
  final Uri uri;
}

final List<_InvalidCodeLinkCase> _invalidCodeLinkCases = <_InvalidCodeLinkCase>[
  _InvalidCodeLinkCase(
    'a code containing the excluded character 0',
    _appLink('AB0234'),
  ),
  _InvalidCodeLinkCase(
    'a code one character short of the required length',
    _appLink('AB23C'),
  ),
];

void main() {
  // --- requirement 1: not a room link at all leaves the field clean ------
  //
  // On main, _handleLink's else branch (home_screen.dart:115-117) fires for
  // every one of these, because roomCodeFromUri returns null for all of
  // them just as surely as it does for a genuinely bad code; main cannot
  // tell "not ours" from "ours but wrong" apart. Expected to fail on main:
  // _codeFieldError comes back non-null where isNull is expected.

  group('requirement 1: a link outside this app\'s room-link space at all '
      'leaves no error on screen, cold path', () {
    for (final _NotARoomLinkCase testCase in _notARoomLinkCases) {
      testWidgets(testCase.description, (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _NavigatorProbe observer = _NavigatorProbe();
        await tester.pumpWidget(
          _homeScreenApp(initialLinkReader: reader.call, observer: observer),
        );
        await tester.pump();
        final int pushesBefore = observer.pushCount;
        final int popsBefore = observer.popCount;

        reader.complete(testCase.uri);
        await tester.pump();
        await tester.pump();

        expect(
          _codeFieldError(tester),
          isNull,
          reason:
              'a link that is not a room link at all (${testCase.description}, '
              'uri: ${testCase.uri}) must not put an error on a field the '
              'player has never touched; roomCodeFromUri returning null for '
              'this reason is not the same as a bad room code',
        );
        expect(_codeFieldText(tester), isEmpty);
        expect(observer.pushCount, pushesBefore);
        expect(observer.popCount, popsBefore);
      });
    }
  });

  group('requirement 1 and requirement 7: the same links leave no error on '
      'screen on the warm-start path', () {
    for (final _NotARoomLinkCase testCase in _notARoomLinkCases) {
      testWidgets(testCase.description, (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _NavigatorProbe observer = _NavigatorProbe();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: opener.call, observer: observer),
        );
        await tester.pump();
        final int pushesBefore = observer.pushCount;
        final int popsBefore = observer.popCount;

        opener.add(testCase.uri);
        await tester.pump();
        await tester.pump();

        expect(
          _codeFieldError(tester),
          isNull,
          reason:
              'a link arriving on the warm-start stream while the app is '
              'already running is subject to exactly the same rule as one '
              'that launched it (requirement 7); '
              '${testCase.description}, uri: ${testCase.uri} must not put '
              'an error on screen',
        );
        expect(_codeFieldText(tester), isEmpty);
        expect(observer.pushCount, pushesBefore);
        expect(observer.popCount, popsBefore);
      });
    }
  });

  // --- requirement 2: a right-host /r/<code> whose code is invalid still --
  // --- errors -------------------------------------------------------------
  //
  // These are expected to keep passing after a correct fix, and also pass
  // on main today, since main's blanket rule happens to be right here even
  // though it is wrong for requirement 1's cases. A fix that silences every
  // link error (rather than only the "not a room link" ones) would fail
  // these; that is exactly what this group exists to catch.

  group('requirement 2: a room link whose code is invalid still shows the '
      'error, cold path', () {
    for (final _InvalidCodeLinkCase testCase in _invalidCodeLinkCases) {
      testWidgets(testCase.description, (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _NavigatorProbe observer = _NavigatorProbe();
        await tester.pumpWidget(
          _homeScreenApp(initialLinkReader: reader.call, observer: observer),
        );
        await tester.pump();
        final int pushesBefore = observer.pushCount;
        final int popsBefore = observer.popCount;

        reader.complete(testCase.uri);
        await tester.pump();
        await tester.pump();

        expect(
          _codeFieldError(tester),
          _loc(tester).homeRoomCodeInvalid,
          reason:
              'a link on this app\'s own host, shaped as /r/<code>, whose '
              'code fails isValidRoomCode (${testCase.description}, uri: '
              '${testCase.uri}) is a genuinely bad room code and must still '
              'show the error; silencing this case would be as wrong as '
              'the bug this order is fixing',
        );
        expect(observer.pushCount, pushesBefore);
        expect(observer.popCount, popsBefore);
      });
    }
  });

  group('requirement 2 and requirement 7: the same room links with invalid '
      'codes still show the error on the warm-start path', () {
    for (final _InvalidCodeLinkCase testCase in _invalidCodeLinkCases) {
      testWidgets(testCase.description, (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _NavigatorProbe observer = _NavigatorProbe();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: opener.call, observer: observer),
        );
        await tester.pump();
        final int pushesBefore = observer.pushCount;
        final int popsBefore = observer.popCount;

        opener.add(testCase.uri);
        await tester.pump();
        await tester.pump();

        expect(
          _codeFieldError(tester),
          _loc(tester).homeRoomCodeInvalid,
          reason:
              'the warm-start path is subject to the same rule as the '
              'cold-start path (requirement 7); ${testCase.description}, '
              'uri: ${testCase.uri} must still show the error',
        );
        expect(observer.pushCount, pushesBefore);
        expect(observer.popCount, popsBefore);
      });
    }
  });

  // --- requirements 4 and 5: typing clears the error ----------------------
  //
  // On main nothing listens to _codeController (home_screen.dart has no
  // addListener call on it anywhere), so _errorText survives every
  // keystroke; these are expected to fail on main with the error text
  // still present where isNull is expected.

  group('requirement 4: typing in the code field clears the error, on the '
      'first keystroke, warm-start path raised it', () {
    testWidgets(
      'a single typed character clears an error raised by an invalid room '
      'link',
      (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: opener.call, observer: _NavigatorProbe()),
        );
        await tester.pump();

        opener.add(_appLink('AB0234'));
        await tester.pump();
        await tester.pump();
        expect(
          _codeFieldError(tester),
          isNotNull,
          reason:
              'fixture is broken: an invalid room link (uri carrying '
              'AB0234, which contains the excluded character 0) must have '
              'raised the error before this test can prove typing clears it',
        );

        await tester.enterText(find.byKey(const Key('room-code-field')), 'A');
        await tester.pump();

        expect(
          _codeFieldError(tester),
          isNull,
          reason:
              'typing a single character into the code field must clear '
              'the error on the very first rebuild after that keystroke, '
              'without the player ever tapping Join Room; nothing in '
              'home_screen.dart currently listens to the code controller '
              '(the error is only ever cleared at home_screen.dart:114 on '
              'a successful link and :176 on a successful submit)',
        );
      },
    );

    testWidgets(
      'a single typed character clears an error raised by an invalid room '
      'link, cold-start path raised it (requirement 7 parity)',
      (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        await tester.pumpWidget(
          _homeScreenApp(
            initialLinkReader: reader.call,
            observer: _NavigatorProbe(),
          ),
        );
        await tester.pump();

        reader.complete(_appLink('AB0234'));
        await tester.pump();
        await tester.pump();
        expect(
          _codeFieldError(tester),
          isNotNull,
          reason:
              'fixture is broken: an invalid room link on the cold-start '
              'path must have raised the error before this test can prove '
              'typing clears it',
        );

        await tester.enterText(find.byKey(const Key('room-code-field')), 'A');
        await tester.pump();

        expect(
          _codeFieldError(tester),
          isNull,
          reason:
              'the cold-start path must be held to exactly the same '
              'typing-clears-the-error rule as the warm-start path '
              '(requirement 7)',
        );
      },
    );
  });

  group('requirement 5: typing clears the error even when the newly typed '
      'code is itself still invalid', () {
    testWidgets(
      'replacing the field with a different but still-invalid code clears '
      'the error',
      (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: opener.call, observer: _NavigatorProbe()),
        );
        await tester.pump();

        opener.add(_appLink('AB0234'));
        await tester.pump();
        await tester.pump();
        expect(
          _codeFieldError(tester),
          isNotNull,
          reason:
              'fixture is broken: an invalid room link must have raised '
              'the error before this test can prove typing clears it',
        );

        // Still six characters, still fails isValidRoomCode (0 is
        // excluded); the point is that clearing is about the player having
        // started to correct the field, not about the new value being
        // right.
        await tester.enterText(
          find.byKey(const Key('room-code-field')),
          'ZZ0000',
        );
        await tester.pump();

        expect(
          _codeFieldError(tester),
          isNull,
          reason:
              'typing must clear the error even when the code the player '
              'has typed so far ("ZZ0000") is itself still invalid; '
              'clearing is not conditioned on the new value passing '
              'isValidRoomCode',
        );
      },
    );
  });

  // --- requirement 6: submit-time validation is not what is being removed -

  group('requirement 6: tapping Join Room with an invalid code still shows '
      'the error', () {
    testWidgets('a hand-typed invalid code, submitted, still errors', (
      tester,
    ) async {
      final _NavigatorProbe observer = _NavigatorProbe();
      await tester.pumpWidget(_homeScreenApp(observer: observer));
      await tester.pump();
      final int pushesBefore = observer.pushCount;

      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'AB0234',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('join-room-button')));
      await tester.pump();

      expect(
        _codeFieldError(tester),
        _loc(tester).homeRoomCodeInvalid,
        reason:
            'order 121 is fixing the link-driven false positive, not the '
            'submit-time shape check in _joinRoom (home_screen.dart:169-174); '
            'a hand-typed code that fails isValidRoomCode must still be '
            'rejected with this error when the player taps Join Room',
      );
      expect(
        observer.pushCount,
        pushesBefore,
        reason: 'an invalid code must never navigate anywhere',
      );
    });
  });
}
