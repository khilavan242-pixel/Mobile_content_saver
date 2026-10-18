import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Background playback: a notification with play / pause / next / previous
/// that also shows on the lock screen and keeps the app alive while the
/// screen is off (like a music player).
class Media {
  static const MethodChannel _c = MethodChannel('tubebox/media');
  static void Function(String cmd)? _onCmd;
  static bool _asked = false;

  static void listen(void Function(String cmd)? fn) {
    _onCmd = fn;
    _c.setMethodCallHandler(fn == null
        ? null
        : (call) async {
            if (call.method == 'cmd') _onCmd?.call(call.arguments as String);
          });
  }

  /// Clears the listener only if [fn] is still the current one.
  static void release(void Function(String cmd) fn) {
    if (_onCmd == fn) listen(null);
  }

  static Future<void> show({required String title, required String subtitle, required bool playing, required bool hasPrev, required bool hasNext, String art = ''}) async {
    if (!_asked) {
      _asked = true;
      try {
        await Permission.notification.request();
      } catch (_) {}
    }
    try {
      await _c.invokeMethod('show', {'title': title, 'subtitle': subtitle, 'playing': playing, 'prev': hasPrev, 'next': hasNext, 'art': art});
    } catch (_) {}
  }

  /// Timeline of the notification (position / length in seconds).
  static Future<void> progress(double pos, double dur, bool playing) async {
    try {
      await _c.invokeMethod('progress', {'pos': (pos * 1000).round(), 'dur': (dur * 1000).round(), 'playing': playing});
    } catch (_) {}
  }

  /// Stops playback and closes TubeBox completely.
  static Future<void> quit() async {
    try {
      await _c.invokeMethod('quit');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _c.invokeMethod('stop');
    } catch (_) {}
  }
}
