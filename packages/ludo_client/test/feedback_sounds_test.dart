// Plain file checks against C-225-feedback.md's "Sounds" and "Android side"
// sections and C-468's D2 and D3, run from the package root: no Flutter
// widget tree, no platform channel, just the files a correct implementation
// must have committed under android/ and tool/.
//
// The WAV header is parsed by hand, byte by byte, rather than trusted from
// a library or from the file extension: a file named fb_win.wav that is
// actually silence, stereo, 8-bit, or 22050Hz would still "exist" and
// still "look like a wav" to a directory listing. C-468 D3 adds
// measurements read from the samples themselves (loudness, peak ceiling, onset, the
// exact zero at the end and the tail), since a clip that is the right size but
// was never normalised, never trimmed or never faded out would pass every
// header check (order 469).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The eleven ids that get a clip (C-468 D2). invalid_tap and tap are
/// deliberately excluded: they have no clip.
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
  'die_land',
  'gloat',
];

/// C-468 D2's "max" column, the strict duration ceiling in seconds.
const Map<String, double> _maxSeconds = <String, double>{
  'your_turn': 0.80,
  'can_move': 0.80,
  'no_move': 1.00,
  'step': 0.16,
  'captured_other': 0.60,
  'captured_me': 0.70,
  'home': 0.60,
  'win': 1.50,
  'game_over': 1.20,
  'die_land': 0.80,
  'gloat': 1.00,
};

/// C-468 D3 step 4's loudness reference R in dBFS (amendment 3). Every clip's
/// loudness is R plus its D2 trim; a lower set-wide reference is this one line.
const double _loudnessReferenceDb = -19.0;

/// C-468 D2's "trim" column in dB, applied to the loudness
/// target (D3 step 4, amended in run 112).
const Map<String, double> _trimDb = <String, double>{
  'your_turn': -4,
  'can_move': 0,
  'no_move': 0,
  'step': -8,
  'captured_other': 0,
  'captured_me': -2,
  'home': 0,
  'win': 0,
  'game_over': -3,
  'die_land': -6,
  'gloat': -3,
};

/// C-468 D2's source file names per cue id, the part after the last slash.
const Map<String, List<String>> _sourceFiles = <String, List<String>>{
  'your_turn': <String>['dice-grab-1.ogg'],
  'can_move': <String>['die-throw-2.ogg'],
  'no_move': <String>['die-throw-4.ogg', 'impactSoft_heavy_000.ogg'],
  'step': <String>['impactWood_light_002.ogg'],
  'captured_other': <String>['impactWood_heavy_000.ogg'],
  'captured_me': <String>['impactPlank_medium_000.ogg'],
  'home': <String>['chips-stack-1.ogg'],
  'win': <String>['jingles_PIZZI02.ogg'],
  'game_over': <String>['jingles_PIZZI13.ogg'],
  'die_land': <String>['die-throw-1.ogg'],
  'gloat': <String>['jingles_SAX11.ogg'],
};

/// C-468 D1's pinned sha256 per pack and the pack names D3 puts above each
/// licence text.
const Map<String, String> _packSha256 = <String, String>{
  'Casino Audio':
      'f36250766ac5bc378c13708ddf12a23a8e54a3251f8d482c7536e51b5dbafa18',
  'Impact Sounds':
      '029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8',
  'Music Jingles':
      'b729ba57959bd58793d2c5cafa348aaf2655d354f3da35ec4729e03ec77197b8',
};

const int _sampleRate = 44100;

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

/// The RIFF/WAVE fields C-225 and C-468 D3 pin: the two magic tags, the PCM
/// format code, channel count, sample rate, bit depth, the chunk list and
/// the decoded samples.
class _WavInfo {
  const _WavInfo({
    required this.fileLength,
    required this.riffTag,
    required this.riffSize,
    required this.waveTag,
    required this.chunkIds,
    required this.audioFormat,
    required this.numChannels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.byteRate,
    required this.dataBytes,
    required this.samples,
  });

  final int fileLength;
  final String riffTag;
  final int riffSize;
  final String waveTag;
  final List<String> chunkIds;
  final int audioFormat;
  final int numChannels;
  final int sampleRate;
  final int bitsPerSample;
  final int byteRate;
  final int dataBytes;

  /// The data chunk read as signed 16-bit little-endian samples.
  final List<int> samples;

  double get durationSeconds =>
      byteRate > 0 ? dataBytes / byteRate : double.infinity;

  int get peak {
    int best = 0;
    for (final int sample in samples) {
      final int magnitude = sample.abs();
      if (magnitude > best) {
        best = magnitude;
      }
    }
    return best;
  }

  @override
  String toString() =>
      '_WavInfo(riff: $riffTag, wave: $waveTag, chunks: $chunkIds, '
      'audioFormat: $audioFormat, channels: $numChannels, '
      'sampleRate: $sampleRate, bitsPerSample: $bitsPerSample, '
      'byteRate: $byteRate, dataBytes: $dataBytes, '
      'duration: ${durationSeconds}s)';
}

/// Walks RIFF chunks from byte 12 onward looking for `fmt ` and `data`,
/// honouring the RIFF rule that a chunk with an odd size is followed by
/// one pad byte. Never trusts a fixed 44-byte header offset.
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
  final riffSize = _u32le(bytes, 4);
  final waveTag = _ascii(bytes, 8, 4);

  int? audioFormat;
  int? numChannels;
  int? sampleRate;
  int? bitsPerSample;
  int? byteRate;
  int? dataBytes;
  int? dataStart;
  final chunkIds = <String>[];

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
    chunkIds.add(chunkId);

    if (chunkId == 'fmt ') {
      audioFormat = _u16le(bytes, bodyStart);
      numChannels = _u16le(bytes, bodyStart + 2);
      sampleRate = _u32le(bytes, bodyStart + 4);
      byteRate = _u32le(bytes, bodyStart + 8);
      bitsPerSample = _u16le(bytes, bodyStart + 14);
    } else if (chunkId == 'data') {
      dataBytes = chunkSize;
      dataStart = bodyStart;
    }

    final advance = chunkSize + (chunkSize.isOdd ? 1 : 0);
    offset = bodyStart + advance;
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

  final samples = <int>[];
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i + 1 < dataBytes!; i += 2) {
    samples.add(view.getInt16(dataStart! + i, Endian.little));
  }

  return _WavInfo(
    fileLength: bytes.length,
    riffTag: riffTag,
    riffSize: riffSize,
    waveTag: waveTag,
    chunkIds: chunkIds,
    audioFormat: audioFormat!,
    numChannels: numChannels!,
    sampleRate: sampleRate!,
    bitsPerSample: bitsPerSample!,
    byteRate: byteRate!,
    dataBytes: dataBytes,
    samples: samples,
  );
}

/// C-468 D3 step 4's loudness: the largest RMS over any 50 ms window
/// (2205 samples), windows stepped by 551 samples, a last partial window
/// ignored, in dBFS re 32768. Negative infinity when no full window exists
/// or every window is silent.
double _loudnessDbfs(List<int> samples) {
  const window = 2205;
  const hop = 551;
  double best = 0;
  for (var start = 0; start + window <= samples.length; start += hop) {
    double sum = 0;
    for (var i = start; i < start + window; i++) {
      final v = samples[i].toDouble();
      sum += v * v;
    }
    final meanSquare = sum / window;
    if (meanSquare > best) {
      best = meanSquare;
    }
  }
  if (best == 0) {
    return double.negativeInfinity;
  }
  return 10 * math.log(best / (32768.0 * 32768.0)) / math.ln10;
}

/// Counts whole-word, case-sensitive occurrences of [needle] in [text]; a
/// word character here is a letter, digit or underscore, so `step` does not
/// match inside `steps` and `die_land` is one token.
int _tokenCount(String text, String needle) {
  final pattern = RegExp(
    '(?<![A-Za-z0-9_])${RegExp.escape(needle)}(?![A-Za-z0-9_])',
  );
  return pattern.allMatches(text).length;
}

String _readText(File file) {
  expect(file.existsSync(), isTrue, reason: 'expected ${file.path} to exist');
  return file.readAsStringSync();
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

  test('res/raw holds exactly fb_<id>.wav for the eleven ids other than '
      'invalid_tap and tap, and no fb_invalid_tap.wav (C-468 D2)', () {
    expect(
      rawDir.existsSync(),
      isTrue,
      reason:
          'expected ${rawDir.path} to exist, holding the eleven fb_<id>.wav '
          'clips C-468 D2 requires',
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

    for (final silent in <String>['invalid_tap', 'tap']) {
      expect(
        actualNames.contains('fb_$silent.wav'),
        isFalse,
        reason:
            '$silent has no clip (C-468 D2: "invalid_tap and tap stay '
            'without a clip"); fb_$silent.wav must not exist in '
            '${rawDir.path}',
      );
    }
  });

  for (final id in _soundIds) {
    test('fb_$id.wav is a valid mono 16-bit 44100Hz RIFF/WAVE clip with no '
        'extra chunks, under its D2 duration ceiling', () {
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
        _sampleRate,
        reason:
            '${file.path}: expected a 44100 Hz sample rate, got '
            '${info.sampleRate}; info=$info',
      );
      expect(
        info.chunkIds,
        equals(<String>['fmt ', 'data']),
        reason:
            '${file.path}: C-468 D3 step 5 writes "no extra chunks", so '
            'exactly fmt and data in that order; got ${info.chunkIds}',
      );
      expect(
        info.riffSize,
        info.fileLength - 8,
        reason:
            '${file.path}: the RIFF size field must be the file length '
            'minus 8 (${info.fileLength - 8}), got ${info.riffSize}',
      );

      final limit = _maxSeconds[id]!;
      final maxSamples = (limit * _sampleRate).round();
      expect(
        info.samples.length,
        lessThanOrEqualTo(maxSamples),
        reason:
            '${file.path}: C-468 D2 caps "$id" at ${limit}s '
            '($maxSamples samples), got ${info.samples.length} samples '
            '(${info.durationSeconds}s); info=$info',
      );
      expect(
        info.samples,
        isNotEmpty,
        reason: '${file.path}: a clip with no samples is silence; info=$info',
      );
    });

    test('fb_$id.wav measures as C-468 D3 says: loudness at the reference plus '
        'its trim, peak ceiling, onset inside 15 ms, a zero last sample and a quiet last 2 ms', () {
      final file = File(p.join(rawDir.path, 'fb_$id.wav'));
      expect(
        file.existsSync(),
        isTrue,
        reason: 'expected ${file.path} to exist',
      );
      final info = _parseWav(file);
      final samples = info.samples;
      expect(samples, isNotEmpty, reason: '${file.path} holds no samples');

      // D3 step 4 (amended run 112): loudness is normalised, not peak. The
      // largest 50 ms RMS sits at the reference plus the D2 trim.
      final peak = info.peak;
      final wantedDb = _loudnessReferenceDb + _trimDb[id]!;
      final gotDb = _loudnessDbfs(samples);
      expect(
        (gotDb - wantedDb).abs(),
        lessThanOrEqualTo(0.5),
        reason:
            '${file.path}: loudness (largest RMS over any 50 ms window, '
            '2205 samples stepped by 551) is ${gotDb.toStringAsFixed(2)} '
            'dBFS; D3 wants $_loudnessReferenceDb dBFS plus the ${_trimDb[id]} dB trim = '
            '$wantedDb dBFS within 0.5 dB (peak is $peak)',
      );
      // The limiter keeps every sample at or under -1.0 dBFS.
      expect(
        peak,
        lessThanOrEqualTo(29204),
        reason:
            '${file.path}: peak is $peak; D3 step 4 allows no sample above '
            '-1.0 dBFS (|s| <= 29204)',
      );

      // D3 step 3: leading silence is stripped, keeping 2 ms before the
      // first sample at -40 dBFS, so that sample sits well inside 15 ms.
      final floor = 32768 * math.pow(10, -40 / 20);
      final firstLoud = samples.indexWhere((s) => s.abs() >= floor);
      final onsetLimit = (0.015 * _sampleRate).round();
      expect(
        firstLoud,
        allOf(greaterThanOrEqualTo(0), lessThan(onsetLimit)),
        reason:
            '${file.path}: first sample at or above -40 dBFS '
            '(|s| >= ${floor.toStringAsFixed(1)}) is at index $firstLoud '
            '(${firstLoud / _sampleRate * 1000} ms); D3 step 3 puts it '
            'within the first 15 ms ($onsetLimit samples), -1 means none',
      );

      // D3 step 4: every clip ends with a fade to exact zero.
      expect(
        samples.last,
        0,
        reason:
            '${file.path}: the final sample must be exactly 0 (D3 step 4 '
            'linear fade to zero), got ${samples.last}',
      );
      final tail = (0.002 * _sampleRate).round();
      final ceiling = 0.2 * peak;
      final tailStart = math.max(0, samples.length - tail);
      var loudest = 0;
      var loudestAt = tailStart;
      for (var i = tailStart; i < samples.length; i++) {
        if (samples[i].abs() > loudest) {
          loudest = samples[i].abs();
          loudestAt = i;
        }
      }
      expect(
        loudest,
        lessThanOrEqualTo(ceiling),
        reason:
            '${file.path}: the last 2 ms (samples $tailStart..'
            '${samples.length - 1}) must stay at or under 0.2 x peak '
            '($ceiling); sample $loudestAt is $loudest of ${samples.length} '
            'samples, so the fade-out is missing or too short',
      );
    });
  }

  test('tool/sounds/SOURCES.md exists and names every one of the eleven '
      'ids', () {
    final file = File(p.join(packageRoot.path, 'tool', 'sounds', 'SOURCES.md'));
    final text = _readText(file);
    for (final id in _soundIds) {
      expect(
        _tokenCount(text, id),
        greaterThanOrEqualTo(1),
        reason: '${file.path} must list the cue id "$id" (C-468 D3)',
      );
    }
  });

  test('tool/sounds/SOURCES.md names the source file of every id and the '
      'CC0 1.0 licence URL', () {
    final file = File(p.join(packageRoot.path, 'tool', 'sounds', 'SOURCES.md'));
    final text = _readText(file);
    for (final entry in _sourceFiles.entries) {
      for (final name in entry.value) {
        expect(
          text.contains(name),
          isTrue,
          reason:
              '${file.path} must name the zip file $name that "${entry.key}" '
              'is cut from (C-468 D2 and D3)',
        );
      }
    }
    expect(
      text.contains('https://creativecommons.org/publicdomain/zero/1.0/'),
      isTrue,
      reason:
          '${file.path} must carry the CC0 1.0 URL '
          'https://creativecommons.org/publicdomain/zero/1.0/ (C-468 D3)',
    );
  });

  test('tool/sounds/LICENSE-kenney.txt exists, says CC0 at least three '
      'times and names each of the three packs', () {
    final file = File(
      p.join(packageRoot.path, 'tool', 'sounds', 'LICENSE-kenney.txt'),
    );
    final text = _readText(file);
    final mentions =
        RegExp('CC0').allMatches(text).length +
        RegExp('Creative Commons Zero').allMatches(text).length;
    expect(
      mentions,
      greaterThanOrEqualTo(3),
      reason:
          '${file.path} holds the verbatim License.txt of three packs, each '
          'CC0; found $mentions mentions of CC0 or "Creative Commons Zero", '
          'wanted at least 3',
    );
    for (final pack in _packSha256.keys) {
      expect(
        text.toLowerCase().contains(pack.toLowerCase()),
        isTrue,
        reason:
            '${file.path} must put a line naming "$pack" above its '
            'licence text (C-468 D3)',
      );
    }
  });

  test('tool/gen_feedback_sounds.py is gone and '
      'tool/build_feedback_sounds.py exists (C-468 D3)', () {
    final gen = File(
      p.join(packageRoot.path, 'tool', 'gen_feedback_sounds.py'),
    );
    final build = File(
      p.join(packageRoot.path, 'tool', 'build_feedback_sounds.py'),
    );
    expect(
      gen.existsSync(),
      isFalse,
      reason:
          '${gen.path} was replaced by the build script and must be deleted',
    );
    expect(
      build.existsSync(),
      isTrue,
      reason: 'expected ${build.path} to exist',
    );
  });

  test('the build script pins the three pack hashes (C-468 D1)', () {
    final build = File(
      p.join(packageRoot.path, 'tool', 'build_feedback_sounds.py'),
    );
    final text = _readText(build);
    for (final entry in _packSha256.entries) {
      expect(
        text.contains(entry.value),
        isTrue,
        reason:
            '${build.path} must pin the sha256 of the ${entry.key} archive '
            '(${entry.value}); a download with no pinned hash is unchecked',
      );
    }
  });

  test('no downloaded archive or source ogg is committed under tool/ or '
      'android/ (C-468 D1: downloaded by the script, never committed)', () {
    final offenders = <String>[];
    for (final dirName in <String>['tool', 'android']) {
      final dir = Directory(p.join(packageRoot.path, dirName));
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (lower.endsWith('.zip') || lower.endsWith('.ogg')) {
          offenders.add(entity.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'archives and source clips must not be committed: $offenders',
    );
  });

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
