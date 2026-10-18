import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


/// On-screen keyboard for Android TV that the remote can move around.
///
/// The system keyboard on some TVs does not react to the arrow keys of the
/// remote, so on a TV this panel opens whenever a text box gets the focus.
/// Arrows move over the keys, OK types, "Done" returns to the screen.
/// Phones are not affected.
class TvKeyboardHost extends StatefulWidget {
  final Widget child;
  const TvKeyboardHost({Key? key, required this.child}) : super(key: key);

  @override
  State<TvKeyboardHost> createState() => _TvKeyboardHostState();
}

class _TvKeyboardHostState extends State<TvKeyboardHost> {
  final FocusNode _scope = FocusNode(debugLabel: 'tvKeyboard', canRequestFocus: false, skipTraversal: true);
  final FocusNode _firstKey = FocusNode(debugLabel: 'tvKeyboardFirst');
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
    _firstKey.dispose();
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
      }
      // Hand the remote over to the keys.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible) _firstKey.requestFocus();
      });
      return;
    }
    if (_visible && !_scope.hasFocus) {
      setState(() => _visible = false);
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
    _dismissedFor = node;
    try {
      et?.performAction(et.widget.textInputAction ?? TextInputAction.done);
    } catch (_) {}
    // Move on to the next thing (OK button of a dialog, next box ...).
    node?.nextFocus();
  }

  Widget _key(String label, VoidCallback onTap, {int flex = 1, FocusNode? node, IconData? icon, bool strong = false}) {
    return Expanded(
      flex: flex,
      child: _KbKey(label: label, icon: icon, strong: strong, node: node, onTap: onTap),
    );
  }

  List<Widget> _letters(String chars, {FocusNode? first}) {
    final out = <Widget>[];
    for (int i = 0; i < chars.length; i++) {
      final c = _caps ? chars[i].toUpperCase() : chars[i];
      out.add(_key(c, () => _type(c), node: i == 0 ? first : null));
    }
    return out;
  }

  Widget _panel() {
    return Focus(
      focusNode: _scope,
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.goBack || e.logicalKey == LogicalKeyboardKey.escape)) {
          _done();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: const Color(0xF2120E24),
        elevation: 16,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: _letters('1234567890', first: _firstKey)),
              Row(children: _letters('qwertyuiop')),
              Row(children: [..._letters('asdfghjkl'), _key('', _backspace, icon: Icons.backspace_outlined)]),
              Row(children: [
                _key('', () => setState(() => _caps = !_caps), icon: _caps ? Icons.keyboard_capslock : Icons.arrow_upward),
                ..._letters('zxcvbnm'),
                _key('.', () => _type('.')),
                _key('/', () => _type('/')),
              ]),
              Row(children: [
                _key(':', () => _type(':')),
                _key('-', () => _type('-')),
                _key('_', () => _type('_')),
                _key('@', () => _type('@')),
                _key('Space', () => _type(' '), flex: 4),
                _key('Clear', _clear, flex: 2),
                _key('Done', _done, flex: 2, strong: true),
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
          left: 0,
          right: 0,
          bottom: 0,
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(14)), child: _panel()))),
        ),
    ]);
  }
}

/// One compact key: a thin white ring shows where the remote is.
class _KbKey extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool strong;
  final FocusNode? node;
  final VoidCallback onTap;
  const _KbKey({Key? key, required this.label, this.icon, this.strong = false, this.node, required this.onTap}) : super(key: key);

  @override
  State<_KbKey> createState() => _KbKeyState();
}

class _KbKeyState extends State<_KbKey> {
  bool _f = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(1.5),
      child: InkWell(
        focusNode: widget.node,
        borderRadius: BorderRadius.circular(6),
        onTap: widget.onTap,
        onFocusChange: (v) => setState(() => _f = v),
        child: Container(
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _f ? Colors.white : (widget.strong ? primary : Colors.white12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: widget.icon != null
              ? Icon(widget.icon, size: 16, color: _f ? Colors.black : Colors.white)
              : Text(widget.label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _f ? Colors.black : Colors.white)),
        ),
      ),
    );
  }
}
