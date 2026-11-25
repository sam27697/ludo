// Whether the player is signed in with Google. There is no sign-in yet, so
// the answer is no unless a test sets the override. Home shows the last-game
// card only to a signed-in player.

/// Set by tests to stand in for a Google sign-in; null leaves the real answer.
bool? debugGoogleSignedInOverride;

/// True when the player is signed in with Google.
bool get googleSignedIn => debugGoogleSignedInOverride ?? false;
