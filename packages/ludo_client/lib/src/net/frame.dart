// docs/PROTOCOL.md section 1. The wire codec: bytes in, a typed [Frame] out,
// and back. Nothing in this file opens a socket, reads a clock, or touches
// `dart:io`; the transport that carries these frames is a later order and it
// stays small precisely because the shape and the validation live here.

import 'dart:convert';
import 'dart:math';

/// docs/PROTOCOL.md section 1.
const int maxFrameBytes = 8192;

/// Thrown by [Frame.decode] and [Frame.encode], and by nothing else in this
/// file. A caller that catches this has a malformed frame; a caller that sees
/// any other exception type out of this file has found a defect.
class FrameFormatException implements Exception {
  const FrameFormatException(this.reason);
  final String reason;
  @override
  String toString() => 'FrameFormatException: $reason';
}

/// docs/PROTOCOL.md section 1: `id` and `re` are 8 to 64 characters, every
/// character in `[A-Za-z0-9_-]`.
final RegExp _idShape = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

class Frame {
  const Frame({
    required this.type,
    required this.id,
    required this.data,
    this.re,
    this.version = 1,
  });

  /// The wire's `v`.
  final int version;

  /// The wire's `t`.
  final String type;

  /// The wire's `id`.
  final String id;

  /// The wire's `d`. Always non-null, possibly empty.
  final Map<String, Object?> data;

  /// The wire's `re`, null when the frame is not a reply.
  final String? re;

  /// Throws [FrameFormatException] on anything malformed, and never lets a
  /// `FormatException`, a `TypeError` or a cast failure escape.
  ///
  /// The byte-length check runs before `text` is handed to `jsonDecode` at
  /// all, and it is a byte count, not `text.length`: a frame carrying Arabic
  /// can sit under the character limit and over the byte limit, and the
  /// point of the check (docs/PROTOCOL.md section 1) is to keep
  /// attacker-sized input away from the parser in the first place.
  factory Frame.decode(String text) {
    if (utf8.encode(text).length > maxFrameBytes) {
      throw const FrameFormatException('frame exceeds maxFrameBytes');
    }

    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      throw const FrameFormatException('not valid JSON');
    }

    if (parsed is! Map<String, Object?>) {
      throw const FrameFormatException('top-level value is not an object');
    }
    final Map<String, Object?> json = parsed;

    final Object? v = json['v'];
    if (v is! int || v != 1) {
      throw const FrameFormatException('v');
    }

    final Object? t = json['t'];
    if (t is! String || t.isEmpty) {
      throw const FrameFormatException('t');
    }

    final Object? id = json['id'];
    if (id is! String || !_idShape.hasMatch(id)) {
      throw const FrameFormatException('id');
    }

    final Object? d = json['d'];
    if (d is! Map<String, Object?>) {
      throw const FrameFormatException('d');
    }

    String? re;
    if (json.containsKey('re') && json['re'] != null) {
      final Object? reValue = json['re'];
      if (reValue is! String || !_idShape.hasMatch(reValue)) {
        throw const FrameFormatException('re');
      }
      re = reValue;
    }

    return Frame(type: t, id: id, data: d, re: re, version: v);
  }

  /// Emits keys in the fixed order `v`, `t`, `id`, `re`, `d`, with `re`
  /// omitted entirely when null, so the output is comparable in a test
  /// without parsing it back. Throws [FrameFormatException] when the encoded
  /// result exceeds [maxFrameBytes], measured in UTF-8 bytes.
  String encode() {
    final Map<String, Object?> json = <String, Object?>{
      'v': version,
      't': type,
      'id': id,
      if (re != null) 're': re,
      'd': data,
    };
    final String text = jsonEncode(json);
    if (utf8.encode(text).length > maxFrameBytes) {
      throw const FrameFormatException('encoded frame exceeds maxFrameBytes');
    }
    return text;
  }

  /// `data['seq']` when present and an `int`, otherwise null.
  int? get seq {
    final Object? value = data['seq'];
    return value is int ? value : null;
  }
}

const String _messageIdAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';

/// 22 characters drawn from `[A-Za-z0-9_-]` using `Random.secure()`.
String newMessageId() {
  final Random random = Random.secure();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < 22; i++) {
    buffer.write(_messageIdAlphabet[random.nextInt(_messageIdAlphabet.length)]);
  }
  return buffer.toString();
}
