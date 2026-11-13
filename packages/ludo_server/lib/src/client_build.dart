/// `docs/PROTOCOL.md` section 27: which build of the app opened a socket, and
/// the minimum build the server accepts. Pure parsing, no I/O, so the rules
/// are testable without a socket and `bin/server.dart` and the wire layer
/// share one reading of them.
library;

/// The upgrade request header the app sends its Android `versionCode` in.
/// Lower case: shelf's header map is case-insensitive, and HTTP requires it
/// to be read that way.
const String clientBuildHeader = 'ludo-client-build';

final RegExp _buildPattern = RegExp(r'^[0-9]{1,9}$');

/// Spaces and tabs only, the optional whitespace HTTP allows around a header
/// value. Not `String.trim`, which also strips Unicode spaces no HTTP peer
/// sends.
String _trimHttpSpace(String value) {
  int start = 0;
  int end = value.length;
  while (start < end && _isHttpSpace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isHttpSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

bool _isHttpSpace(int unit) => unit == 0x20 || unit == 0x09;

/// Section 27 rule 2. The build the header carries: 1 to 9 ASCII digits
/// after trimming, with an integer value of at least 1. Everything else,
/// including an absent header, an empty value, a sign, a decimal point, ten
/// or more digits and several comma-joined values, is build `0`, meaning
/// unknown. Never throws.
int parseClientBuildHeader(String? value) {
  if (value == null) {
    return 0;
  }
  final String trimmed = _trimHttpSpace(value);
  if (!_buildPattern.hasMatch(trimmed)) {
    return 0;
  }
  return int.parse(trimmed);
}

/// Section 27 rule 3. The `MIN_CLIENT_BUILD` environment value: absent or
/// empty is `0` (the check is off), 1 to 9 ASCII digits after trimming is
/// that number, anything else throws a [FormatException] naming the
/// variable, for `bin/server.dart` to turn into a failed start.
int parseMinClientBuild(String? raw) {
  if (raw == null) {
    return 0;
  }
  final String trimmed = _trimHttpSpace(raw);
  if (trimmed.isEmpty) {
    return 0;
  }
  if (!_buildPattern.hasMatch(trimmed)) {
    throw FormatException(
      'MIN_CLIENT_BUILD must be a non-negative decimal integer of at most '
      '9 digits, got "$raw"',
    );
  }
  return int.parse(trimmed);
}
