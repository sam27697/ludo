// Deep link conformance suite, work order 088.
//
// Written blind, from the frozen declaration in
// work/orders/088-client-deep-link-tests.md alone, before order 082's
// implementation of lib/src/deep_link.dart and the HomeScreen changes ever
// landed in this worktree. Nothing here was written by reading that code;
// every assertion traces back to a lettered rule in the declaration
// (A1-A6, B1-B7, C1-C2, D1-D2) or to one of the twenty numbered coverage
// items the order requires. On this base, lib/src/deep_link.dart does not
// exist, so this file does not compile here; that is expected, not a bug in
// the test.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:path/path.dart' as p;

// --- shared fixtures --------------------------------------------------

/// A valid, well-formed app link built from a code that is itself already
/// normalised (upper case, no dash or space), so a test that just needs
/// "some valid link" does not also have to reason about normalisation.
Uri _validLink([String code = 'AB23CD']) {
  return Uri.parse('https://ludo.provefair.app/r/$code');
}

/// An [InitialLinkReader] whose future is held open by a [Completer] until
/// the test calls [complete], and which counts how many times it was
/// invoked, per coverage item 17.
class _FakeInitialLinkReader {
  final Completer<Uri?> _completer = Completer<Uri?>();
  int callCount = 0;

  Future<Uri?> call() {
    callCount += 1;
    return _completer.future;
  }

  /// Completes the held future. A second call is a no-op rather than a
  /// StateError, so a test that wants to complete defensively in a
  /// tearDown does not itself have to track whether it already did.
  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }
}

/// A [LinkStreamOpener] backed by a broadcast [StreamController], so that
/// [add] never throws even if nothing (any more) is listening -- which is
/// exactly the case coverage item 16 needs to be able to provoke without
/// the fixture itself throwing first. Counts how many times it was invoked
/// to open a stream, per coverage item 17.
class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  int callCount = 0;

  Stream<Uri> call() {
    callCount += 1;
    return _controller.stream;
  }

  void add(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();

  /// True while something is still subscribed to the stream this opener
  /// handed out. Coverage item 16 needs this, not just the absence of a
  /// thrown error: a defensive `if (!mounted) return;` guard inside the
  /// listener callback would also stop a post-dispose event from throwing,
  /// without the subscription itself ever having been cancelled the way
  /// declaration rule B3 requires. Only a broadcast controller reporting no
  /// listener left tells the two apart.
  bool get hasListener => _controller.hasListener;
}

/// Records every push/pop/replace/remove a [Navigator] reports, so "nothing
/// navigates" can be asserted against a count instead of assumed from the
/// absence of a screen that happens to be easy to find.
class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;
  int popCount = 0;
  int replaceCount = 0;
  int removeCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    replaceCount += 1;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removeCount += 1;
  }
}

/// Pumps [HomeScreen] the same way [LudoApp] assembles one (same
/// localizationsDelegates and supportedLocales), with a substitutable
/// [initialLinkReader] and [linkStream], which is what B1 requires
/// [HomeScreen] to expose directly. [observer], when given, is attached so
/// a test can read push/pop counts off it.
Widget _homeScreenApp({
  InitialLinkReader initialLinkReader = noInitialLink,
  LinkStreamOpener linkStream = noLinkStream,
  NavigatorObserver? observer,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: observer == null
        ? const <NavigatorObserver>[]
        : <NavigatorObserver>[observer],
    home: HomeScreen(
      onToggleLocale: () {},
      initialLinkReader: initialLinkReader,
      linkStream: linkStream,
    ),
  );
}

/// Pumps [LudoApp] directly with a substitutable [initialLinkReader] and
/// [linkStream], which is what C1 requires [LudoApp] to expose and pass
/// straight down to [HomeScreen].
Widget _ludoApp({
  InitialLinkReader initialLinkReader = noInitialLink,
  LinkStreamOpener linkStream = noLinkStream,
}) {
  return LudoApp(initialLinkReader: initialLinkReader, linkStream: linkStream);
}

/// The room-code-field TextField itself. [skipOffstage] defaults to true,
/// matching Finder's own default; a test reaching for the field while it
/// sits underneath a pushed route (declaration rule B5) must pass false
/// explicitly, the same way it has to on a real Navigator: a route pushed
/// on top keeps the previous route's widgets mounted but wrapped in an
/// Offstage, which the default finder skips.
TextField _codeField(WidgetTester tester, {bool skipOffstage = true}) {
  return tester.widget<TextField>(
    find.byKey(const Key('room-code-field'), skipOffstage: skipOffstage),
  );
}

String _codeFieldText(WidgetTester tester, {bool skipOffstage = true}) {
  final TextEditingController? controller = _codeField(
    tester,
    skipOffstage: skipOffstage,
  ).controller;
  expect(
    controller,
    isNotNull,
    reason: 'fixture is broken: room-code-field has no controller attached',
  );
  return controller!.text;
}

String? _codeFieldError(WidgetTester tester, {bool skipOffstage = true}) {
  return _codeField(tester, skipOffstage: skipOffstage).decoration?.errorText;
}

/// Finds this package's own root directory regardless of where `flutter
/// test` was invoked from, the same walk no_hardcoded_strings_test.dart
/// uses. Duplicated locally rather than imported from that file, since this
/// order is scoped to creating exactly one new test file and nothing else.
Directory _findPackageRoot() {
  bool isLudoClient(Directory dir) {
    final File pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec
            .readAsStringSync()
            .split('\n')
            .any((line) => line.trim() == 'name: ludo_client');
  }

  final Directory cwd = Directory.current;
  if (isLudoClient(cwd)) {
    return cwd;
  }

  final Directory nested = Directory(
    p.join(cwd.path, 'packages', 'ludo_client'),
  );
  if (isLudoClient(nested)) {
    return nested;
  }

  Directory walker = cwd;
  for (var i = 0; i < 8; i++) {
    final Directory parent = walker.parent;
    if (parent.path == walker.path) break;
    if (isLudoClient(parent)) {
      return parent;
    }
    walker = parent;
  }

  fail('could not locate the ludo_client package root from cwd ${cwd.path}');
}

/// A5 requires noInitialLink and noLinkStream to be usable as a `const`
/// default argument value, which requires them to be a compile-time
/// constant expression -- true of a plain top-level function tear-off, not
/// of (say) a closure assigned to a variable. A `const` top-level variable
/// initializer is held to exactly the same "must be a compile-time
/// constant" requirement a default parameter value is, so declaring these
/// two is itself the test: if either default were not a valid constant
/// expression, this file would fail to compile right here, independent of
/// whatever HomeScreen or LudoApp end up doing with them.
const InitialLinkReader _constDefaultReaderProbe = noInitialLink;
const LinkStreamOpener _constDefaultOpenerProbe = noLinkStream;

void main() {
  // --- roomCodeFromUri, pure, no widgets --------------------------------

  group('roomCodeFromUri', () {
    test('item 1: a valid https app link with a code returns the code', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/ABC234');
      expect(roomCodeFromUri(uri), 'ABC234');
    });

    test('item 2: a lowercase code returns the upper-cased code', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/abc234');
      expect(roomCodeFromUri(uri), 'ABC234');
    });

    test('item 2: a code carrying a dash returns it stripped', () {
      // Built with the Uri(pathSegments:) constructor rather than parsed
      // from a literal string, so the dash is guaranteed to survive into
      // pathSegments[1] exactly as written, independent of how Uri.parse
      // would otherwise treat a raw dash in a path.
      final Uri uri = Uri(
        scheme: 'https',
        host: kAppLinkHost,
        pathSegments: const ['r', 'AB2-3CD'],
      );
      expect(roomCodeFromUri(uri), 'AB23CD');
    });

    test('item 2: a code carrying a space returns it stripped', () {
      final Uri uri = Uri(
        scheme: 'https',
        host: kAppLinkHost,
        pathSegments: const ['r', 'AB2 3CD'],
      );
      expect(roomCodeFromUri(uri), 'AB23CD');
    });

    test('item 3: http instead of https returns null', () {
      final Uri uri = Uri.parse('http://ludo.provefair.app/r/ABC234');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 4: a wholly different host returns null', () {
      final Uri uri = Uri.parse('https://example.com/r/ABC234');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 4: evil.ludo.provefair.app returns null, a suffix match is not '
        'an equality check', () {
      final Uri uri = Uri.parse('https://evil.ludo.provefair.app/r/ABC234');
      expect(
        roomCodeFromUri(uri),
        isNull,
        reason:
            'host comparison must be exact equality against kAppLinkHost; '
            'a suffix or "ends with" comparison would wrongly accept a '
            'host an attacker controls, evil.ludo.provefair.app',
      );
    });

    test('item 5: a code containing an excluded character (0) returns null, '
        'matching the server, which also 404s AB0234', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/AB0234');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 6: a code shorter than 6 characters returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/AB23C');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 6: a code longer than 6 characters returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/AB23CDE');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 7: /r/ with no code returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 7: /r/A/B, three path segments, returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/A/B');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 7: / alone returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/');
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 8: a valid code carried only in the query string, with a '
        'non-matching path, returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/?code=ABC234');
      expect(
        uri.pathSegments,
        isEmpty,
        reason:
            'fixture is broken: this case only proves anything about the '
            'query string being ignored if the path itself carries no '
            'code segments at all',
      );
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 8: a valid code carried only in the fragment, with a '
        'non-matching path, returns null', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/#/r/ABC234');
      expect(
        uri.pathSegments,
        isEmpty,
        reason:
            'fixture is broken: this case only proves anything about the '
            'fragment being ignored if the path itself carries no code '
            'segments at all',
      );
      expect(roomCodeFromUri(uri), isNull);
    });

    test('item 9: L is accepted, it is in the alphabet on purpose', () {
      final Uri uri = Uri.parse('https://ludo.provefair.app/r/ABLCDE');
      expect(roomCodeFromUri(uri), 'ABLCDE');
    });
  });

  // --- A1: the constant must match the manifest -------------------------

  test('kAppLinkHost equals the android:host of the autoVerify intent filter '
      'in AndroidManifest.xml', () {
    final Directory root = _findPackageRoot();
    final File manifest = File(
      p.join(root.path, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
    );
    expect(
      manifest.existsSync(),
      isTrue,
      reason: 'expected ${manifest.path} to exist',
    );
    final String contents = manifest.readAsStringSync();
    expect(
      contents,
      contains('android:host="$kAppLinkHost"'),
      reason:
          'kAppLinkHost ("$kAppLinkHost") must equal the android:host of '
          'the autoVerify intent filter, declaration rule A1; it was not '
          'found verbatim in ${manifest.path}',
    );
  });

  // --- A5: the inert defaults, tested directly, no widgets ---------------

  group('A5: the inert defaults', () {
    test('noInitialLink resolves to null', () async {
      expect(await noInitialLink(), isNull);
    });

    test('noLinkStream emits nothing', () async {
      final List<Uri> events = <Uri>[];
      final StreamSubscription<Uri> sub = noLinkStream().listen(events.add);
      // A bounded, real asynchronous gap (not pumpEventQueue, which hangs
      // inside a testWidgets body per this order's trap 1; this is a plain
      // `test`, not a `testWidgets`, so there is no fake-async zone to hang
      // in) is enough for anything the stream was ever going to emit
      // synchronously-soon to have arrived.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, isEmpty);
    });

    test('noInitialLink and noLinkStream are each usable as a const default '
        'argument value', () {
      expect(_constDefaultReaderProbe, same(noInitialLink));
      expect(_constDefaultOpenerProbe, same(noLinkStream));
    });
  });

  // --- A6 / C2: import and wiring discipline, source scans ---------------

  group('A6 and C2: import and wiring discipline', () {
    test('deep_link.dart is the only file under lib/ that imports '
        'package:app_links', () {
      final Directory root = _findPackageRoot();
      final Directory libDir = Directory(p.join(root.path, 'lib'));
      final List<File> dartFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(dartFiles, isNotEmpty);

      final List<String> violators = <String>[];
      for (final File file in dartFiles) {
        if (p.basename(file.path) == 'deep_link.dart') continue;
        final String source = file.readAsStringSync();
        if (source.contains('package:app_links')) {
          violators.add(p.relative(file.path, from: libDir.path));
        }
      }
      expect(
        violators,
        isEmpty,
        reason:
            'declaration rule A6: only deep_link.dart may import '
            'package:app_links; also found it in: ${violators.join(', ')}',
      );
    });

    test('nothing under lib/src/ names appLinksInitialLink or '
        'appLinksLinkStream as a default argument value', () {
      final Directory root = _findPackageRoot();
      final Directory srcDir = Directory(p.join(root.path, 'lib', 'src'));
      final List<File> dartFiles = srcDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(dartFiles, isNotEmpty);

      final RegExp defaultsToRealAdapter = RegExp(
        r'=\s*appLinksInitialLink\b|=\s*appLinksLinkStream\b',
      );

      final List<String> violators = <String>[];
      for (final File file in dartFiles) {
        if (p.basename(file.path) == 'deep_link.dart') continue;
        final String source = file.readAsStringSync();
        if (defaultsToRealAdapter.hasMatch(source)) {
          violators.add(p.relative(file.path, from: srcDir.path));
        }
      }
      expect(
        violators,
        isEmpty,
        reason:
            'declaration rule C2: nothing under lib/src/ may name the '
            'real adapters as a default; found in: '
            '${violators.join(', ')}',
      );
    });

    test('lib/main.dart wires the real adapters into LudoApp', () {
      final Directory root = _findPackageRoot();
      final File main = File(p.join(root.path, 'lib', 'main.dart'));
      expect(main.existsSync(), isTrue);
      final String source = main.readAsStringSync();
      expect(
        source.contains('appLinksInitialLink'),
        isTrue,
        reason:
            'declaration rule C2: lib/main.dart must pass '
            'appLinksInitialLink to LudoApp',
      );
      expect(
        source.contains('appLinksLinkStream'),
        isTrue,
        reason:
            'declaration rule C2: lib/main.dart must pass '
            'appLinksLinkStream to LudoApp',
      );
    });
  });

  // --- D1/D2: the manifest ------------------------------------------------

  group('D: the manifest', () {
    test('D1: flutter_deeplinking_enabled is declared false inside the '
        'activity', () {
      final Directory root = _findPackageRoot();
      final File manifest = File(
        p.join(
          root.path,
          'android',
          'app',
          'src',
          'main',
          'AndroidManifest.xml',
        ),
      );
      final String contents = manifest.readAsStringSync();
      final int activityStart = contents.indexOf('<activity');
      final int activityEnd = contents.indexOf('</activity>');
      expect(
        activityStart,
        greaterThanOrEqualTo(0),
        reason: 'fixture is broken: no <activity> element found',
      );
      expect(activityEnd, greaterThan(activityStart));
      final String activityBlock = contents.substring(
        activityStart,
        activityEnd,
      );
      expect(
        activityBlock.contains('flutter_deeplinking_enabled') &&
            activityBlock.contains('android:value="false"'),
        isTrue,
        reason:
            'declaration rule D1: the activity must declare '
            '<meta-data android:name="flutter_deeplinking_enabled" '
            'android:value="false" />, or app_links\' own deep-link '
            'handling loses the intent to Flutter\'s built-in handling',
      );
    });

    test('D2: the autoVerify intent filter, its scheme, host and path prefix '
        'are untouched', () {
      final Directory root = _findPackageRoot();
      final File manifest = File(
        p.join(
          root.path,
          'android',
          'app',
          'src',
          'main',
          'AndroidManifest.xml',
        ),
      );
      final String contents = manifest.readAsStringSync();
      expect(contents, contains('android:autoVerify="true"'));
      expect(contents, contains('android:scheme="https"'));
      expect(contents, contains('android:host="ludo.provefair.app"'));
      expect(contents, contains('android:pathPrefix="/r/"'));
    });
  });

  // --- the cold path, driven through initialLinkReader --------------------

  group('the cold path', () {
    testWidgets('item 10: a valid cold link fills the room code field through '
        'HomeScreen directly, and nothing navigates', (tester) async {
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      await tester.pumpWidget(
        _homeScreenApp(initialLinkReader: reader.call, observer: observer),
      );
      await tester.pump();
      final int pushesBefore = observer.pushCount;
      final int popsBefore = observer.popCount;

      reader.complete(_validLink('AB23CD'));
      await tester.pump();

      expect(_codeFieldText(tester), 'AB23CD');
      expect(_codeFieldError(tester), isNull);
      expect(observer.pushCount, pushesBefore);
      expect(observer.popCount, popsBefore);
      expect(find.byType(LobbyScreen), findsNothing);
    });

    testWidgets('item 10: a valid cold link fills the room code field through '
        'LudoApp, and nothing navigates', (tester) async {
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      await tester.pumpWidget(_ludoApp(initialLinkReader: reader.call));
      await tester.pump();

      reader.complete(_validLink('AB23CD'));
      await tester.pump();

      expect(_codeFieldText(tester), 'AB23CD');
      expect(_codeFieldError(tester), isNull);
      expect(find.byType(LobbyScreen), findsNothing);
    });

    testWidgets(
      'item 11: an invalid cold link leaves the field exactly as it was and '
      'shows the invalid-code error, and nothing navigates',
      (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        await tester.pumpWidget(
          _homeScreenApp(initialLinkReader: reader.call, observer: observer),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('room-code-field')),
          'ZQ77KM',
        );
        await tester.pump();
        final int pushesBefore = observer.pushCount;
        final int popsBefore = observer.popCount;

        // wrong host: never matches, so this is an invalid link.
        reader.complete(Uri.parse('https://example.com/r/AB23CD'));
        await tester.pump();

        expect(
          _codeFieldText(tester),
          'ZQ77KM',
          reason:
              'an invalid link must leave whatever the player had already '
              'typed exactly as it was, not clear it',
        );
        final BuildContext context = tester.element(find.byType(HomeScreen));
        final AppLocalizations loc = AppLocalizations.of(context);
        expect(_codeFieldError(tester), loc.homeRoomCodeInvalid);
        expect(observer.pushCount, pushesBefore);
        expect(observer.popCount, popsBefore);
      },
    );

    testWidgets('item 12: initialLinkReader completing with null, the ordinary '
        'launch, leaves the field empty and shows no error', (tester) async {
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
      await tester.pumpWidget(_homeScreenApp(initialLinkReader: reader.call));
      await tester.pump();

      reader.complete(null);
      await tester.pump();

      expect(_codeFieldText(tester), isEmpty);
      expect(_codeFieldError(tester), isNull);
    });
  });

  // --- the warm path, driven through linkStream ---------------------------

  group('the warm path', () {
    testWidgets(
      'item 13: a valid uri emitted on the stream after the first frame '
      'fills the field',
      (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
        await tester.pump();

        opener.add(_validLink('AB23CD'));
        await tester.pump();

        expect(_codeFieldText(tester), 'AB23CD');
        expect(_codeFieldError(tester), isNull);
      },
    );

    testWidgets('item 14: a second uri emitted later replaces the first code', (
      tester,
    ) async {
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();

      opener.add(_validLink('AB23CD'));
      await tester.pump();
      expect(_codeFieldText(tester), 'AB23CD');

      opener.add(_validLink('ZY98XW'));
      await tester.pump();

      expect(_codeFieldText(tester), 'ZY98XW');
    });

    testWidgets(
      'item 15: an invalid uri on the stream sets the error and leaves the '
      'text alone',
      (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('room-code-field')),
          'KEEPME',
        );
        await tester.pump();

        opener.add(Uri.parse('http://ludo.provefair.app/r/AB23CD'));
        await tester.pump();

        expect(_codeFieldText(tester), 'KEEPME');
        final BuildContext context = tester.element(find.byType(HomeScreen));
        final AppLocalizations loc = AppLocalizations.of(context);
        expect(_codeFieldError(tester), loc.homeRoomCodeInvalid);
      },
    );
  });

  // --- the things that will actually break --------------------------------

  group('the things that will actually break', () {
    testWidgets('item 16: the linkStream subscription is cancelled on dispose; '
        'emitting afterwards does not throw and does not setState', (
      tester,
    ) async {
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();
      expect(
        opener.callCount,
        1,
        reason:
            'fixture is broken: HomeScreen must have opened the link '
            'stream once by now',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(
        opener.hasListener,
        isFalse,
        reason:
            'declaration rule B3: the subscription must actually be '
            'cancelled in dispose(), not merely rendered harmless by a '
            'stray "if (!mounted) return" guard inside the listener; the '
            'stream this opener handed out must have no listener left once '
            'the widget is disposed',
      );

      opener.add(_validLink('AB23CD'));
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'declaration rule B3: the linkStream subscription must be '
            'cancelled in dispose(); an event delivered after disposal '
            'must not reach a setState on the unmounted state',
      );
    });

    testWidgets(
      'item 17: initialLinkReader is called exactly once and linkStream is '
      'opened exactly once, even across a rebuild',
      (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

        Widget build() => _homeScreenApp(
          initialLinkReader: reader.call,
          linkStream: opener.call,
        );

        await tester.pumpWidget(build());
        await tester.pump();
        expect(reader.callCount, 1);
        expect(opener.callCount, 1);

        // Same widget shape rebuilt on top of the same tree: the framework
        // reuses the existing State rather than tearing it down and
        // recreating it, exactly like any ordinary parent rebuild would.
        await tester.pumpWidget(build());
        await tester.pump();

        expect(
          reader.callCount,
          1,
          reason:
              'declaration rule B3: initialLinkReader must be called '
              'exactly once; a rebuild must not read the initial link again',
        );
        expect(
          opener.callCount,
          1,
          reason:
              'declaration rule B3: linkStream must be subscribed exactly '
              'once; a rebuild must not open a second subscription',
        );

        reader.complete(null);
        await tester.pump();
      },
    );

    testWidgets(
      'item 18: a cold read that completes after the widget is disposed '
      'does not throw',
      (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        await tester.pumpWidget(_homeScreenApp(initialLinkReader: reader.call));
        await tester.pump();
        expect(reader.callCount, 1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        reader.complete(_validLink('AB23CD'));
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason:
              'declaration rule B6: the cold read completing after the '
              'widget is unmounted must not call setState on it and must '
              'not throw',
        );
      },
    );

    testWidgets(
      'item 19: cold and warm, valid and invalid, none of it ever pushes '
      'or pops a route',
      (tester) async {
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        await tester.pumpWidget(
          _homeScreenApp(
            initialLinkReader: reader.call,
            linkStream: opener.call,
            observer: observer,
          ),
        );
        await tester.pump();

        final int pushesAfterLoad = observer.pushCount;
        final int popsAfterLoad = observer.popCount;
        final int replacesAfterLoad = observer.replaceCount;
        final int removesAfterLoad = observer.removeCount;

        reader.complete(_validLink('AB23CD'));
        await tester.pump();
        opener.add(Uri.parse('http://ludo.provefair.app/r/AB23CD'));
        await tester.pump();
        opener.add(_validLink('ZY98XW'));
        await tester.pump();
        opener.add(Uri.parse('https://example.com/r/AB23CD'));
        await tester.pump();

        expect(
          observer.pushCount,
          pushesAfterLoad,
          reason:
              'declaration rule B4: a link, valid or invalid, cold or warm, '
              'must never push a route; a link never joins a room by itself',
        );
        expect(observer.popCount, popsAfterLoad);
        expect(observer.replaceCount, replacesAfterLoad);
        expect(observer.removeCount, removesAfterLoad);
        expect(find.byType(LobbyScreen), findsNothing);
      },
    );

    testWidgets(
      'B5: an incoming link still updates the home screen underneath a '
      'route pushed above it, and does not pop that route or push its own',
      (tester) async {
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _RecordingNavigatorObserver observer =
            _RecordingNavigatorObserver();
        await tester.pumpWidget(
          _homeScreenApp(linkStream: opener.call, observer: observer),
        );
        await tester.pump();

        final BuildContext homeContext = tester.element(
          find.byType(HomeScreen),
        );
        Navigator.of(homeContext).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(key: Key('above-home-probe')),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('above-home-probe')), findsOneWidget);
        final int pushesAfterProbe = observer.pushCount;
        final int popsAfterProbe = observer.popCount;

        opener.add(_validLink('AB23CD'));
        await tester.pump();

        expect(
          _codeFieldText(tester, skipOffstage: false),
          'AB23CD',
          reason:
              'declaration rule B5: the home screen underneath a pushed '
              'route must still absorb the link exactly as B4 describes; a '
              'player already inside a lobby or a game is not exempt, the '
              'field just is not the visible one right now',
        );
        expect(
          find.byKey(const Key('above-home-probe')),
          findsOneWidget,
          reason:
              'declaration rule B5: the link must not pop the route pushed '
              'above the home screen; a player already inside a lobby or a '
              'game must not be yanked out of it by an incoming link',
        );
        expect(
          observer.pushCount,
          pushesAfterProbe,
          reason:
              'declaration rule B5: the link must not push a route of '
              'its own on top of the one already pushed',
        );
        expect(observer.popCount, popsAfterProbe);
      },
    );
  });

  // --- the default is inert ------------------------------------------------

  group('the default is inert', () {
    /// Registers a handler on [channel] that flips a flag if it is ever
    /// invoked, and unregisters it again once the test ends, so a
    /// mis-scoped mock handler from this test cannot bleed into the next
    /// one.
    void guardChannel(
      WidgetTester tester,
      String channel,
      void Function() onTouched,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(channel, (ByteData? message) async {
            onTouched();
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMessageHandler(channel, null);
      });
    }

    testWidgets(
      'item 20: HomeScreen built with no link arguments at all reaches a '
      'steady state with an empty code field, no error, and never touches '
      'the app_links platform channels',
      (tester) async {
        bool messagesTouched = false;
        bool eventsTouched = false;
        guardChannel(
          tester,
          'com.llfbandit.app_links/messages',
          () => messagesTouched = true,
        );
        guardChannel(
          tester,
          'com.llfbandit.app_links/events',
          () => eventsTouched = true,
        );

        await tester.pumpWidget(
          MaterialApp(
            supportedLocales: appSupportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: HomeScreen(onToggleLocale: () {}),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(_codeFieldText(tester), isEmpty);
        expect(_codeFieldError(tester), isNull);
        expect(
          messagesTouched,
          isFalse,
          reason:
              'declaration rule A5: the defaults must be inert everywhere '
              'in lib/src/; building HomeScreen with no link arguments must '
              'never reach a real platform channel',
        );
        expect(eventsTouched, isFalse);
      },
    );

    testWidgets(
      'item 20: LudoApp built with no link arguments at all reaches a '
      'steady state with an empty code field, no error, and never touches '
      'the app_links platform channels',
      (tester) async {
        bool messagesTouched = false;
        bool eventsTouched = false;
        guardChannel(
          tester,
          'com.llfbandit.app_links/messages',
          () => messagesTouched = true,
        );
        guardChannel(
          tester,
          'com.llfbandit.app_links/events',
          () => eventsTouched = true,
        );

        await tester.pumpWidget(const LudoApp());
        await tester.pump();
        await tester.pump();

        expect(_codeFieldText(tester), isEmpty);
        expect(_codeFieldError(tester), isNull);
        expect(messagesTouched, isFalse);
        expect(eventsTouched, isFalse);
      },
    );
  });
}
