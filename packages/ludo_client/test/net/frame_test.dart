// Conformance tests for lib/src/net/frame.dart, written from
// docs/PROTOCOL.md section 1 and the frozen interface in work order 067,
// against no implementation the author of this file has read.
//
// Every negative test asserts the exception TYPE, never just "throws":
// throwsA(isA<FrameFormatException>()), never throwsException, because the
// latter also passes on a TypeError or a FormatException escaping from a
// careless cast, which is exactly the defect this rule exists to catch.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/frame.dart';

/// 8 characters, all in [A-Za-z0-9_-]: the minimum-length valid `id`/`re`.
const _validId = 'AAAAAAAA';

Map<String, Object?> _validFrameJson() => <String, Object?>{
  'v': 1,
  't': 'ping',
  'id': _validId,
  'd': <String, Object?>{},
};

Map<String, Object?> _without(Map<String, Object?> json, String key) {
  final copy = Map<String, Object?>.from(json);
  copy.remove(key);
  return copy;
}

Map<String, Object?> _replacing(
  Map<String, Object?> json,
  String key,
  Object? value,
) {
  final copy = Map<String, Object?>.from(json);
  copy[key] = value;
  return copy;
}

/// A minimal `{v,t,id,d}` skeleton with `d: {"pad": pad}`, used to build
/// frames of a precise UTF-8 byte size for the size-boundary tests.
String _skeleton(String pad) => jsonEncode(<String, Object?>{
  'v': 1,
  't': 'ping',
  'id': _validId,
  'd': <String, Object?>{'pad': pad},
});

/// Structural equality for the JSON-shaped values that live in a Frame's
/// `data`. Frame does not override `==`, and neither does anything it holds,
/// so a field-by-field comparison has to be written by hand rather than
/// relying on `expect(a, equals(b))` doing the right thing by accident.
bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void main() {
  group('Frame.decode: byte length, docs/PROTOCOL.md section 1', () {
    // This is the single highest-value test in this suite: an
    // implementation that checks `text.length` (UTF-16 code units) rather
    // than the UTF-8 byte count passes every ASCII-only test and silently
    // admits attacker-sized input the moment a user types Arabic, which is
    // half this app's user base.
    test('a frame whose payload is Arabic text exceeds maxFrameBytes in UTF-8 '
        'bytes while staying under maxFrameBytes in characters, and must be '
        'rejected', () {
      final baseBytes = utf8.encode(_skeleton('')).length;
      // Arabic letter alef, U+0627: one UTF-16 code unit, two UTF-8 bytes.
      const arabicChar = 'ا';
      // Solve for a repeat count that pushes the byte count over the
      // limit while the character count stays comfortably under it.
      final repeats = ((maxFrameBytes - baseBytes) / 2).ceil() + 8;
      final text = _skeleton(arabicChar * repeats);
      final totalChars = text.length;
      final totalBytes = utf8.encode(text).length;

      expect(
        totalChars,
        lessThan(maxFrameBytes),
        reason:
            'fixture is broken: character count must stay under '
            'maxFrameBytes ($maxFrameBytes) or this is no longer proving '
            'anything about byte-vs-character length; repeats=$repeats, '
            'chars=$totalChars',
      );
      expect(
        totalBytes,
        greaterThan(maxFrameBytes),
        reason:
            'fixture is broken: byte count must exceed maxFrameBytes '
            '($maxFrameBytes) or this frame should legitimately decode; '
            'repeats=$repeats, bytes=$totalBytes',
      );
      expect(
        () => Frame.decode(text),
        throwsA(isA<FrameFormatException>()),
        reason:
            'a decoder that checks text.length (characters, $totalChars) '
            'instead of the UTF-8 byte count ($totalBytes) would wrongly '
            'accept this frame; reproduce with repeats=$repeats',
      );
    });

    test('a frame one byte under maxFrameBytes decodes', () {
      final baseBytes = utf8.encode(_skeleton('')).length;
      final padLen = maxFrameBytes - baseBytes - 1;
      final text = _skeleton('a' * padLen);
      final totalBytes = utf8.encode(text).length;
      expect(
        totalBytes,
        maxFrameBytes - 1,
        reason: 'fixture is broken: expected exactly one byte under the limit',
      );
      expect(
        () => Frame.decode(text),
        returnsNormally,
        reason:
            'a frame of $totalBytes bytes, under maxFrameBytes '
            '($maxFrameBytes), must decode; padLen=$padLen',
      );
    });

    test('a frame at exactly maxFrameBytes decodes', () {
      final baseBytes = utf8.encode(_skeleton('')).length;
      final padLen = maxFrameBytes - baseBytes;
      final text = _skeleton('a' * padLen);
      final totalBytes = utf8.encode(text).length;
      expect(totalBytes, maxFrameBytes);
      expect(
        () => Frame.decode(text),
        returnsNormally,
        reason:
            'a frame of exactly maxFrameBytes ($maxFrameBytes) bytes is '
            'not "larger" and must decode; padLen=$padLen',
      );
    });

    test('a frame one byte over maxFrameBytes throws', () {
      final baseBytes = utf8.encode(_skeleton('')).length;
      final padLen = maxFrameBytes - baseBytes + 1;
      final text = _skeleton('a' * padLen);
      final totalBytes = utf8.encode(text).length;
      expect(totalBytes, maxFrameBytes + 1);
      expect(
        () => Frame.decode(text),
        throwsA(isA<FrameFormatException>()),
        reason:
            'a frame of $totalBytes bytes, one over maxFrameBytes '
            '($maxFrameBytes), must be rejected; padLen=$padLen',
      );
    });
  });

  group('Frame.decode: malformed top-level JSON value', () {
    final cases = <String, String>{
      'an empty string': '',
      'the literal null': 'null',
      'a JSON array': '[]',
      'an unterminated object': '{',
      'a bare string': '"a string"',
      'a bare number': '7',
      'a run of bytes that is not valid JSON at all':
          'this is not json {{{ at all, not even close',
    };
    for (final entry in cases.entries) {
      test('${entry.key} throws FrameFormatException, never a TypeError or a '
          'FormatException', () {
        expect(
          () => Frame.decode(entry.value),
          throwsA(isA<FrameFormatException>()),
          reason:
              'input ${jsonEncode(entry.value)} is not a well-formed '
              'frame and must surface as FrameFormatException, the only '
              'exception type this file is allowed to let escape',
        );
      });
    }
  });

  group('Frame.decode: v', () {
    test('missing v throws', () {
      expect(
        () => Frame.decode(jsonEncode(_without(_validFrameJson(), 'v'))),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('v = 1, the only valid value, decodes', () {
      final frame = Frame.decode(jsonEncode(_validFrameJson()));
      expect(frame.version, 1);
    });

    final invalidV = <String, Object?>{
      'the integer 2': 2,
      'the string "1"': '1',
      'the double 1.0': 1.0,
      'the boolean true': true,
      'a JSON null': null,
      'a JSON array': <Object?>[1],
    };
    for (final entry in invalidV.entries) {
      test('v = ${entry.key} throws', () {
        expect(
          () => Frame.decode(
            jsonEncode(_replacing(_validFrameJson(), 'v', entry.value)),
          ),
          throwsA(isA<FrameFormatException>()),
          reason: 'v must be exactly the integer 1; got ${entry.key}',
        );
      });
    }
  });

  group('Frame.decode: t', () {
    test('missing t throws', () {
      expect(
        () => Frame.decode(jsonEncode(_without(_validFrameJson(), 't'))),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('t as an empty string throws', () {
      expect(
        () => Frame.decode(jsonEncode(_replacing(_validFrameJson(), 't', ''))),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('t as the wrong runtime type throws', () {
      expect(
        () => Frame.decode(jsonEncode(_replacing(_validFrameJson(), 't', 5))),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a normal t decodes and is preserved verbatim', () {
      final frame = Frame.decode(
        jsonEncode(_replacing(_validFrameJson(), 't', 'roll')),
      );
      expect(frame.type, 'roll');
    });
  });

  group('Frame.decode: id', () {
    test('7 characters, one under the minimum, throws', () {
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 'id', 'A' * 7)),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('8 characters, the minimum, decodes', () {
      final frame = Frame.decode(
        jsonEncode(_replacing(_validFrameJson(), 'id', 'A' * 8)),
      );
      expect(frame.id, 'A' * 8);
    });

    test('64 characters, the maximum, decodes', () {
      final frame = Frame.decode(
        jsonEncode(_replacing(_validFrameJson(), 'id', 'A' * 64)),
      );
      expect(frame.id, 'A' * 64);
    });

    test('65 characters, one over the maximum, throws', () {
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 'id', 'A' * 65)),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a character outside [A-Za-z0-9_-] throws', () {
      // 7 valid characters plus one space: correct length, rejected alphabet.
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 'id', 'AAAAAAA ')),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('missing id throws', () {
      expect(
        () => Frame.decode(jsonEncode(_without(_validFrameJson(), 'id'))),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('id as the wrong runtime type throws', () {
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 'id', 12345678)),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('an id using every character in the alphabet decodes', () {
      const id = 'Aa0-_Bb1Az'; // 10 chars, within 8..64, every class present
      final frame = Frame.decode(
        jsonEncode(_replacing(_validFrameJson(), 'id', id)),
      );
      expect(frame.id, id);
    });
  });

  group('Frame.decode: d', () {
    test('missing d throws', () {
      expect(
        () => Frame.decode(jsonEncode(_without(_validFrameJson(), 'd'))),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('an empty d is valid', () {
      final frame = Frame.decode(jsonEncode(_validFrameJson()));
      expect(frame.data, isEmpty);
    });

    test('a populated d is preserved', () {
      final json = _replacing(_validFrameJson(), 'd', <String, Object?>{
        'token': 2,
        'flag': true,
      });
      final frame = Frame.decode(jsonEncode(json));
      expect(frame.data['token'], 2);
      expect(frame.data['flag'], true);
    });

    final invalidD = <String, Object?>{
      'a JSON array': <Object?>[1, 2],
      'a bare string': 'not an object',
      'a bare number': 7,
      'a boolean': true,
      'a JSON null': null,
    };
    for (final entry in invalidD.entries) {
      test('d as ${entry.key} throws', () {
        expect(
          () => Frame.decode(
            jsonEncode(_replacing(_validFrameJson(), 'd', entry.value)),
          ),
          throwsA(isA<FrameFormatException>()),
        );
      });
    }
  });

  group('Frame.decode: re', () {
    test('absent re decodes to null', () {
      final frame = Frame.decode(jsonEncode(_validFrameJson()));
      expect(frame.re, isNull);
    });

    test('explicit null re decodes to null', () {
      final frame = Frame.decode(
        jsonEncode(_replacing(_validFrameJson(), 're', null)),
      );
      expect(frame.re, isNull);
    });

    test('a valid re, satisfying the id rule, is preserved', () {
      final frame = Frame.decode(
        jsonEncode(_replacing(_validFrameJson(), 're', 'B' * 22)),
      );
      expect(frame.re, 'B' * 22);
    });

    test('a re that is too short (7 characters) throws', () {
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 're', 'B' * 7)),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a re containing a rejected character throws', () {
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 're', 'BBBBBBB.')),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a re of the wrong runtime type throws', () {
      expect(
        () => Frame.decode(
          jsonEncode(_replacing(_validFrameJson(), 're', 12345678)),
        ),
        throwsA(isA<FrameFormatException>()),
      );
    });
  });

  group('Frame.decode: unknown top-level keys', () {
    test('are ignored, not rejected', () {
      final json = <String, Object?>{
        ..._validFrameJson(),
        'extra': 'junk',
        'another': 42,
      };
      final frame = Frame.decode(jsonEncode(json));
      expect(frame.type, 'ping');
      expect(frame.id, _validId);
      expect(frame.data, isEmpty);
    });
  });

  group('Frame.seq', () {
    test('returns the int when data["seq"] is an int', () {
      final json = _replacing(_validFrameJson(), 'd', <String, Object?>{
        'seq': 42,
      });
      final frame = Frame.decode(jsonEncode(json));
      expect(frame.seq, 42);
    });

    test('returns null when seq is absent', () {
      final frame = Frame.decode(jsonEncode(_validFrameJson()));
      expect(frame.seq, isNull);
    });

    test('returns null when seq is present but a String', () {
      final json = _replacing(_validFrameJson(), 'd', <String, Object?>{
        'seq': '42',
      });
      final frame = Frame.decode(jsonEncode(json));
      expect(frame.seq, isNull);
    });

    test('returns null when seq is a double, even 42.0, not an int', () {
      final json = _replacing(_validFrameJson(), 'd', <String, Object?>{
        'seq': 42.0,
      });
      final frame = Frame.decode(jsonEncode(json));
      expect(frame.seq, isNull);
    });
  });

  group('Frame.encode: key order', () {
    test('v, t, id, re, d in that order when re is present', () {
      const frame = Frame(
        type: 'roll',
        id: 'AAAAAAAA',
        re: 'BBBBBBBB',
        data: <String, Object?>{'k': 1},
      );
      final text = frame.encode();
      final iV = text.indexOf('"v":');
      final iT = text.indexOf('"t":');
      final iId = text.indexOf('"id":');
      final iRe = text.indexOf('"re":');
      final iD = text.indexOf('"d":');
      expect(
        [iV, iT, iId, iRe, iD],
        everyElement(greaterThanOrEqualTo(0)),
        reason: 'expected all of v, t, id, re, d to appear in: $text',
      );
      expect(
        iV < iT && iT < iId && iId < iRe && iRe < iD,
        isTrue,
        reason: 'expected key order v, t, id, re, d but got: $text',
      );
    });

    test('re is omitted entirely, not written as null, when re is null', () {
      const frame = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{},
      );
      final text = frame.encode();
      expect(
        text.contains('"re"'),
        isFalse,
        reason: 're must be omitted entirely, not present as "re":null: $text',
      );
      final iV = text.indexOf('"v":');
      final iT = text.indexOf('"t":');
      final iId = text.indexOf('"id":');
      final iD = text.indexOf('"d":');
      expect(
        iV < iT && iT < iId && iId < iD,
        isTrue,
        reason: 'expected key order v, t, id, d but got: $text',
      );
    });
  });

  group('Frame.encode: size limit', () {
    test('throws when the encoded frame exceeds maxFrameBytes', () {
      final frame = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{'pad': 'x' * maxFrameBytes},
      );
      expect(() => frame.encode(), throwsA(isA<FrameFormatException>()));
    });

    test('does not throw when the encoded frame is exactly maxFrameBytes', () {
      const probe = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{'pad': ''},
      );
      final baseBytes = utf8.encode(probe.encode()).length;
      final padLen = maxFrameBytes - baseBytes;
      final frame = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{'pad': 'a' * padLen},
      );
      final text = frame.encode();
      expect(utf8.encode(text).length, maxFrameBytes);
    });

    test('throws when the encoded frame is one byte over maxFrameBytes', () {
      const probe = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{'pad': ''},
      );
      final baseBytes = utf8.encode(probe.encode()).length;
      final padLen = maxFrameBytes - baseBytes + 1;
      final frame = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{'pad': 'a' * padLen},
      );
      expect(() => frame.encode(), throwsA(isA<FrameFormatException>()));
    });
  });

  group('round trip: decode(encode(f))', () {
    test('reproduces every field when re is null', () {
      final original = Frame(
        type: 'roll',
        id: 'AAAAAAAA',
        data: <String, Object?>{
          'token': 2,
          'note': 'hello',
          'flag': true,
          'amount': null,
        },
      );
      final decoded = Frame.decode(original.encode());
      expect(decoded.version, original.version);
      expect(decoded.type, original.type);
      expect(decoded.id, original.id);
      expect(decoded.re, original.re);
      expect(
        _deepEquals(decoded.data, original.data),
        isTrue,
        reason: 'expected data ${original.data} but decoded ${decoded.data}',
      );
    });

    test(
      'reproduces every field when re is present, including nested data',
      () {
        final original = Frame(
          type: 'room',
          id: 'BBBBBBBB',
          re: 'CCCCCCCC',
          data: <String, Object?>{
            'seq': 7,
            'nested': <String, Object?>{
              'a': 1,
              'b': <Object?>[1, 2, 3],
            },
          },
        );
        final decoded = Frame.decode(original.encode());
        expect(decoded.version, original.version);
        expect(decoded.type, original.type);
        expect(decoded.id, original.id);
        expect(decoded.re, original.re);
        expect(
          _deepEquals(decoded.data, original.data),
          isTrue,
          reason: 'expected data ${original.data} but decoded ${decoded.data}',
        );
      },
    );

    test('preserves an empty data map', () {
      final original = Frame(
        type: 'ping',
        id: 'AAAAAAAA',
        data: <String, Object?>{},
      );
      final decoded = Frame.decode(original.encode());
      expect(decoded.data, isEmpty);
    });
  });

  group('newMessageId', () {
    final alphabet = RegExp(r'^[A-Za-z0-9_-]+$');

    test('is exactly 22 characters', () {
      final id = newMessageId();
      expect(id.length, 22, reason: 'newMessageId() returned "$id"');
    });

    test('every character is in [A-Za-z0-9_-]', () {
      final id = newMessageId();
      expect(
        alphabet.hasMatch(id),
        isTrue,
        reason: 'id "$id" contains a character outside [A-Za-z0-9_-]',
      );
    });

    test('two successive calls differ', () {
      final first = newMessageId();
      final second = newMessageId();
      expect(
        first,
        isNot(equals(second)),
        reason:
            'two successive calls returned the same id "$first"; this can '
            'happen by chance with a correct CSPRNG only with negligible '
            'probability, so a repeat here almost certainly means the '
            'generator is not actually drawing fresh randomness',
      );
    });

    test('the result satisfies Frame.decode\'s id rule, used as id and re', () {
      final id = newMessageId();
      final json = <String, Object?>{
        'v': 1,
        't': 'ping',
        'id': id,
        're': id,
        'd': <String, Object?>{},
      };
      final frame = Frame.decode(jsonEncode(json));
      expect(frame.id, id);
      expect(frame.re, id);
    });
  });
}
