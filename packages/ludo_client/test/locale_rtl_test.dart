import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/app.dart';

void main() {
  testWidgets('Arabic locale resolves to right-to-left text direction', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold));
    expect(Directionality.of(context), TextDirection.rtl);
  });

  testWidgets('English locale resolves to left-to-right text direction', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp(initialLocale: Locale('en')));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold));
    expect(Directionality.of(context), TextDirection.ltr);
  });

  testWidgets('the locale toggle flips text direction along with language', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    var context = tester.element(find.byType(Scaffold));
    expect(Directionality.of(context), TextDirection.ltr);

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();

    context = tester.element(find.byType(Scaffold));
    expect(Directionality.of(context), TextDirection.rtl);
  });
}
