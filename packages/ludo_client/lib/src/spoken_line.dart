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
///
/// C-629: the region's label changes at most once per frame, because only
/// the last value of a frame is spoken. Lines spoken while an earlier line
/// is still waiting for its frame are queued and set one per frame, in the
/// order they were spoken. None is dropped and none is reordered.
class SpokenLineController extends ChangeNotifier {
  String _current = '';
  Timer? _holdTimer;
  bool _disposed = false;
  bool _notifyPending = false;

  /// True from the moment a line (or the empty frame before a repeated line)
  /// is set until the frame that draws it has completed.
  bool _busy = false;
  final List<String> _queue = <String>[];

  /// The line the region shows now, or '' when nothing is held.
  String get current => _current;

  /// Shows [line] from the next frame on and clears it after
  /// [kSpokenLineHold], counted from the moment the line is set. A line
  /// spoken while another was set in the same frame waits its turn and is
  /// set after the next completed frame. The same line while it is still
  /// held clears the region for one frame first, because only a change of
  /// the label is spoken. An empty line is ignored.
  void speak(String line) {
    if (_disposed || line.isEmpty) {
      return;
    }
    if (_busy) {
      _queue.add(line);
      return;
    }
    _present(line);
  }

  void _present(String line) {
    _busy = true;
    if (_current == line) {
      // The region must be drawn empty for one frame before the line comes
      // back.
      _holdTimer?.cancel();
      _holdTimer = null;
      _set('');
      _afterRender(() {
        if (_disposed) {
          return;
        }
        _show(line);
      });
      return;
    }
    _show(line);
  }

  void _show(String line) {
    _set(line);
    _holdTimer?.cancel();
    _holdTimer = Timer(kSpokenLineHold, () {
      _holdTimer = null;
      if (_queue.isEmpty) {
        _set('');
      }
    });
    _afterRender(_advance);
  }

  void _advance() {
    if (_disposed) {
      return;
    }
    _busy = false;
    if (_queue.isNotEmpty) {
      _present(_queue.removeAt(0));
    }
  }

  /// Runs [action] after the frame that draws the latest [_set]. A change
  /// made mid-build reaches its listener only after that frame, so the frame
  /// that draws it is the next one.
  void _afterRender(VoidCallback action) {
    final SchedulerBinding binding = SchedulerBinding.instance;
    final bool deferred =
        binding.schedulerPhase == SchedulerPhase.persistentCallbacks;
    binding.addPostFrameCallback((Duration stamp) {
      if (_disposed) {
        return;
      }
      if (deferred) {
        binding.addPostFrameCallback((Duration stamp) {
          if (!_disposed) {
            action();
          }
        });
        binding.ensureVisualUpdate();
      } else {
        action();
      }
    });
    binding.ensureVisualUpdate();
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
    _queue.clear();
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
