import 'package:flutter/material.dart';

import 'pip.dart';
import 'player_screen.dart';
import 'youtube_core.dart';

/// Owns the one player of the app. The player lives above every screen, so it
/// can shrink into a mini bar (like YouTube) and keep playing while you browse.
class PlayerHost extends ChangeNotifier {
  static final PlayerHost instance = PlayerHost._();

  PlayerHost._() {
    Pip.listen((v) {
      inPip = v;
      notifyListeners();
    });
  }

  List<YtItem> queue = const [];
  int start = 0;
  int session = 0;
  bool active = false;
  bool minimized = false;
  bool inPip = false;

  /// Set by the open player: handles the Back key, returns true when used.
  bool Function()? backHandler;

  void open(List<YtItem> q, int index) {
    queue = List<YtItem>.from(q);
    start = index;
    active = true;
    minimized = false;
    session++;
    notifyListeners();
  }

  void minimize() {
    if (!active || minimized) return;
    minimized = true;
    notifyListeners();
  }

  void expand() {
    if (!active || !minimized) return;
    minimized = false;
    notifyListeners();
  }

  void close() {
    if (!active) return;
    active = false;
    minimized = false;
    session++;
    notifyListeners();
  }

  /// Android Back: true when the open (full size) player took it.
  bool handleBack() {
    if (!active || minimized) return false;
    return backHandler?.call() ?? false;
  }
}

/// Sits above the navigator (MaterialApp.builder) and shows the player either
/// full size, as a mini bar at the bottom, or as the floating window.
class PlayerLayer extends StatefulWidget {
  final Widget child;
  const PlayerLayer({Key? key, required this.child}) : super(key: key);

  @override
  State<PlayerLayer> createState() => _PlayerLayerState();
}

class _PlayerLayerState extends State<PlayerLayer> {
  final PlayerHost _host = PlayerHost.instance;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: _host,
      builder: (context, _) {
        final full = _host.active && (!_host.minimized || _host.inPip);
        final mini = _host.active && _host.minimized && !_host.inPip;
        return Stack(children: [
          Positioned.fill(child: ExcludeFocus(excluding: full, child: widget.child)),
          if (_host.active)
            Positioned(
              left: mini ? 8 : 0,
              right: mini ? 8 : 0,
              top: mini ? null : 0,
              bottom: mini ? mq.padding.bottom + 84 : 0,
              height: mini ? 66 : null,
              child: const _PlayerOverlay(),
            ),
        ]);
      },
    );
  }
}

/// An Overlay of its own (tooltips and menus need one) holding the player.
class _PlayerOverlay extends StatefulWidget {
  const _PlayerOverlay({Key? key}) : super(key: key);

  @override
  State<_PlayerOverlay> createState() => _PlayerOverlayState();
}

class _PlayerOverlayState extends State<_PlayerOverlay> {
  late final OverlayEntry _entry;

  @override
  void initState() {
    super.initState();
    final host = PlayerHost.instance;
    _entry = OverlayEntry(
      builder: (context) => FocusScope(
        child: AnimatedBuilder(
          animation: host,
          builder: (context, _) {
            if (!host.active) return const SizedBox.shrink();
            return PlayerScreen(
              key: ValueKey(host.session),
              queue: host.queue,
              startIndex: host.start,
              minimized: host.minimized && !host.inPip,
              inPip: host.inPip,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
