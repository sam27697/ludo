// Home screen link error conformance suite, work order 093.
//
// Written blind, from the frozen declaration shared with work order 092
// (the E0/E1/E2/E3 block reproduced there) alone, against
// lib/src/home_screen.dart as it stands on base commit a3ab7f3 -- the
// version with the defect. Nothing here was written by reading order 092's
// fix. On this base, initialLinkReader().then(...) and
// linkStream().listen(_handleLink) are both unguarded, so most tests below
// are expected to fail here; see the comment on each group for what failure
// means and why.
//
// A note on how the failures show up. A Future that completes with an
// error, or a Stream that emits one, with nothing on the chain to catch it,
// does not merely fail a plain expect() on this base: flutter_test's own
// binding intercepts the escaped zone error before this file's assertions
// ever run, and because this suite has replaced FlutterError.onError to
// capture what reaches it, the binding's internal bookkeeping trips its own
// assertion ('_pendingExceptionDetails != null') instead of producing a
// tidy expect() failure. That is still a failure of the test in question,
// attributed to it and not to any other test, and it is itself evidence for
// E0: the error reached nobody's onError at all, mine included, until the
// binding caught it as a bare crash. See the Acceptance report for the
// verbatim text.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';

// --- shared fixtures --------------------------------------------------

/// A valid, well-formed app link built from a code that is itself already
/// normalised (upper case, no dash or space).
Uri _validLink([String code = 'AB23CD']) {
  return Uri.parse('https://ludo.provefair.app/r/$code');
}

/// A well-formed https link whose host is not kAppLinkHost, so
/// roomCodeFromUri returns null: the "invalid link" fixture, matching the
/// case used by test/deep_link_test.dart item 11.
Uri _invalidLink() => Uri.parse('https://example.com/r/AB23CD');

/// An [InitialLinkReader] whose future is held open by a [Completer] until
/// the test completes or fails it.
class _FakeInitialLinkReader {
  final Completer<Uri?> _completer = Completer<Uri?>();

  Future<Uri?> call() => _completer.future;

  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }
}

/// A [LinkStreamOpener] backed by a broadcast [StreamController], so a test
/// can push both data and error events onto the same stream a listen()
/// call already got.
class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  Stream<Uri> call() => _controller.stream;

  void add(Uri uri) => _controller.add(uri);

  void addError(Object error, [StackTrace? stackTrace]) =>
      _controller.addError(error, stackTrace);
}

/// The exact object thrown by [_throwingInitialLinkReader], shared so a
/// test can assert identity (`same`) against whatever
/// FlutterErrorDetails.exception captures.
final Object _syncInitialLinkError = StateError(
  'initialLinkReader threw synchronously',
);

/// An [InitialLinkReader] that throws before ever returning a Future,
/// covering the synchronous half of E1 requirement 5.
Future<Uri?> _throwingInitialLinkReader() {
  throw _syncInitialLinkError;
}

/// The exact object thrown by [_throwingLinkStream].
final Object _syncLinkStreamError = StateError(
  'linkStream threw synchronously',
);

/// A [LinkStreamOpener] that throws before ever returning a Stream,
/// covering the other synchronous half of E1 requirement 5.
Stream<Uri> _throwingLinkStream() {
  throw _syncLinkStreamError;
}

/// Records every push/pop/replace/remove a [Navigator] reports, so "nothing
/// navigates" (E1 requirement 2) is asserted against a count rather than
/// assumed from the absence of a screen that happens to be easy to find.
class _RecordingNavigatorObserver extends NavigatorObserver {
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
  required _RecordingNavigatorObserver observer,
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

/// Overrides [FlutterError.onError] for the current test only, capturing
/// every [FlutterErrorDetails] reported through it, and restores whatever
/// was installed before once the test ends -- so one test's override can
/// never leak into the next one, per this order's own instruction.
List<FlutterErrorDetails> _captureFlutterErrors() {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previousOnError = FlutterError.onError;
  FlutterError.onError = captured.add;
  addTearDown(() {
    FlutterError.onError = previousOnError;
  });
  return captured;
}

/// Asserts everything E1 requirements 1 and 2 demand of the screen once a
/// link error has happened: it still builds, usable, showing no error text,
/// no snackbar, no dialog, and nothing has navigated.
void _expectScreenUndisturbed(
  WidgetTester tester, {
  required _RecordingNavigatorObserver observer,
  String expectedCodeText = '',
}) {
  expect(
    find.byKey(const Key('room-code-field')),
    findsOneWidget,
    reason:
        'declaration E1 requirement 1: the screen must keep building; a '
        'reported link error must not replace it with an ErrorWidget or '
        'anything else',
  );
  expect(
    _codeFieldText(tester),
    expectedCodeText,
    reason:
        'declaration E1 requirement 1: the code field must be untouched by '
        'an error the app itself could not read',
  );
  expect(
    _codeFieldError(tester),
    isNull,
    reason:
        'declaration E1 requirement 2: no error text may be shown to the '
        'player for a link failure that is not their fault and that they '
        'cannot act on',
  );
  expect(find.byType(SnackBar), findsNothing);
  expect(find.byType(Dialog), findsNothing);
  expect(
    observer.pushCount,
    0,
    reason: 'declaration E1 requirement 2: nothing may navigate',
  );
  expect(observer.popCount, 0);
}

/// Asserts everything E1 requirement 3 demands of a single reported error:
/// exactly one [FlutterErrorDetails], carrying the original error object by
/// identity, a non-null stack, and library 'ludo client'.
void _expectReportedOnce(
  List<FlutterErrorDetails> captured, {
  required Object expectedException,
}) {
  expect(
    captured,
    hasLength(1),
    reason:
        'declaration E1 requirement 3: exactly one error must reach '
        'FlutterError.onError for this scenario; captured $captured',
  );
  final FlutterErrorDetails details = captured.single;
  expect(
    details.exception,
    same(expectedException),
    reason:
        'declaration E1 requirement 3: FlutterErrorDetails.exception must '
        'be the original error object, not a copy or a rethrown wrapper',
  );
  expect(
    details.stack,
    isNotNull,
    reason: 'declaration E1 requirement 3: the stack trace must not be null',
  );
  expect(
    details.library,
    'ludo client',
    reason:
        "declaration E1 requirement 3: library must be exactly 'ludo "
        "client', not the framework default; got '${details.library}'",
  );
}

void main() {
  group('E1 requirements 1-3: a Future.error from initialLinkReader', () {
    // On base commit a3ab7f3, initialLinkReader().then((uri) {...}) has no
    // onError, so completing the fake reader's future with an error becomes
    // a genuinely unhandled asynchronous error at the zone level -- there is
    // no code path that ever calls FlutterError.reportError. With
    // FlutterError.onError overridden to capture reports (as this test
    // must, to prove E1 requirement 3), flutter_test's own binding detects
    // that escaped zone error and trips its internal
    // '_pendingExceptionDetails != null' assertion before this test's own
    // expect() calls ever run. That is the expected failure on base: a
    // crash inside flutter_test's binding, not a clean expect() mismatch,
    // and it is itself the proof that nothing on the chain caught the
    // error. See the Acceptance report for the verbatim text.
    testWidgets('reaches FlutterError.onError and the screen keeps working', (
      tester,
    ) async {
      // No FlutterError.onError override here: flutter_test's own binding
      // uses the currently installed onError to record a genuinely
      // zone-escaped error (exactly what base commit produces, since
      // nothing on the chain catches it), and replacing that handler in a
      // test that might hit that exact escape path collides with the
      // binding's own bookkeeping instead of producing a plain expect()
      // failure. Left at its default, an escape is caught cleanly by the
      // binding and fails this test on its own; a correct fix instead
      // reports through the default onError as a normal, drainable
      // exception, which takeException() below both surfaces and drains.
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      await tester.pumpWidget(
        _homeScreenApp(initialLinkReader: reader.call, observer: observer),
      );
      await tester.pump();

      final Object thrown = StateError(
        'initialLinkReader future failed (scenario: platform channel '
        'error)',
      );
      reader.completeError(thrown);
      await tester.pump();
      await tester.pump();

      _expectScreenUndisturbed(tester, observer: observer);
      expect(
        tester.takeException(),
        same(thrown),
        reason:
            'declaration E1 requirement 3: the error must not be swallowed; '
            'it must reach the framework as the original error object, '
            'drainable through tester.takeException()',
      );
    });
  });

  group('E1 requirements 1-4: a stream error from linkStream', () {
    // Same shape of expected base-commit failure as the group above:
    // widget.linkStream().listen(_handleLink) passes no onError, so an
    // error event on the fake stream is unhandled at the zone level on base
    // commit, and the same flutter_test binding assertion is the expected
    // crash there.
    testWidgets(
      'reaches FlutterError.onError, the screen keeps working, and a later '
      'valid Uri on the same stream still pre-fills the code field',
      (tester) async {
        // See the matching comment on the initialLinkReader test above:
        // no onError override here, for the same reason.
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: opener.call, observer: observer),
        );
        await tester.pump();

        final Object thrown = StateError(
          'linkStream emitted an error (scenario: platform channel error)',
        );
        opener.addError(thrown);
        await tester.pump();
        await tester.pump();

        _expectScreenUndisturbed(tester, observer: observer);
        expect(
          tester.takeException(),
          same(thrown),
          reason:
              'declaration E1 requirement 3: the error must not be '
              'swallowed; it must reach the framework as the original '
              'error object, drainable through tester.takeException()',
        );

        // E1 requirement 4, tested directly rather than by implication: the
        // subscription must still be useful after the error. An
        // implementation that lets the error cancel the subscription (for
        // instance by using stream.listen(_handleLink).onError(...) instead
        // of the onError parameter of listen) passes every assertion above
        // and still fails this one.
        opener.add(_validLink('AB23CD'));
        await tester.pump();

        expect(
          _codeFieldText(tester),
          'AB23CD',
          reason:
              'declaration E1 requirement 4: a stream error must not end '
              'the subscription; a later valid Uri on the same stream must '
              'still reach _handleLink and pre-fill the code field',
        );
        expect(_codeFieldError(tester), isNull);
      },
    );
  });

  group('E1 requirement 5: a synchronous throw', () {
    testWidgets('from initialLinkReader() still lets the screen build and is '
        'reported', (tester) async {
      final List<FlutterErrorDetails> captured = _captureFlutterErrors();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      await tester.pumpWidget(
        _homeScreenApp(
          initialLinkReader: _throwingInitialLinkReader,
          observer: observer,
        ),
      );
      await tester.pump();

      _expectScreenUndisturbed(tester, observer: observer);
      _expectReportedOnce(captured, expectedException: _syncInitialLinkError);
    });

    testWidgets(
      'from linkStream() still lets the screen build, is reported, and '
      'leaves dispose safe',
      (tester) async {
        final List<FlutterErrorDetails> captured = _captureFlutterErrors();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: _throwingLinkStream, observer: observer),
        );
        await tester.pump();

        _expectScreenUndisturbed(tester, observer: observer);
        _expectReportedOnce(captured, expectedException: _syncLinkStreamError);

        // declaration E1 requirement 5: "_linkSubscription stays null and
        // dispose must still be safe." Tear the widget down and confirm
        // nothing throws.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason:
              'declaration E1 requirement 5: disposing a HomeScreen whose '
              'linkStream() threw synchronously must not throw',
        );
      },
    );
  });

  group('E3: the two context values distinguish the two paths', () {
    // Driven through the two synchronous-throw scenarios rather than the
    // two async ones above: both a synchronous throw and a later
    // Future/stream error are required to go through the same reporting
    // rule (E1 requirement 5), so the context each path names should not
    // depend on which of the two ways that path happens to fail, and only
    // the synchronous shape is safe to combine with a FlutterError.onError
    // override in this suite (see the comments on the async-error groups
    // above for why the async shape is not).
    testWidgets(
      'the initialLinkReader failure and the linkStream failure report '
      'distinct, path-naming FlutterErrorDetails.context values',
      (tester) async {
        final List<FlutterErrorDetails> captured = _captureFlutterErrors();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        await tester.pumpWidget(
          _homeScreenApp(
            initialLinkReader: _throwingInitialLinkReader,
            linkStream: _throwingLinkStream,
            observer: observer,
          ),
        );
        await tester.pump();

        expect(
          captured,
          hasLength(2),
          reason:
              'expected one report from the initialLinkReader failure '
              'followed by one from the linkStream failure; captured '
              '$captured',
        );

        final String initialContext = captured[0].context
            .toString()
            .toLowerCase();
        final String streamContext = captured[1].context
            .toString()
            .toLowerCase();

        expect(
          initialContext,
          isNot(equals(streamContext)),
          reason:
              'declaration E3: the two context values must not be '
              'identical strings; both were "${captured[0].context}"',
        );

        // The declaration deliberately leaves the exact wording to the
        // implementer (E3), so this checks for one of a small set of
        // words grounded in the shared declaration's own vocabulary
        // (InitialLinkReader is documented as reading "the cold-start
        // path"; LinkStreamOpener as "the warm-start path") rather than a
        // literal sentence this file cannot know. If an implementation
        // names its paths with different words entirely, this specific
        // check would wrongly fail it; that is a real ambiguity in what
        // "names its path in plain English" is allowed to mean, and is
        // reported as such rather than resolved by guessing a longer list.
        const List<String> initialPathWords = <String>['initial', 'cold'];
        const List<String> streamPathWords = <String>['stream', 'warm'];
        expect(
          initialPathWords.any(initialContext.contains),
          isTrue,
          reason:
              'declaration E3: the context reported for the '
              'initialLinkReader failure ("${captured[0].context}") must '
              'name that path; expected one of $initialPathWords',
        );
        expect(
          streamPathWords.any(streamContext.contains),
          isTrue,
          reason:
              'declaration E3: the context reported for the linkStream '
              'failure ("${captured[1].context}") must name that path; '
              'expected one of $streamPathWords',
        );
      },
    );
  });

  group('E1 requirement 6: the non-error paths are unaffected', () {
    // These three pass on base commit a3ab7f3 already: none of them touch
    // either error path, they just exercise the same non-error behaviour
    // test/deep_link_test.dart already proves (items 10-12), rebuilt here
    // with this file's own fixtures so this suite does not depend on that
    // file. They stand guard against a fix that breaks the happy path.
    testWidgets('a null initial link does nothing', (tester) async {
      final List<FlutterErrorDetails> captured = _captureFlutterErrors();
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      await tester.pumpWidget(
        _homeScreenApp(initialLinkReader: reader.call, observer: observer),
      );
      await tester.pump();

      reader.complete(null);
      await tester.pump();

      expect(_codeFieldText(tester), isEmpty);
      expect(_codeFieldError(tester), isNull);
      expect(captured, isEmpty);
    });

    testWidgets('a valid initial link still pre-fills the code field', (
      tester,
    ) async {
      final List<FlutterErrorDetails> captured = _captureFlutterErrors();
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      await tester.pumpWidget(
        _homeScreenApp(initialLinkReader: reader.call, observer: observer),
      );
      await tester.pump();

      reader.complete(_validLink('AB23CD'));
      await tester.pump();

      expect(_codeFieldText(tester), 'AB23CD');
      expect(_codeFieldError(tester), isNull);
      expect(captured, isEmpty);
    });

    testWidgets('an invalid initial link still sets the existing error text', (
      tester,
    ) async {
      final List<FlutterErrorDetails> captured = _captureFlutterErrors();
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      await tester.pumpWidget(
        _homeScreenApp(initialLinkReader: reader.call, observer: observer),
      );
      await tester.pump();

      reader.complete(_invalidLink());
      await tester.pump();

      expect(_codeFieldText(tester), isEmpty);
      final BuildContext context = tester.element(find.byType(HomeScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(_codeFieldError(tester), loc.homeRoomCodeInvalid);
      expect(captured, isEmpty);
    });
  });
}
