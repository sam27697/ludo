// Plain file checks against C-225-feedback.md's "Sounds" and "Android side"
// sections, run from the package root: no Flutter widget tree, no platform
// channel, just the files a correct order-225 implementation must have
// committed under android/. Written against a checkout where none of
// android/app/src/main/res/raw/, tool/gen_feedback_sounds.py, or the
// VIBRATE permission line exist yet.
//
// The WAV header is parsed by hand, byte by byte, rather than trusted from
// a library or from the file extension: a file named fb_win.wav that is
// actually silence, stereo, 8-bit, or 22050Hz would still "exist" and
// still "look like a wav" to a directory listing, and the doctrine's
// promise ("a player who looks away must still know what happened from
// the vibration alone", with sound as the paired channel) depends on
// these clips actually being what C-225 says: mono, 16-bit, 44100Hz, and
// short.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The nine ids that get a generated clip. invalid_tap is deliberately
/// excluded (C-225's doctrine table: "none").
const List<String> _soundIds = <String>[
  'your_turn',
  'can_move',
  'no_move',
  'step',
  'captured_other',
  'captured_me',
  'home',
  'win',
  'game_over',
];

/// Strict duration ceilings in seconds, from C-225's "Sounds" section:
/// "Each under 1.5 s (win) and under 0.3 s for the rest except home and
/// game_over (under 0.6 s)".
const Map<String, double> _durationLimitOverridesSeconds = <String, double>{
  'win': 1.5,
  'home': 0.6,
  'game_over': 0.6,
};

double _durationLimitSeconds(String id) =>
    _durationLimitOverridesSeconds[id] ?? 0.3;

/// Finds this package's own root directory regardless of where `flutter
/// test` was invoked from: directly inside packages/ludo_client (the
/// normal case) or from the repository root with `packages/ludo_client`
/// given as the test target. Mirrors no_hardcoded_strings_test.dart's
/// helper of the same purpose.
Directory _findPackageRoot() {
  bool isLudoClient(Directory dir) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec
            .readAsStringSync()
            .split('\n')
            .any((line) => line.trim() == 'name: ludo_client');
  }

  final cwd = Directory.current;
  if (isLudoClient(cwd)) {
    return cwd;
  }

  final nested = Directory(p.join(cwd.path, 'packages', 'ludo_client'));
  if (isLudoClient(nested)) {
    return nested;
  }

  var walker = cwd;
  for (var i = 0; i < 8; i++) {
    final parent = walker.parent;
    if (parent.path == walker.path) break;
    if (isLudoClient(parent)) {
      return parent;
    }
    walker = parent;
  }

  fail('could not locate the ludo_client package root from cwd ${cwd.path}');
}

String _ascii(Uint8List bytes, int start, int length) =>
    String.fromCharCodes(bytes.sublist(start, start + length));

int _u16le(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// The handful of RIFF/WAVE fields C-225 pins: the two magic tags, the PCM
/// format code, channel count, sample rate, bit depth, and enough of the
/// data chunk to compute a duration.
class _WavInfo {
  const _WavInfo({
    required this.riffTag,
    required this.waveTag,
    required this.audioFormat,
    required this.numChannels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.byteRate,
    required this.dataBytes,
  });

  final String riffTag;
  final String waveTag;
  final int audioFormat;
  final int numChannels;
  final int sampleRate;
  final int bitsPerSample;
  final int byteRate;
  final int dataBytes;

  double get durationSeconds =>
      byteRate > 0 ? dataBytes / byteRate : double.infinity;

  @override
  String toString() =>
      '_WavInfo(riff: $riffTag, wave: $waveTag, audioFormat: $audioFormat, '
      'channels: $numChannels, sampleRate: $sampleRate, '
      'bitsPerSample: $bitsPerSample, byteRate: $byteRate, '
      'dataBytes: $dataBytes, duration: ${durationSeconds}s)';
}

/// Walks RIFF chunks from byte 12 onward looking for `fmt ` and `data`,
/// honouring the RIFF rule that a chunk with an odd size is followed by
/// one pad byte. Never trusts a fixed 44-byte header offset: a real
/// encoder is free to place extra chunks (e.g. `LIST`) before `data`.
_WavInfo _parseWav(File file) {
  final bytes = file.readAsBytesSync();
  expect(
    bytes.length,
    greaterThanOrEqualTo(44),
    reason:
        '${file.path} is only ${bytes.length} bytes, too small to hold a '
        'minimal RIFF/WAVE header',
  );

  final riffTag = _ascii(bytes, 0, 4);
  final waveTag = _ascii(bytes, 8, 4);

  int? audioFormat;
  int? numChannels;
  int? sampleRate;
  int? bitsPerSample;
  int? byteRate;
  int? dataBytes;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = _ascii(bytes, offset, 4);
    final chunkSize = _u32le(bytes, offset + 4);
    final bodyStart = offset + 8;
    expect(
      bodyStart + chunkSize,
      lessThanOrEqualTo(bytes.length),
      reason:
          '${file.path}: chunk "$chunkId" claims $chunkSize bytes starting '
          'at $bodyStart, past the end of a ${bytes.length}-byte file',
    );

    if (chunkId == 'fmt ') {
      audioFormat = _u16le(bytes, bodyStart);
      numChannels = _u16le(bytes, bodyStart + 2);
      sampleRate = _u32le(bytes, bodyStart + 4);
      byteRate = _u32le(bytes, bodyStart + 8);
      bitsPerSample = _u16le(bytes, bodyStart + 14);
    } else if (chunkId == 'data') {
      dataBytes = chunkSize;
    }

    final advance = chunkSize + (chunkSize.isOdd ? 1 : 0);
    offset = bodyStart + advance;
    if (dataBytes != null) {
      break;
    }
  }

  expect(
    audioFormat,
    isNotNull,
    reason: '${file.path}: no "fmt " chunk found while walking RIFF chunks',
  );
  expect(
    dataBytes,
    isNotNull,
    reason: '${file.path}: no "data" chunk found while walking RIFF chunks',
  );

  return _WavInfo(
    riffTag: riffTag,
    waveTag: waveTag,
    audioFormat: audioFormat!,
    numChannels: numChannels!,
    sampleRate: sampleRate!,
    bitsPerSample: bitsPerSample!,
    byteRate: byteRate!,
    dataBytes: dataBytes!,
  );
}

void main() {
  late Directory packageRoot;
  late Directory rawDir;

  setUpAll(() {
    packageRoot = _findPackageRoot();
    rawDir = Directory(
      p.join(packageRoot.path, 'android', 'app', 'src', 'main', 'res', 'raw'),
    );
  });

  test('res/raw holds exactly fb_<id>.wav for the nine ids other than '
      'invalid_tap, and no fb_invalid_tap.wav', () {
    expect(
      rawDir.existsSync(),
      isTrue,
      reason:
          'expected ${rawDir.path} to exist, holding the nine fb_<id>.wav '
          'clips C-225\'s "Sounds" section requires',
    );

    final actualNames = rawDir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toSet();
    final expectedNames = _soundIds.map((id) => 'fb_$id.wav').toSet();

    expect(
      actualNames,
      equals(expectedNames),
      reason:
          'expected exactly ${(expectedNames.toList()..sort())} in '
          '${rawDir.path}, got ${(actualNames.toList()..sort())}',
    );

    expect(
      actualNames.contains('fb_invalid_tap.wav'),
      isFalse,
      reason:
          'invalid_tap has no sound (C-225\'s doctrine table: "none"); '
          'fb_invalid_tap.wav must not exist in ${rawDir.path}',
    );
  });

  for (final id in _soundIds) {
    test('fb_$id.wav is a valid mono 16-bit 44100Hz RIFF/WAVE clip under its '
        'duration limit', () {
      final file = File(p.join(rawDir.path, 'fb_$id.wav'));
      expect(
        file.existsSync(),
        isTrue,
        reason: 'expected ${file.path} to exist',
      );

      final info = _parseWav(file);

      expect(
        info.riffTag,
        'RIFF',
        reason:
            '${file.path}: expected the RIFF magic tag, got '
            '"${info.riffTag}"',
      );
      expect(
        info.waveTag,
        'WAVE',
        reason:
            '${file.path}: expected the WAVE format tag, got '
            '"${info.waveTag}"',
      );
      expect(
        info.audioFormat,
        1,
        reason:
            '${file.path}: expected PCM (audioFormat 1), got '
            '${info.audioFormat}; info=$info',
      );
      expect(
        info.numChannels,
        1,
        reason:
            '${file.path}: expected mono (1 channel), got '
            '${info.numChannels}; info=$info',
      );
      expect(
        info.bitsPerSample,
        16,
        reason:
            '${file.path}: expected 16-bit samples, got '
            '${info.bitsPerSample}; info=$info',
      );
      expect(
        info.sampleRate,
        44100,
        reason:
            '${file.path}: expected a 44100 Hz sample rate, got '
            '${info.sampleRate}; info=$info',
      );

      final limit = _durationLimitSeconds(id);
      expect(
        info.durationSeconds,
        lessThan(limit),
        reason:
            '${file.path}: C-225 requires "$id" to run under ${limit}s, '
            'got ${info.durationSeconds}s; info=$info',
      );
    });
  }

  test('AndroidManifest.xml declares android.permission.VIBRATE', () {
    final manifest = File(
      p.join(
        packageRoot.path,
        'android',
        'app',
        'src',
        'main',
        'AndroidManifest.xml',
      ),
    );
    expect(
      manifest.existsSync(),
      isTrue,
      reason: 'expected ${manifest.path} to exist',
    );

    final text = manifest.readAsStringSync();
    expect(
      text.contains('android.permission.VIBRATE'),
      isTrue,
      reason:
          '${manifest.path} must declare '
          '<uses-permission android:name="android.permission.VIBRATE"/>, '
          'per C-225\'s "Android side" section; contents were:\n$text',
    );
  });
}
