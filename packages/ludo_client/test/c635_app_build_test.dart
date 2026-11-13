// Proof for contract C-635 (work/ludo/orders/634-update-required.md, order
// 635t), docs/PROTOCOL.md section 27 rule 1: the app reads its own build
// through the platform channel `app.fayad.ludo/app`, method `build`, and a
// build it cannot read, or reads below 1, is "unknown" (null), which is what
// makes the transport omit the header.
//
//   readAppBuild()  an int >= 1 -> that int
//                   anything else, a PlatformException, a
//                   MissingPluginException -> null, never a throw
//
// The channel is mocked through the test binding's messenger, the way the
// platform side would answer; nothing here touches the real engine.
//
// `package:ludo_client/src/app_build.dart` does not exist on the tree this was
// written for, so this file does not compile there, by design.
//
// Cases:
//   B1      the channel is named `app.fayad.ludo/app` and the call is `build`
//   B2.*    an int >= 1 comes back as it is (561, the boundary 1, a large one)
//   B3.*    0, negatives, a string, a double, a bool, null, a list and a map
//           are all null
//   B4.*    a PlatformException and a MissingPluginException from the handler
//           and no handler at all are null
//   B5      the method is called once per read, with no other method used
//
// There is no random input. Each failure reason names the case, what was
// expected, what the channel returned, and ends with the command that replays
// that one case:
//   flutter test test/c635_app_build_test.dart --plain-name '<id>'

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/app_build.dart';

const String _channelName = 'app.fayad.ludo/app';
const MethodChannel _channel = MethodChannel(_channelName);

String _reproduce(String id) =>
    'reproduce: flutter test test/c635_app_build_test.dart '
    '--plain-name "$id"';

void _mock(Future<Object?>? Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => _mock(null));

  test(
    'B1: the channel is app.fayad.ludo/app and the method is build',
    () async {
      const String id = 'B1';
      expect(
        appBuildChannel.name,
        _channelName,
        reason:
            '$id: expected appBuildChannel to be named "$_channelName"; saw '
            '"${appBuildChannel.name}". ${_reproduce(id)}',
      );
      final List<String> methods = <String>[];
      _mock((MethodCall call) async {
        methods.add(call.method);
        return 561;
      });
      final int? build = await readAppBuild();
      expect(
        methods,
        <String>['build'],
        reason:
            '$id: expected exactly one call to the method "build"; the '
            'channel saw $methods. ${_reproduce(id)}',
      );
      expect(
        build,
        561,
        reason: '$id: expected 561; saw $build. ${_reproduce(id)}',
      );
    },
  );

  for (final ({String name, int value}) row in <({String name, int value})>[
    (name: 'the build the contract names', value: 561),
    (name: 'the boundary, 1', value: 1),
    (name: 'a two digit build', value: 42),
    (name: 'the largest 32 bit versionCode', value: 2147483647),
  ]) {
    test(
      'B2: an int of ${row.value} (${row.name}) comes back as it is',
      () async {
        final String id = 'B2 ${row.value}';
        _mock((MethodCall call) async => row.value);
        final int? build = await readAppBuild();
        expect(
          build,
          row.value,
          reason: '$id: expected ${row.value}; saw $build. ${_reproduce(id)}',
        );
      },
    );
  }

  for (final ({String name, Object? value}) row
      in <({String name, Object? value})>[
        (name: 'zero', value: 0),
        (name: 'minus one', value: -1),
        (name: 'a large negative', value: -2147483648),
        (name: 'the string "561"', value: '561'),
        (name: 'an empty string', value: ''),
        (name: 'the double 561.0', value: 561.0),
        (name: 'the double 0.5', value: 0.5),
        (name: 'true', value: true),
        (name: 'null', value: null),
        (name: 'a list holding 561', value: <int>[561]),
        (name: 'a map holding 561', value: <String, int>{'build': 561}),
      ]) {
    test('B3: ${row.name} is null', () async {
      final String id = 'B3 ${row.name}';
      _mock((MethodCall call) async => row.value);
      final int? build = await readAppBuild();
      expect(
        build,
        isNull,
        reason:
            '$id: expected null for a reply of ${row.value.runtimeType} '
            '${row.value}; saw $build. ${_reproduce(id)}',
      );
    });
  }

  test(
    'B4: a PlatformException from the platform side is null, not a throw',
    () async {
      const String id = 'B4 platform exception';
      _mock((MethodCall call) async {
        throw PlatformException(
          code: 'unavailable',
          message: 'no package info',
        );
      });
      final int? build = await readAppBuild();
      expect(
        build,
        isNull,
        reason: '$id: expected null; saw $build. ${_reproduce(id)}',
      );
    },
  );

  test('B4: a MissingPluginException raised by the handler is null', () async {
    const String id = 'B4 missing plugin raised';
    _mock((MethodCall call) async {
      throw MissingPluginException('no implementation');
    });
    final int? build = await readAppBuild();
    expect(
      build,
      isNull,
      reason: '$id: expected null; saw $build. ${_reproduce(id)}',
    );
  });

  test('B4: no handler on the channel at all (a platform with no '
      'MainActivity channel) is null', () async {
    const String id = 'B4 no handler';
    _mock(null);
    final int? build = await readAppBuild();
    expect(
      build,
      isNull,
      reason: '$id: expected null; saw $build. ${_reproduce(id)}',
    );
  });

  test('B4: a handler that fails with a plain exception is null', () async {
    const String id = 'B4 plain exception';
    _mock((MethodCall call) async {
      throw StateError('the platform side broke');
    });
    final int? build = await readAppBuild();
    expect(
      build,
      isNull,
      reason: '$id: expected null; saw $build. ${_reproduce(id)}',
    );
  });

  test('B5: two reads make two calls of build and nothing else, and a read '
      'after a failure still works', () async {
    const String id = 'B5';
    final List<String> methods = <String>[];
    bool fail = true;
    _mock((MethodCall call) async {
      methods.add(call.method);
      if (fail) {
        throw PlatformException(code: 'unavailable');
      }
      return 600;
    });
    final int? first = await readAppBuild();
    fail = false;
    final int? second = await readAppBuild();
    expect(
      first,
      isNull,
      reason:
          '$id: expected null on the failing read; saw $first. '
          '${_reproduce(id)}',
    );
    expect(
      second,
      600,
      reason:
          '$id: expected 600 once the platform side answers; saw $second. '
          '${_reproduce(id)}',
    );
    expect(
      methods,
      <String>['build', 'build'],
      reason:
          '$id: expected two calls of "build" and no other method; the '
          'channel saw $methods. ${_reproduce(id)}',
    );
  });
}
