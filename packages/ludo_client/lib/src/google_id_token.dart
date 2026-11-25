// The real GoogleIdTokenSource, over the google_sign_in plugin (Credential
// Manager on Android). The plugin is started once per run with the server's
// client id; the token it returns is handed straight to the caller and kept
// nowhere.

import 'package:google_sign_in/google_sign_in.dart';

import 'account.dart';

class PluginGoogleIdTokenSource implements GoogleIdTokenSource {
  String? _initializedFor;

  @override
  Future<String?> idToken(String serverClientId) async {
    if (_initializedFor != serverClientId) {
      await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
      _initializedFor = serverClientId;
    }
    try {
      final GoogleSignInAccount account = await GoogleSignIn.instance
          .authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    if (_initializedFor == null) {
      return;
    }
    await GoogleSignIn.instance.signOut();
  }
}
