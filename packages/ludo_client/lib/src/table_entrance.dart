// The veil a new game arrives through (C-554 D2). A full-size layer in the
// screen's own background colour that starts opaque and fades to clear, so the
// board that replaces the lobby or the end card settles into view instead of
// appearing in one frame. It sits above everything the screen draws, takes no
// tap, and never moves or rebuilds what is under it. Once the fade is over it
// leaves the tree. Under the system "remove animations" setting it is not
// drawn at all.

import 'package:flutter/material.dart';

/// How long the veil takes to go from opaque to clear.
const Duration kTableEntranceFade = Duration(milliseconds: 360);

class TableEntrance extends StatefulWidget {
  const TableEntrance({super.key, this.onDone});

  /// Called once, after the fade has finished and the layer has left the
  /// tree, so the owner can drop the widget as well.
  final VoidCallback? onDone;

  @override
  State<TableEntrance> createState() => _TableEntranceState();
}

class _TableEntranceState extends State<TableEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  late final CurvedAnimation _curve;
  late final Animation<double> _opacity;
  bool _done = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: kTableEntranceFade);
    _fade.addStatusListener(_onStatus);
    _curve = CurvedAnimation(parent: _fade, curve: Curves.easeOut);
    _opacity = Tween<double>(begin: 1, end: 0).animate(_curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || _done) {
      return;
    }
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _done = true;
      return;
    }
    _fade.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _done) {
      return;
    }
    setState(() {
      _done = true;
    });
    widget.onDone?.call();
  }

  @override
  void dispose() {
    _curve.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      key: const Key('game-table-entrance'),
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _opacity,
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
