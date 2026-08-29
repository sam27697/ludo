import 'package:app_links/app_links.dart';

import 'room_code.dart';

/// The host of the production Android App Link, `https://ludo.provefair.app/r/<CODE>`.
///
/// Must equal the `android:host` of the `autoVerify` intent filter in
/// `android/app/src/main/AndroidManifest.xml`. That filter and this constant
/// are owned separately (the manifest by order 076, this file by order 082)
/// and nothing enforces they stay equal except reading both.
const String kAppLinkHost = 'ludo.provefair.app';

/// Extracts a room code from an incoming link, or returns `null` if the link
/// does not carry one worth acting on.
///
/// A `null` result covers three different situations on purpose, and all
/// three are treated the same by every caller: the link is not one of ours,
/// or it is one of ours but shaped wrong, or its code fails the local shape
/// check `isValidRoomCode` already applies to a typed code. The code arrives
/// from outside the app -- from a tapped link, not from the keyboard -- so it
/// is untrusted input and gets the same scrutiny either way.
///
/// The query string and the fragment are never inspected.
String? roomCodeFromUri(Uri uri) {
  if (uri.scheme != 'https') {
    return null;
  }
  if (uri.host != kAppLinkHost) {
    return null;
  }
  if (uri.pathSegments.length != 2) {
    return null;
  }
  if (uri.pathSegments[0] != 'r') {
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
