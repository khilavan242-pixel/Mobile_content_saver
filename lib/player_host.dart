import 'package:flutter/material.dart';

import 'media.dart';
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
  /// Seconds to start the first video at ("Continue watching").
  double startAt = 0;
  int session = 0;
  bool active = false;
  bool minimized = false;
  bool inPip = false;

  /// Audio mode shrinks into a bar; video shrinks into a draggable window.
  bool audioMode = false;
  Offset? miniPos; // top-left of the floating window (null = default corner)
  static const double miniW = 232, miniH = 131;

  void setAudioMode(bool v) {
    if (audioMode == v) return;
    audioMode = v;
    notifyListeners();
  }

  void dragMini(Offset d, Size screen, EdgeInsets pad) {
    final cur = miniPos ?? Offset(screen.width - miniW - 12, screen.height - miniH - pad.bottom - 90);
    miniPos = Offset(
      (cur.dx + d.dx).clamp(4.0, screen.width - miniW - 4).toDouble(),
      (cur.dy + d.dy).clamp(pad.top + 4, screen.height - miniH - pad.bottom - 4).toDouble(),
    );
    notifyListeners();
  }

  /// Remote commands (from a casting phone): play / pause / next / prev / close.
  void Function(String cmd)? commandHandler;
  void command(String c) {
    if (c == 'close') {
      close();
    } else {
      commandHandler?.call(c);
    }
  }

  FocusNode? _returnFocus;

  /// Set by the open player: handles the Back key, returns true when used.
  bool Function()? backHandler;

  void open(List<YtItem> q, int index, {double startAt = 0}) {
    // Remember what had the remote focus so it can come back when the player closes (TV).
    if (!active) _returnFocus = FocusManager.instance.primaryFocus;
    queue = List<YtItem>.from(q);
    start = index;
    this.startAt = startAt;
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

  /// The X of the floating window / notification: stop everything and close the app.
  void closeAndQuit() {
    close();
    Media.quit();
  }

  void close() {
    if (!active) return;
    active = false;
    minimized = false;
    audioMode = false;
    session++;
    notifyListeners();
    final back = _returnFocus;
    _returnFocus = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (back != null && back.context != null && back.canRequestFocus) back.requestFocus();
    });
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
        final bar = mini && _host.audioMode;
        final win = mini && !_host.audioMode;
        final size = mq.size;
        final pos = _host.miniPos ?? Offset(size.width - PlayerHost.miniW - 12, size.height - PlayerHost.miniH - mq.padding.bottom - 90);
        return Stack(children: [
          Positioned.fill(child: ExcludeFocus(excluding: full, child: widget.child)),
          if (_host.active)
            Positioned(
              left: win ? pos.dx : (bar ? 8 : 0),
              right: win ? null : (bar ? 8 : 0),
              top: win ? pos.dy : (bar ? null : 0),
              bottom: win ? null : (bar ? mq.padding.bottom + 84 : 0),
              width: win ? PlayerHost.miniW : null,
              height: win ? PlayerHost.miniH : (bar ? 66 : null),
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
              startAt: host.startAt,
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
