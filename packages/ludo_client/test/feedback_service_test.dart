// Conformance tests for lib/src/feedback.dart's PlatformFeedbackService,
// FeedbackSettings and FeedbackScope, written from work order
// C-225-feedback.md's "The service" section, against no implementation of
// feedback.dart the author of this file has read. feedback.dart does not
// exist on the branch this file was written on.
//
// Two constructor shapes are not pinned by C-225's prose (it gives field
// and behaviour names, not a full declaration block the way it does for
// FeedbackCue and cuesForFrame), and this file had to pick one to compile
// against at all:
//
//   1. PlatformFeedbackService's constructor: C-225 says only "constructor
//      takes a FeedbackSettings and an optional MethodChannel". Read as two
//      positional parameters, in that order, with the MethodChannel
//      defaulting to MethodChannel('app.fayad.ludo/feedback'). Tested as
//      PlatformFeedbackService(settings) and
//      PlatformFeedbackService(settings, channel).
//   2. FeedbackScope's constructor: C-225 says it "extends
//      InheritedNotifier<FeedbackSettings>" and that FeedbackScope.of
//      "returns the service it carries", which means it carries both a
//      FeedbackSettings (the notifier InheritedNotifier itself requires)
//      and a FeedbackService, but never names the constructor's
//      parameters. Tested as
//      FeedbackScope(service: ..., settings: ..., child: ...). If order
//      225 names these differently, the FeedbackScope group below fails to
//      compile on that ground alone, not on any behavioural ground; that
//      would be this file's inference proven wrong, not a defect in this
//      file's understanding of C-225's actual behavioural rules, which are
//      exact.
//
// Every negative and off/on-switch case below asserts the exact set of
// platform calls made, not just that "something" or "nothing" happened, so
// a service that fires the wrong method or the wrong id alongside the
// right one is still caught.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _feedbackChannel = MethodChannel('app.fayad.ludo/feedback');

/// Installs a recording mock handler on [channel], returning the calls it
/// has recorded in arrival order. Cleared automatically after the test
/// (flutter_test's own guarantee), and explicitly torn down here as well
/// so a later test in this file that relies on no handler being installed
/// is never accidentally fed a stale one.
List<MethodCall> _recordCalls(
  WidgetTester? tester,
  MethodChannel channel, {
  Future<Object?> Function(MethodCall call)? onCall,
}) {
  final List<MethodCall> calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (onCall != null) {
          return onCall(call);
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  return calls;
}

String? _idOf(MethodCall call) => (call.arguments as Map)['id'] as String?;

/// A minimal, do-nothing FeedbackService, distinct from NoopFeedbackService,
/// used only so FeedbackScope.of's identity test has something to compare
/// against that is not itself the class under test on the "no scope"
/// side.
class _DummyFeedbackService implements FeedbackService {
  int playCount = 0;

  @override
  void play(FeedbackCue cue) {
    playCount += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformFeedbackService.play: both channels on', () {
    test('play(win) invokes exactly haptic {id: win} and sound {id: win}, and '
        'nothing else', () async {
      final calls = _recordCalls(null, _feedbackChannel);
      final settings = FeedbackSettings.forTest();
      final service = PlatformFeedbackService(settings, _feedbackChannel);

      service.play(FeedbackCue.win);
      await pumpEventQueue();

      expect(
        calls.map((c) => '${c.method}:${_idOf(c)}').toSet(),
        equals(<String>{'haptic:win', 'sound:win'}),
        reason:
            'play(win) with both switches on must invoke exactly '
            'haptic{id:win} and sound{id:win}; got '
            '${calls.map((c) => '${c.method}:${_idOf(c)}').toList()}',
      );
      expect(
        calls,
        hasLength(2),
        reason:
            'play(win) must make exactly two platform calls, not '
            '${calls.length}: $calls',
      );
    });
  });

  group('PlatformFeedbackService.play: the switches gate the channels', () {
    test('haptics off, sound on: play(win) invokes only sound', () async {
      final calls = _recordCalls(null, _feedbackChannel);
      final settings = FeedbackSettings.forTest(haptics: false, sound: true);
      final service = PlatformFeedbackService(settings, _feedbackChannel);

      service.play(FeedbackCue.win);
      await pumpEventQueue();

      expect(
        calls,
        hasLength(1),
        reason: 'expected exactly one call with haptics off, got $calls',
      );
      expect(calls.single.method, 'sound');
      expect(_idOf(calls.single), 'win');
    });

    test('sound off, haptics on: play(win) invokes only haptic', () async {
      final calls = _recordCalls(null, _feedbackChannel);
      final settings = FeedbackSettings.forTest(haptics: true, sound: false);
      final service = PlatformFeedbackService(settings, _feedbackChannel);

      service.play(FeedbackCue.win);
      await pumpEventQueue();

      expect(
        calls,
        hasLength(1),
        reason: 'expected exactly one call with sound off, got $calls',
      );
      expect(calls.single.method, 'haptic');
      expect(_idOf(calls.single), 'win');
    });

    test('both switches off: play(win) invokes nothing', () async {
      final calls = _recordCalls(null, _feedbackChannel);
      final settings = FeedbackSettings.forTest(haptics: false, sound: false);
      final service = PlatformFeedbackService(settings, _feedbackChannel);

      service.play(FeedbackCue.win);
      await pumpEventQueue();

      expect(
        calls,
        isEmpty,
        reason: 'both switches off must invoke nothing, got $calls',
      );
    });
  });

  group('invalidTap never calls sound', () {
    test('with both switches on, play(invalidTap) invokes haptic only, never '
        'sound', () async {
      final calls = _recordCalls(null, _feedbackChannel);
      final settings = FeedbackSettings.forTest();
      final service = PlatformFeedbackService(settings, _feedbackChannel);

      service.play(FeedbackCue.invalidTap);
      await pumpEventQueue();

      expect(
        calls.any((c) => c.method == 'sound'),
        isFalse,
        reason:
            'invalidTap must never call sound, per the doctrine table '
            '("none"), even with settings.sound on; got $calls',
      );
      expect(
        calls.where((c) => c.method == 'haptic').map(_idOf),
        equals(<String?>['invalid_tap']),
        reason: 'invalidTap must still call haptic{id:invalid_tap}; got $calls',
      );
    });
  });

  group('step throttle: at most one haptic and one sound per 60ms', () {
    test('ten play(step) within 10ms of fake time produce one haptic and one '
        'sound; after 60ms elapses, another is allowed', () {
      fakeAsync((FakeAsync async) {
        final List<MethodCall> calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_feedbackChannel, (
              MethodCall call,
            ) async {
              calls.add(call);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(_feedbackChannel, null),
        );

        final settings = FeedbackSettings.forTest();
        final service = PlatformFeedbackService(settings, _feedbackChannel);

        // All ten calls at the same fake instant (0ms apart), well within
        // the "within 10ms" the order names.
        for (var i = 0; i < 10; i++) {
          service.play(FeedbackCue.step);
        }
        async.flushMicrotasks();

        List<MethodCall> stepCalls() =>
            calls.where((c) => _idOf(c) == 'step').toList();

        expect(
          stepCalls().where((c) => c.method == 'haptic'),
          hasLength(1),
          reason:
              'ten play(step) calls at the same instant must produce '
              'exactly one step haptic, got ${stepCalls()}',
        );
        expect(
          stepCalls().where((c) => c.method == 'sound'),
          hasLength(1),
          reason:
              'ten play(step) calls at the same instant must produce '
              'exactly one step sound, got ${stepCalls()}',
        );

        async.elapse(const Duration(milliseconds: 60));
        async.flushMicrotasks();

        service.play(FeedbackCue.step);
        async.flushMicrotasks();

        expect(
          stepCalls().where((c) => c.method == 'haptic'),
          hasLength(2),
          reason:
              'a play(step) 60ms after the throttled burst must be '
              'let through, giving a second step haptic; got '
              '${stepCalls()}',
        );
        expect(
          stepCalls().where((c) => c.method == 'sound'),
          hasLength(2),
          reason:
              'a play(step) 60ms after the throttled burst must be '
              'let through, giving a second step sound; got '
              '${stepCalls()}',
        );
      });
    });
  });

  group(
    'a failing platform call never throws out of play(), and is counted',
    () {
      test('a handler that throws PlatformException: play does not throw and '
          'failedCalls increases by exactly one for invalidTap\'s single '
          'platform call', () async {
        _recordCalls(
          null,
          _feedbackChannel,
          onCall: (call) async {
            throw PlatformException(code: 'NO_VIBRATOR', message: 'nope');
          },
        );
        final settings = FeedbackSettings.forTest();
        final service = PlatformFeedbackService(settings, _feedbackChannel);

        expect(service.failedCalls, 0);
        expect(
          () => service.play(FeedbackCue.invalidTap),
          returnsNormally,
          reason:
              'play() must never throw, even when the platform call '
              'throws a PlatformException',
        );
        await pumpEventQueue();

        expect(
          service.failedCalls,
          1,
          reason:
              'invalidTap makes exactly one platform call (haptic only); '
              'a PlatformException from it must raise failedCalls to 1, '
              'got ${service.failedCalls}',
        );
      });

      test(
        'no handler at all (MissingPluginException): play does not throw and '
        'failedCalls increases by exactly one for invalidTap\'s single '
        'platform call',
        () async {
          // Deliberately no setMockMethodCallHandler call for this channel:
          // an unregistered channel makes invokeMethod complete with
          // MissingPluginException, the platform-channel term for "the
          // native side never answered this method at all".
          const channel = MethodChannel('app.fayad.ludo/feedback.unregistered');
          final settings = FeedbackSettings.forTest();
          final service = PlatformFeedbackService(settings, channel);

          expect(service.failedCalls, 0);
          expect(
            () => service.play(FeedbackCue.invalidTap),
            returnsNormally,
            reason:
                'play() must never throw, even when there is no platform '
                'handler at all',
          );
          await pumpEventQueue();

          expect(
            service.failedCalls,
            1,
            reason:
                'a MissingPluginException from invalidTap\'s one platform '
                'call must raise failedCalls to 1, got ${service.failedCalls}',
          );
        },
      );

      test(
        'a failure is reported exactly once per service instance via '
        'debugPrint, naming the method and the error; a second failing '
        'play() on the same instance adds no further debugPrint call',
        () async {
          _recordCalls(
            null,
            _feedbackChannel,
            onCall: (call) async {
              throw PlatformException(code: 'NO_VIBRATOR', message: 'nope');
            },
          );

          final List<String?> printed = <String?>[];
          final DebugPrintCallback original = debugPrint;
          debugPrint = (String? message, {int? wrapWidth}) {
            printed.add(message);
          };
          addTearDown(() => debugPrint = original);

          final settings = FeedbackSettings.forTest();
          final service = PlatformFeedbackService(settings, _feedbackChannel);

          // win makes two platform calls (haptic and sound), both failing;
          // home makes two more failing calls on the same instance.
          service.play(FeedbackCue.win);
          await pumpEventQueue();
          service.play(FeedbackCue.home);
          await pumpEventQueue();

          expect(
            service.failedCalls,
            greaterThanOrEqualTo(3),
            reason:
                'this scenario causes at least three failing platform '
                'calls (four, if both cues invoke both channels); if '
                'failedCalls is lower than that, the debugPrint-count '
                'assertion below is not exercising what it claims to, '
                'got ${service.failedCalls}',
          );
          expect(
            printed,
            hasLength(1),
            reason:
                'C-225 says a platform failure is "reported once per '
                'service instance": however many platform calls fail on '
                'one PlatformFeedbackService, debugPrint must be called '
                'exactly once for its whole lifetime, not once per '
                'failure; got $printed after ${service.failedCalls} '
                'failures',
          );
          expect(
            printed.single,
            anyOf(contains('haptic'), contains('sound')),
            reason:
                'the single report must name the method that failed '
                '(haptic or sound); got "${printed.single}"',
          );
          expect(
            printed.single,
            contains('NO_VIBRATOR'),
            reason:
                'the single report must name the error; the mock handler '
                'threw PlatformException(code: "NO_VIBRATOR"), so that '
                'code should be visible in the report; got '
                '"${printed.single}"',
          );
        },
      );
    },
  );

  group('FeedbackSettings.load()', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('absent keys give haptics true and sound true', () async {
      final settings = await FeedbackSettings.load();
      expect(settings.haptics, isTrue);
      expect(settings.sound, isTrue);
    });

    test(
      'feedback.haptics=false gives haptics false, sound still true',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'feedback.haptics': false,
        });
        final settings = await FeedbackSettings.load();
        expect(settings.haptics, isFalse);
        expect(settings.sound, isTrue);
      },
    );

    test(
      'feedback.sound=false gives sound false, haptics still true',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'feedback.sound': false,
        });
        final settings = await FeedbackSettings.load();
        expect(settings.sound, isFalse);
        expect(settings.haptics, isTrue);
      },
    );

    test('setting sound=false persists: a second load() reads false, and '
        'notifies listeners exactly once', () async {
      final settings = await FeedbackSettings.load();
      var notifications = 0;
      settings.addListener(() => notifications += 1);

      settings.sound = false;
      expect(
        notifications,
        1,
        reason:
            'assigning settings.sound must notify listeners exactly '
            'once; got $notifications',
      );

      await pumpEventQueue();

      final relaunched = await FeedbackSettings.load();
      expect(
        relaunched.sound,
        isFalse,
        reason:
            'a later FeedbackSettings.load() must read the sound=false '
            'written by the previous instance\'s setter',
      );
    });

    test('setting haptics=false persists: a second load() reads false, and '
        'notifies listeners exactly once', () async {
      final settings = await FeedbackSettings.load();
      var notifications = 0;
      settings.addListener(() => notifications += 1);

      settings.haptics = false;
      expect(notifications, 1);

      await pumpEventQueue();

      final relaunched = await FeedbackSettings.load();
      expect(relaunched.haptics, isFalse);
    });
  });

  group('FeedbackSettings.forTest', () {
    test('defaults both haptics and sound to true', () {
      final settings = FeedbackSettings.forTest();
      expect(settings.haptics, isTrue);
      expect(settings.sound, isTrue);
    });

    test('accepts explicit haptics and sound values', () {
      final settings = FeedbackSettings.forTest(haptics: false, sound: false);
      expect(settings.haptics, isFalse);
      expect(settings.sound, isFalse);
    });
  });

  group('FeedbackScope', () {
    testWidgets('FeedbackScope.of returns the scope\'s own service instance', (
      WidgetTester tester,
    ) async {
      final settings = FeedbackSettings.forTest();
      final service = _DummyFeedbackService();
      FeedbackService? resolved;

      await tester.pumpWidget(
        FeedbackScope(
          service: service,
          settings: settings,
          child: Builder(
            builder: (BuildContext context) {
              resolved = FeedbackScope.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(
        identical(resolved, service),
        isTrue,
        reason:
            'FeedbackScope.of must return the exact FeedbackService the '
            'nearest FeedbackScope was built with; got $resolved, '
            'expected the same object as $service',
      );
    });

    testWidgets(
      'FeedbackScope.of returns a NoopFeedbackService when there is no '
      'scope above, so bare widget trees (existing GameScreen tests) keep '
      'working',
      (WidgetTester tester) async {
        FeedbackService? resolved;

        await tester.pumpWidget(
          Builder(
            builder: (BuildContext context) {
              resolved = FeedbackScope.of(context);
              return const SizedBox.shrink();
            },
          ),
        );

        expect(
          resolved,
          isA<NoopFeedbackService>(),
          reason:
              'with no FeedbackScope above the context, FeedbackScope.of '
              'must return a NoopFeedbackService, not throw and not '
              'return null; got $resolved',
        );
      },
    );

    testWidgets('a NoopFeedbackService.play never throws for any cue', (
      WidgetTester tester,
    ) async {
      FeedbackService? resolved;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            resolved = FeedbackScope.of(context);
            return const SizedBox.shrink();
          },
        ),
      );

      for (final cue in FeedbackCue.values) {
        expect(
          () => resolved!.play(cue),
          returnsNormally,
          reason: 'NoopFeedbackService.play(${cue.id}) must not throw',
        );
      }
    });
  });
}
