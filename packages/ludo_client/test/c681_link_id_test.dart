// C-681t: parsing a tapped room link into a link id (docs/PROTOCOL.md
// section 31 items 1 and 9, order 681 "Interface frozen").
//
// Written from the order and the spec alone. `roomLinkIdFromUri` is a new
// name in lib/src/deep_link.dart: until order 681's lib lands this file does
// not compile (unresolved name), by design.
//
// Contract pinned here:
//   - shape `[0-9a-z]{4,10}-[0-9a-z]{6}`, folded to lower case
//   - one trailing slash accepted, as for codes; more segments refused
//   - https on ludo.provefair.app only, path `/r/<id>`
//   - a six-character code in `/r/` is not a link id (section 31 item 9)
//   - `isAppRoomLinkUri` keeps its meaning, `roomCodeFromUri` still reads
//     codes and never reads a link id
//
// No random input. Every reason names the case, the input and the value seen;
// replay: flutter test test/c681_link_id_test.dart --plain-name '<case>'

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/deep_link.dart';

const String _base = 'https://ludo.provefair.app/r/';
const String _id = 't5k2q9a-x7m3pd';

String _why(String id, String input, Object? saw, String wanted) =>
    '$id: input "$input": expected $wanted; saw $saw. '
    "reproduce: flutter test test/c681_link_id_test.dart --plain-name '$id'";

void _expectId(String id, String input, String? wanted) {
  final String? saw = roomLinkIdFromUri(Uri.parse(input));
  expect(saw, wanted, reason: _why(id, input, saw, '$wanted'));
}

void main() {
  group('shape', () {
    test('a well-formed id is returned as is', () {
      _expectId('shape.ok', '$_base$_id', _id);
    });

    test('the part before the dash is 4 to 10 characters', () {
      _expectId('shape.pre3', '${_base}abc-x7m3pd', null);
      _expectId('shape.pre4', '${_base}abcd-x7m3pd', 'abcd-x7m3pd');
      _expectId(
        'shape.pre10',
        '${_base}abcdefghij-x7m3pd',
        'abcdefghij-x7m3pd',
      );
      _expectId('shape.pre11', '${_base}abcdefghijk-x7m3pd', null);
    });

    test('the part after the dash is exactly 6 characters', () {
      _expectId('shape.post5', '${_base}t5k2q9a-x7m3p', null);
      _expectId('shape.post7', '${_base}t5k2q9a-x7m3pdz', null);
      _expectId('shape.post0', '${_base}t5k2q9a-', null);
    });

    test('digits are allowed on both sides of the dash', () {
      _expectId('shape.digits', '${_base}0000000-000000', '0000000-000000');
    });

    test('a character outside 0-9a-z is refused', () {
      _expectId('shape.underscore', '${_base}t5k2q9a-x7m3p_', null);
      _expectId('shape.dot', '${_base}t5k2.9a-x7m3pd', null);
      _expectId('shape.plus', '${_base}t5k2q9a-x7m3p%2B', null);
      _expectId('shape.space', '${_base}t5k2q9a-x7m%203', null);
      _expectId('shape.nonascii', '${_base}t5k2q9a-x7m3pé', null);
    });

    test('no dash, two dashes, or an empty id is refused', () {
      _expectId('shape.nodash', '${_base}t5k2q9ax7m3pd', null);
      _expectId('shape.twodash', '${_base}t5k2-q9a-x7m3pd', null);
      _expectId('shape.empty', _base, null);
      _expectId('shape.dashonly', '$_base-', null);
    });
  });

  group('case', () {
    test('upper case is folded to lower case', () {
      _expectId('case.upper', '${_base}T5K2Q9A-X7M3PD', _id);
    });

    test('mixed case is folded to lower case', () {
      _expectId('case.mixed', '${_base}T5k2Q9a-x7M3pD', _id);
    });
  });

  group('trailing slash and extras', () {
    test('one trailing slash is the same link', () {
      _expectId('slash.one', '$_base$_id/', _id);
    });

    test('two trailing slashes or a further segment are refused', () {
      _expectId('slash.two', '$_base$_id//', null);
      _expectId('slash.segment', '$_base$_id/more', null);
    });

    test('the query and the fragment are never read', () {
      _expectId('extra.query', '$_base$_id?x=1', _id);
      _expectId('extra.fragment', '$_base$_id#frag', _id);
      _expectId('extra.query_slash', '$_base$_id/?x=1', _id);
    });

    test('a query cannot smuggle an id into a link with none', () {
      _expectId('extra.query_only', '${_base}x?id=$_id', null);
    });
  });

  group('a six-character code is not ours', () {
    test('a code in /r/ is not a link id, in any case', () {
      _expectId('code.upper', '${_base}ABC234', null);
      _expectId('code.lower', '${_base}abc234', null);
      _expectId('code.slash', '${_base}ABC234/', null);
    });

    test('a code cannot pass for a link id by being padded with a dash', () {
      _expectId('code.dash_prefix', '$_base-ABC234', null);
      _expectId('code.dash_suffix', '${_base}ABC234-', null);
    });

    test('roomCodeFromUri still reads a code and never reads a link id', () {
      expect(
        roomCodeFromUri(Uri.parse('${_base}ABC234')),
        'ABC234',
        reason: _why('code.compat', '${_base}ABC234', null, 'ABC234'),
      );
      final String? fromLinkId = roomCodeFromUri(Uri.parse('$_base$_id'));
      expect(
        fromLinkId,
        isNull,
        reason: _why('code.compat_id', '$_base$_id', fromLinkId, 'null'),
      );
    });

    test('isAppRoomLinkUri keeps its meaning for a link id and a code', () {
      for (final String input in <String>[
        '$_base$_id',
        '$_base$_id/',
        '${_base}ABC234',
      ]) {
        expect(
          isAppRoomLinkUri(Uri.parse(input)),
          isTrue,
          reason: _why('code.is_app_link', input, false, 'true'),
        );
      }
      expect(
        isAppRoomLinkUri(Uri.parse('https://ludo.provefair.app/x/$_id')),
        isFalse,
        reason: _why('code.is_app_link_path', '/x/$_id', true, 'false'),
      );
    });
  });

  group('other host, scheme or path', () {
    test('another host is not ours', () {
      _expectId('host.other', 'https://example.com/r/$_id', null);
      _expectId(
        'host.suffix',
        'https://ludo.provefair.app.evil.test/r/$_id',
        null,
      );
      _expectId('host.prefix', 'https://evil.ludo.provefair.app/r/$_id', null);
      _expectId(
        'host.userinfo',
        'https://ludo.provefair.app@evil.test/r/$_id',
        null,
      );
    });

    test('another scheme is not ours', () {
      _expectId('scheme.http', 'http://ludo.provefair.app/r/$_id', null);
      _expectId('scheme.custom', 'ludo://ludo.provefair.app/r/$_id', null);
    });

    test('another path is not ours', () {
      _expectId('path.root', 'https://ludo.provefair.app/$_id', null);
      _expectId('path.other', 'https://ludo.provefair.app/x/$_id', null);
      _expectId('path.upper_r', 'https://ludo.provefair.app/R/$_id', null);
      _expectId('path.nested', 'https://ludo.provefair.app/a/r/$_id', null);
    });

    test('a relative reference is not ours', () {
      _expectId('rel.path', '/r/$_id', null);
      _expectId('rel.empty', '', null);
    });
  });
}
