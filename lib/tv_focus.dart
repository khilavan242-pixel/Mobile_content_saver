import 'package:flutter/material.dart';

/// A tappable area with a thick, clearly visible focus ring so it can be used
/// with a TV remote (D-pad moves the ring, OK/Enter taps).
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double radius;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocus;
  const TvFocusable({
    Key? key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.radius = 12,
    this.autofocus = false,
    this.focusNode,
    this.onFocus,
  }) : super(key: key);

  @override
  _TvFocusableState createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius + 3),
        border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 3),
        color: _focused ? Colors.white.withOpacity(0.08) : Colors.transparent,
      ),
      child: InkWell(
        borderRadius: r,
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onFocusChange: (v) {
          setState(() => _focused = v);
          widget.onFocus?.call(v);
        },
        child: widget.child,
      ),
    );
  }
}
