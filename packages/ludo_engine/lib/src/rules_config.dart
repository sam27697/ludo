// docs/ENGINE_API.md section 2, verbatim shape.

/// Toggles the server may set per room. Both default on.
class RulesConfig {
  const RulesConfig({this.blocks = true, this.captureBonus = true});

  /// Rule 21: two or more of a seat's tokens on one main-track square block
  /// every other seat from passing or landing there.
  final bool blocks;

  /// Rule 11: a capture grants the capturing seat another roll.
  final bool captureBonus;

  @override
  bool operator ==(Object other) =>
      other is RulesConfig &&
      other.blocks == blocks &&
      other.captureBonus == captureBonus;

  @override
  int get hashCode => Object.hash(blocks, captureBonus);

  @override
  String toString() =>
      'RulesConfig(blocks: $blocks, captureBonus: $captureBonus)';
}
