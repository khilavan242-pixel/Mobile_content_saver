import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ============================================================================
// MODEL
// ============================================================================
class YtItem {
  final String kind; // 'video' or 'playlist'
  final String id;
  String title;

  YtItem({required this.kind, required this.id, required this.title});

  bool get isPlaylist => kind == 'playlist';

  String get webUrl => isPlaylist
      ? 'https://www.youtube.com/playlist?list=$id'
      : 'https://www.youtube.com/watch?v=$id';

  String get kodiUrl => isPlaylist
      ? 'plugin://plugin.video.youtube/play/?playlist_id=$id&order=default&play=1'
      : 'plugin://plugin.video.youtube/play/?video_id=$id';

  String get thumbUrl => 'https://img.youtube.com/vi/$id/mqdefault.jpg';

  // Placeholder titles start with "YouTube " (e.g. "YouTube video").
  bool get hasRealTitle => title.isNotEmpty && !title.startsWith('YouTube ');
}

final RegExp _videoIdRe = RegExp(r'(?:[?&]v=|youtu\.be/|/shorts/|/embed/|/live/|video_id=)([A-Za-z0-9_-]{11})');
final RegExp _playlistIdRe = RegExp(r'(?:[?&]list=|playlist_id=)([A-Za-z0-9_-]{10,})');

/// Finds every YouTube video / playlist link inside any pasted text.
/// A link that points at a video wins over a playlist id in the same link.
List<YtItem> parseYtText(String text) {
  final List<YtItem> found = [];
  final Set<String> seen = {};
  for (final token in text.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (!token.contains('youtu') && !token.contains('video_id=') && !token.contains('playlist_id=')) continue;
    YtItem? item;
    final v = _videoIdRe.firstMatch(token);
    if (v != null) {
      item = YtItem(kind: 'video', id: v.group(1)!, title: 'YouTube video');
    } else {
      final p = _playlistIdRe.firstMatch(token);
      if (p != null) item = YtItem(kind: 'playlist', id: p.group(1)!, title: 'YouTube playlist');
    }
    if (item != null && seen.add('${item.kind}:${item.id}')) found.add(item);
  }
  return found;
}

Future<String?> fetchYtTitle(YtItem item) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final uri = Uri.parse('https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(item.webUrl)}');
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    final title = (jsonDecode(body)['title'] as String?)?.trim();
    return (title == null || title.isEmpty) ? null : title;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

// ============================================================================
// STORAGE: one .m3u file per list inside <base folder>/YouTube_Lists
// (same format the Android share receiver writes, and Kodi can open them)
// ============================================================================
class YtStore {
  final String basePath;
  YtStore(this.basePath);

  Directory get dir => Directory('$basePath/YouTube_Lists');

  static String safeName(String n) => n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  File fileFor(String name) => File('${dir.path}/${safeName(name)}.m3u');

  Future<List<String>> listNames() async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final names = <String>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.m3u')) {
        final base = e.path.split('/').last;
        names.add(base.substring(0, base.length - 4));
      }
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  Future<void> create(String name) async {
    final f = fileFor(name);
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    if (!await f.exists()) await f.writeAsString('#EXTM3U\n');
  }

  Future<void> delete(String name) async {
    final f = fileFor(name);
    if (await f.exists()) await f.delete();
  }

  Future<void> rename(String oldName, String newName) async {
    await fileFor(oldName).rename(fileFor(newName).path);
  }

  Future<List<YtItem>> load(String name) async {
    final f = fileFor(name);
    if (!await f.exists()) return [];
    final lines = await f.readAsLines();
    final items = <YtItem>[];
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXTINF')) continue;
      String title;
      final m = RegExp(r'tvg-logo="[^"]*",\s*(.*)$').firstMatch(lines[i]);
      if (m != null) {
        title = m.group(1)!.trim();
      } else {
        title = lines[i].substring(lines[i].lastIndexOf(',') + 1).trim();
      }
      String url = '';
      for (int j = i + 1; j < lines.length && j <= i + 2; j++) {
        if (lines[j].trim().isNotEmpty && !lines[j].startsWith('#')) {
          url = lines[j].trim();
          break;
        }
      }
      final p = RegExp(r'playlist_id=([A-Za-z0-9_-]+)').firstMatch(url);
      final v = RegExp(r'video_id=([A-Za-z0-9_-]{11})').firstMatch(url);
      if (p != null) {
        items.add(YtItem(kind: 'playlist', id: p.group(1)!, title: title));
      } else if (v != null) {
        items.add(YtItem(kind: 'video', id: v.group(1)!, title: title));
      }
    }
    return items;
  }

  Future<void> save(String name, List<YtItem> items) async {
    final group = name.replaceAll('"', '');
    final sb = StringBuffer('#EXTM3U\n');
    for (final it in items) {
      final logo = it.isPlaylist ? '' : it.thumbUrl.replaceFirst('mqdefault', 'hqdefault');
      final title = it.title.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      sb.write('\n#EXTINF:-1 group-title="$group" tvg-logo="$logo", $title\n${it.kodiUrl}\n');
    }
    final f = fileFor(name);
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    await f.writeAsString(sb.toString());
  }

  /// Tells the native "share to this app" receiver which file to save into,
  /// so a YouTube share is stored without ever opening this app.
  Future<void> writeShareConfig(String name) async {
    try {
      final support = await getApplicationSupportDirectory();
      await File('${support.path}/share_config.txt').writeAsString('${fileFor(name).path}\n$name');
    } catch (e) {
      debugPrint('Could not write share config: $e');
    }
  }

  /// Shares received before a target list was chosen are parked natively in
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
// SCREEN
// ============================================================================
class YouTubeListsScreen extends StatefulWidget {
  final String basePath;
  const YouTubeListsScreen({Key? key, required this.basePath}) : super(key: key);

  @override
  _YouTubeListsScreenState createState() => _YouTubeListsScreenState();
}

class _YouTubeListsScreenState extends State<YouTubeListsScreen> with WidgetsBindingObserver {
  late final YtStore _store;
  final TextEditingController _addCtrl = TextEditingController();

  List<String> _names = [];
  String? _active;
  List<YtItem> _items = [];
  bool _ready = false;
  bool _fetchingTitles = false;

  static const String _defaultList = 'My Videos';

  @override
  void initState() {
    super.initState();
    _store = YtStore(widget.basePath);
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _addCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Videos shared from the YouTube app land in the file while we are away.
    if (state == AppLifecycleState.resumed && _ready) {
      _refresh();
    }
  }

  Future<void> _init() async {
    try {
      var names = await _store.listNames();
      if (names.isEmpty) {
        await _store.create(_defaultList);
        names = [_defaultList];
      }
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('yt_active_list');
      _names = names;
      _active = (saved != null && names.contains(saved)) ? saved : names.first;
      await prefs.setString('yt_active_list', _active!);
      await _importPending();
      _items = await _store.load(_active!);
      await _store.writeShareConfig(_active!);
    } catch (e) {
      _snack('Could not open lists: $e');
    }
    if (!mounted) return;
    setState(() => _ready = true);
    _fetchMissingTitles();
  }

  Future<void> _importPending() async {
    if (_active == null) return;
    final pending = await _store.takePendingShares();
    if (pending.isEmpty) return;
    final current = await _store.load(_active!);
    final known = current.map((e) => '${e.kind}:${e.id}').toSet();
    for (final p in pending) {
      if (known.add('${p.kind}:${p.id}')) current.add(p);
    }
    await _store.save(_active!, current);
  }

  Future<void> _refresh() async {
    if (_active == null) return;
    try {
      final names = await _store.listNames();
      await _importPending();
      final items = await _store.load(_active!);
      if (!mounted) return;
      setState(() {
        _names = names;
        _items = items;
      });
      _fetchMissingTitles();
    } catch (_) {}
  }

  Future<void> _switchTo(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('yt_active_list', name);
    final items = await _store.load(name);
    await _store.writeShareConfig(name);
    if (!mounted) return;
    setState(() {
      _active = name;
      _items = items;
    });
    _fetchMissingTitles();
  }

  void _snack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.green : Colors.redAccent,
    ));
  }

  // --------------------------------------------------------------- titles
  Future<void> _fetchMissingTitles() async {
    if (_fetchingTitles || _active == null) return;
    final listName = _active!;
    final missing = _items.where((e) => !e.hasRealTitle).toList();
    if (missing.isEmpty) return;
    _fetchingTitles = true;
    final found = <String, String>{};
    try {
      for (final it in missing) {
        final t = await fetchYtTitle(it);
        if (t != null) {
          found['${it.kind}:${it.id}'] = t;
          if (mounted && _active == listName) {
            setState(() => it.title = t);
          }
        }
      }
      if (found.isNotEmpty) {
        // Re-read the file first: a share may have appended while we were fetching.
        final fresh = await _store.load(listName);
        for (final it in fresh) {
          final t = found['${it.kind}:${it.id}'];
          if (t != null) it.title = t;
        }
        await _store.save(listName, fresh);
      }
    } finally {
      _fetchingTitles = false;
    }
  }

  // ---------------------------------------------------------------- add
  Future<void> _addFromText() async {
    if (_active == null) return;
    final parsed = parseYtText(_addCtrl.text);
    if (parsed.isEmpty) {
      _snack('No YouTube video or playlist links found in the text.');
      return;
    }
    final current = await _store.load(_active!);
    final known = current.map((e) => '${e.kind}:${e.id}').toSet();
    int added = 0;
    for (final p in parsed) {
      if (known.add('${p.kind}:${p.id}')) {
        current.add(p);
        added++;
      }
    }
    await _store.save(_active!, current);
    _addCtrl.clear();
    if (!mounted) return;
    setState(() => _items = current);
    _snack('Added $added to "$_active" (${parsed.length - added} already there)', success: true);
    _fetchMissingTitles();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      setState(() => _addCtrl.text = data!.text!);
    }
  }

  // ------------------------------------------------------------- list ops
  Future<String?> _askName(String title, {String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'List name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _newList() async {
    final name = await _askName('New list');
    if (name == null || name.isEmpty) return;
    final safe = YtStore.safeName(name);
    if (safe.isEmpty) return;
    if (_names.any((n) => n.toLowerCase() == safe.toLowerCase())) {
      _snack('A list named "$safe" already exists.');
      return;
    }
    await _store.create(safe);
    final names = await _store.listNames();
    setState(() => _names = names);
    await _switchTo(safe);
  }

  Future<void> _renameList() async {
    if (_active == null) return;
    final name = await _askName('Rename list', initial: _active!);
    if (name == null || name.isEmpty) return;
    final safe = YtStore.safeName(name);
    if (safe.isEmpty || safe == _active) return;
    if (_names.any((n) => n.toLowerCase() == safe.toLowerCase())) {
      _snack('A list named "$safe" already exists.');
      return;
    }
    final items = await _store.load(_active!);
    await _store.rename(_active!, safe);
    await _store.save(safe, items); // refreshes group-title inside the file
    final names = await _store.listNames();
    setState(() => _names = names);
    await _switchTo(safe);
  }

  Future<void> _deleteList() async {
    if (_active == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "$_active"?'),
        content: const Text('The list file and all links in it will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.delete(_active!);
    var names = await _store.listNames();
    if (names.isEmpty) {
      await _store.create(_defaultList);
      names = [_defaultList];
    }
    setState(() => _names = names);
    await _switchTo(names.first);
  }

  Future<void> _copyAllLinks() async {
    if (_items.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _items.map((e) => e.webUrl).join('\n')));
    _snack('Copied ${_items.length} links', success: true);
  }

  // ------------------------------------------------------------ item ops
  Future<void> _open(YtItem item) async {
    final app = Uri.parse(item.isPlaylist ? 'https://www.youtube.com/playlist?list=${item.id}' : 'vnd.youtube://${item.id}');
    final web = Uri.parse(item.webUrl);
    try {
      if (!item.isPlaylist && await canLaunchUrl(app)) {
        await launchUrl(app, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _snack('Could not open YouTube.');
    }
  }

  Future<void> _deleteItem(YtItem item) async {
    final fresh = await _store.load(_active!);
    fresh.removeWhere((e) => e.kind == item.kind && e.id == item.id);
    await _store.save(_active!, fresh);
    setState(() => _items = fresh);
  }

  Future<void> _editTitle(YtItem item) async {
    final t = await _askName('Edit title', initial: item.title);
    if (t == null || t.isEmpty) return;
    final fresh = await _store.load(_active!);
    for (final e in fresh) {
      if (e.kind == item.kind && e.id == item.id) e.title = t;
    }
    await _store.save(_active!, fresh);
    setState(() => _items = fresh);
  }

  Future<void> _moveItem(YtItem item) async {
    final others = _names.where((n) => n != _active).toList();
    if (others.isEmpty) {
      _snack('Create another list first (the + chip).');
      return;
    }
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to list'),
        children: others.map((n) => SimpleDialogOption(onPressed: () => Navigator.pop(ctx, n), child: Text(n))).toList(),
      ),
    );
    if (target == null) return;
    final dest = await _store.load(target);
    if (!dest.any((e) => e.kind == item.kind && e.id == item.id)) dest.add(item);
    await _store.save(target, dest);
    await _deleteItem(item);
    _snack('Moved to "$target"', success: true);
  }

  // ---------------------------------------------------------------- UI
  Widget _thumb(YtItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 96,
        height: 54,
        child: item.isPlaylist
            ? Container(color: Colors.grey.shade800, child: const Icon(Icons.playlist_play, size: 34, color: Colors.redAccent))
            : Image.network(
                item.thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => Container(color: Colors.grey.shade800, child: const Icon(Icons.play_circle_outline)),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Lists'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _renameList();
                  break;
                case 'delete':
                  _deleteList();
                  break;
                case 'copy':
                  _copyAllLinks();
                  break;
                case 'titles':
                  _fetchMissingTitles();
                  break;
              }
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename this list')),
              PopupMenuItem(value: 'copy', child: Text('Copy all links')),
              PopupMenuItem(value: 'titles', child: Text('Fetch missing titles')),
              PopupMenuItem(value: 'delete', child: Text('Delete this list')),
            ],
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      ..._names.map((n) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(n),
                              selected: n == _active,
                              selectedColor: Theme.of(context).colorScheme.primary,
                              onSelected: (_) => _switchTo(n),
                            ),
                          )),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('New list'),
                        onPressed: _newList,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.5)),
                  ),
                  child: Text(
                    'In the YouTube app: Share → "Save to TubeBox". It saves instantly into "$_active" without opening this app.',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _addCtrl,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: 'Paste YouTube video / playlist links (one or many)…',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Paste',
                        onPressed: _pasteFromClipboard,
                        icon: const Icon(Icons.paste),
                      ),
                      ElevatedButton(
                        onPressed: _addFromText,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
                        ),
                        child: const Text('Add', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('${_items.length} item(s) in "$_active"', style: const TextStyle(color: Colors.grey)),
                  ),
                ),
                Expanded(
                  child: _items.isEmpty
                      ? const Center(child: Text('This list is empty.', style: TextStyle(color: Colors.grey)))
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              return Card(
                                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                color: const Color(0xFF1B1633),
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
                                  leading: _thumb(item),
                                  title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(item.isPlaylist ? 'Playlist' : 'Video',
                                      style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                                  onTap: () => _open(item),
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (v) async {
                                      switch (v) {
                                        case 'open':
                                          _open(item);
                                          break;
                                        case 'copy':
                                          await Clipboard.setData(ClipboardData(text: item.webUrl));
                                          _snack('Link copied', success: true);
                                          break;
                                        case 'edit':
                                          _editTitle(item);
                                          break;
                                        case 'move':
                                          _moveItem(item);
                                          break;
                                        case 'delete':
                                          _deleteItem(item);
                                          break;
                                      }
                                    },
                                    itemBuilder: (c) => const [
                                      PopupMenuItem(value: 'open', child: Text('Open in YouTube')),
                                      PopupMenuItem(value: 'copy', child: Text('Copy link')),
                                      PopupMenuItem(value: 'edit', child: Text('Edit title')),
                                      PopupMenuItem(value: 'move', child: Text('Move to another list')),
                                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
