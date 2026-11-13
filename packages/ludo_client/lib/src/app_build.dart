// The app's own build number, the Android versionCode, read from the
// platform side. docs/PROTOCOL.md section 27 rule 1: it rides on every
// WebSocket upgrade as `Ludo-Client-Build`, so the server can tell an app
// that is too old to play to update instead of leaving it a dead socket.

import 'package:flutter/services.dart';

/// The channel MainActivity answers with `build`. Separate from
/// `app.fayad.ludo/feedback`, which stays exactly as it was.
const MethodChannel appBuildChannel = MethodChannel('app.fayad.ludo/app');

/// The installed build number, or null when it cannot be read: no platform
/// side (a test, a desktop run), a platform error, or a value that is not an
/// integer of at least 1. Null means the upgrade carries no header, which
/// the server reads as build 0.
Future<int?> readAppBuild() async {
  try {
    final Object? value = await appBuildChannel.invokeMethod<Object>('build');
    if (value is int && value >= 1) {
      return value;
    }
    return null;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
