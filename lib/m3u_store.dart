import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'youtube_core.dart';

// ============================================================================
// STORAGE: every .m3u file in the chosen folder (plus the old YouTube_Lists
// sub-folder) is one "M3U file". Shares from the YouTube app are appended to
// the currently selected one.
// ============================================================================
class M3uFile {
  final String path;
  final String name; // file name without ".m3u"
  M3uFile(this.path, this.name);

  @override
  bool operator ==(Object other) => other is M3uFile && other.path == path;
  @override
  int get hashCode => path.hashCode;
}

/// One entry together with the file it lives in (used when several files are
/// shown at once).
class Entry {
  final M3uFile file;
  final YtItem item;
  Entry(this.file, this.item);

  String get id => '${file.path}|${item.key}';
}

class YtStore {
  final String basePath;
  YtStore(this.basePath);

  Directory get _legacyDir => Directory('$basePath/YouTube_Lists');

  static String safeName(String n) => n
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\.m3u$', caseSensitive: false), '')
      .trim();

  static String _baseName(String path) {
    final f = path.split('/').last;
    return f.toLowerCase().endsWith('.m3u') ? f.substring(0, f.length - 4) : f;
  }

  Future<List<M3uFile>> listFiles() async {
    final files = <M3uFile>[];
    final seen = <String>{};
    for (final d in [Directory(basePath), _legacyDir]) {
      if (!await d.exists()) continue;
      await for (final e in d.list(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.m3u') && seen.add(e.path)) {
          files.add(M3uFile(e.path, _baseName(e.path)));
        }
      }
    }
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return files;
  }

  Future<M3uFile> create(String name) async {
    final f = File('$basePath/${safeName(name)}.m3u');
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    if (!await f.exists()) await f.writeAsString('#EXTM3U\n');
    return M3uFile(f.path, _baseName(f.path));
  }

  Future<void> delete(M3uFile f) async {
    final file = File(f.path);
    if (await file.exists()) await file.delete();
  }

  Future<M3uFile> rename(M3uFile f, String newName) async {
    final dir = f.path.substring(0, f.path.lastIndexOf('/'));
    final target = '$dir/${safeName(newName)}.m3u';
    await File(f.path).rename(target);
    return M3uFile(target, _baseName(target));
  }

  Future<List<YtItem>> load(M3uFile f) async {
    final file = File(f.path);
    if (!await file.exists()) return [];
    return parseM3uLines(await file.readAsLines());
  }

  Future<void> save(M3uFile f, List<YtItem> items) async {
    final file = File(f.path);
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(buildM3uText(items, fallbackGroup: f.name.replaceAll('"', '')));
  }

  /// Load → change → save in one go, always starting from what is on disk now
  /// (a YouTube share may have appended to the file in the meantime).
  Future<List<YtItem>> update(M3uFile f, void Function(List<YtItem> items) change) async {
    final items = await load(f);
    change(items);
    await save(f, items);
    return items;
  }

  // ----------------------------------------------------------- Kodi profiles
  Future<List<String>> loadChildren() async {
    final prefs = await SharedPreferences.getInstance();
    final c = prefs.getStringList('child_profiles');
    return (c == null || c.isEmpty) ? ['Lakshya'] : c;
  }

  Future<void> saveChildren(List<String> children) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('child_profiles', children);
  }

  Future<List<String>> loadSubjects() async {
    try {
      final f = File('$basePath/saved_subjects.txt');
      if (await f.exists()) {
        final lines = (await f.readAsLines()).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        if (lines.isNotEmpty) return lines;
      }
    } catch (_) {}
    return ['English', 'Math'];
  }

  Future<void> saveSubjects(List<String> subjects) async {
    try {
      await File('$basePath/saved_subjects.txt').writeAsString(subjects.join('\n'));
    } catch (e) {
      debugPrint('Could not save subjects: $e');
    }
  }

  // ----------------------------------------------------------------- sharing
  /// Tells the native "share to this app" receiver which file to save into,
  /// so a YouTube share is stored without ever opening this app.
  Future<void> writeShareConfig(M3uFile f) async {
    try {
      final support = await getApplicationSupportDirectory();
      await File('${support.path}/share_config.txt').writeAsString('${f.path}\n${f.name}');
    } catch (e) {
      debugPrint('Could not write share config: $e');
    }
  }

  /// Shares received before a target file was chosen are parked natively in
  /// pending_shares.txt (one "kind<TAB>id<TAB>title" per line).
  Future<List<YtItem>> takePendingShares() async {
    try {
      final support = await getApplicationSupportDirectory();
      final f = File('${support.path}/pending_shares.txt');
      if (!await f.exists()) return [];
      final lines = await f.readAsLines();
      await f.delete();
      final items = <YtItem>[];
      for (final l in lines) {
        final parts = l.split('\t');
        if (parts.length >= 2 && parts[1].isNotEmpty) {
          items.add(YtItem(kind: parts[0], id: parts[1], title: parts.length > 2 ? parts[2] : 'YouTube video'));
        }
      }
      return items;
    } catch (_) {
      return [];
    }
  }
}

// ============================================================================
// CHAPTER HELPERS (Kodi style "CH3: Title" numbering inside each group)
// ============================================================================

/// Next free chapter number inside [group] of [items].
int nextChapter(List<YtItem> items, String group) {
  int highest = 0;
  for (final it in items) {
    if (it.group != group) continue;
    final c = it.chapter;
    if (c != null && c > highest) highest = c;
  }
  return highest + 1;
}

/// Renumbers CH1, CH2, ... in file order for every given group that already
/// uses chapter numbers.
void renumberGroups(List<YtItem> items, Iterable<String> groups) {
  for (final g in groups.toSet()) {
    final inGroup = items.where((e) => e.group == g).toList();
    if (!inGroup.any((e) => e.chapter != null)) continue;
    int n = 1;
    for (final it in inGroup) {
      it.setChapter(n++);
    }
  }
}

/// Default folder used on first start so nobody has to pick one.
const String kDefaultFolder = '/storage/emulated/0/Documents/TubeBox';
