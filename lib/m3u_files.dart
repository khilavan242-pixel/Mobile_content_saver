import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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

class YtStore {
  final String basePath;
  YtStore(this.basePath);

  Directory get _legacyDir => Directory('$basePath/YouTube_Lists');

  static String safeName(String n) => n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\.m3u$', caseSensitive: false), '').trim();

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
    final lines = await file.readAsLines();
    final items = <YtItem>[];
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXTINF')) continue;

      String prefix;
      String title;
      final m = RegExp(r'^(#EXTINF:.*?tvg-logo="[^"]*",\s*)(.*)$').firstMatch(lines[i]);
      if (m != null) {
        prefix = m.group(1)!;
        title = m.group(2)!.trim();
      } else {
        final c = lines[i].lastIndexOf(',');
        prefix = c >= 0 ? '${lines[i].substring(0, c + 1)} ' : '#EXTINF:-1, ';
        title = c >= 0 ? lines[i].substring(c + 1).trim() : '';
      }

      String url = '';
      for (int j = i + 1; j < lines.length && j <= i + 3; j++) {
        final t = lines[j].trim();
        if (t.isNotEmpty && !t.startsWith('#')) {
          url = t;
          break;
        }
      }
      if (url.isEmpty) continue;

      final p = RegExp(r'playlist_id=([A-Za-z0-9_-]+)').firstMatch(url);
      final v = RegExp(r'video_id=([A-Za-z0-9_-]{11})').firstMatch(url);
      if (p != null) {
        items.add(YtItem(kind: 'playlist', id: p.group(1)!, title: title, infoPrefix: prefix));
      } else if (v != null) {
        items.add(YtItem(kind: 'video', id: v.group(1)!, title: title, infoPrefix: prefix));
      } else {
        final yt = parseYtText(url);
        if (yt.isNotEmpty) {
          yt.first.title = title;
          yt.first.infoPrefix = prefix;
          items.add(yt.first);
        } else {
          items.add(YtItem(kind: 'other', id: url, title: title, infoPrefix: prefix));
        }
      }
    }
    return items;
  }

  Future<void> save(M3uFile f, List<YtItem> items) async {
    final group = f.name.replaceAll('"', '');
    final sb = StringBuffer('#EXTM3U\n');
    for (final it in items) {
      final title = it.title.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      final String info;
      if (it.infoPrefix != null) {
        info = '${it.infoPrefix}$title';
      } else {
        final logo = it.isVideo ? it.thumbUrlHq : '';
        info = '#EXTINF:-1 group-title="$group" tvg-logo="$logo", $title';
      }
      sb.write('\n$info\n${it.kodiUrl}\n');
    }
    final file = File(f.path);
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(sb.toString());
  }

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
// SCREEN: YouTube-style thumbnail view of the selected .m3u file
// ============================================================================
class M3uFilesScreen extends StatefulWidget {
  final String basePath;
  const M3uFilesScreen({Key? key, required this.basePath}) : super(key: key);

  @override
  _M3uFilesScreenState createState() => _M3uFilesScreenState();
}

class _M3uFilesScreenState extends State<M3uFilesScreen> with WidgetsBindingObserver {
  late final YtStore _store;
  final TextEditingController _addCtrl = TextEditingController();

  List<M3uFile> _files = [];
  M3uFile? _active;
  List<YtItem> _items = [];
  final Set<String> _selected = {};
  bool _ready = false;
  bool _grid = false;
  String? _busy; // progress text while reading playlists
  bool _working = false;
  final Set<String> _failedPlaylists = {};

  static const String _defaultFile = 'My Videos';

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
    if (state == AppLifecycleState.resumed && _ready) _refresh();
  }

  Future<void> _init() async {
    try {
      var files = await _store.listFiles();
      final prefs = await SharedPreferences.getInstance();
      _grid = prefs.getBool('m3u_grid') ?? false;
      if (files.isEmpty) {
        files = [await _store.create(_defaultFile)];
      }
      final savedPath = prefs.getString('m3u_active_file');
      _files = files;
      _active = files.firstWhere((f) => f.path == savedPath, orElse: () {
        // First run: prefer the file shares were already going into, else the first one.
        return files.first;
      });
      await prefs.setString('m3u_active_file', _active!.path);
      await _importPending();
      _items = await _store.load(_active!);
      await _store.writeShareConfig(_active!);
    } catch (e) {
      _snack('Could not open files: $e');
    }
    if (!mounted) return;
    setState(() => _ready = true);
    _postProcess();
  }

  Future<void> _importPending() async {
    if (_active == null) return;
    final pending = await _store.takePendingShares();
    if (pending.isEmpty) return;
    final current = await _store.load(_active!);
    final known = current.map((e) => e.key).toSet();
    for (final p in pending) {
      if (known.add(p.key)) current.add(p);
    }
    await _store.save(_active!, current);
  }

  Future<void> _refresh() async {
    if (_active == null) return;
    try {
      final files = await _store.listFiles();
      await _importPending();
      final items = await _store.load(_active!);
      if (!mounted) return;
      setState(() {
        _files = files;
        _items = items;
        _selected.removeWhere((k) => !items.any((e) => e.key == k));
      });
      _postProcess();
    } catch (_) {}
  }

  Future<void> _switchTo(M3uFile f) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('m3u_active_file', f.path);
    final items = await _store.load(f);
    await _store.writeShareConfig(f);
    if (!mounted) return;
    setState(() {
      _active = f;
      _items = items;
      _selected.clear();
    });
    _postProcess();
  }

  void _snack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.green : Colors.redAccent,
    ));
  }

  // ------------------------------------------------- background processing
  /// Expands playlist entries into their videos, then fills in missing titles.
  Future<void> _postProcess() async {
    if (_working || _active == null) return;
    _working = true;
    try {
      await _expandPlaylists();
      await _fetchMissingTitles();
    } finally {
      _working = false;
    }
  }

  Future<void> _expandPlaylists({String? onlyId}) async {
    final file = _active;
    if (file == null) return;
    final targets = _items.where((e) => e.isPlaylist && (onlyId == null ? !_failedPlaylists.contains(e.id) : e.id == onlyId)).toList();
    if (targets.isEmpty) return;

    final results = <String, PlaylistResult>{};
    String? lastError;
    for (final p in targets) {
      if (mounted) setState(() => _busy = 'Reading playlist…');
      final res = await fetchPlaylist(p.id, onProgress: (n) {
        if (mounted) setState(() => _busy = 'Reading playlist… $n videos');
      });
      if (res.videos.isEmpty) {
        _failedPlaylists.add(p.id);
        lastError = res.error;
      } else {
        results[p.id] = res;
        if (res.partial && res.error != null) lastError = res.error;
      }
    }
    if (mounted) setState(() => _busy = null);

    if (results.isNotEmpty) {
      // Re-read the file: a share may have been appended while we were fetching.
      final fresh = await _store.load(file);
      final known = fresh.where((e) => !e.isPlaylist || !results.containsKey(e.id)).map((e) => e.key).toSet();
      final out = <YtItem>[];
      int added = 0;
      for (final it in fresh) {
        final r = it.isPlaylist ? results[it.id] : null;
        if (r == null) {
          out.add(it);
        } else {
          for (final v in r.videos) {
            if (known.add(v.key)) {
              out.add(v);
              added++;
            }
          }
        }
      }
      await _store.save(file, out);
      if (mounted && _active == file) setState(() => _items = out);
      _snack('Playlist expanded: $added video(s) added', success: true);
    }
    if (lastError != null) _snack(lastError);
  }

  Future<void> _fetchMissingTitles() async {
    final file = _active;
    if (file == null) return;
    final missing = _items.where((e) => !e.isOther && !e.hasRealTitle && !e.isPlaylist).toList();
    if (missing.isEmpty) return;
    final found = <String, String>{};
    for (final it in missing) {
      final t = await fetchYtTitle(it);
      if (t != null) {
        found[it.key] = t;
        if (mounted && _active == file) setState(() => it.title = t);
      }
    }
    if (found.isNotEmpty) {
      final fresh = await _store.load(file);
      for (final it in fresh) {
        final t = found[it.key];
        if (t != null) it.title = t;
      }
      await _store.save(file, fresh);
    }
  }

  // ---------------------------------------------------------------- add
  Future<void> _addFromText() async {
    final file = _active;
    if (file == null) return;
    final parsed = parseYtText(_addCtrl.text);
    if (parsed.isEmpty) {
      _snack('No YouTube video or playlist links found in the text.');
      return;
    }

    final toAdd = <YtItem>[];
    final notes = <String>[];
    for (final p in parsed) {
      if (!p.isPlaylist) {
        toAdd.add(p);
        continue;
      }
      setState(() => _busy = 'Reading playlist…');
      final res = await fetchPlaylist(p.id, onProgress: (n) {
        if (mounted) setState(() => _busy = 'Reading playlist… $n videos');
      });
      if (res.videos.isEmpty) {
        _failedPlaylists.add(p.id);
        notes.add(res.error ?? 'Playlist could not be read.');
        toAdd.add(p); // keep as a playlist entry so it can still be opened
      } else {
        if (res.error != null) notes.add(res.error!);
        toAdd.addAll(res.videos);
      }
    }
    if (mounted) setState(() => _busy = null);

    final current = await _store.load(file);
    final known = current.map((e) => e.key).toSet();
    int added = 0;
    for (final p in toAdd) {
      if (known.add(p.key)) {
        current.add(p);
        added++;
      }
    }
    await _store.save(file, current);
    _addCtrl.clear();
    if (!mounted) return;
    setState(() => _items = current);
    _snack(
      'Added $added to "${file.name}.m3u" (${toAdd.length - added} already there)${notes.isEmpty ? '' : '\n${notes.first}'}',
      success: notes.isEmpty,
    );
    _postProcess();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) setState(() => _addCtrl.text = data!.text!);
  }

  // ------------------------------------------------------------- file ops
  Future<String?> _askName(String title, {String initial = '', String hint = 'Name'}) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _newFile() async {
    final name = await _askName('New .m3u file', hint: 'e.g. Maths Videos');
    if (name == null) return;
    final safe = YtStore.safeName(name);
    if (safe.isEmpty) return;
    if (_files.any((f) => f.name.toLowerCase() == safe.toLowerCase())) {
      _snack('A file named "$safe.m3u" already exists.');
      return;
    }
    final f = await _store.create(safe);
    final files = await _store.listFiles();
    setState(() => _files = files);
    await _switchTo(f);
    _snack('Created "$safe.m3u". New shared links will be saved here.', success: true);
  }

  Future<void> _renameFile() async {
    final cur = _active;
    if (cur == null) return;
    final name = await _askName('Rename file', initial: cur.name);
    if (name == null) return;
    final safe = YtStore.safeName(name);
    if (safe.isEmpty || safe == cur.name) return;
    if (_files.any((f) => f.name.toLowerCase() == safe.toLowerCase())) {
      _snack('A file named "$safe.m3u" already exists.');
      return;
    }
    final renamed = await _store.rename(cur, safe);
    final files = await _store.listFiles();
    setState(() => _files = files);
    await _switchTo(renamed);
  }

  Future<void> _deleteFile() async {
    final cur = _active;
    if (cur == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${cur.name}.m3u"?'),
        content: const Text('The file and all links in it will be removed.'),
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
    await _store.delete(cur);
    var files = await _store.listFiles();
    if (files.isEmpty) files = [await _store.create(_defaultFile)];
    setState(() => _files = files);
    await _switchTo(files.first);
  }

  Future<void> _openEditor() async {
    final cur = _active;
    if (cur == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => M3uEditorScreen(file: cur)));
    await _refresh();
  }

  Future<void> _copyLinks(Iterable<YtItem> items) async {
    final list = items.toList();
    if (list.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: list.map((e) => e.webUrl).join('\n')));
    _snack('Copied ${list.length} link(s)', success: true);
  }

  Future<void> _toggleGrid() async {
    setState(() => _grid = !_grid);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('m3u_grid', _grid);
    } catch (_) {}
  }

  // ------------------------------------------------------------ item ops
  Future<void> _open(YtItem item) async {
    if (item.isOther) {
      _snack('This entry is not a YouTube link.');
      return;
    }
    final app = Uri.parse('vnd.youtube://${item.id}');
    final web = Uri.parse(item.webUrl);
    try {
      if (item.isVideo && await canLaunchUrl(app)) {
        await launchUrl(app, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _snack('Could not open YouTube.');
    }
  }

  Future<void> _removeItems(Set<String> keys) async {
    final file = _active;
    if (file == null || keys.isEmpty) return;
    final fresh = await _store.load(file);
    fresh.removeWhere((e) => keys.contains(e.key));
    await _store.save(file, fresh);
    if (!mounted) return;
    setState(() {
      _items = fresh;
      _selected.removeAll(keys);
    });
  }

  Future<void> _editTitle(YtItem item) async {
    final file = _active;
    if (file == null) return;
    final t = await _askName('Edit title', initial: item.title, hint: 'Title');
    if (t == null || t.isEmpty) return;
    final fresh = await _store.load(file);
    for (final e in fresh) {
      if (e.key == item.key) e.title = t;
    }
    await _store.save(file, fresh);
    if (mounted) setState(() => _items = fresh);
  }

  Future<void> _moveItems(List<YtItem> items) async {
    final cur = _active;
    if (cur == null || items.isEmpty) return;
    final others = _files.where((f) => f != cur).toList();
    if (others.isEmpty) {
      _snack('Create another .m3u file first (the "+ New file" chip).');
      return;
    }
    final target = await showDialog<M3uFile>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to file'),
        children: others.map((f) => SimpleDialogOption(onPressed: () => Navigator.pop(ctx, f), child: Text('${f.name}.m3u'))).toList(),
      ),
    );
    if (target == null) return;
    final dest = await _store.load(target);
    final known = dest.map((e) => e.key).toSet();
    for (final it in items) {
      if (known.add(it.key)) {
        dest.add(YtItem(kind: it.kind, id: it.id, title: it.title));
      }
    }
    await _store.save(target, dest);
    await _removeItems(items.map((e) => e.key).toSet());
    _snack('Moved ${items.length} to "${target.name}.m3u"', success: true);
  }

  // ---------------------------------------------------------------- UI
  Widget _thumb(YtItem item, {double radius = 12}) {
    Widget placeholder(IconData icon) => Container(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF2A2250), Color(0xFF3B2A6E)])),
          child: Center(child: Icon(icon, size: 40, color: Colors.white54)),
        );
    final selected = _selected.contains(item.key);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.isVideo)
              Image.network(
                item.thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => placeholder(Icons.play_circle_outline),
                loadingBuilder: (c, child, p) => p == null ? child : placeholder(Icons.play_circle_outline),
              )
            else
              placeholder(item.isPlaylist ? Icons.playlist_play : Icons.link),
            if (item.isPlaylist)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.playlist_play, size: 14, color: Colors.white),
                    SizedBox(width: 3),
                    Text('PLAYLIST', style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            if (selected)
              Container(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.55),
                child: const Center(child: Icon(Icons.check_circle, size: 40, color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _itemMenu(YtItem item) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      onSelected: (v) async {
        switch (v) {
          case 'open':
            _open(item);
            break;
          case 'copy':
            _copyLinks([item]);
            break;
          case 'edit':
            _editTitle(item);
            break;
          case 'expand':
            _failedPlaylists.remove(item.id);
            _expandPlaylists(onlyId: item.id);
            break;
          case 'move':
            _moveItems([item]);
            break;
          case 'delete':
            _removeItems({item.key});
            break;
        }
      },
      itemBuilder: (c) => [
        const PopupMenuItem(value: 'open', child: Text('Open in YouTube')),
        const PopupMenuItem(value: 'copy', child: Text('Copy link')),
        const PopupMenuItem(value: 'edit', child: Text('Edit title')),
        if (item.isPlaylist) const PopupMenuItem(value: 'expand', child: Text('Expand into videos')),
        const PopupMenuItem(value: 'move', child: Text('Move to another file')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  void _tap(YtItem item) {
    if (_selected.isNotEmpty) {
      setState(() {
        if (!_selected.add(item.key)) _selected.remove(item.key);
      });
    } else {
      _open(item);
    }
  }

  void _longPress(YtItem item) => setState(() => _selected.add(item.key));

  Widget _card(YtItem item, {required bool compact}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _tap(item),
      onLongPress: () => _longPress(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _thumb(item),
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title.isEmpty ? (item.isPlaylist ? 'YouTube playlist' : 'YouTube video') : item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: compact ? 13 : 15, fontWeight: FontWeight.w600, height: 1.25),
                      ),
                      if (!compact)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            item.isPlaylist ? 'Playlist • tap to open' : (item.isOther ? 'Link' : 'YouTube video'),
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: 32, height: 32, child: _itemMenu(item)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (_selected.isNotEmpty) {
      final chosen = _items.where((e) => _selected.contains(e.key)).toList();
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
        title: Text('${_selected.length} selected'),
        actions: [
          IconButton(
            tooltip: _selected.length == _items.length ? 'Deselect all' : 'Select all',
            icon: Icon(_selected.length == _items.length ? Icons.deselect : Icons.select_all),
            onPressed: () => setState(() {
              if (_selected.length == _items.length) {
                _selected.clear();
              } else {
                _selected.addAll(_items.map((e) => e.key));
              }
            }),
          ),
          IconButton(tooltip: 'Copy links', icon: const Icon(Icons.copy), onPressed: () => _copyLinks(chosen)),
          IconButton(tooltip: 'Move to another file', icon: const Icon(Icons.drive_file_move_outline), onPressed: () => _moveItems(chosen)),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: () => _removeItems(_selected.toSet()),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('M3U Files'),
      actions: [
        IconButton(
          tooltip: _grid ? 'Big cards' : 'Grid view',
          icon: Icon(_grid ? Icons.view_agenda_outlined : Icons.grid_view),
          onPressed: _toggleGrid,
        ),
        IconButton(tooltip: 'Edit as text (full page)', icon: const Icon(Icons.edit_note), onPressed: _openEditor),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'new':
                _newFile();
                break;
              case 'rename':
                _renameFile();
                break;
              case 'delete':
                _deleteFile();
                break;
              case 'copy':
                _copyLinks(_items);
                break;
              case 'expand':
                _failedPlaylists.clear();
                _postProcess();
                break;
              case 'select':
                setState(() => _selected.addAll(_items.map((e) => e.key)));
                break;
            }
          },
          itemBuilder: (c) => const [
            PopupMenuItem(value: 'new', child: Text('New .m3u file')),
            PopupMenuItem(value: 'select', child: Text('Select all')),
            PopupMenuItem(value: 'copy', child: Text('Copy all links')),
            PopupMenuItem(value: 'expand', child: Text('Expand playlists / fetch titles')),
            PopupMenuItem(value: 'rename', child: Text('Rename this file')),
            PopupMenuItem(value: 'delete', child: Text('Delete this file')),
          ],
        ),
      ],
    );
  }

  Widget _buildFeed() {
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.video_library_outlined, size: 56, color: Colors.white24),
              const SizedBox(height: 12),
              Text(
                'No videos in "${_active?.name}.m3u" yet.\nPaste links above, or share a video from the YouTube app.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }
    final feed = _grid
        ? LayoutBuilder(builder: (context, c) {
            const pad = 12.0, gap = 12.0;
            final w = (c.maxWidth - pad * 2 - gap) / 2;
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(pad, 4, pad, 24),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: gap,
                mainAxisSpacing: 14,
                mainAxisExtent: w * 9 / 16 + 62,
              ),
              itemCount: _items.length,
              itemBuilder: (context, i) => _card(_items[i], compact: true),
            );
          })
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 18),
            itemBuilder: (context, i) => _card(_items[i], compact: false),
          );
    return RefreshIndicator(onRefresh: _refresh, child: feed);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: _buildAppBar(),
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
                      ..._files.map((f) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              avatar: f == _active ? const Icon(Icons.download_done, size: 16) : null,
                              label: Text('${f.name}.m3u'),
                              selected: f == _active,
                              selectedColor: primary,
                              onSelected: (_) => _switchTo(f),
                            ),
                          )),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('New file'),
                        onPressed: _newFile,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: primary.withOpacity(0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.share, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'YouTube → Share → TubeBox saves straight into "${_active?.name}.m3u"',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _addCtrl,
                          minLines: 1,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            hintText: 'Paste video or playlist links…',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(tooltip: 'Paste', onPressed: _pasteFromClipboard, icon: const Icon(Icons.paste)),
                      FilledButton(
                        onPressed: _busy == null ? _addFromText : null,
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16)),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),
                if (_busy != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                    child: Row(
                      children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 10),
                        Text(_busy!, style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('${_items.length} item(s)', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ),
                ),
                Expanded(child: _buildFeed()),
              ],
            ),
    );
  }
}

// ============================================================================
// FULL-PAGE .m3u TEXT EDITOR  (select all, cut, copy, paste, undo, redo, save)
// ============================================================================
class M3uEditorScreen extends StatefulWidget {
  final M3uFile file;
  const M3uEditorScreen({Key? key, required this.file}) : super(key: key);

  @override
  _M3uEditorScreenState createState() => _M3uEditorScreenState();
}

class _M3uEditorScreenState extends State<M3uEditorScreen> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final UndoHistoryController _undo = UndoHistoryController();
  bool _loading = true;
  bool _dirty = false;
  String _saved = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _undo.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.file.path);
      _saved = await f.exists() ? await f.readAsString() : '';
    } catch (e) {
      _saved = '';
    }
    _ctrl.text = _saved;
    _ctrl.addListener(() {
      if (mounted) setState(() => _dirty = _ctrl.text != _saved);
    });
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.green : Colors.redAccent,
      duration: const Duration(seconds: 2),
    ));
  }

  TextSelection get _sel => _ctrl.selection;
  bool get _hasSel => _sel.isValid && !_sel.isCollapsed;

  void _selectAll() {
    _focus.requestFocus();
    _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
  }

  Future<void> _copy() async {
    final text = _hasSel ? _sel.textInside(_ctrl.text) : _ctrl.text;
    await Clipboard.setData(ClipboardData(text: text));
    _snack(_hasSel ? 'Copied selection' : 'Nothing selected - copied the whole file', success: true);
  }

  Future<void> _cut() async {
    if (!_hasSel) {
      _snack('Select some text first (or use Select all).');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _sel.textInside(_ctrl.text)));
    _replaceSelection('');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text == null || data!.text!.isEmpty) {
      _snack('Clipboard is empty.');
      return;
    }
    _replaceSelection(data.text!);
  }

  void _replaceSelection(String insert) {
    final text = _ctrl.text;
    final start = _sel.isValid ? _sel.start : text.length;
    final end = _sel.isValid ? _sel.end : text.length;
    final newText = text.replaceRange(start, end, insert);
    _ctrl.value = TextEditingValue(text: newText, selection: TextSelection.collapsed(offset: start + insert.length));
    _focus.requestFocus();
  }

  void _clearAll() {
    _ctrl.value = const TextEditingValue(text: '#EXTM3U\n', selection: TextSelection.collapsed(offset: 8));
  }

  Future<bool> _save() async {
    try {
      await File(widget.file.path).writeAsString(_ctrl.text);
      _saved = _ctrl.text;
      setState(() => _dirty = false);
      _snack('Saved ${widget.file.name}.m3u', success: true);
      return true;
    } catch (e) {
      _snack('Could not save: $e');
      return false;
    }
  }

  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Save your changes to this .m3u file before leaving?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Keep editing')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard', style: TextStyle(color: Colors.redAccent))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'save') {
      if (await _save() && mounted) Navigator.pop(context, true);
    } else if (choice == 'discard') {
      Navigator.pop(context, false);
    }
  }

  Widget _tool(IconData icon, String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = _ctrl.text.isEmpty ? 0 : '\n'.allMatches(_ctrl.text).length + 1;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.file.name}.m3u${_dirty ? ' •' : ''}', overflow: TextOverflow.ellipsis),
          actions: [
            ValueListenableBuilder<UndoHistoryValue>(
              valueListenable: _undo,
              builder: (context, v, _) => Row(children: [
                IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: v.canUndo ? _undo.undo : null),
                IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: v.canRedo ? _undo.redo : null),
              ]),
            ),
            IconButton(
              tooltip: 'Save',
              icon: Icon(Icons.save, color: _dirty ? Colors.greenAccent : null),
              onPressed: _dirty ? _save : null,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        undoController: _undo,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        enableSuggestions: false,
                        autocorrect: false,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35),
                        decoration: const InputDecoration(hintText: '#EXTM3U …', contentPadding: EdgeInsets.all(12)),
                      ),
                    ),
                  ),
                  Container(
                    color: kEditorBar,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(children: [
                              _tool(Icons.select_all, 'Select all', _selectAll),
                              _tool(Icons.content_cut, 'Cut', _cut),
                              _tool(Icons.copy, 'Copy', _copy),
                              _tool(Icons.paste, 'Paste', _paste),
                              _tool(Icons.delete_sweep, 'Clear', _clearAll),
                              _tool(Icons.save, 'Save', _dirty ? _save : null),
                            ]),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('$lines lines • ${_ctrl.text.length} characters', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

const Color kEditorBar = Color(0xFF1B1633);
