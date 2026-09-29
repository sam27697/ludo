// docs/VERIFY.md sections 6 and 7: the two checkers published at
// `/v/verify.js` and `/v/verify.py`, verbatim. Both are read by a stranger
// deciding whether to trust the game, so both stay short, plain, and
// commented where the maths is not obvious to somebody who has not read
// docs/FAIRNESS.md. Neither has a dependency: `verify.js` uses only
// `crypto.subtle` (and runs under a browser or under Node 20+ with
// `require`); `verify.py` uses only the standard library.
//
// These are raw strings, not templates: nothing in either script is filled
// in by this file at request time, which is exactly why `wire_server.dart`
// can serve them with a 300-second cache and never touch them per request.

/// The complete text of `/v/verify.js`.
const String verifyJsSource = r'''
// Offline verifier for a ludo (or backgammon) fairness record. Runs in a
// browser with WebCrypto, and under Node 20+ with `require`. No dependency
// beyond `crypto.subtle`.
//
// This is the same twenty lines of maths as packages/fair_dice, and the
// point of publishing it here is that nobody has to trust that package
// either: this file is short enough to read end to end and check by hand.

'use strict';

// 2^32 - (2^32 mod 6): the largest multiple of 6 that fits in 32 bits.
// Accepting only words below this threshold makes every accepted word
// equally likely to land in each of the six residue classes mod 6, so
// `u mod 6` carries no modulo bias. docs/FAIRNESS.md section 2.3.
const REJECTION_THRESHOLD = 4294967292;

function hexToBytes(hex) {
  if (hex.length % 2 !== 0) {
    throw new Error('odd-length hex string: ' + hex);
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

async function sha256(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return new Uint8Array(digest);
}

async function hmacSha256(keyBytes, messageBytes) {
  const key = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, messageBytes);
  return new Uint8Array(signature);
}

// face for roll k, die index d, exactly FAIRNESS.md section 2.3:
//   msg    = "<game_id>|<client_seeds>|<k>|<d>"
//   digest = HMAC-SHA256(key = s[k], message = UTF-8 bytes of msg)
// digest read as eight big-endian 32-bit words; the first word u with
// u < REJECTION_THRESHOLD gives the face (u mod 6) + 1. If every word of a
// round is rejected -- astronomically rare -- re-HMAC with msg + "|r1",
// then "|r2", and so on.
async function drawDie(revealHex, gameId, clientSeeds, k, d) {
  const key = hexToBytes(revealHex);
  const encoder = new TextEncoder();
  let round = 0;
  while (true) {
    const suffix = round === 0 ? '' : '|r' + round;
    const message = gameId + '|' + clientSeeds + '|' + k + '|' + d + suffix;
    const mac = await hmacSha256(key, encoder.encode(message));
    for (let word = 0; word < 8; word++) {
      const offset = word * 4;
      const u = ((mac[offset] << 24) |
        (mac[offset + 1] << 16) |
        (mac[offset + 2] << 8) |
        mac[offset + 3]) >>> 0;
      if (u < REJECTION_THRESHOLD) {
        return (u % 6) + 1;
      }
    }
    round++;
  }
}

// SHA-256(reveal) == parent, both lowercase hex. docs/FAIRNESS.md section
// 2.1: the whole reveal check is this, called once per roll, chained back
// to chain_commit for the first roll.
async function chainLinkOk(revealHex, parentHex) {
  const digest = await sha256(hexToBytes(revealHex));
  return bytesToHex(digest) === parentHex.toLowerCase();
}

// Every check of docs/VERIFY.md section 7, in the same order:
//   1. format == 1
//   2. client_seeds equals the seeds list joined as "seat:seed" with "|"
//   3. rolls[i].k == i + 1 for every i
//   4. chain: sha256(reveal_k) == previous
//   5. die: drawDie(reveal_k, ...) == die
//
// `error` is set only for a failure of checks 1 to 3, which make the record
// as a whole unreadable; a failure of check 4 or 5 for one particular roll
// is instead visible on that roll's own `chainOk`/`dieOk`, with `ok` false
// overall and `error` left null, since the record was perfectly readable,
// just wrong about one roll.
async function verifyRecord(record) {
  const rollsOut = [];

  if (record.format !== 1) {
    return { ok: false, error: 'format', rolls: rollsOut };
  }

  const seeds = record.seeds || [];
  const expectedClientSeeds = seeds
    .map(function (s) {
      return s.seat + ':' + s.seed;
    })
    .join('|');
  if (expectedClientSeeds !== record.client_seeds) {
    return { ok: false, error: 'client_seeds', rolls: rollsOut };
  }

  const rolls = record.rolls || [];
  for (let i = 0; i < rolls.length; i++) {
    if (rolls[i].k !== i + 1) {
      return { ok: false, error: 'roll_sequence', rolls: rollsOut };
    }
  }

  let previous = record.chain_commit;
  let ok = true;
  for (let i = 0; i < rolls.length; i++) {
    const roll = rolls[i];
    const chainOk = await chainLinkOk(roll.reveal, previous);
    const computedDie = await drawDie(
      roll.reveal,
      record.game_id,
      record.client_seeds,
      roll.k,
      0,
    );
    const dieOk = computedDie === roll.die;
    if (!chainOk || !dieOk) {
      ok = false;
    }
    rollsOut.push({ k: roll.k, chainOk: chainOk, dieOk: dieOk, computedDie: computedDie });
    previous = roll.reveal;
  }

  return { ok: ok, error: null, rolls: rollsOut };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { drawDie: drawDie, verifyRecord: verifyRecord };
} else {
  (function () {
    const el = document.getElementById('record');
    const record = JSON.parse(el.textContent);
    verifyRecord(record).then(function (result) {
      for (let i = 0; i < result.rolls.length; i++) {
        const row = result.rolls[i];
        const chainCell = document.getElementById('chain-' + row.k);
        const dieCell = document.getElementById('die-' + row.k);
        if (chainCell) {
          chainCell.textContent = row.chainOk ? 'checked: matches' : 'checked: does not match';
        }
        if (dieCell) {
          dieCell.textContent = row.dieOk ? 'checked: matches' : 'checked: does not match';
        }
      }
      const summary = document.getElementById('summary');
      if (summary) {
        summary.textContent = result.ok
          ? 'checked: all ' + result.rolls.length + ' rolls verified'
          : 'checked: failed (' + (result.error || 'a roll did not match') + ')';
      }
    });
  })();
}
''';

/// The complete text of `/v/verify.py`.
const String verifyPySource = r'''#!/usr/bin/env python3
"""Offline verifier for a ludo (or backgammon) fairness record.

Usage:
    python3 verify.py <game_id | https URL of a .json record | path to a .json file>

Standard library only. Reads docs/FAIRNESS.md sections 2.1 through 2.3 and
checks a record against them without trusting anything but the record
itself and the maths below.
"""

import hashlib
import hmac
import json
import sys
import urllib.request

# 2^32 - (2^32 mod 6): the largest multiple of 6 that fits in 32 bits.
# Accepting only words below this threshold makes every accepted word
# equally likely to land in each of the six residue classes mod 6, so
# "u mod 6" carries no modulo bias. docs/FAIRNESS.md section 2.3.
REJECTION_THRESHOLD = 4294967292


def draw_die(reveal_hex, game_id, client_seeds, k, d):
    """face for roll k, die index d, exactly FAIRNESS.md section 2.3:

        msg    = "<game_id>|<client_seeds>|<k>|<d>"
        digest = HMAC-SHA256(key = s[k], message = UTF-8 bytes of msg)

    digest read as eight big-endian 32-bit words; the first word u with
    u < REJECTION_THRESHOLD gives the face (u mod 6) + 1. If every word of
    a round is rejected -- astronomically rare -- re-HMAC with
    msg + "|r1", then "|r2", and so on.
    """
    key = bytes.fromhex(reveal_hex)
    round_ = 0
    while True:
        suffix = '' if round_ == 0 else '|r{}'.format(round_)
        message = '{}|{}|{}|{}{}'.format(game_id, client_seeds, k, d, suffix)
        mac = hmac.new(key, message.encode('utf-8'), hashlib.sha256).digest()
        for word in range(8):
            offset = word * 4
            u = int.from_bytes(mac[offset:offset + 4], 'big')
            if u < REJECTION_THRESHOLD:
                return (u % 6) + 1
        round_ += 1


def _chain_link_ok(reveal_hex, parent_hex):
    """SHA-256(reveal) == parent, both lowercase hex. docs/FAIRNESS.md
    section 2.1: the whole reveal check is this, called once per roll,
    chained back to chain_commit for the first roll."""
    digest = hashlib.sha256(bytes.fromhex(reveal_hex)).hexdigest()
    return digest == parent_hex.lower()


def verify_record(record):
    """Every check of docs/VERIFY.md section 7, in the same order:

        1. format == 1
        2. client_seeds equals the seeds list joined as "seat:seed" with "|"
        3. rolls[i].k == i + 1 for every i
        4. chain: sha256(reveal_k) == previous
        5. die: draw_die(reveal_k, ...) == die

    Returns (ok, lines): one line per roll when the record is readable
    (checks 1 to 3 passed), followed by one final PASS or FAIL line; a
    single FAIL line with no per-roll lines when the record itself is not
    readable.
    """
    if record.get('format') != 1:
        return False, ['FAIL: format is not 1']

    seeds = record.get('seeds', [])
    expected_client_seeds = '|'.join(
        '{}:{}'.format(seed['seat'], seed['seed']) for seed in seeds
    )
    if expected_client_seeds != record.get('client_seeds'):
        return False, ['FAIL: client_seeds does not match the seeds list']

    rolls = record.get('rolls', [])
    for i, roll in enumerate(rolls):
        if roll['k'] != i + 1:
            return False, ['FAIL: roll {} is out of sequence'.format(i)]

    game_id = record['game_id']
    client_seeds = record['client_seeds']
    previous = record['chain_commit']
    ok = True
    lines = []

    for roll in rolls:
        k = roll['k']
        chain_ok = _chain_link_ok(roll['reveal'], previous)
        computed_die = draw_die(roll['reveal'], game_id, client_seeds, k, 0)
        die_ok = computed_die == roll['die']
        if not chain_ok or not die_ok:
            ok = False
        lines.append(
            'k={} seat={} die={} chain={} die_check={}'.format(
                k,
                roll['seat'],
                roll['die'],
                'ok' if chain_ok else 'FAIL',
                'ok' if die_ok else 'FAIL',
            )
        )
        previous = roll['reveal']

    if ok:
        lines.append(
            'PASS: {} rolls verified against chain_commit {}'.format(
                len(rolls), record['chain_commit']
            )
        )
    else:
        lines.append('FAIL: one or more rolls did not verify')
    return ok, lines


def _looks_like_game_id(arg):
    if len(arg) != 16:
        return False
    return all(c in '0123456789abcdef' for c in arg)


def _load_record(arg):
    if _looks_like_game_id(arg):
        url = 'https://provefair.app/v/{}.json'.format(arg)
        with urllib.request.urlopen(url) as response:
            return json.load(response)
    if arg.startswith('https://') or arg.startswith('http://'):
        with urllib.request.urlopen(arg) as response:
            return json.load(response)
    with open(arg, 'r', encoding='utf-8') as handle:
        return json.load(handle)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(
            'usage: verify.py <game_id | https URL of a .json record | '
            'path to a .json file>\n'
        )
        return 1
    record = _load_record(argv[1])
    ok, lines = verify_record(record)
    for line in lines:
        print(line)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
''';
