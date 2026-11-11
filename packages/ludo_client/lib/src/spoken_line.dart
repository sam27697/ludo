import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// How long a spoken line stays in the region before it clears.
const Duration kSpokenLineHold = Duration(milliseconds: 1500);

/// The key of the region's root, so a test or a screen can find it.
const Key kSpokenLineRegionKey = Key('spoken-line-region');

/// C-624 D3: the text a screen's polite live region holds. Every line a
/// screen sends with `SemanticsService.sendAnnouncement` is also given to
/// [speak], so TalkBack still hears it if the announcement event is ever
/// dropped. The line is held for [kSpokenLineHold] and then clears, so a
/// swipe through the screen never lands on a stale node.
class SpokenLineController extends ChangeNotifier {
  String _current = '';
  Timer? _holdTimer;
  int _generation = 0;
  bool _disposed = false;
  bool _notifyPending = false;

  /// The line the region shows now, or '' when nothing is held.
  String get current => _current;

  /// Shows [line] from the next frame on and clears it after
  /// [kSpokenLineHold]. A different line replaces the held one at once and
  /// restarts the hold. The same line while it is still held clears the
  /// region for one frame first, because only a change of the label is
  /// spoken. An empty line is ignored.
  void speak(String line) {
    if (_disposed || line.isEmpty) {
      return;
    }
    _generation += 1;
    final int generation = _generation;
    _holdTimer?.cancel();
    _holdTimer = Timer(kSpokenLineHold, () {
      _holdTimer = null;
      _set('');
    });
    if (_current == line) {
      // The region must be drawn empty for one frame before the line comes
      // back. A clear made mid-build tells its listener only after that
      // frame, so the line waits one frame more.
      final bool deferred =
          SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks;
      _set('');
      void showAgain(Duration stamp) {
        if (_disposed || generation != _generation) {
          return;
        }
        _set(line);
      }

      SchedulerBinding.instance.addPostFrameCallback((Duration stamp) {
        if (deferred) {
          SchedulerBinding.instance.addPostFrameCallback(showAgain);
          SchedulerBinding.instance.ensureVisualUpdate();
        } else {
          showAgain(stamp);
        }
      });
      SchedulerBinding.instance.ensureVisualUpdate();
      return;
    }
    _set(line);
  }

  void _set(String value) {
    if (_disposed || _current == value) {
      return;
    }
    _current = value;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // Some of a screen's lines are spoken while it builds, and a listener
      // cannot be marked dirty mid-build: tell it after this frame.
      if (!_notifyPending) {
        _notifyPending = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _notifyPending = false;
          if (!_disposed) {
            notifyListeners();
          }
        });
        SchedulerBinding.instance.ensureVisualUpdate();
      }
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    super.dispose();
  }
}

/// C-624 D2: one polite live region that paints nothing, takes no taps and
/// takes no layout space (a single logical pixel, drawn transparent, placed
/// by its screen). While [SpokenLineController.current] is empty the tree
/// holds no semantics node from it at all. The node carries the
/// surrounding [Directionality] so an Arabic line is read right to left.
class SpokenLineRegion extends StatelessWidget {
  const SpokenLineRegion({super.key, required this.controller});

  final SpokenLineController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final String line = controller.current;
        return IgnorePointer(
          key: kSpokenLineRegionKey,
          ignoring: true,
          child: line.isEmpty
              ? const SizedBox.shrink()
              : Semantics(
                  container: true,
                  liveRegion: true,
                  label: line,
                  textDirection: Directionality.of(context),
                  child: const SizedBox(width: 1, height: 1),
                ),
        );
      },
    );
  }
}
