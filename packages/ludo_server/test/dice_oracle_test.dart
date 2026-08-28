// Order 060: proves the sliding-window search in `support/dice_oracle.dart`
// computes exactly what the slow, full-chain walk it replaces would have
// computed, that it is still deterministic across processes, and that its
// remaining slow path (a caller-supplied `nextCandidate`) and its failure
// modes (bad `count`, exhausted `maxCandidates`) still behave the way
// `findSecretForFaces`'s own doc comment promises.
//
// Written from `support/dice_oracle.dart`'s doc comments only. The
// sliding-window identity this file checks --
// `candidate i's reveal s[j] == T[chainLength - j + i]`,
// `candidate i's chain_commit == T[chainLength + i]` -- is stated there and
// is exactly what `fastRevealsAndCommitAt` is checked against
// `revealsFor`'s independent full-chain walk for, below.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fair_dice/fair_dice.dart'
    show chainCommit, defaultChainLength, hexEncode;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';

/// A handful of client seeds distinct enough that two different searches in
/// this file are never accidentally asking the same question.
const String _gameIdA = 'dice-oracle-test-game-a';
const String _clientSeedsA = '0:seed-a|2:seed-b';

void main() {
  group('fast path vs. the full-chain walk: same maths, cheaper to run', () {
    // Three candidate indices (an edge index, a small one and one well past
    // the window's own size) crossed with two face-sequence lengths, per
    // the order's acceptance criterion 2: "at least three different
    // candidate indices and at least two different face-sequence lengths".
    const List<int> indices = <int>[0, 1, 4000];
    const List<int> counts = <int>[2, 5];

    for (final int count in counts) {
      for (final int index in indices) {
        test(
            'index=$index, count=$count: fastRevealsAndCommitAt matches '
            'revealsFor + chainCommit computed from candidateSecretAt(index) '
            'directly', () {
          final List<int> secret = candidateSecretAt(index);
          final List<String> expectedReveals =
              revealsFor(secret, count: count);
          final String expectedCommit = chainCommit(secret);

          final ({List<String> reveals, String chainCommit}) fast =
              fastRevealsAndCommitAt(index, count: count);

          expect(
            fast.reveals,
            expectedReveals,
            reason: 'index=$index, count=$count: fast-path reveals '
                '${fast.reveals} did not match the full-chain walk\'s '
                '$expectedReveals for secret ${hexEncode(secret)}',
          );
          expect(
            fast.chainCommit,
            expectedCommit,
            reason: 'index=$index, count=$count: fast-path chain_commit '
                '${fast.chainCommit} did not match the full-chain walk\'s '
                '$expectedCommit for secret ${hexEncode(secret)}',
          );
        });
      }
    }

    test(
        'boundary: count == chainLength still agrees, with a chainLength '
        'small enough to run the full walk\'s O(chainLength) cost many '
        'times over in a unit test', () {
      const int smallChainLength = 12;
      const int count = smallChainLength;
      for (final int index in indices) {
        final List<int> secret = candidateSecretAt(index);
        final List<String> expectedReveals = revealsFor(
          secret,
          count: count,
          chainLength: smallChainLength,
        );
        final String expectedCommit =
            chainCommit(secret, chainLength: smallChainLength);

        final ({List<String> reveals, String chainCommit}) fast =
            fastRevealsAndCommitAt(
          index,
          count: count,
          chainLength: smallChainLength,
        );

        expect(
          fast.reveals,
          expectedReveals,
          reason: 'index=$index, count=chainLength=$smallChainLength: '
              'fast-path reveals ${fast.reveals} did not match the '
              'full-chain walk\'s $expectedReveals',
        );
        expect(
          fast.chainCommit,
          expectedCommit,
          reason: 'index=$index, count=chainLength=$smallChainLength: '
              'fast-path chain_commit ${fast.chainCommit} did not match the '
              'full-chain walk\'s $expectedCommit',
        );
      }
    });
  });

  group('findSecretForFaces itself, not just its building blocks', () {
    test(
        'a secret found by the default (fast) search reproduces the wanted '
        'faces through facesFor, and its reveals/chain_commit agree with '
        'the full-chain walk computed from the returned secret directly',
        () {
      const List<int> wanted = <int>[3, 1, 4];
      final SteeredSecret found = findSecretForFaces(
        wanted: wanted,
        gameId: _gameIdA,
        clientSeeds: _clientSeedsA,
      );

      expect(
        found.faces,
        wanted,
        reason: 'findSecretForFaces returned a secret whose own recorded '
            'faces ${found.faces} do not equal the wanted sequence $wanted',
      );
      expect(
        facesFor(
          found.secret,
          gameId: _gameIdA,
          clientSeeds: _clientSeedsA,
          count: wanted.length,
        ),
        wanted,
        reason: 'the returned secret ${hexEncode(found.secret)} does not '
            'itself produce $wanted through the independent facesFor/'
            'revealsFor full-chain path -- the fast path found a secret '
            'that does not actually work',
      );
      expect(
        found.chainCommit,
        chainCommit(found.secret),
        reason: 'the returned chain_commit ${found.chainCommit} does not '
            'match chainCommit(found.secret) computed independently from '
            'the returned secret',
      );
      expect(
        found.reveals,
        revealsFor(found.secret, count: wanted.length),
        reason: 'the returned reveals ${found.reveals} do not match '
            'revealsFor(found.secret) computed independently from the '
            'returned secret',
      );
    });

    test(
        'a caller-supplied nextCandidate still takes the general (slow) '
        'path and finds a secret that actually works, proving the fast '
        'path\'s identity check does not silently swallow a custom '
        'generator', () {
      // A trivial, deliberately non-T-chain generator: every candidate is
      // an independent hash of its index, exactly what candidateSecretAt
      // used to be before this order. The sliding-window trick would give
      // wrong answers if applied to this generator, so this test would
      // catch the fast path being applied where it must not be.
      List<int> independentCandidate(int index) => sha256
          .convert(
            utf8.encode('dice-oracle-test-independent-candidate|$index'),
          )
          .bytes;

      const List<int> wanted = <int>[2, 6];
      final SteeredSecret found = findSecretForFaces(
        wanted: wanted,
        gameId: _gameIdA,
        clientSeeds: _clientSeedsA,
        nextCandidate: independentCandidate,
        maxCandidates: 2000,
      );

      expect(
        found.faces,
        wanted,
        reason: 'custom nextCandidate: findSecretForFaces returned a '
            'secret whose own recorded faces ${found.faces} do not equal '
            'the wanted sequence $wanted',
      );
      expect(
        facesFor(
          found.secret,
          gameId: _gameIdA,
          clientSeeds: _clientSeedsA,
          count: wanted.length,
        ),
        wanted,
        reason: 'custom nextCandidate: the returned secret '
            '${hexEncode(found.secret)} does not itself produce $wanted '
            'through the independent facesFor path',
      );
    });

    test(
        'count == 0 (an empty wanted list) is rejected the same way '
        'revealsFor rejects it, through the default fast path', () {
      expect(
        () => findSecretForFaces(
          wanted: const <int>[],
          gameId: _gameIdA,
          clientSeeds: _clientSeedsA,
        ),
        throwsA(isA<RangeError>()),
        reason: 'wanted=[] should be rejected as an invalid count before '
            'any search runs, the same way revealsFor(secret, count: 0) '
            'rejects it',
      );
    });

    test(
        'count > chainLength is rejected the same way revealsFor rejects '
        'it, through the default fast path', () {
      expect(
        () => findSecretForFaces(
          wanted: List<int>.filled(defaultChainLength + 1, 1),
          gameId: _gameIdA,
          clientSeeds: _clientSeedsA,
        ),
        throwsA(isA<RangeError>()),
        reason: 'wanted longer than chainLength should be rejected as an '
            'invalid count before any search runs, the same way '
            'revealsFor(secret, count: chainLength + 1) rejects it',
      );
    });

    test(
        'exhaustion still reports maxCandidates, wanted, gameId and '
        'clientSeeds -- everything needed to reproduce the search -- and '
        'still names maxCandidates as the knob to turn', () {
      // maxCandidates: 1 means only candidate 0 is ever tried; candidate 0
      // producing exactly [1, 1, 1, 1, 1, 1, 1, 1] (an 8-face run of all
      // ones) is a 6^-8 event, not one this test should ever actually hit.
      const List<int> wanted = <int>[1, 1, 1, 1, 1, 1, 1, 1];
      expect(
        () => findSecretForFaces(
          wanted: wanted,
          gameId: _gameIdA,
          clientSeeds: _clientSeedsA,
          maxCandidates: 1,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(
              contains('1 candidates'),
              contains('$wanted'),
              contains('game_id=$_gameIdA'),
              contains('client_seeds=$_clientSeedsA'),
              contains('maxCandidates'),
            ),
          ),
        ),
        reason: 'exhausting maxCandidates=1 for wanted=$wanted should throw '
            'a StateError naming the candidate count, wanted faces, '
            'game_id, client_seeds and maxCandidates itself, so a failure '
            'here is reproducible without rereading this file',
      );
    });
  });

  group('determinism', () {
    const List<int> wanted = <int>[5, 5, 2];

    test(
        'the same call, run twice in this process, returns the same '
        'secret, faces, reveals and chain_commit', () {
      final SteeredSecret first = findSecretForFaces(
        wanted: wanted,
        gameId: _gameIdA,
        clientSeeds: _clientSeedsA,
      );
      final SteeredSecret second = findSecretForFaces(
        wanted: wanted,
        gameId: _gameIdA,
        clientSeeds: _clientSeedsA,
      );

      expect(
        hexEncode(second.secret),
        hexEncode(first.secret),
        reason: 'the same wanted=$wanted, game_id=$_gameIdA, '
            'client_seeds=$_clientSeedsA found secret '
            '${hexEncode(first.secret)} on the first call and '
            '${hexEncode(second.secret)} on the second -- the search is '
            'supposed to be a pure function of its arguments',
      );
      expect(second.faces, first.faces);
      expect(second.reveals, first.reveals);
      expect(second.chainCommit, first.chainCommit);
    });

    test(
        'a fresh process, given the same arguments, finds the same secret '
        '-- not just the same process running the search twice', () async {
      final Uri? packageConfig = await Isolate.packageConfig;
      if (packageConfig == null) {
        fail(
          'Isolate.packageConfig was null; cannot locate this workspace\'s '
          'package_config.json to resolve imports for the subprocess this '
          'test spawns',
        );
      }
      final Uri oracleUri = Directory.current.uri.resolve(
        'test/support/dice_oracle.dart',
      );
      if (!File.fromUri(oracleUri).existsSync()) {
        fail(
          'expected test/support/dice_oracle.dart to exist relative to the '
          'current working directory (${Directory.current.path}); this '
          'test must be run from packages/ludo_server, the same as every '
          'other command in this suite',
        );
      }

      final Directory scratch =
          await Directory.systemTemp.createTemp('dice_oracle_fresh_process');
      addTearDown(() => scratch.delete(recursive: true));
      final File script = File('${scratch.path}/find_secret.dart');
      await script.writeAsString('''
import 'dart:convert';
import 'dart:io';
import '${oracleUri.toString()}';

void main() {
  final SteeredSecret steered = findSecretForFaces(
    wanted: $wanted,
    gameId: '$_gameIdA',
    clientSeeds: '$_clientSeedsA',
  );
  stdout.write(jsonEncode(<String, Object?>{
    'secret': steered.secret,
    'faces': steered.faces,
    'reveals': steered.reveals,
    'chainCommit': steered.chainCommit,
  }));
}
''');

      final ProcessResult result = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          '--packages=${packageConfig.toFilePath()}',
          script.path,
        ],
      );
      expect(
        result.exitCode,
        0,
        reason: 'the fresh-process search exited ${result.exitCode}; '
            'stdout: ${result.stdout}; stderr: ${result.stderr}',
      );

      final Map<String, Object?> decoded =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      final List<int> freshSecret = (decoded['secret']! as List<Object?>)
          .cast<int>();

      final SteeredSecret inProcess = findSecretForFaces(
        wanted: wanted,
        gameId: _gameIdA,
        clientSeeds: _clientSeedsA,
      );

      expect(
        hexEncode(freshSecret),
        hexEncode(inProcess.secret),
        reason: 'a fresh dart process searching for wanted=$wanted, '
            'game_id=$_gameIdA, client_seeds=$_clientSeedsA found secret '
            '${hexEncode(freshSecret)}, but this process found '
            '${hexEncode(inProcess.secret)} for the same arguments; '
            'stdout was: ${result.stdout}',
      );
      expect(decoded['faces'], inProcess.faces);
      expect(decoded['reveals'], inProcess.reveals);
      expect(decoded['chainCommit'], inProcess.chainCommit);
    });
  });
}
