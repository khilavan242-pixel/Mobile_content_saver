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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    _isTv = size.width >= 900 && size.width > size.height;
    return Stack(children: [
      Positioned.fill(child: widget.child),
      if (_isTv && _visible)
        Positioned(
          right: 24,
          top: 76,
          width: 420,
          child: ClipRRect(borderRadius: BorderRadius.circular(14), child: _panel()),
        ),
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
