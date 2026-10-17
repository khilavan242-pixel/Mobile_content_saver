import 'package:flutter/services.dart';

/// Floating mini player (Android Picture-in-Picture). The little window can be
/// dragged anywhere on the screen, even over other apps.
class Pip {
  static const MethodChannel _c = MethodChannel('tubebox/pip');
  static void Function(bool inPip)? _listener;

  static void listen(void Function(bool inPip)? fn) {
    _listener = fn;
    _c.setMethodCallHandler(fn == null
        ? null
        : (call) async {
            if (call.method == 'pip') _listener?.call(call.arguments == true);
          });
  }

  /// [wide] = 16:9 window, otherwise a tall 9:16 window (Shorts).
  static Future<bool> enter({bool wide = true}) async {
    try {
      return (await _c.invokeMethod('enter', {'wide': wide})) == true;
    } catch (_) {
      return false;
    }
  }

  /// While on, pressing Home turns the playing video into the floating window.
  static Future<void> auto(bool on, {bool wide = true}) async {
    try {
      await _c.invokeMethod('auto', {'on': on, 'wide': wide});
    } catch (_) {}
  }
}
