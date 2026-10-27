// Service proof for C-468 D6 (order 469), written from the contract's text
// alone: FeedbackCue.dieLand and FeedbackCue.gloat reach the platform as
// `sound` calls only, never as `haptic`, gated on the sound switch and
// never throttled (step is the one throttled cue). Kept beside
// feedback_service_test.dart rather than inside it so that file keeps
// compiling on a tree where the two cues do not exist yet.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // C-468 D4, D5, D6 (order 469): die_land and gloat are sound only.
  group('dieLand and gloat are sound only and never throttled (C-468 D6)', () {
    for (final (FeedbackCue cue, String id) in <(FeedbackCue, String)>[
      (FeedbackCue.dieLand, 'die_land'),
      (FeedbackCue.gloat, 'gloat'),
    ]) {
      test('both switches on: play($id) invokes exactly sound {id: $id}, '
          'never haptic', () async {
        final calls = _recordCalls(null, _feedbackChannel);
        final service = PlatformFeedbackService(
          FeedbackSettings.forTest(),
          _feedbackChannel,
        );

        service.play(cue);
        await pumpEventQueue();

        expect(
          calls.map((c) => '${c.method}:${_idOf(c)}').toList(),
          equals(<String>['sound:$id']),
          reason:
              'play($id) with both switches on must make exactly one '
              'platform call, sound{id:$id}; got '
              '${calls.map((c) => '${c.method}:${_idOf(c)}').toList()}',
        );
      });

      test(
        'haptics off, sound on: play($id) still invokes sound only',
        () async {
          final calls = _recordCalls(null, _feedbackChannel);
          final service = PlatformFeedbackService(
            FeedbackSettings.forTest(haptics: false, sound: true),
            _feedbackChannel,
          );

          service.play(cue);
          await pumpEventQueue();

          expect(
            calls.map((c) => '${c.method}:${_idOf(c)}').toList(),
            equals(<String>['sound:$id']),
            reason:
                'got ${calls.map((c) => '${c.method}:${_idOf(c)}').toList()}',
          );
        },
      );

      test('sound off, haptics on: play($id) invokes nothing', () async {
        final calls = _recordCalls(null, _feedbackChannel);
        final service = PlatformFeedbackService(
          FeedbackSettings.forTest(haptics: true, sound: false),
          _feedbackChannel,
        );

        service.play(cue);
        await pumpEventQueue();

        expect(
          calls,
          isEmpty,
          reason:
              'play($id) is sound only, so with the sound switch off it '
              'must invoke nothing (no haptic stand-in); got $calls',
        );
      });

      test('both switches off: play($id) invokes nothing', () async {
        final calls = _recordCalls(null, _feedbackChannel);
        final service = PlatformFeedbackService(
          FeedbackSettings.forTest(haptics: false, sound: false),
          _feedbackChannel,
        );

        service.play(cue);
        await pumpEventQueue();

        expect(calls, isEmpty, reason: 'got $calls');
      });

      test('$id has its own id on the wire and is not the id of any '
          'other cue', () {
        expect(cue.id, id);
        expect(
          FeedbackCue.values.where((c) => c.id == id),
          hasLength(1),
          reason: 'exactly one cue may carry the id $id',
        );
      });
    }

    test('two play(dieLand) 10ms apart both invoke sound: not throttled', () {
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
        final service = PlatformFeedbackService(
          FeedbackSettings.forTest(),
          _feedbackChannel,
        );

        service.play(FeedbackCue.dieLand);
        async.elapse(const Duration(milliseconds: 10));
        service.play(FeedbackCue.dieLand);
        async.flushMicrotasks();

        expect(
          calls.map((c) => '${c.method}:${_idOf(c)}').toList(),
          equals(<String>['sound:die_land', 'sound:die_land']),
          reason:
              'two dieLand 10ms apart are two dice landing, so both must '
              'sound (step is the only throttled cue); got '
              '${calls.map((c) => '${c.method}:${_idOf(c)}').toList()}',
        );
      });
    });

    test('five play(dieLand) and five play(gloat) at the same instant all '
        'invoke sound', () {
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
        final service = PlatformFeedbackService(
          FeedbackSettings.forTest(),
          _feedbackChannel,
        );

        for (int i = 0; i < 5; i++) {
          service.play(FeedbackCue.dieLand);
          service.play(FeedbackCue.gloat);
        }
        async.flushMicrotasks();

        expect(calls.where((c) => _idOf(c) == 'die_land'), hasLength(5));
        expect(calls.where((c) => _idOf(c) == 'gloat'), hasLength(5));
        expect(
          calls.where((c) => c.method != 'sound'),
          isEmpty,
          reason: 'neither cue may reach haptic; got $calls',
        );
      });
    });
  });
}
