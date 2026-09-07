import 'package:app_links/app_links.dart';

import 'room_code.dart';

/// The host of the production Android App Link, `https://ludo.provefair.app/r/<CODE>`.
///
/// Must equal the `android:host` of the `autoVerify` intent filter in
/// `android/app/src/main/AndroidManifest.xml`. That filter and this constant
/// are owned separately (the manifest by order 076, this file by order 082)
/// and nothing enforces they stay equal except reading both.
const String kAppLinkHost = 'ludo.provefair.app';

/// Whether [uri] addresses this app's room-link space at all: the right
/// scheme, the right host, and the right path shape (`/r/<something>`).
///
/// This says nothing about whether the code segment itself is a valid room
/// code -- that is a separate question, answered by [roomCodeFromUri]. The
/// split exists because a caller deciding whether an unreadable link is the
/// player's fault needs to ask two different questions where
/// `roomCodeFromUri` on its own only ever asked one: "did this URI even try
/// to be one of ours" is answered here, and "is the code it gave me any
/// good" is answered by normalising and checking it. A link that fails this
/// predicate was never a room link to begin with, wrong app, wrong host, a
/// share-sheet accident, whatever else the platform might hand the app on a
/// plain launch; a link that passes this predicate but still comes back
/// `null` from [roomCodeFromUri] genuinely carried a bad code.
///
/// The query string and the fragment are never inspected.
bool isAppRoomLinkUri(Uri uri) {
  return uri.scheme == 'https' &&
      uri.host == kAppLinkHost &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments[0] == 'r';
}

/// Extracts a room code from an incoming link, or returns `null` if the link
/// does not carry one worth acting on.
///
/// A `null` result covers four different situations, and every existing
/// caller of this function treats them the same on purpose, because every
/// existing caller only ever needed "do I have a code to act on or not": the
/// link is not one of ours by scheme, or by host, or by path shape (see
/// [isAppRoomLinkUri] for those three), or it is one of ours but its code
/// fails the local shape check `isValidRoomCode` already applies to a typed
/// code. The code arrives from outside the app -- from a tapped link, not
/// from the keyboard -- so it is untrusted input and gets the same scrutiny
/// either way.
///
/// A caller that needs to tell "not our link" apart from "our link, bad
/// code" -- to decide, say, whether an unreadable link is the player's fault
/// -- calls [isAppRoomLinkUri] itself instead of trying to reverse-engineer
/// the reason out of this function's single `null`.
///
/// The query string and the fragment are never inspected.
String? roomCodeFromUri(Uri uri) {
  if (!isAppRoomLinkUri(uri)) {
    return null;
  }
  final String normalized = normalizeRoomCode(uri.pathSegments[1]);
  return isValidRoomCode(normalized) ? normalized : null;
}

/// Reads whatever link launched the app (the cold-start path), or `null` if
/// it was not launched by a link at all.
typedef InitialLinkReader = Future<Uri?> Function();

/// Opens a stream of links that arrive while the app is already running (the
/// warm-start path).
typedef LinkStreamOpener = Stream<Uri> Function();

/// The inert [InitialLinkReader]: never launched by a link. This is the
/// default everywhere under `lib/src/`, so a widget pumped with no arguments
/// never touches a real platform channel.
Future<Uri?> noInitialLink() => Future<Uri?>.value();

/// The inert [LinkStreamOpener]: no link ever arrives. This is the default
/// everywhere under `lib/src/`, for the same reason as [noInitialLink].
Stream<Uri> noLinkStream() => const Stream<Uri>.empty();

/// The real [InitialLinkReader], over `package:app_links`. Named as a
/// default only in `main.dart`; nothing under `lib/src/` may reach for it.
Future<Uri?> appLinksInitialLink() => AppLinks().getInitialLink();

/// The real [LinkStreamOpener], over `package:app_links`. Named as a default
/// only in `main.dart`; nothing under `lib/src/` may reach for it.
Stream<Uri> appLinksLinkStream() => AppLinks().uriLinkStream;
