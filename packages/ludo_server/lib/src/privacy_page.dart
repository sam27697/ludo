// The privacy policy page served at `GET /privacy`. The document is built
// once, at compile time, from the blessed-pending draft text in
// `work/ludo/PRIVACY_DRAFT.md` (the section headed `## The text`). Nothing
// here reads a file at request time: [buildPrivacyPageHtml] is a pure
// function of one optional string, called once by `WireServer.start` and
// cached, per order 049.
//
// The wording below is the draft's wording, unchanged. The only edits made
// converting it to HTML are: the bold lead-ins became `<h2>` headings, the
// publication date replaced the `[DATE OF PUBLICATION]` placeholder, and the
// one em-dash in the draft's title ("Privacy Policy - Ludo RNG") was
// rewritten as a hyphen, because hard rule 5 of the mission forbids an
// em-dash reaching a public page. Nothing was added, and nothing was
// dropped.

import 'dart:convert';

/// `YYYY-MM-DD`, matching the "Last updated" line in the rendered page.
/// Bump this string, and only this string, the day the policy text changes.
const String privacyLastUpdated = '2026-08-28';

const HtmlEscape _escaper = HtmlEscape();

/// Builds the complete privacy policy document.
///
/// [contactEmail] is the operator-supplied contact address, read from the
/// `PRIVACY_CONTACT_EMAIL` environment variable by `bin/server.dart` and
/// passed in here as configuration -- this function never reads the
/// environment itself. Null or empty omits the contact section entirely
/// rather than shipping an invented or a placeholder address; the value is
/// HTML-escaped before it is interpolated, since it arrives from the
/// environment and lands in a public page.
String buildPrivacyPageHtml({String? contactEmail}) {
  final String? trimmedEmail =
      (contactEmail != null && contactEmail.trim().isNotEmpty)
          ? contactEmail
          : null;

  final StringBuffer body = StringBuffer()
    ..writeln('<h1>Privacy Policy - Ludo RNG</h1>')
    ..writeln('<p class="updated">Last updated: $privacyLastUpdated</p>')
    ..writeln(
      '<p>Ludo RNG is a game you play online with people you invite. '
      'This policy explains what the app and its server handle, and what '
      'they do not.</p>',
    )
    ..writeln('<h2>We do not collect personal information.</h2>')
    ..writeln(
      '<p>Ludo RNG has no account, no sign-in, no email address, no '
      'password and no profile. You do not tell us who you are and we do '
      'not ask.</p>',
    )
    ..writeln('<h2>No advertising, no analytics, no tracking.</h2>')
    ..writeln(
      '<p>The app contains no advertising network, no analytics library '
      'and no third-party crash reporting. Nothing about your use of the '
      'app is shared with any other company. There is no advertising '
      'identifier and no device identifier collected.</p>',
    )
    ..writeln('<h2>What you type, and where it goes.</h2>')
    ..writeln(
      '<p>To play, you create a room or join one with a room code. You '
      'may enter a display name for your seat. That name and the room '
      'code are sent to our server so the other players in your room can '
      'see them, and they are visible to everyone in that room. Choose a '
      'display name you are comfortable showing to the people you '
      'invited. Rooms are temporary: the room and everything in it, '
      'including any display name, is deleted from the server when the '
      'room ends or expires.</p>',
    )
    ..writeln('<h2>What the server records automatically.</h2>')
    ..writeln(
      '<p>Like any server on the internet, ours records the technical '
      'details of a connection so the service can be kept working and '
      'abuse can be stopped: the IP address of the connecting device, the '
      'time of the connection, and error information. These records are '
      'kept for a short period and are not used to build a profile of '
      'you, are not sold, and are not shared with anyone except where the '
      'law requires it.</p>',
    )
    ..writeln('<h2>Verifiable rolls.</h2>')
    ..writeln(
      '<p>Every dice roll is accompanied by information that lets you '
      'check the roll was not altered after the fact. That information '
      'is about the game, not about you, and contains no personal '
      'data.</p>',
    )
    ..writeln('<h2>Children.</h2>')
    ..writeln(
      '<p>Ludo RNG is not directed at children under 13. We do not '
      'knowingly collect any personal information from anyone, including '
      'children.</p>',
    )
    ..writeln('<h2>Data you can ask about.</h2>')
    ..writeln(
      '<p>Because we hold no account and no personal profile, there is '
      'normally nothing to give you a copy of or to delete. If you '
      'believe we hold something about you and you want it removed, '
      'write to the address below and we will act on it.</p>',
    )
    ..writeln('<h2>Changes to this policy.</h2>')
    ..writeln(
      '<p>If this policy changes, the new version appears on this page '
      'with a new date at the top.</p>',
    );

  if (trimmedEmail != null) {
    final String escapedEmail = _escaper.convert(trimmedEmail);
    body
      ..writeln('<h2>Contact.</h2>')
      ..writeln('<p>$escapedEmail</p>');
  }

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy Policy - Ludo RNG</title>
<style>
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    Helvetica, Arial, sans-serif;
  max-width: 40em;
  margin: 0 auto;
  padding: 1.5em;
  line-height: 1.5;
  color: #1a1a1a;
}
h1 {
  font-size: 1.4em;
}
h2 {
  font-size: 1.1em;
  margin-top: 1.5em;
}
p.updated {
  color: #555;
}
</style>
</head>
<body>
$body</body>
</html>
''';
}
