import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/theme.dart';

void main() {
  test('ColorScheme.fromSeed is absent from theme.dart', () {
    final String src = File('lib/src/theme.dart').readAsStringSync();
    final int count = RegExp(r'ColorScheme\.fromSeed').allMatches(src).length;
    print('fromSeed_count=$count');
    expect(count, 0);
  });

  test('hand-built ColorScheme slot table has non_brand_count 0', () {
    final ColorScheme scheme = buildAppTheme().colorScheme;
    final Set<int> tokenArgb = <int>{
      LudoColors.feltDeep.toARGB32(),
      LudoColors.feltMid.toARGB32(),
      LudoColors.feltLight.toARGB32(),
      LudoColors.paper.toARGB32(),
      LudoColors.paperElevated.toARGB32(),
      LudoColors.ink.toARGB32(),
      LudoColors.inkMuted.toARGB32(),
      LudoColors.dieFace.toARGB32(),
      LudoColors.dieEdge.toARGB32(),
      LudoColors.action.toARGB32(),
      LudoColors.actionOn.toARGB32(),
      LudoColors.error.toARGB32(),
      LudoColors.paperWashTop.toARGB32(),
      LudoColors.paperWashBottom.toARGB32(),
      for (final Color c in LudoColors.seats) c.toARGB32(),
    };
    final Map<String, Color> slots = <String, Color>{
      'primary': scheme.primary,
      'onPrimary': scheme.onPrimary,
      'primaryContainer': scheme.primaryContainer,
      'onPrimaryContainer': scheme.onPrimaryContainer,
      'secondary': scheme.secondary,
      'onSecondary': scheme.onSecondary,
      'secondaryContainer': scheme.secondaryContainer,
      'onSecondaryContainer': scheme.onSecondaryContainer,
      'tertiary': scheme.tertiary,
      'onTertiary': scheme.onTertiary,
      'tertiaryContainer': scheme.tertiaryContainer,
      'onTertiaryContainer': scheme.onTertiaryContainer,
      'error': scheme.error,
      'onError': scheme.onError,
      'errorContainer': scheme.errorContainer,
      'onErrorContainer': scheme.onErrorContainer,
      'surface': scheme.surface,
      'onSurface': scheme.onSurface,
      'surfaceDim': scheme.surfaceDim,
      'surfaceBright': scheme.surfaceBright,
      'surfaceContainerLowest': scheme.surfaceContainerLowest,
      'surfaceContainerLow': scheme.surfaceContainerLow,
      'surfaceContainer': scheme.surfaceContainer,
      'surfaceContainerHigh': scheme.surfaceContainerHigh,
      'surfaceContainerHighest': scheme.surfaceContainerHighest,
      'onSurfaceVariant': scheme.onSurfaceVariant,
      'outline': scheme.outline,
      'outlineVariant': scheme.outlineVariant,
      'shadow': scheme.shadow,
      'scrim': scheme.scrim,
      'inverseSurface': scheme.inverseSurface,
      'onInverseSurface': scheme.onInverseSurface,
      'inversePrimary': scheme.inversePrimary,
      'surfaceTint': scheme.surfaceTint,
    };
    int nonBrand = 0;
    print('SCHEME_SLOT_TABLE brightness=${scheme.brightness.name}');
    print('SLOT\tARGB\tBRAND');
    for (final MapEntry<String, Color> e in slots.entries) {
      final bool brand = tokenArgb.contains(e.value.toARGB32());
      if (!brand) {
        nonBrand++;
      }
      print(
        '${e.key}\t0x${e.value.toARGB32().toRadixString(16).padLeft(8, '0')}\t$brand',
      );
    }
    print('non_brand_count=$nonBrand total=${slots.length}');
    expect(
      nonBrand,
      0,
      reason:
          'expected 0 non-brand ColorScheme slots after hand-built scheme; '
          'got $nonBrand',
    );
  });
}
