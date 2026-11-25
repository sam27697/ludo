// Proof for order 721 (optional Google sign-in), the home half. Written from
// docs/PROTOCOL.md section 36.6 and the keys and interfaces order 721 pins, not
// from the home's code.
//
// A real HomeScreen on the project's fake transport (support/c701_harness.dart)
// with `debugAccountServiceOverride` set to a service over fakes
// (support/c721_fakes.dart). Every row runs in English and Arabic (RTL) at
// 360x640. Waits are on conditions in fixed 50 ms steps, never pumpAndSettle.
//
// The order pins no arb key names, so the visible failure lines are found
// without them: the texts that appear on screen after a failed action are
// compared with the texts before it, and each new text must be a value of the
// locale's arb file (so it is localised, not hardcoded), in the locale's
// script, and different for `failed` and `unavailable`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/account.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/c701_harness.dart';
import 'support/c721_fakes.dart';
import 'support/home_flow.dart';

const String _file = 'c721_home_sign_in_test.dart';
const Key _signInKey = Key('home-google-sign-in');
const Key _chipKey = Key('home-account-chip');
const Key _sheetKey = Key('account-sheet');
const Key _signOutKey = Key('account-sheet-sign-out');
const Key _deleteKey = Key('account-sheet-delete');
const Key _confirmKey = Key('account-delete-confirm');
const Key _cancelKey = Key('account-delete-cancel');

const Size _phone = Size(360, 640);
const List<C701Variant> _variants = <C701Variant>[
  C701Variant(Locale('en'), _phone),
  C701Variant(Locale('ar'), _phone),
];

final RegExp _arabicLetter = RegExp(r'[؀-ۿ]');

Set<String> _arbValues(String lang) {
  final File f = File('lib/l10n/app_$lang.arb');
  final Map<String, Object?> json =
      jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  return <String>{
    for (final MapEntry<String, Object?> e in json.entries)
      if (!e.key.startsWith('@') && e.value is String) e.value! as String,
  };
}

Set<String> _visibleTexts(WidgetTester t) => <String>{
  for (final Text w in t.widgetList<Text>(
    find.byType(Text, skipOffstage: false),
  ))
    if ((w.data ?? w.textSpan?.toPlainText() ?? '').trim().isNotEmpty)
      (w.data ?? w.textSpan!.toPlainText()).trim(),
};

class C721Home {
  C721Home(this.rig, this.parts, this.service);

  final C721Rig rig;
  final C721Parts parts;
  final AccountService service;

  WidgetTester get t => rig.tester;
}

class C721Rig extends C701Rig {
  C721Rig(
    super.tester,
    super.variant, {
    required super.file,
    required super.row,
  });
}

String _name(WidgetTester t) =>
    t.widget<TextField>(find.byKey(homeNameFieldKey)).controller!.text;

/// Registers one row per variant. [signedIn] seeds the device record,
/// [clientId] the fake config answer, [typed] the saved player name, and
/// [build] may swap in a scripted service.
void row(
  String name,
  Future<void> Function(C721Home h) body, {
  bool signedIn = false,
  String? clientId = kC721ClientId,
  String? typed,
  AccountService Function(C721Parts p)? build,
}) {
  for (final C701Variant v in _variants) {
    final String full = '${v.id}: $name';
    testWidgets(full, (WidgetTester tester) async {
      final C721Rig rig = C721Rig(tester, v, file: _file, row: full);
      final C721Parts parts = C721Parts(clientId: clientId);
      final AccountService service = build == null
          ? parts.service
          : build(parts);
      debugAccountServiceOverride = service;
      addTearDown(() {
        debugAccountServiceOverride = null;
        debugGoogleSignedInOverride = null;
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        'session.lastName': ?typed,
        if (signedIn) 'account.signed_in': true,
        if (signedIn) 'account.name': 'Layla Google',
      });
      await tester.runAsync(service.load);
      try {
        await rig.mount(keepPrefs: true);
        await body(C721Home(rig, parts, service));
      } finally {
        await rig.finish();
      }
    });
  }
}

void _expectAtLeast48(C721Rig r, Key key, String what) {
  final Size s = r.tester.getSize(find.byKey(key));
  expect(
    s.width >= 47.5 && s.height >= 47.5,
    isTrue,
    reason:
        '$what ($key) is ${s.width.toStringAsFixed(1)} x '
        '${s.height.toStringAsFixed(1)} dp, expected at least 48 x 48. '
        '${r.repro}',
  );
}

void _expectFullyOnScreen(C721Rig r, Key key, String what) {
  final Finder f = find.byKey(key);
  expect(f, findsOneWidget, reason: '$what ($key) not found. ${r.repro}');
  final Rect rect = r.tester.getRect(f);
  expect(
    rect.left >= -0.5 &&
        rect.top >= -0.5 &&
        rect.right <= _phone.width + 0.5 &&
        rect.bottom <= _phone.height + 0.5,
    isTrue,
    reason:
        '$what ($key) is at $rect, outside the ${_phone.width}x${_phone.height} '
        'screen. ${r.repro}',
  );
}

Future<void> _signInByTap(C721Home h) async {
  await h.rig.tap(find.byKey(_signInKey), what: 'home-google-sign-in');
  await pumpUntilFound(
    h.t,
    find.byKey(_chipKey),
    what: 'home-account-chip after the sign-in tap. ${h.rig.repro}',
  );
}

Future<void> _openSheet(C721Home h) async {
  await h.rig.tap(find.byKey(_chipKey), what: 'home-account-chip');
  await pumpUntilAtRest(
    h.t,
    find.byKey(_sheetKey),
    what: 'account-sheet. ${h.rig.repro}',
  );
}

Future<void> _openConfirm(C721Home h) async {
  await _openSheet(h);
  await h.rig.tap(find.byKey(_deleteKey), what: 'account-sheet-delete');
  await pumpUntilAtRest(
    h.t,
    find.byKey(_confirmKey),
    what: 'account-delete-confirm. ${h.rig.repro}',
  );
}

/// Taps [key], then collects every text that was not on screen before, over
/// 1.5 s of fixed steps.
Future<Set<String>> _newTextsAfterTap(C721Home h, Key key) async {
  final Set<String> before = _visibleTexts(h.t);
  await h.rig.tap(find.byKey(key), what: '$key');
  final Set<String> seen = <String>{};
  for (int i = 0; i < 30; i++) {
    seen.addAll(_visibleTexts(h.t).difference(before));
    await h.t.pump(const Duration(milliseconds: 50));
  }
  return seen;
}

void _expectLocalisedLine(C721Home h, Set<String> fresh, String what) {
  final String lang = h.rig.variant.lang;
  final Set<String> arb = _arbValues(lang);
  final List<String> lines = fresh.where(arb.contains).toList();
  expect(
    lines,
    isNotEmpty,
    reason:
        '$what: expected a visible line that is a value of app_$lang.arb, '
        'new texts on screen were $fresh. ${h.rig.repro}',
  );
  for (final String line in lines) {
    final bool arabic = _arabicLetter.hasMatch(line);
    expect(
      arabic,
      lang == 'ar',
      reason:
          '$what: the line "$line" is in the wrong script for $lang. '
          '${h.rig.repro}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugAccountServiceOverride = null;
    debugGoogleSignedInOverride = null;
  });

  group('not available', () {
    row('config null: no sign-in control, the two buttons stay', (
      C721Home h,
    ) async {
      expect(
        find.byKey(_signInKey),
        findsNothing,
        reason: 'sign-in control shown with sign-in off. ${h.rig.repro}',
      );
      expect(
        find.byKey(_chipKey),
        findsNothing,
        reason: 'chip shown while signed out. ${h.rig.repro}',
      );
      expect(
        find.byKey(createRoomButtonKey),
        findsOneWidget,
        reason: 'create button missing. ${h.rig.repro}',
      );
      expect(
        find.byKey(joinGameButtonKey),
        findsOneWidget,
        reason: 'join button missing. ${h.rig.repro}',
      );
      expect(
        h.parts.http.posts,
        isEmpty,
        reason: 'a POST was made by home. ${h.rig.repro}',
      );
    }, clientId: null);

    row(
      'config answer not understood: still no control',
      (C721Home h) async {
        expect(
          find.byKey(_signInKey),
          findsNothing,
          reason: 'control shown after a 500 config. ${h.rig.repro}',
        );
      },
      build: (C721Parts p) {
        p.http.setRoute('/auth/config', 500, '{"code":"X"}');
        return p.service;
      },
    );

    row(
      'config call that throws: still no control',
      (C721Home h) async {
        expect(
          find.byKey(_signInKey),
          findsNothing,
          reason: 'control shown after a thrown config. ${h.rig.repro}',
        );
      },
      build: (C721Parts p) {
        p.http.throwOn.add('/auth/config');
        return p.service;
      },
    );

    row(
      'signed-in record with sign-in off still shows the chip',
      (C721Home h) async {
        expect(
          find.byKey(_signInKey),
          findsNothing,
          reason: 'sign-in control shown to a signed-in player. ${h.rig.repro}',
        );
        expect(
          find.byKey(_chipKey),
          findsOneWidget,
          reason:
              'a player signed in on this device must keep the chip even '
              'when the config is off, or they cannot sign out or delete. '
              '${h.rig.repro}',
        );
      },
      clientId: null,
      signedIn: true,
    );
  });

  group('available', () {
    row('shows the sign-in control, no chip, and nothing is sent yet', (
      C721Home h,
    ) async {
      expect(
        find.byKey(_signInKey),
        findsOneWidget,
        reason: 'no home-google-sign-in with sign-in on. ${h.rig.repro}',
      );
      expect(
        find.byKey(_chipKey),
        findsNothing,
        reason: 'chip shown while signed out. ${h.rig.repro}',
      );
      expect(
        h.parts.http.posts,
        isEmpty,
        reason: 'home posted before any tap. ${h.rig.repro}',
      );
      expect(
        h.parts.google.clientIds,
        isEmpty,
        reason: 'home asked Google before any tap. ${h.rig.repro}',
      );
    });

    row('tap signs in, shows the chip and the Google name in the name row', (
      C721Home h,
    ) async {
      await _signInByTap(h);
      expect(
        find.byKey(_signInKey),
        findsNothing,
        reason: 'control still shown once signed in. ${h.rig.repro}',
      );
      expect(
        _name(h.t),
        'Layla Google',
        reason:
            'name field must show the Google name, shows "${_name(h.t)}". '
            '${h.rig.repro}',
      );
      expect(
        h.parts.http.to('/auth/google').length,
        1,
        reason:
            'expected one POST /auth/google: ${h.parts.http.describe()}. '
            '${h.rig.repro}',
      );
      expect(
        googleSignedIn,
        isTrue,
        reason: 'googleSignedIn false after sign-in. ${h.rig.repro}',
      );
    });

    row('an empty Google name leaves the typed name in the field', (
      C721Home h,
    ) async {
      h.parts.http.signInAnswers(name: '');
      await _signInByTap(h);
      expect(
        _name(h.t),
        'Nour',
        reason: 'typed name lost, field shows "${_name(h.t)}". ${h.rig.repro}',
      );
    }, typed: 'Nour');

    row('chip opens the account sheet with sign out and delete', (
      C721Home h,
    ) async {
      expect(
        find.byKey(_chipKey),
        findsOneWidget,
        reason: 'no chip for a signed-in player. ${h.rig.repro}',
      );
      await _openSheet(h);
      expect(
        find.byKey(_signOutKey),
        findsOneWidget,
        reason: 'no account-sheet-sign-out. ${h.rig.repro}',
      );
      expect(
        find.byKey(_deleteKey),
        findsOneWidget,
        reason: 'no account-sheet-delete. ${h.rig.repro}',
      );
      expect(
        find.byKey(_confirmKey),
        findsNothing,
        reason: 'the confirm is shown before delete was tapped. ${h.rig.repro}',
      );
    }, signedIn: true);

    row('sign out from the sheet: local only, control returns', (
      C721Home h,
    ) async {
      await _openSheet(h);
      final int calls = h.parts.http.calls.length;
      await h.rig.tap(find.byKey(_signOutKey), what: 'account-sheet-sign-out');
      await pumpUntilGone(
        h.t,
        find.byKey(_chipKey),
        what: 'chip after sign out. ${h.rig.repro}',
      );
      await pumpUntilGone(
        h.t,
        find.byKey(_sheetKey),
        what: 'sheet after sign out. ${h.rig.repro}',
      );
      expect(
        find.byKey(_signInKey),
        findsOneWidget,
        reason: 'sign-in control did not come back. ${h.rig.repro}',
      );
      expect(
        h.parts.http.calls.length,
        calls,
        reason:
            'sign out used the network: ${h.parts.http.describe()}. '
            '${h.rig.repro}',
      );
      expect(
        h.parts.google.signOutCalls,
        1,
        reason: 'google.signOut not called once. ${h.rig.repro}',
      );
      expect(
        googleSignedIn,
        isFalse,
        reason: 'googleSignedIn still true. ${h.rig.repro}',
      );
    }, signedIn: true);

    row('delete: confirm step, then confirm sends and signs out', (
      C721Home h,
    ) async {
      await _openConfirm(h);
      expect(
        h.parts.http.to('/account/delete'),
        isEmpty,
        reason: 'delete sent before the confirm. ${h.rig.repro}',
      );
      expect(
        find.byKey(_cancelKey),
        findsOneWidget,
        reason: 'no account-delete-cancel. ${h.rig.repro}',
      );
      await h.rig.tap(find.byKey(_confirmKey), what: 'account-delete-confirm');
      await pumpUntilGone(
        h.t,
        find.byKey(_chipKey),
        what: 'chip after delete. ${h.rig.repro}',
      );
      expect(
        h.parts.http.to('/account/delete').length,
        1,
        reason:
            'expected one POST /account/delete: ${h.parts.http.describe()}. '
            '${h.rig.repro}',
      );
      expect(
        find.byKey(_signInKey),
        findsOneWidget,
        reason:
            'sign-in control did not come back after delete. ${h.rig.repro}',
      );
      expect(
        googleSignedIn,
        isFalse,
        reason: 'still signed in after delete. ${h.rig.repro}',
      );
    }, signedIn: true);

    row(
      'delete answered deleted:false also signs out',
      (C721Home h) async {
        await _openConfirm(h);
        await h.rig.tap(
          find.byKey(_confirmKey),
          what: 'account-delete-confirm',
        );
        await pumpUntilGone(
          h.t,
          find.byKey(_chipKey),
          what: 'chip after delete. ${h.rig.repro}',
        );
        expect(
          googleSignedIn,
          isFalse,
          reason: 'still signed in. ${h.rig.repro}',
        );
      },
      signedIn: true,
      build: (C721Parts p) {
        p.http.deleteAnswers(deleted: false);
        return p.service;
      },
    );

    row('cancel in the confirm sends nothing and stays signed in', (
      C721Home h,
    ) async {
      await _openConfirm(h);
      await h.rig.tap(find.byKey(_cancelKey), what: 'account-delete-cancel');
      await pumpUntilGone(
        h.t,
        find.byKey(_confirmKey),
        what: 'confirm after cancel. ${h.rig.repro}',
      );
      expect(
        h.parts.http.to('/account/delete'),
        isEmpty,
        reason: 'a delete was sent after cancel. ${h.rig.repro}',
      );
      expect(
        h.parts.google.clientIds,
        isEmpty,
        reason: 'Google was asked for a token after cancel. ${h.rig.repro}',
      );
      expect(
        googleSignedIn,
        isTrue,
        reason: 'signed out by a cancel. ${h.rig.repro}',
      );
      expect(
        find.byKey(_chipKey),
        findsOneWidget,
        reason: 'chip gone after cancel. ${h.rig.repro}',
      );
    }, signedIn: true);

    row(
      'a failed delete says so and keeps the player signed in',
      (C721Home h) async {
        await _openConfirm(h);
        final Set<String> fresh = await _newTextsAfterTap(h, _confirmKey);
        expect(
          googleSignedIn,
          isTrue,
          reason: 'a failed delete signed the player out. ${h.rig.repro}',
        );
        _expectLocalisedLine(h, fresh, 'failed delete');
      },
      signedIn: true,
      build: (C721Parts p) {
        p.http.errorAnswer('/account/delete', 401, 'BAD_TOKEN');
        return p.service;
      },
    );

    row(
      'a failed sign-in shows a visible localised line, stays signed out',
      (C721Home h) async {
        final Set<String> fresh = await _newTextsAfterTap(h, _signInKey);
        expect(
          googleSignedIn,
          isFalse,
          reason: 'signed in after a 401. ${h.rig.repro}',
        );
        expect(
          find.byKey(_chipKey),
          findsNothing,
          reason: 'chip shown after a failed sign-in. ${h.rig.repro}',
        );
        _expectLocalisedLine(h, fresh, 'failed sign-in');
      },
      build: (C721Parts p) {
        p.http.errorAnswer('/auth/google', 401, 'BAD_TOKEN');
        return p.service;
      },
    );

    row(
      'a cancelled sign-in is silent and posts nothing',
      (C721Home h) async {
        final Set<String> fresh = await _newTextsAfterTap(h, _signInKey);
        final Set<String> arb = _arbValues(h.rig.variant.lang);
        expect(
          h.parts.http.posts,
          isEmpty,
          reason: 'a POST after the player backed out. ${h.rig.repro}',
        );
        expect(
          googleSignedIn,
          isFalse,
          reason: 'signed in after backing out. ${h.rig.repro}',
        );
        expect(
          fresh.where(arb.contains),
          isEmpty,
          reason:
              'backing out is not an error, yet new lines appeared: '
              '${fresh.where(arb.contains).toList()}. ${h.rig.repro}',
        );
        expect(
          find.byKey(_signInKey),
          findsOneWidget,
          reason: 'control gone after backing out. ${h.rig.repro}',
        );
      },
      build: (C721Parts p) {
        p.google.cancel = true;
        return p.service;
      },
    );

    row(
      'failed and unavailable have their own words',
      (C721Home h) async {
        final ScriptedAccountService s = h.service as ScriptedAccountService;
        s.signInOutcome = AccountOutcome.failed;
        final Set<String> failed = await _newTextsAfterTap(h, _signInKey);
        s.signInOutcome = AccountOutcome.unavailable;
        await h.t.pump(const Duration(seconds: 12));
        final Set<String> before = _visibleTexts(h.t);
        final Set<String> seen = <String>{};
        await h.rig.tap(find.byKey(_signInKey), what: 'home-google-sign-in');
        for (int i = 0; i < 30; i++) {
          seen.addAll(_visibleTexts(h.t));
          await h.t.pump(const Duration(milliseconds: 50));
        }
        final Set<String> arb = _arbValues(h.rig.variant.lang);
        final Set<String> unavailableLines = seen
            .where((String s) => arb.contains(s))
            .toSet();
        final Set<String> failedLines = failed.where(arb.contains).toSet();
        _expectLocalisedLine(h, failed, 'failed');
        expect(
          unavailableLines.difference(before.where(arb.contains).toSet()),
          isNotEmpty,
          reason: 'unavailable showed no new line. ${h.rig.repro}',
        );
        expect(
          unavailableLines.difference(before).difference(failedLines),
          isNotEmpty,
          reason:
              'unavailable shows only the words of failed ($failedLines); '
              'the order gives them their own. ${h.rig.repro}',
        );
      },
      build: (C721Parts p) => ScriptedAccountService(
        origin: kC721Origin,
        google: p.google,
        http: p.http.call,
      ),
    );
  });

  group('layout and access', () {
    row('360x640: both main buttons fully on screen with the control shown', (
      C721Home h,
    ) async {
      _expectFullyOnScreen(h.rig, _signInKey, 'sign-in control');
      _expectFullyOnScreen(h.rig, createRoomButtonKey, 'create button');
      _expectFullyOnScreen(h.rig, joinGameButtonKey, 'join button');
      h.rig.expectNoOverflow('home with the sign-in control');
    });

    row('360x640: both main buttons fully on screen with the chip shown', (
      C721Home h,
    ) async {
      _expectFullyOnScreen(h.rig, _chipKey, 'account chip');
      _expectFullyOnScreen(h.rig, createRoomButtonKey, 'create button');
      _expectFullyOnScreen(h.rig, joinGameButtonKey, 'join button');
      h.rig.expectNoOverflow('home with the chip');
    }, signedIn: true);

    row('the sign-in control is at least 48x48 and mirrored in Arabic', (
      C721Home h,
    ) async {
      _expectAtLeast48(h.rig, _signInKey, 'sign-in control');
      final TextDirection dir = Directionality.of(
        h.t.element(find.byKey(_signInKey)),
      );
      expect(
        dir,
        h.rig.variant.lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        reason: 'sign-in control has the wrong direction. ${h.rig.repro}',
      );
    });

    row('the sign-in control reads in the locale, not as a logo', (
      C721Home h,
    ) async {
      final Set<String> arb = _arbValues(h.rig.variant.lang);
      final List<String> words = <String>[
        for (final Text w in h.t.widgetList<Text>(
          find.descendant(
            of: find.byKey(_signInKey),
            matching: find.byType(Text),
          ),
        ))
          (w.data ?? w.textSpan?.toPlainText() ?? '').trim(),
      ];
      expect(
        words,
        isNotEmpty,
        reason:
            'the control carries no words (a meta action, text allowed '
            'and required). ${h.rig.repro}',
      );
      expect(
        words.where(arb.contains),
        isNotEmpty,
        reason:
            'the control text $words is not an arb value for '
            '${h.rig.variant.lang}. ${h.rig.repro}',
      );
    });

    row('the chip is at least 48x48 and has a spoken label', (
      C721Home h,
    ) async {
      _expectAtLeast48(h.rig, _chipKey, 'account chip');
      final SemanticsHandle handle = h.t.ensureSemantics();
      try {
        final SemanticsNode node = h.t.getSemantics(find.byKey(_chipKey));
        expect(
          node.label.trim(),
          isNotEmpty,
          reason: 'the chip has no TalkBack label. ${h.rig.repro}',
        );
      } finally {
        handle.dispose();
      }
    }, signedIn: true);

    row('every tappable in the sheet and the confirm is at least 48x48', (
      C721Home h,
    ) async {
      await _openSheet(h);
      _expectAtLeast48(h.rig, _signOutKey, 'sign out');
      _expectAtLeast48(h.rig, _deleteKey, 'delete');
      await h.rig.tap(find.byKey(_deleteKey), what: 'account-sheet-delete');
      await pumpUntilAtRest(
        h.t,
        find.byKey(_confirmKey),
        what: 'account-delete-confirm. ${h.rig.repro}',
      );
      _expectAtLeast48(h.rig, _confirmKey, 'confirm');
      _expectAtLeast48(h.rig, _cancelKey, 'cancel');
      _expectFullyOnScreen(h.rig, _confirmKey, 'confirm');
      _expectFullyOnScreen(h.rig, _cancelKey, 'cancel');
      h.rig.expectNoOverflow('delete confirm at 360x640');
    }, signedIn: true);

    row('the delete confirm says it cannot be undone, in the locale', (
      C721Home h,
    ) async {
      final Set<String> before = _visibleTexts(h.t);
      await _openConfirm(h);
      final Set<String> fresh = _visibleTexts(h.t).difference(before);
      final Set<String> arb = _arbValues(h.rig.variant.lang);
      final List<String> lines = fresh.where(arb.contains).toList();
      expect(
        lines.length,
        greaterThanOrEqualTo(2),
        reason:
            'the confirm should carry a title and a body from the arb, '
            'new texts were $fresh. ${h.rig.repro}',
      );
      for (final String l in lines) {
        expect(
          _arabicLetter.hasMatch(l),
          h.rig.variant.lang == 'ar',
          reason: 'line "$l" is in the wrong script. ${h.rig.repro}',
        );
      }
    }, signedIn: true);
  });
}
