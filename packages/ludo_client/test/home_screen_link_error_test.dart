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
// does not merely fail a plain expect() on this base: it is a genuine
// zone-level escape, and on base that is itself the proof of E0, that
// nothing on the chain caught the error before flutter_test's own binding
// did. See the doc comment on _captureFlutterErrors below for what that
// binding does with an escape once a test has its own FlutterError.onError
// installed, and why every capture in this file is scoped the way it is.

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

/// Runs [drive] with [FlutterError.onError] swapped for a collector, then
/// puts the previous handler straight back before this function returns --
/// never in an addTearDown. flutter_test's own binding
/// (flutter_test/lib/src/binding.dart, handleUncaughtError, around the
/// `_pendingExceptionDetails != null` assert) routes any error that escapes
/// the test's zone through whatever FlutterError.onError is installed at
/// that instant; if a test's own override is still installed there, the
/// report goes to the override instead of the binding's own handler, the
/// binding's bookkeeping assert trips, and the line that would complete the
/// test never runs, so flutter_test waits forever. addTearDown restores too
/// late for that, because addTearDown callbacks run after the binding's
/// post-body work has already needed the handler back. Restoring inside a
/// finally, before the caller ever calls expect(), is what keeps a failure
/// in [drive] -- or in anything else that reaches the zone while [drive]
/// runs -- a plain reported one instead of a hang. Every assertion about
/// what was captured belongs after this function returns, never inside
/// [drive].
Future<List<FlutterErrorDetails>> _captureFlutterErrors(
  Future<void> Function() drive,
) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previousOnError = FlutterError.onError;
  FlutterError.onError = captured.add;
  try {
    await drive();
  } finally {
    FlutterError.onError = previousOnError;
  }
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
    1,
    reason:
        'declaration E1 requirement 2: nothing may navigate. The baseline is '
        'one push and not zero, because a Navigator reports its own initial '
        'route through didPush: MaterialApp\'s home: route arrives through '
        '_RouteEntry.handleAdd, which enqueues a _NavigatorPushObservation, '
        'and that calls observer.didPush (widgets/navigator.dart). Measured '
        'on a control that pumps this same tree with no link error at all: '
        'pushCount is 1 before the screen does anything. So 2 here means the '
        'error path really navigated, and 0 means the initial route stopped '
        'being observed and this assertion has gone blind',
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
    testWidgets('reaches FlutterError.onError and the screen keeps working', (
      tester,
    ) async {
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      final Object thrown = StateError(
        'initialLinkReader future failed (scenario: platform channel '
        'error)',
      );

      final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
        () async {
          await tester.pumpWidget(
            _homeScreenApp(initialLinkReader: reader.call, observer: observer),
          );
          await tester.pump();

          reader.completeError(thrown);
          await tester.pump();
          await tester.pump();
        },
      );

      _expectScreenUndisturbed(tester, observer: observer);
      _expectReportedOnce(captured, expectedException: thrown);
    });
  });

  group('E1 requirements 1-4: a stream error from linkStream', () {
    testWidgets(
      'reaches FlutterError.onError, the screen keeps working, and a later '
      'valid Uri on the same stream still pre-fills the code field',
      (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        final Object thrown = StateError(
          'linkStream emitted an error (scenario: platform channel error)',
        );

        final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
          () async {
            await tester.pumpWidget(
              _homeScreenApp(linkStream: opener.call, observer: observer),
            );
            await tester.pump();

            opener.addError(thrown);
            await tester.pump();
            await tester.pump();
          },
        );

        _expectScreenUndisturbed(tester, observer: observer);
        _expectReportedOnce(captured, expectedException: thrown);

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
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
        () async {
          await tester.pumpWidget(
            _homeScreenApp(
              initialLinkReader: _throwingInitialLinkReader,
              observer: observer,
            ),
          );
          await tester.pump();
        },
      );

      _expectScreenUndisturbed(tester, observer: observer);
      _expectReportedOnce(captured, expectedException: _syncInitialLinkError);
    });

    testWidgets(
      'from linkStream() still lets the screen build, is reported, and '
      'leaves dispose safe',
      (tester) async {
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
          () async {
            await tester.pumpWidget(
              _homeScreenApp(
                linkStream: _throwingLinkStream,
                observer: observer,
              ),
            );
            await tester.pump();
          },
        );

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
    // depend on which of the two ways that path happens to fail. Either
    // shape would do here; the synchronous one just needs one pump instead
    // of two.
    testWidgets(
      'the initialLinkReader failure and the linkStream failure report '
      'distinct, path-naming FlutterErrorDetails.context values',
      (tester) async {
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
          () async {
            await tester.pumpWidget(
              _homeScreenApp(
                initialLinkReader: _throwingInitialLinkReader,
                linkStream: _throwingLinkStream,
                observer: observer,
              ),
            );
            await tester.pump();
          },
        );

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
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
        () async {
          await tester.pumpWidget(
            _homeScreenApp(initialLinkReader: reader.call, observer: observer),
          );
          await tester.pump();

          reader.complete(null);
          await tester.pump();
        },
      );

      expect(_codeFieldText(tester), isEmpty);
      expect(_codeFieldError(tester), isNull);
      expect(captured, isEmpty);
    });

    testWidgets('a valid initial link still pre-fills the code field', (
      tester,
    ) async {
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
        () async {
          await tester.pumpWidget(
            _homeScreenApp(initialLinkReader: reader.call, observer: observer),
          );
          await tester.pump();

          reader.complete(_validLink('AB23CD'));
          await tester.pump();
        },
      );

      expect(_codeFieldText(tester), 'AB23CD');
      expect(_codeFieldError(tester), isNull);
      expect(captured, isEmpty);
    });

    testWidgets('an invalid initial link still sets the existing error text', (
      tester,
    ) async {
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      final List<FlutterErrorDetails> captured = await _captureFlutterErrors(
        () async {
          await tester.pumpWidget(
            _homeScreenApp(initialLinkReader: reader.call, observer: observer),
          );
          await tester.pump();

          reader.complete(_invalidLink());
          // Setting the code field's text updates the TextEditingController
          // directly and is visible after a single pump, but errorText is a
          // decoration built from _errorText, which only shows up once the
          // frame that setState scheduled has actually rebuilt the tree; the
          // async-error tests above pump twice for the same reason.
          await tester.pump();
          await tester.pump();
        },
      );

      expect(_codeFieldText(tester), isEmpty);
      final BuildContext context = tester.element(find.byType(HomeScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(_codeFieldError(tester), loc.homeRoomCodeInvalid);
      expect(captured, isEmpty);
    });
  });
}
