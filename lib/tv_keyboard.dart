import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


/// On-screen keyboard for Android TV that the remote can move around.
///
/// The system keyboard on some TVs does not react to the arrow keys of the
/// remote, so on a TV this panel opens whenever a text box gets the focus.
/// Arrows move over the keys, OK types, "Done" returns to the screen.
/// Phones are not affected.
class TvKeyboardHost extends StatefulWidget {
  /// True while the keyboard is on screen (screens can end "editing" when it closes).
  static final ValueNotifier<bool> visibleNotifier = ValueNotifier<bool>(false);

  final Widget child;
  const TvKeyboardHost({Key? key, required this.child}) : super(key: key);

  @override
  State<TvKeyboardHost> createState() => _TvKeyboardHostState();
}

class _TvKeyboardHostState extends State<TvKeyboardHost> {
  final FocusNode _scope = FocusNode(debugLabel: 'tvKeyboard', canRequestFocus: false, skipTraversal: true);
  // YouTube TV style keypad: rows of [8, 8, 8, 7, 3] keys, one focus node per key.
  static const List<int> _rowLens = [8, 8, 8, 7, 3];
  final List<List<FocusNode>> _nodes = [
    for (final n in _rowLens) [for (int i = 0; i < n; i++) FocusNode(debugLabel: 'kb')],
  ];
  // flex of every key (rows have different widths); used to line up Up / Down.
  static const List<List<int>> _flex = [
    [1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1],
    [3, 2, 3],
  ];
  bool _sym = false; // &123 page
  FocusNode get _firstKey => _nodes[0][0];
  EditableTextState? _target;
  FocusNode? _dismissedFor;
  bool _visible = false;
  bool _caps = false;
  bool _isTv = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _scope.dispose();
    for (final r in _nodes) {
      for (final n in r) {
        n.dispose();
      }
    }
    TvKeyboardHost.visibleNotifier.value = false;
    super.dispose();
  }

  bool _pending = false;

  void _onFocus() {
    if (!_isTv || !mounted || _pending) return;
    _pending = true;
    // Focus can change in the middle of building: look at it a moment later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (mounted) _check();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _check() {
    final pf = FocusManager.instance.primaryFocus;
    final ctx = pf?.context;
    final et = ctx?.findAncestorStateOfType<EditableTextState>();
    if (et != null) {
      if (_dismissedFor != null && identical(_dismissedFor, et.widget.focusNode)) return;
      _dismissedFor = null;
      if (!_visible || !identical(_target, et)) {
        setState(() {
          _target = et;
          _visible = true;
        });
        TvKeyboardHost.visibleNotifier.value = true;
        // Dialogs slide in: place the keyboard again once they have settled.
        Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (mounted && _visible) setState(() {});
        });
      }
      // Hand the remote over to the keys.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible) _firstKey.requestFocus();
      });
      return;
    }
    if (_visible && !_scope.hasFocus) {
      setState(() => _visible = false);
      TvKeyboardHost.visibleNotifier.value = false;
    }
    if (pf != null && !identical(pf, _dismissedFor)) _dismissedFor = null;
  }

  void _type(String s) {
    final et = _target;
    if (et == null) return;
    final v = et.textEditingValue;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final text = v.text.replaceRange(sel.start, sel.end, s);
    et.updateEditingValue(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: sel.start + s.length)));
  }

  void _backspace() {
    final et = _target;
    if (et == null) return;
    final v = et.textEditingValue;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    if (!sel.isCollapsed) {
      _type('');
      return;
    }
    if (sel.start == 0) return;
    final text = v.text.replaceRange(sel.start - 1, sel.start, '');
    et.updateEditingValue(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: sel.start - 1)));
  }

  void _clear() {
    _target?.updateEditingValue(const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0)));
  }

  void _done() {
    final et = _target;
    final node = et?.widget.focusNode;
    setState(() => _visible = false);
    TvKeyboardHost.visibleNotifier.value = false;
    _dismissedFor = node;
    try {
      et?.performAction(et.widget.textInputAction ?? TextInputAction.done);
    } catch (_) {}
    // Move on to the next thing (OK button of a dialog, next box ...).
    node?.nextFocus();
  }

  Widget _key(int r, int c, String label, VoidCallback onTap, {IconData? icon, bool small = false, bool boxed = false}) {
    return Expanded(
      flex: _flex[r][c],
      child: _KbKey(label: label, icon: icon, small: small, boxed: boxed, node: _nodes[r][c], onTap: onTap),
    );
  }

  /// Arrow keys move over the keys by position (row / column), nothing else.
  KeyEventResult _arrow(FocusNode n, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (e is KeyDownEvent) _done();
      return KeyEventResult.handled;
    }
    final isArrow = k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown;
    if (!isArrow) return KeyEventResult.ignored;
    int r = -1, c = -1;
    for (int i = 0; i < _nodes.length; i++) {
      for (int j = 0; j < _nodes[i].length; j++) {
        if (_nodes[i][j].hasPrimaryFocus) {
          r = i;
          c = j;
        }
      }
    }
    if (r < 0) {
      _firstKey.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (c > 0) _nodes[r][c - 1].requestFocus();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      if (c < _nodes[r].length - 1) _nodes[r][c + 1].requestFocus();
    } else {
      final nr = k == LogicalKeyboardKey.arrowUp ? r - 1 : r + 1;
      if (nr >= 0 && nr < _nodes.length) {
        // Same horizontal position in the other row.
        double total(List<int> f) => f.fold<int>(0, (a, b) => a + b).toDouble();
        double centre(int row, int col) {
          double acc = 0;
          for (int i = 0; i < col; i++) {
            acc += _flex[row][i];
          }
          return (acc + _flex[row][col] / 2) / total(_flex[row]);
        }
        final want = centre(r, c);
        int best = 0;
        double bestD = 9;
        for (int j = 0; j < _nodes[nr].length; j++) {
          final d = (centre(nr, j) - want).abs();
          if (d < bestD) {
            bestD = d;
            best = j;
          }
        }
        _nodes[nr][best].requestFocus();
      }
    }
    return KeyEventResult.handled;
  }

  static const List<String> _letterPage = ['abcdefg', 'hijklmn', 'opqrstu', "vwxyz-'"];
  static const List<String> _symbolPage = ['1234567', '890./:@', '_=,?!&#', '()*%+-\''];

  Widget _panel() {
    final page = _sym ? _symbolPage : _letterPage;
    Widget typed(int r, int c) {
      final raw = page[r][c];
      final ch = (!_sym && _caps) ? raw.toUpperCase() : raw;
      return _key(r, c, raw.toUpperCase(), () => _type(ch));
    }

    List<Widget> rowOf(int r, {Widget? last}) => [
          for (int c = 0; c < page[r].length; c++) typed(r, c),
          if (last != null) last,
        ];

    return FocusScope(
      child: Focus(
        focusNode: _scope,
        onKeyEvent: _arrow,
        child: Material(
          color: const Color(0xF0101010),
          elevation: 16,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: rowOf(0, last: _key(0, 7, '', _backspace, icon: Icons.backspace_outlined))),
              Row(children: rowOf(1, last: _key(1, 7, _sym ? 'ABC' : '&123', () => setState(() => _sym = !_sym), small: true))),
              Row(children: rowOf(2, last: _key(2, 7, '', () => setState(() => _caps = !_caps), icon: _caps ? Icons.keyboard_capslock : Icons.arrow_upward))),
              Row(children: rowOf(3)),
              const SizedBox(height: 4),
              Row(children: [
                _key(4, 0, 'SPACE', () => _type(' '), small: true, boxed: true),
                _key(4, 1, 'CLEAR', _clear, small: true, boxed: true),
                _key(4, 2, 'SEARCH', _done, small: true, boxed: true),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  static const double _kbW = 420, _kbH = 236;

  /// The area the keyboard must not cover: the box being typed in, and when it sits in a
  /// dialog the whole dialog card (so its buttons stay reachable).
  Rect? _avoidRect() {
    final ctx = _target?.context;
    if (ctx == null || !ctx.mounted) return null;
    RenderBox? card;
    ctx.visitAncestorElements((e) {
      if (e.widget is Dialog) return false;
      if (e.widget is Material) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.attached) card = ro;
      }
      return true;
    });
    // `card` is the outermost Material below the Dialog (the dialog card), or the
    // outermost Material of the page - only use it when a Dialog really is above.
    var inDialog = false;
    ctx.visitAncestorElements((e) {
      if (e.widget is Dialog) {
        inDialog = true;
        return false;
      }
      return true;
    });
    final field = ctx.findRenderObject();
    RenderBox? box = inDialog ? card : null;
    if (box == null && field is RenderBox) box = field;
    if (box == null || !box.hasSize || !box.attached) return null;
    return (box.localToGlobal(Offset.zero) & box.size).inflate(6);
  }

  /// Puts the keyboard where it hides nothing: beside the box, else below, else above.
  /// If no free place is big enough the keyboard shrinks to fit.
  Widget _placed(Size size) {
    final safe = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    final avoid = _avoidRect();
    double fit(Rect r) => r.width <= 0 || r.height <= 0 ? 0 : [1.0, r.width / _kbW, r.height / _kbH].reduce((a, b) => a < b ? a : b);
    Rect left = safe, top = safe;
    double scale = 1;
    if (avoid != null) {
      final regions = <String, Rect>{
        'right': Rect.fromLTRB(avoid.right + 8, safe.top, safe.right, safe.bottom),
        'left': Rect.fromLTRB(safe.left, safe.top, avoid.left - 8, safe.bottom),
        'below': Rect.fromLTRB(safe.left, avoid.bottom + 8, safe.right, safe.bottom),
        'above': Rect.fromLTRB(safe.left, safe.top, safe.right, avoid.top - 8),
      };
      String best = 'below';
      double bestS = -1;
      for (final e in regions.entries) {
        final f = fit(e.value);
        if (f > bestS + 0.001) {
          bestS = f;
          best = e.key;
        }
      }
      scale = bestS.clamp(0.5, 1.0).toDouble();
      final r = regions[best]!;
      final w = _kbW * scale, h = _kbH * scale;
      switch (best) {
        case 'right':
          left = Rect.fromLTWH(r.left, (avoid.center.dy - h / 2).clamp(safe.top, safe.bottom - h).toDouble(), 0, 0);
          break;
        case 'left':
          left = Rect.fromLTWH(r.right - w, (avoid.center.dy - h / 2).clamp(safe.top, safe.bottom - h).toDouble(), 0, 0);
          break;
        case 'below':
          left = Rect.fromLTWH((avoid.left).clamp(safe.left, safe.right - w).toDouble(), r.top, 0, 0);
          break;
        default:
          left = Rect.fromLTWH((avoid.left).clamp(safe.left, safe.right - w).toDouble(), r.bottom - h, 0, 0);
      }
      top = left;
    } else {
      scale = fit(Rect.fromLTRB(safe.right - _kbW, 76, safe.right, safe.bottom));
      left = Rect.fromLTWH(safe.right - _kbW * scale, 76, 0, 0);
    }
    return Positioned(
      left: left.left,
      top: top.top,
      width: _kbW * scale,
      height: _kbH * scale,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
        child: SizedBox(width: _kbW, child: ClipRRect(borderRadius: BorderRadius.circular(14), child: _panel())),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    _isTv = size.width >= 900 && size.width > size.height;
    return Stack(children: [
      Positioned.fill(child: widget.child),
      if (_isTv && _visible) _placed(size),
    ]);
  }
}

/// One key: plain letter, white rounded square where the remote is.
class _KbKey extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool small, boxed;
  final FocusNode? node;
  final VoidCallback onTap;
  const _KbKey({Key? key, required this.label, this.icon, this.small = false, this.boxed = false, this.node, required this.onTap}) : super(key: key);

  @override
  State<_KbKey> createState() => _KbKeyState();
}

class _KbKeyState extends State<_KbKey> {
  bool _f = false;

  @override
  Widget build(BuildContext context) {
    final fg = _f ? Colors.black : Colors.white;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: InkWell(
        focusNode: widget.node,
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onTap,
        onFocusChange: (v) => setState(() => _f = v),
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _f ? Colors.white : (widget.boxed ? Colors.white12 : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: widget.icon != null
              ? Icon(widget.icon, size: 20, color: fg)
              : Text(widget.label, style: TextStyle(fontSize: widget.small ? 14 : 20, fontWeight: FontWeight.w600, color: fg)),
        ),
      ),
    );
  }
}
