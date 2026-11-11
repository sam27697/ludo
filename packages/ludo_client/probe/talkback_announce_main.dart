// Order 623 (X170 step 2): a probe entry point, not part of the app. It lives
// outside lib/ so nothing here ships, and is built only by
// .github/workflows/talkback-probe.yml with
//
//   flutter build apk --profile -t probe/talkback_announce_main.dart
//
// It plays a fixed script of announcement cases on one screen, each with a
// unique text, while TalkBack runs on the emulator. tool/talkback_probe/
// probe.sh then counts how many times TalkBack spoke each text.
//
// The question: the game speaks every line through
// SemanticsService.sendAnnouncement, which Android 16 deprecated. The fix under
// consideration adds a polite live region carrying the same line. Does TalkBack
// speak that pair once or twice?
//
// The cases:
//   A  sendAnnouncement only
//   B  live region only (label empty -> text)
//   C  both in the same synchronous callback, same text
//   D  both, the live region set 300 ms after the announcement
//   E  live region set, cleared 1.5 s later, set to the SAME text 2 s after that
//   F  case C in Arabic, right-to-left
//
// Order 627 adds five cases with two different lines each (X179: what does
// TalkBack speak when a second line follows the first within a frame or so):
//   G  live region only, line 1, one frame later line 2
//   H  live region only, line 1, 300 ms later line 2
//   I  sendAnnouncement only, line 1 and line 2 in the same frame
//   J  today's app shape: both announcements, then the live region set to
//      line 2, all in the same frame
//   K  the fix under consideration: announcement and live region for line 1,
//      one frame later announcement and live region for line 2
//
// A live region is cleared 1.5 s after it was set in every case that uses one,
// the way the fix under consideration would do it.
//
// The announcement call has the shape of game_screen.dart _announce:
// SemanticsService.sendAnnouncement(View.of(context), message,
// Directionality.of(context)). Case F switches the MaterialApp locale to
// Arabic, so Directionality.of(context) is right to left there the same way it
// is in the game under the Arabic locale.
//
// Every case writes one line to logcat (tag "flutter") that the counting script
// reads, so the case list exists in this file only:
//   LUDO_PROBE_CASE_START|<letter>|<description>|<text>
// and a case with two lines writes both texts, separated by another bar:
//   LUDO_PROBE_CASE_START|<letter>|<description>|<text 1>|<text 2>
// The end of the script writes LUDO_PROBE_DONE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Time the screen sits idle before case A, so TalkBack's own start-up speech
/// (window title, first focus) is over.
const Duration _settle = Duration(seconds: 10);

/// Spacing between the start of one case and the start of the next.
const Duration _slot = Duration(seconds: 5);

/// Case E needs 1.5 s + 2 s before its second utterance and that utterance
/// needs about a second to be spoken, so it gets a longer slot than the others.
const Duration _slotE = Duration(seconds: 8);

/// How long a live region keeps its text before it is cleared.
const Duration _liveHold = Duration(milliseconds: 1500);

/// Gap between clearing the live region and setting the same text again, case E.
const Duration _repeatGap = Duration(seconds: 2);

/// Offset of the live region after the announcement, case D.
const Duration _lateLive = Duration(milliseconds: 300);

/// Offset of the second line after the first, case H.
const Duration _secondLine = Duration(milliseconds: 300);

/// Pause between the locale going back to English at the end of case F and the
/// start of case G, so the direction has reached the tree.
const Duration _localeBack = Duration(milliseconds: 300);

const Duration _tail = Duration(seconds: 5);

void main() {
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final ValueNotifier<Locale> _locale = ValueNotifier<Locale>(
    const Locale('en'),
  );

  @override
  void dispose() {
    _locale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: _locale,
      builder: (BuildContext context, Locale locale, Widget? child) {
        return MaterialApp(
          title: 'Announce probe',
          locale: locale,
          supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child,
        );
      },
      child: _ProbeScreen(locale: _locale),
    );
  }
}

class _ProbeScreen extends StatefulWidget {
  const _ProbeScreen({required this.locale});

  final ValueNotifier<Locale> locale;

  @override
  State<_ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<_ProbeScreen> {
  String _live = '';
  String _caseName = 'waiting';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(_settle);
    await _caseA();
    await _caseB();
    await _caseC();
    await _caseD();
    await _caseE();
    await _caseF();
    await Future<void>.delayed(_localeBack);
    await _caseG();
    await _caseH();
    await _caseI();
    await _caseJ();
    await _caseK();
    await Future<void>.delayed(_tail);
    _log('LUDO_PROBE_DONE');
    if (mounted) {
      setState(() => _caseName = 'done');
    }
  }

  void _log(String line) {
    debugPrint(line);
  }

  void _start(String letter, String description, String text, [String? next]) {
    if (!mounted) {
      return;
    }
    final String texts = next == null ? text : '$text|$next';
    _log('LUDO_PROBE_CASE_START|$letter|$description|$texts');
    setState(() {
      _caseName = letter;
    });
  }

  void _announce(String text) {
    if (!mounted) {
      return;
    }
    SemanticsService.sendAnnouncement(
      View.of(context),
      text,
      Directionality.of(context),
    );
  }

  void _setLive(String text) {
    if (!mounted) {
      return;
    }
    setState(() => _live = text);
  }

  void _clearLiveAfterHold() {
    Timer(_liveHold, () => _setLive(''));
  }

  Future<void> _caseA() async {
    const String text = 'probe alpha one';
    _start('A', 'sendAnnouncement only', text);
    _announce(text);
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseB() async {
    const String text = 'probe bravo two';
    _start('B', 'live region only', text);
    _setLive(text);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseC() async {
    const String text = 'probe charlie three';
    _start('C', 'both at the same frame', text);
    _announce(text);
    _setLive(text);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseD() async {
    const String text = 'probe delta four';
    _start('D', 'both, live region 300 ms after the announcement', text);
    _announce(text);
    await Future<void>.delayed(_lateLive);
    _setLive(text);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot - _lateLive);
  }

  Future<void> _caseE() async {
    const String text = 'probe echo five';
    _start('E', 'live region set, cleared, set to the same text again', text);
    _setLive(text);
    await Future<void>.delayed(_liveHold);
    _setLive('');
    await Future<void>.delayed(_repeatGap);
    _setLive(text);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slotE - _liveHold - _repeatGap);
  }

  Future<void> _caseF() async {
    // Arabic, "now it is your turn".
    const String text =
        'حان دورك '
        'الآن';
    widget.locale.value = const Locale('ar');
    // Let the new direction reach the tree before the call reads it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _start('F', 'case C in Arabic, right to left', text);
    _announce(text);
    _setLive(text);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
    widget.locale.value = const Locale('en');
  }

  Future<void> _caseG() async {
    const String one = 'probe golf one';
    const String two = 'probe golf two';
    _start('G', 'live region only, line 2 one frame after line 1', one, two);
    _setLive(one);
    await WidgetsBinding.instance.endOfFrame;
    _setLive(two);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseH() async {
    const String one = 'probe hotel one';
    const String two = 'probe hotel two';
    _start('H', 'live region only, line 2 300 ms after line 1', one, two);
    _setLive(one);
    await Future<void>.delayed(_secondLine);
    _setLive(two);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseI() async {
    const String one = 'probe india one';
    const String two = 'probe india two';
    _start('I', 'sendAnnouncement only, two lines in the same frame', one, two);
    _announce(one);
    _announce(two);
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseJ() async {
    const String one = 'probe juliet one';
    const String two = 'probe juliet two';
    _start(
      'J',
      'two announcements and the live region on line 2, same frame',
      one,
      two,
    );
    _announce(one);
    _announce(two);
    _setLive(two);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
  }

  Future<void> _caseK() async {
    const String one = 'probe kilo one';
    const String two = 'probe kilo two';
    _start(
      'K',
      'announcement and live region per line, one frame apart',
      one,
      two,
    );
    _announce(one);
    _setLive(one);
    await WidgetsBinding.instance.endOfFrame;
    _announce(two);
    _setLive(two);
    _clearLiveAfterHold();
    await Future<void>.delayed(_slot);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Announce probe')),
      body: Column(
        children: <Widget>[
          // Nothing here may carry a probe text, so what TalkBack says about
          // the cases comes from the two channels only.
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('case $_caseName'),
            ),
          ),
          Semantics(
            liveRegion: true,
            label: _live,
            textDirection: Directionality.of(context),
            child: const SizedBox(height: 48, width: double.infinity),
          ),
        ],
      ),
    );
  }
}
