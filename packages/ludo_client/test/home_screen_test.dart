import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';

void main() {
  testWidgets('home screen renders and shows both actions', (tester) async {
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold));
    final loc = AppLocalizations.of(context);

    expect(find.text(loc.appTitle), findsOneWidget);
    expect(find.byKey(const Key('create-room-button')), findsOneWidget);
    expect(find.text(loc.homeCreateRoomButton), findsOneWidget);
    expect(find.byKey(const Key('join-room-button')), findsOneWidget);
    expect(find.text(loc.homeJoinRoomButton), findsOneWidget);
    expect(find.byKey(const Key('room-code-field')), findsOneWidget);
  });

  testWidgets(
    'Create Room navigates to the placeholder room screen with no code',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      final loc = AppLocalizations.of(context);

      await tester.tap(find.byKey(const Key('create-room-button')));
      await tester.pumpAndSettle();

      expect(find.text(loc.roomScreenNoCode), findsOneWidget);
      expect(find.text(loc.roomScreenNotImplemented), findsOneWidget);
    },
  );

  testWidgets(
    'Join Room with a valid, dictated code navigates to the room screen',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      final loc = AppLocalizations.of(context);

      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'ab2-3cd',
      );
      await tester.tap(find.byKey(const Key('join-room-button')));
      await tester.pumpAndSettle();

      expect(find.text(loc.roomScreenCodeLabel('AB23CD')), findsOneWidget);
      expect(find.text(loc.roomScreenNotImplemented), findsOneWidget);
    },
  );

  testWidgets(
    'Join Room with an invalid code shows an error and does not navigate',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      final loc = AppLocalizations.of(context);

      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'AB01CD',
      );
      await tester.tap(find.byKey(const Key('join-room-button')));
      await tester.pumpAndSettle();

      expect(find.text(loc.homeRoomCodeInvalid), findsOneWidget);
      expect(
        find.byKey(const Key('room-screen-not-implemented')),
        findsNothing,
      );
    },
  );

  testWidgets('the locale toggle switches the visible language', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    expect(find.text('Create Room'), findsOneWidget);

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();

    expect(find.text('Create Room'), findsNothing);
    expect(find.text('إنشاء غرفة'), findsOneWidget);
  });
}
