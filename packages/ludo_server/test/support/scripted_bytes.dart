// A `Random` source a dice-steering test can hand to `RoomRegistry` (via
// `ServerHarness.build`'s `secure` parameter, added additively in
// `wire_harness.dart` for order 052) so a room's whole draw sequence -- room
// code, seat tokens, the dice chain's server secret, `game_id`, and the
// engine's own opaque seed -- is fixed bytes chosen ahead of time by the
// test, rather than `Random.secure()`'s.
//
// docs/PROTOCOL.md section 11.1/11.2 and `lib/src/registry.dart` together
// establish the one and only order `RoomRegistry` draws from its injected
// `Random` for a two-seat room that reaches `start_game` with both seats
// already carrying a `client_seed` from their own `set_seed` (so the
// server-seeded-seat loop in `startGame`, `lib/src/registry.dart:437-445`,
// draws nothing at all):
//
//   RoomRegistry.createRoom (lib/src/registry.dart:313)
//     1. _generateUniqueCode()            -- roomCodeLength (6) draws,
//        (:330, :892)                        nextInt(roomCodeAlphabet.length)
//     2. generateSeatToken() [host seat]  -- 32 draws, nextInt(256)
//        (:335, seat_token.dart:16)
//     3. DiceChain.build(_drawBytes(32))  -- 32 draws, nextInt(256): the
//        (:343, :916)                        server secret, s[chainLength]
//   RoomRegistry.joinRoom [guest seat]
//     4. generateSeatToken()              -- 32 draws, nextInt(256)
//        (:382)
//   RoomRegistry.startGame, once every seat already holds a client_seed
//     5. room.gameId = _drawBytes(8)      -- 8 draws, nextInt(256)
//        (:447)
//     6. _secureSeed()                    -- 2 draws, nextInt(1 << 32)
//        (:459, :906-909)
//
// `RoomRegistry.roll` (docs/PROTOCOL.md section 12.1, lib/src/registry.dart
// `roll()`) never touches this `Random` again once a game has started:
// `reveal` comes from the `DiceChain` object built at step 3 and `value`
// from `package:fair_dice`'s `drawDie`, so nothing about any roll depends on
// this `Random` having anything left to give.
//
// If a future change to `registry.dart` adds, removes or reorders a draw
// anywhere in steps 1-6, the offsets below stop lining up with the secret.
// That is not silently wrong: `dice_steering_test.dart`'s own
// reveal-verification test checks every reveal it reads off the wire against
// the `chain_commit` the same room published, using `verifyReveal` from
// `package:fair_dice`, and its `game_started.game_id` check compares against
// the exact bytes this file put at [gameIdOffset]. Either one failing is the
// signal that this file's picture of the draw order no longer matches
// `registry.dart`, not a hand-tuned constant quietly producing the wrong
// answer.
//
// This lives only under `test/`. Nothing in `lib/` or `bin/` imports it,
// references it, or can be switched to it by any environment variable: the
// production server always builds its `RoomRegistry` with `Random.secure()`
// (`bin/server.dart`), unconditionally; this class exists so a *test* can
// stand in for that one constructor argument, which `RoomRegistry` has
// always accepted (`lib/src/registry.dart:284`, `required Random secure`).

import 'dart:math';

/// `nextInt(roomCodeAlphabet.length)` draws in step 1 above.
/// `docs/PROTOCOL.md` section 2 and `lib/src/room_code.dart` fix the room
/// code at 6 characters (`roomCodeLength`); duplicated here as a literal
/// rather than imported so this file has no dependency on `lib/` beyond the
/// one constructor argument it exists to supply.
const int roomCodeDraws = 6;

/// `nextInt(256)` draws for one seat token (`lib/src/seat_token.dart`,
/// `_seatTokenBytes`), steps 2 and 4 above.
const int seatTokenDraws = 32;

/// `nextInt(256)` draws for the chain's server secret
/// (`lib/src/registry.dart`'s `_serverSecretBytes`), step 3 above.
const int serverSecretDraws = 32;

/// `nextInt(256)` draws for `game_id` (`lib/src/registry.dart`'s
/// `_gameIdBytes`), step 5 above.
const int gameIdDraws = 8;

/// `nextInt(1 << 32)` draws for `_secureSeed`, step 6 above. Each one costs
/// 4 script bytes under [ScriptedBytesRandom.nextInt], not 1.
const int secureSeedDraws = 2;

/// The offset, in script bytes, of the first of [serverSecretDraws] bytes
/// that become the chain's server secret: step 3, after the room code (step
/// 1) and the host's seat token (step 2) have already been drawn.
const int serverSecretOffset = roomCodeDraws + seatTokenDraws;

/// The offset, in script bytes, of the first of [gameIdDraws] bytes that
/// become `game_id`: step 5, after the room code, the host's seat token, the
/// server secret and the guest's seat token (steps 1-4) have all already
/// been drawn.
const int gameIdOffset =
    serverSecretOffset + serverSecretDraws + seatTokenDraws;

/// Total script bytes one full create + join + start sequence (steps 1-5
/// above) draws in `nextInt(256)`-or-smaller units.
const int _byteSizedDraws = gameIdOffset + gameIdDraws;

/// Bytes a script needs to cover steps 1-6 above once, with no fallback ever
/// required: [_byteSizedDraws] one-byte draws plus [secureSeedDraws] draws
/// worth 4 bytes each (see [ScriptedBytesRandom.nextInt]).
final int fullScriptLength = _byteSizedDraws + secureSeedDraws * 4;

/// A `Random` whose `nextInt` calls are served from a fixed, caller-supplied
/// [script] of bytes rather than any entropy source: `nextInt(max)` for `max
/// <= 256` consumes exactly one script byte and returns `byte % max`; for
/// `max > 256` (only `1 << 32` appears anywhere in `lib/`, `_secureSeed`'s
/// two calls) it consumes four script bytes, most-significant first, and
/// returns their big-endian value modulo `max`.
///
/// Once [script] is exhausted, further draws come from [fallback] -- a
/// second, ordinary `Random`, `Random.secure()` unless the caller supplies
/// one -- so a scenario this class was not sized for still runs instead of
/// throwing. Nothing in this order's own tests ever reaches that fallback,
/// because every script they build with [buildScript] is exactly
/// [fullScriptLength] bytes long, sized for precisely the one create + join
/// + start sequence each test drives.
class ScriptedBytesRandom implements Random {
  ScriptedBytesRandom(List<int> script, {Random? fallback})
      : _script = List<int>.unmodifiable(script),
        _fallback = fallback ?? Random.secure() {
    for (final int byte in _script) {
      if (byte < 0 || byte > 0xff) {
        throw ArgumentError.value(
          byte,
          'script',
          'every script byte must be 0..255',
        );
      }
    }
  }

  final List<int> _script;
  final Random _fallback;
  int _cursor = 0;

  /// How many of [_script]'s bytes have been consumed so far. Exposed so a
  /// test that wants to prove its whole script was actually exercised (and
  /// not, say, silently short-circuited by an early error) can check this
  /// against the script's length after the fact.
  int get bytesConsumed => _cursor;

  int _nextByte() {
    if (_cursor < _script.length) {
      return _script[_cursor++];
    }
    return _fallback.nextInt(256);
  }

  @override
  int nextInt(int max) {
    if (max <= 0) {
      throw ArgumentError.value(max, 'max', 'must be positive');
    }
    if (max <= 256) {
      return _nextByte() % max;
    }
    int value = 0;
    for (int i = 0; i < 4; i++) {
      value = (value << 8) | _nextByte();
    }
    return value % max;
  }

  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);

  @override
  bool nextBool() => nextInt(2) == 1;
}

/// Builds one [fullScriptLength]-byte script for a full create + join +
/// start sequence (steps 1-6 of the header comment above), with [secret]
/// (exactly [serverSecretDraws] bytes) spliced in at [serverSecretOffset]
/// and every other byte deterministic filler, `i % 256` at script position
/// `i`. The filler is not chosen to look like anything in particular; it is
/// chosen only so the room code, seat tokens, `game_id` and engine seed this
/// script produces are fixed and repeatable within one test run. A test that
/// cares what `game_id` results should read the bytes at [gameIdOffset]
/// (`hexEncode(script.sublist(gameIdOffset, gameIdOffset + gameIdDraws))`
/// from `package:fair_dice`) before creating the room, so it can assert
/// `game_started.game_id` off the wire against a prediction, rather than
/// trusting this file's offsets blind.
List<int> buildScript({required List<int> secret}) {
  if (secret.length != serverSecretDraws) {
    throw ArgumentError.value(
      secret.length,
      'secret.length',
      'must be exactly $serverSecretDraws bytes',
    );
  }
  return List<int>.generate(fullScriptLength, (int i) {
    if (i >= serverSecretOffset && i < serverSecretOffset + serverSecretDraws) {
      return secret[i - serverSecretOffset];
    }
    return i % 256;
  });
}
