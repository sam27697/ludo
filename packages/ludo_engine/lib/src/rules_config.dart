// docs/ENGINE_API.md section 2, verbatim shape; section 10.1 adds rollQueue,
// section 11.1 adds yardRelease.

/// Toggles the server may set per room.
class RulesConfig {
  const RulesConfig({
    this.blocks = true,
    this.captureBonus = true,
    this.rollQueue = false,
    this.homeBonus = false,
    this.yardRelease = false,
  });

  /// Rule 21: two or more of a seat's tokens on one main-track square block
  /// every other seat from passing or landing there.
  final bool blocks;

  /// Rule 11: a capture grants the capturing seat another roll.
  final bool captureBonus;

  /// Rule 9q (docs/RULES.md section 3.2a): every roll a seat is owed is
  /// rolled before any face is spent, replacing rules 9, 12 and 13. Defaults
  /// off so that records written before Sam's 2026-10-15 ruling replay
  /// unchanged; the server turns it on for every room.
  final bool rollQueue;

  /// Rule 11a: a move that brings a token home (`progress == 57`) grants
  /// another roll, unless it wins the game. Defaults off so that records
  /// written before Sam's 2026-10-15 ruling replay unchanged; the server
  /// turns it on for every room (`docs/ENGINE_API.md` section 8).
  final bool homeBonus;

  /// Rules 9r to 15r (docs/RULES.md section 3.2b): a seat whose four tokens
  /// all stay in the yard for 10 rolls without a 6 is granted one release.
  /// Defaults off so older records replay unchanged. Requires [rollQueue];
  /// `newGame` throws [ArgumentError] on a config that sets one without the
  /// other (docs/ENGINE_API.md section 11.1).
  final bool yardRelease;

  @override
  bool operator ==(Object other) =>
      other is RulesConfig &&
      other.blocks == blocks &&
      other.captureBonus == captureBonus &&
      other.rollQueue == rollQueue &&
      other.homeBonus == homeBonus &&
      other.yardRelease == yardRelease;

  @override
  int get hashCode =>
      Object.hash(blocks, captureBonus, rollQueue, homeBonus, yardRelease);

  @override
  String toString() => 'RulesConfig(blocks: $blocks, '
      'captureBonus: $captureBonus, rollQueue: $rollQueue, '
      'homeBonus: $homeBonus, yardRelease: $yardRelease)';
}
