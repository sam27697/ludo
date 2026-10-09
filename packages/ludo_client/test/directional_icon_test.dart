// Proof of C-286 rules 3 and 4. Home is mounted the way
// test/home_chrome_test.dart and test/locale_rtl_test.dart mount it:
// LudoApp, one mount per case, initialLocale for Arabic. The mirror is
// read off a Transform ancestor of the Icon, between that Icon and the
// button.
//
// The Arabic join case is red on this tree: Icons.login_rounded under
// join-room-button has no Transform ancestor with a negative matrix
// entry (0, 0). English join, and the Create Room icon in Arabic, have
// no such Transform either, which is what those two cases require.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';

const Key _joinKey = Key('join-room-button');
const Key _createKey = Key('create-room-button');

Future<void> _mountHome(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(LudoApp(initialLocale: locale));
  await tester.pumpAndSettle();
}

Finder _iconUnder(Key buttonKey, IconData icon) {
  return find.descendant(
    of: find.byKey(buttonKey),
    matching: find.byWidgetPredicate(
      (Widget widget) => widget is Icon && widget.icon == icon,
    ),
  );
}

/// A [Transform] on the ancestor chain from [icon] up to, but not
/// including, the widget keyed [buttonKey], whose matrix entry (0, 0)
/// is negative. Null when no ancestor in that span mirrors on x.
Transform? _mirroringTransform(
  WidgetTester tester,
  Finder icon,
  Key buttonKey,
) {
  Transform? mirror;
  tester.element(icon).visitAncestorElements((Element ancestor) {
    final Widget widget = ancestor.widget;
    if (widget.key == buttonKey) {
      return false;
    }
    if (widget is Transform && widget.transform.entry(0, 0) < 0) {
      mirror = widget;
      return false;
    }
    return true;
  });
  return mirror;
}

void _expectMirror(
  WidgetTester tester,
  Key buttonKey,
  IconData icon,
  bool mirrored,
) {
  final Finder iconFinder = _iconUnder(buttonKey, icon);
  expect(
    iconFinder,
    findsOneWidget,
    reason:
        'fixture: $buttonKey must contain one Icon '
        '(code point ${icon.codePoint})',
  );
  final Transform? mirror = _mirroringTransform(tester, iconFinder, buttonKey);
  expect(
    mirror != null,
    mirrored,
    reason: mirrored
        ? '$buttonKey in this locale: the Icon must have a Transform '
              'ancestor under the button whose matrix entry (0, 0) is '
              'negative'
        : '$buttonKey in this locale: no Transform with a negative '
              'matrix entry (0, 0) may sit between the button and the Icon',
  );
}

void main() {
  testWidgets('ar: Icons.login_rounded under join-room-button has a Transform '
      'ancestor under the button whose matrix entry (0, 0) is negative', (
    tester,
  ) async {
    await _mountHome(tester, const Locale('ar'));
    expect(
      Directionality.of(tester.element(find.byType(HomeScreen))),
      TextDirection.rtl,
      reason: 'ar fixture: HomeScreen must be rtl',
    );
    _expectMirror(tester, _joinKey, Icons.login_rounded, true);
  });

  testWidgets('en: Icons.login_rounded under join-room-button has no Transform '
      'with a negative matrix entry (0, 0) between the button and the icon', (
    tester,
  ) async {
    await _mountHome(tester, const Locale('en'));
    expect(
      Directionality.of(tester.element(find.byType(HomeScreen))),
      TextDirection.ltr,
      reason: 'en fixture: HomeScreen must be ltr',
    );
    _expectMirror(tester, _joinKey, Icons.login_rounded, false);
  });

  testWidgets(
    'ar: the Create Room button icon has no Transform with a negative '
    'matrix entry (0, 0) between the button and the icon',
    (tester) async {
      await _mountHome(tester, const Locale('ar'));
      expect(
        Directionality.of(tester.element(find.byType(HomeScreen))),
        TextDirection.rtl,
        reason: 'ar fixture: HomeScreen must be rtl',
      );
      _expectMirror(tester, _createKey, Icons.add_rounded, false);
    },
  );
}
