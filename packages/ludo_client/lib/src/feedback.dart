// The feedback service: one place that turns a game event into a felt cue
// on three channels (doctrine P2, work/ludo/orders/C-225-feedback.md).
//
// [cuesForFrame] is the pure derivation from the wire (docs/PROTOCOL.md
// section 5) to the fixed vocabulary of [FeedbackCue]. It never imports
// anything from Flutter beyond `foundation` and never touches a platform
// channel, a clock or a file, so it is provable with plain frames in and a
// list of cues out. [FeedbackService] is the seam a screen calls `play` on;
// [PlatformFeedbackService] is the only implementation that actually
// vibrates or makes a sound, through the `app.fayad.ludo/feedback` method
// channel MainActivity.kt answers. [NoopFeedbackService] is what
// [FeedbackScope.of] hands back to a widget tree that never wired one in,
// so existing screen tests that build a bare `GameScreen` keep working.
//
// Wiring this service into the screens, and the settings switches
// themselves, are a later order. This file only builds the instrument.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/frame.dart';

/// The fixed vocabulary of felt game events, doctrine section 3 and
/// C-225. Stable names; [FeedbackCueId.id] gives the wire id tests and the
/// platform channel key on.
enum FeedbackCue {
  yourTurn,
  canMove,
  noMove,
  step,
  capturedOther,
  capturedMe,
  home,
  win,
  gameOver,
  invalidTap,
}

/// C-225's wire ids, one per [FeedbackCue], exactly as the Kotlin side and
/// the sound file names key on. A lookup table rather than a switch: these
/// are protocol identifiers, the same class of string as a `Frame.type`,
/// never player-visible text.
const Map<FeedbackCue, String> _cueIds = <FeedbackCue, String>{
  FeedbackCue.yourTurn: 'your_turn',
  FeedbackCue.canMove: 'can_move',
  FeedbackCue.noMove: 'no_move',
  FeedbackCue.step: 'step',
  FeedbackCue.capturedOther: 'captured_other',
  FeedbackCue.capturedMe: 'captured_me',
  FeedbackCue.home: 'home',
  FeedbackCue.win: 'win',
  FeedbackCue.gameOver: 'game_over',
  FeedbackCue.invalidTap: 'invalid_tap',
};

extension FeedbackCueId on FeedbackCue {
  String get id => _cueIds[this]!;
}

/// `data[key]` from a frame's `d`, when present and an `int`; null on a
/// missing field, a null field or a field of any other type. A frame this
/// permissive about never throws is a frame [cuesForFrame] can read without
/// a `try`.
int? _intAt(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  return value is int ? value : null;
}

/// `data[key]` as a `List`, when present and a `List` of any element type;
/// null otherwise. JSON decoding hands back `List<dynamic>`, so the check
/// is on `List`, not `List<Object?>`.
List<Object?>? _listAt(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  return value is List ? value.cast<Object?>() : null;
}

/// True when some entry of [captured] (`moved`'s `{"seat":int,"token":int}`
/// list) names [seat]. An entry that is not a map, or whose `seat` is
/// missing, is simply not a match; it does not invalidate the rest of the
/// list. A `seat` present but not an `int` is caught earlier, by
/// [_capturedHasMistypedSeat], and never reaches this function.
bool _capturedIncludesSeat(List<Object?> captured, int seat) {
  for (final Object? entry in captured) {
    if (entry is Map) {
      final Object? entrySeat = entry['seat'];
      if (entrySeat is int && entrySeat == seat) {
        return true;
      }
    }
  }
  return false;
}

/// True when [captured] holds an entry whose `seat` field is present but
/// not an `int`. PROTOCOL 12.2's captured entries are always
/// `{"seat":int,"token":int}`; a `seat` of the wrong type makes the whole
/// entry, and so the whole frame, untrustworthy (C-225's catch-all row: "a
/// field missing or of the wrong type -> []"), rather than something
/// [_capturedIncludesSeat] should silently skip past.
bool _capturedHasMistypedSeat(List<Object?> captured) {
  for (final Object? entry in captured) {
    if (entry is Map && entry.containsKey('seat') && entry['seat'] is! int) {
      return true;
    }
  }
  return false;
}

/// C-225's `moved` row, amended by C-259 rule 1: the frame itself plays no
/// step any more -- the board plays one `FeedbackCue.step` per square as
/// the drawn token actually arrives there (`game_screen.dart`'s
/// `onTokenStep`), not in one burst the instant this frame lands. Isolated
/// from [cuesForFrame] because it is the one frame type with two
/// independent branches (my move, someone else's) and an ordered list of
/// cues rather than at most one.
List<FeedbackCue> _cuesForMoved(Map<String, Object?> data, int mySeat) {
  final int? seat = _intAt(data, 'seat');
  if (seat == null) {
    return const <FeedbackCue>[];
  }
  // PROTOCOL 12.2: `captured` is always sent, empty when there is none.
  // Absent entirely, or present but not a list, is the wrong shape and
  // means the whole frame, not just the capture cue, is untrustworthy.
  final List<Object?>? captured = _listAt(data, 'captured');
  if (captured == null) {
    return const <FeedbackCue>[];
  }
  if (seat == mySeat) {
    final int? from = _intAt(data, 'from');
    final int? to = _intAt(data, 'to');
    if (from == null || to == null) {
      return const <FeedbackCue>[];
    }
    final List<FeedbackCue> cues = <FeedbackCue>[];
    if (captured.isNotEmpty) {
      cues.add(FeedbackCue.capturedOther);
    }
    if (to == 57) {
      cues.add(FeedbackCue.home);
    }
    return cues;
  }
  if (_capturedHasMistypedSeat(captured)) {
    return const <FeedbackCue>[];
  }
  return _capturedIncludesSeat(captured, mySeat)
      ? const <FeedbackCue>[FeedbackCue.capturedMe]
      : const <FeedbackCue>[];
}

/// C-225: the wire, one [Frame] at a time, to the cues it means for the
/// seat sitting at [mySeat]. Pure, total and silent on anything it does not
/// recognise: an unknown `type`, a missing or mistyped field, `turn_passed`
/// (its `noMove` already travelled with the `rolled` that caused it), a
/// null [mySeat], and another seat's routine move (doctrine section 3's
/// last line, "never fire haptics for other players' routine moves") all
/// answer `[]`, never an exception.
List<FeedbackCue> cuesForFrame(Frame frame, {required int? mySeat}) {
  if (mySeat == null) {
    return const <FeedbackCue>[];
  }
  final Map<String, Object?> data = frame.data;
  switch (frame.type) {
    case 'turn':
      return _intAt(data, 'seat') == mySeat
          ? const <FeedbackCue>[FeedbackCue.yourTurn]
          : const <FeedbackCue>[];
    case 'rolled':
      if (_intAt(data, 'seat') != mySeat) {
        return const <FeedbackCue>[];
      }
      final List<Object?>? legal = _listAt(data, 'legal');
      if (legal == null) {
        return const <FeedbackCue>[];
      }
      return legal.isEmpty
          ? const <FeedbackCue>[FeedbackCue.noMove]
          : const <FeedbackCue>[FeedbackCue.canMove];
    case 'moved':
      return _cuesForMoved(data, mySeat);
    case 'game_over':
      final int? winner = _intAt(data, 'winner');
      if (winner == null) {
        return const <FeedbackCue>[];
      }
      return winner == mySeat
          ? const <FeedbackCue>[FeedbackCue.win]
          : const <FeedbackCue>[FeedbackCue.gameOver];
    default:
      return const <FeedbackCue>[];
  }
}

/// The seam a screen plays a cue on. [play] never throws and never awaits
/// the platform: a screen calls it from an animation callback, not from an
/// `async` chain it has to keep alive.
abstract class FeedbackService {
  void play(FeedbackCue cue);
}

/// The service a widget tree gets when no [FeedbackScope] is above it, so
/// screen tests that build a bare `GameScreen` keep working (C-225).
class NoopFeedbackService implements FeedbackService {
  const NoopFeedbackService();

  @override
  void play(FeedbackCue cue) {}
}

/// The in-app switches, one per channel (doctrine P9: "haptics and sound
/// each have an in-app toggle and follow the system settings"). The system
/// settings themselves are honoured on the Android side, in `haptic` and
/// `sound`; this class only carries the player's own two switches.
///
/// [load] reads the persisted value and future writes through the setters
/// persist back; [forTest] never touches a platform channel, so a widget
/// test can build one synchronously.
class FeedbackSettings extends ChangeNotifier {
  FeedbackSettings._(this._haptics, this._sound, this._persist);

  /// A settings object that never reads or writes SharedPreferences, for
  /// widget and unit tests.
  factory FeedbackSettings.forTest({bool haptics = true, bool sound = true}) {
    return FeedbackSettings._(haptics, sound, false);
  }

  static const String _hapticsKey = 'feedback.haptics';
  static const String _soundKey = 'feedback.sound';

  bool _haptics;
  bool _sound;
  final bool _persist;

  bool get haptics => _haptics;

  set haptics(bool value) {
    _haptics = value;
    notifyListeners();
    if (_persist) {
      unawaited(_write(_hapticsKey, value));
    }
  }

  bool get sound => _sound;

  set sound(bool value) {
    _sound = value;
    notifyListeners();
    if (_persist) {
      unawaited(_write(_soundKey, value));
    }
  }

  static Future<void> _write(String key, bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// Reads `feedback.haptics` and `feedback.sound`; either absent reads as
  /// on, matching the "on by default" the doctrine's toggles start from.
  static Future<FeedbackSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return FeedbackSettings._(
      prefs.getBool(_hapticsKey) ?? true,
      prefs.getBool(_soundKey) ?? true,
      true,
    );
  }
}

/// C-225's platform-backed [FeedbackService]: a `play` turns into up to two
/// invocations (`haptic`, `sound`) of the `app.fayad.ludo/feedback` method
/// channel that MainActivity.kt answers, each gated on the matching
/// in-app switch in [settings]. `invalidTap` has no sound (doctrine
/// section 3's table: none). `step` is throttled independently per channel
/// to at most one call per [_stepThrottle]; a `step` inside the window is
/// dropped, not queued, so a fast run of squares does not pile up buzzes
/// behind the animation.
///
/// A `PlatformException` or `MissingPluginException` out of either
/// invocation (a device with no vibrator, a stub engine under test, a
/// channel with nothing listening) is caught here and never reaches the
/// player: every occurrence counts in [failedCalls], and the first one
/// per instance is named once with [debugPrint] so a developer sees it
/// without a logcat flooded by every later cue on the same unsupported
/// device.
class PlatformFeedbackService implements FeedbackService {
  PlatformFeedbackService(this.settings, [MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('app.fayad.ludo/feedback');

  static const Duration _stepThrottle = Duration(milliseconds: 60);

  final FeedbackSettings settings;
  final MethodChannel _channel;

  /// Every failed platform call, haptic or sound, counted so a test can
  /// assert a device without a vibrator still finished the game.
  int failedCalls = 0;

  bool _reportedFailure = false;

  // A step that plays closes its channel's gate and starts a [_stepThrottle]
  // timer that reopens it; a step arriving while the gate is closed is
  // dropped, not queued. A `Timer`, not `DateTime.now()`, so the gate obeys
  // whatever clock the caller runs on (including `fake_async` in tests).
  bool _stepHapticGateOpen = true;
  bool _stepSoundGateOpen = true;
  Timer? _stepHapticTimer;
  Timer? _stepSoundTimer;

  @override
  void play(FeedbackCue cue) {
    if (settings.haptics && _admitStep(cue, isHaptic: true)) {
      unawaited(_invoke('haptic', cue));
    }
    if (settings.sound &&
        cue != FeedbackCue.invalidTap &&
        _admitStep(cue, isHaptic: false)) {
      unawaited(_invoke('sound', cue));
    }
  }

  /// True when [cue] may play on this channel now. Only `step` is ever
  /// throttled; every other cue always passes.
  bool _admitStep(FeedbackCue cue, {required bool isHaptic}) {
    if (cue != FeedbackCue.step) {
      return true;
    }
    if (isHaptic) {
      if (!_stepHapticGateOpen) {
        return false;
      }
      _stepHapticGateOpen = false;
      _stepHapticTimer = Timer(_stepThrottle, () {
        _stepHapticGateOpen = true;
      });
    } else {
      if (!_stepSoundGateOpen) {
        return false;
      }
      _stepSoundGateOpen = false;
      _stepSoundTimer = Timer(_stepThrottle, () {
        _stepSoundGateOpen = true;
      });
    }
    return true;
  }

  /// Cancels the pending step-throttle timers. Call when this service is no
  /// longer wired to a widget tree, so a dangling `Timer` never fires after
  /// the screen it fed is gone.
  void dispose() {
    _stepHapticTimer?.cancel();
    _stepSoundTimer?.cancel();
  }

  Future<void> _invoke(String method, FeedbackCue cue) async {
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{
        'id': cue.id,
      });
    } on PlatformException catch (error) {
      _recordFailure(method, error);
    } on MissingPluginException catch (error) {
      _recordFailure(method, error);
    }
  }

  void _recordFailure(String method, Object error) {
    failedCalls++;
    if (!_reportedFailure) {
      _reportedFailure = true;
      debugPrint('FeedbackService.$method failed once: $error');
    }
  }
}

/// Carries a [FeedbackSettings] and the [FeedbackService] built from it
/// down a widget tree. [of] is the read side: a screen below a
/// [FeedbackScope] gets the real service, a screen built without one (a
/// bare widget test) gets a [NoopFeedbackService], never a null check the
/// caller has to write.
class FeedbackScope extends InheritedNotifier<FeedbackSettings> {
  const FeedbackScope({
    super.key,
    required FeedbackSettings settings,
    required this.service,
    required super.child,
  }) : super(notifier: settings);

  final FeedbackService service;

  static FeedbackService of(BuildContext context) {
    final FeedbackScope? scope = context
        .dependOnInheritedWidgetOfExactType<FeedbackScope>();
    return scope?.service ?? const NoopFeedbackService();
  }
}
