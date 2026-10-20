import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs.dart';
import 'youtube_core.dart';

/// One video that was started but not finished.
class WatchRec {
  final String id;
  String title;
  double pos;
  double dur;
  int t;
  WatchRec(this.id, this.title, this.pos, this.dur, this.t);

  double get fraction => dur <= 0 ? 0 : (pos / dur).clamp(0.0, 1.0).toDouble();
  YtItem toItem() => YtItem(kind: 'video', id: id, title: title);

  Map<String, dynamic> toJson() => {'i': id, 'n': title, 'p': pos.round(), 'd': dur.round(), 't': t};
}

/// "Continue watching" + which videos were already seen (for "New for you").
/// Saved in the app's settings file; updated by the player while it plays.
class WatchHistory extends ChangeNotifier {
  static final WatchHistory instance = WatchHistory._();
  WatchHistory._();

  static const String _key = 'tb_watch';
  final List<WatchRec> items = [];
  final Set<String> seen = <String>{};
  bool _loaded = false;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dirty = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      for (final e in (m['c'] as List? ?? const [])) {
        if (e is Map) {
          items.add(WatchRec('${e['i']}', '${e['n'] ?? ''}', (e['p'] as num?)?.toDouble() ?? 0, (e['d'] as num?)?.toDouble() ?? 0, (e['t'] as num?)?.toInt() ?? 0));
        }
      }
      for (final s in (m['s'] as List? ?? const [])) {
        seen.add('$s');
      }
      notifyListeners();
    } catch (_) {}
  }

  WatchRec? recFor(String id) {
    for (final r in items) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Called about twice a second while a video plays.
  void update(YtItem it, double pos, double dur) {
    if (!it.isVideo || dur <= 0 || pos.isNaN || dur.isNaN) return;
    if (pos >= 5 && seen.add(it.id)) _dirty = true;
    final existing = recFor(it.id);
    if (dur - pos < 20 || pos / dur > 0.95) {
      if (existing != null) {
        items.remove(existing);
        _dirty = true;
      }
    } else if (pos >= 15) {
      if (existing == null) {
        items.insert(0, WatchRec(it.id, it.plainTitle.isEmpty ? it.title : it.plainTitle, pos, dur, DateTime.now().millisecondsSinceEpoch));
        if (items.length > 20) items.removeLast();
      } else {
        existing.pos = pos;
        existing.dur = dur;
        existing.t = DateTime.now().millisecondsSinceEpoch;
        if (it.title.isNotEmpty && !it.title.startsWith('YouTube ')) existing.title = it.plainTitle;
        if (items.first != existing) {
          items.remove(existing);
          items.insert(0, existing);
        }
      }
      _dirty = true;
    }
    if (_dirty && DateTime.now().difference(_lastSave) > const Duration(seconds: 8)) flush();
  }

  void remove(String id) {
    items.removeWhere((r) => r.id == id);
    _dirty = true;
    flush();
  }

  /// Write to disk and tell the screens.
  void flush() {
    if (!_dirty) return;
    _dirty = false;
    _lastSave = DateTime.now();
    notifyListeners();
    final seenList = seen.toList();
    final keep = seenList.length > 3000 ? seenList.sublist(seenList.length - 3000) : seenList;
    SharedPreferences.getInstance().then((p) => p.setString(_key, jsonEncode({'c': [for (final r in items) r.toJson()], 's': keep})));
  }
}
