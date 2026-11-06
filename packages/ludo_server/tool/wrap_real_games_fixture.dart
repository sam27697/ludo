// Order 576: wraps the recorded real-games fixture as Dart source, so the
// store-capture test can carry it to an Android emulator, which cannot read a
// host file path (and an asset would ship inside the app).
//
//   cd packages/ludo_server && dart run tool/wrap_real_games_fixture.dart
//       [--in PATH] [--out PATH]
//
// Reads `packages/ludo_client/integration_test/fixtures/real_games.json` and
// writes `packages/ludo_client/integration_test/fixtures/real_games_fixture.dart`:
// a header comment, then one `const String realGamesJson = r'''...''';` that
// holds the JSON bytes unchanged. Both paths default to places next to this
// file's own location, so the working directory does not matter.
//
// The JSON must not contain `'''` (the string would end early) or a carriage
// return (Dart reads a line terminator in a multi-line string as `\n`, so the
// text would no longer be the same bytes). Either one fails the run loudly;
// nothing is escaped. Exit codes: 0 written, 1 refused, 64 bad command line.
//
// packages/ludo_client/test/real_games_fixture_wrapper_test.dart goes red
// when real_games.json was re-recorded and this tool was not re-run.

import 'dart:convert';
import 'dart:io';

const String _command =
    'cd packages/ludo_server && dart run tool/wrap_real_games_fixture.dart';

void main(List<String> args) {
  exitCode = _run(args);
}

int _run(List<String> args) {
  final Directory toolDir = File.fromUri(Platform.script).parent;
  final Directory packagesDir = toolDir.parent.parent;
  final String fixtureDir =
      '${packagesDir.path}/ludo_client/integration_test/fixtures';
  var inPath = '$fixtureDir/real_games.json';
  var outPath = '$fixtureDir/real_games_fixture.dart';

  for (var i = 0; i < args.length; i++) {
    final String arg = args[i];
    if ((arg == '--in' || arg == '--out') && i + 1 < args.length) {
      i += 1;
      if (arg == '--in') {
        inPath = args[i];
      } else {
        outPath = args[i];
      }
    } else {
      stderr.writeln(
        'usage: dart run tool/wrap_real_games_fixture.dart '
        '[--in PATH] [--out PATH]; got "$arg"',
      );
      return 64;
    }
  }

  final File input = File(inPath);
  if (!input.existsSync()) {
    stderr.writeln('wrap_real_games_fixture: $inPath does not exist');
    return 1;
  }
  final String json = utf8.decode(input.readAsBytesSync());

  final int quotes = json.indexOf("'''");
  if (quotes >= 0) {
    stderr.writeln(
      "wrap_real_games_fixture: $inPath holds ''' at offset $quotes; a raw "
      'string cannot carry it and nothing is escaped. Refusing to write.',
    );
    return 1;
  }
  final int cr = json.indexOf('\r');
  if (cr >= 0) {
    stderr.writeln(
      'wrap_real_games_fixture: $inPath holds a carriage return at offset '
      '$cr; Dart would read it as a line feed and the wrapped text would '
      'differ from the file. Refusing to write.',
    );
    return 1;
  }
  if (json.startsWith('\n')) {
    stderr.writeln(
      'wrap_real_games_fixture: $inPath starts with a line feed, which Dart '
      'drops after an opening triple quote. Refusing to write.',
    );
    return 1;
  }
  // The text must be the JSON it claims to be before it is wrapped.
  try {
    jsonDecode(json);
  } on FormatException catch (e) {
    stderr.writeln('wrap_real_games_fixture: $inPath is not JSON: $e');
    return 1;
  }

  final StringBuffer out = StringBuffer()
    ..writeln('// GENERATED FILE. Do not edit by hand.')
    ..writeln('//')
    ..writeln('// Written by the wrapper; re-run:  $_command')
    ..writeln(
      '// Source:        packages/ludo_client/integration_test/'
      'fixtures/real_games.json',
    )
    ..writeln('//')
    ..writeln(
      '// The JSON below is that file, byte for byte. A re-record of '
      'the source that',
    )
    ..writeln(
      '// does not re-run the command above fails '
      'packages/ludo_client/test/',
    )
    ..writeln('// real_games_fixture_wrapper_test.dart.')
    ..writeln()
    ..write("const String realGamesJson = r'''")
    ..write(json)
    ..writeln("''';");

  File(outPath).writeAsBytesSync(utf8.encode(out.toString()));
  stdout.writeln(
    'wrap_real_games_fixture: wrote $outPath (${json.length} characters of '
    'JSON from $inPath)',
  );
  return 0;
}
