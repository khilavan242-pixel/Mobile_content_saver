import 'dart:async';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'prefs.dart';
import 'package:url_launcher/url_launcher.dart';

import 'm3u_editor.dart';
import 'm3u_store.dart';
import 'player_host.dart';
import 'tv_focus.dart';
import 'tv_keyboard.dart';
import 'voice_search.dart';
import 'tv_sync.dart';
import 'youtube_core.dart';

enum _Scope { current, all, custom }

class _AddRequest {
  final String text;
  final M3uFile file;
  final bool numbered;
  final String group;
  final String subject;
  final int? startChapter;
  final String customName;
  _AddRequest({
    required this.text,
    required this.file,
    required this.numbered,
    required this.group,
    required this.subject,
    required this.startChapter,
    required this.customName,
  });
}

Color _statusColor(String s) => s == 'unavailable' ? Colors.redAccent : (s == 'kodi_error' ? Colors.orange : Colors.green);

// ============================================================================
// SCREEN: YouTube-style thumbnail view of one, several or all .m3u files
// ============================================================================
class M3uFilesScreen extends StatefulWidget {
  final String basePath;
  final ValueNotifier<bool> navVisible;
  final VoidCallback onGoToTvSync;
  /// TV: the side menu asks for the search box through this.
  final ValueNotifier<int>? searchRequest;
  /// Phone: the bottom bar's "+" asks for the add-links sheet through this.
  final ValueNotifier<int>? addRequest;
  /// Phone: the bottom bar's Menu asks for the file actions (the old three-dot menu) through this.
  final ValueNotifier<int>? menuRequest;
  /// Phone: extra rows (change folder, TV, exit) shown below the file actions in that menu.
  final List<Widget> Function(BuildContext sheetContext)? menuExtras;
  /// TV: width taken by the collapsed side menu on the left.
  final double railInset;
  const M3uFilesScreen({
    Key? key,
    required this.basePath,
    required this.navVisible,
    required this.onGoToTvSync,
    this.searchRequest,
    this.addRequest,
    this.menuRequest,
    this.menuExtras,
    this.railInset = 0,
  }) : super(key: key);

  @override
  _M3uFilesScreenState createState() => _M3uFilesScreenState();
}

class _M3uFilesScreenState extends State<M3uFilesScreen> with WidgetsBindingObserver {
  late final YtStore _store;
  final TextEditingController _searchCtrl = TextEditingController();

  List<M3uFile> _files = [];
  M3uFile? _active; // where new links / YouTube shares are saved
  _Scope _scope = _Scope.current;
  final Set<String> _customPaths = {};
  final Map<String, List<YtItem>> _data = {};
  final Set<String> _selected = {};

  String _query = '';
  String _type = 'all'; // all | video | playlist
  String _status = 'all'; // all | working | unavailable | kodi_error
  String? _group;
  String _sort = 'file'; // file | newest | title | chapter

  bool _ready = false;
  bool _grid = true;
  String? _busy;
  bool _working = false;
  final Set<String> _failedPlaylists = {};

  static const String _defaultFile = 'Master_Playlist';

  @override
  void initState() {
    super.initState();
    _store = YtStore(widget.basePath);
    WidgetsBinding.instance.addObserver(this);
    widget.searchRequest?.addListener(_onSearchRequest);
    widget.addRequest?.addListener(_onAddRequest);
    widget.menuRequest?.addListener(_onMenuRequest);
    TvKeyboardHost.visibleNotifier.addListener(_onKbVisible);
    _init();
  }

  void _onMenuRequest() {
    if (mounted && _ready) _openMenuSheet();
  }

  /// The former three-dot menu, now part of the bottom "Menu" sheet.
  Future<void> _openMenuSheet() async {
    Widget tile(IconData icon, String title, VoidCallback run) => ListTile(
          dense: true,
          leading: Icon(icon),
          title: Text(title),
          onTap: () {
            Navigator.pop(context);
            run();
          },
        );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF1B1633),
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: ListView(shrinkWrap: true, children: [
            tile(_grid ? Icons.view_agenda_outlined : Icons.grid_view, _grid ? 'Switch to big cards' : 'Switch to grid', _toggleGrid),
            tile(Icons.edit_note, 'Edit .m3u as text (full page)', _openEditor),
            tile(Icons.fact_check_outlined, 'Check which videos play', () => _checkAvailability(_visible())),
            tile(Icons.cast_connected, 'Send this file to my TV', _sendToTv),
            tile(Icons.select_all, 'Select all', () => setState(() => _selected.addAll(_visible().map((e) => e.id)))),
            tile(Icons.copy, 'Copy links', () => _copyLinks(_visible().map((e) => e.item))),
            tile(Icons.playlist_add_check, 'Expand playlists / fetch titles', () {
              _failedPlaylists.clear();
              _postProcess();
            }),
            tile(Icons.note_add_outlined, 'New .m3u file', _newFile),
            tile(Icons.drive_file_rename_outline, 'Rename this file', _renameFile),
            tile(Icons.delete_outline, 'Delete this file', _deleteFile),
            if (widget.menuExtras != null) ...[const Divider(), ...widget.menuExtras!(c)],
          ]),
        ),
      ),
    );
  }

  bool _phoneSearching = false;

  void _onAddRequest() {
    if (mounted && _ready) _showAddSheet();
  }

  void _onSearchRequest() {
    if (!mounted || !_ready) return;
    if (_isTv) {
      _startTvSearch();
    } else {
      setState(() => _phoneSearching = true);
    }
  }

  // TV: the search box becomes a real text box; the on-screen keyboard (tv_keyboard.dart) types into it.
  bool _tvEditing = false;
  final FocusNode _searchFocus = FocusNode();
  bool _kbWasVisible = false;

  void _onKbVisible() {
    final v = TvKeyboardHost.visibleNotifier.value;
    if (_kbWasVisible && !v && _tvEditing && mounted) setState(() => _tvEditing = false);
    _kbWasVisible = v;
  }

  void _startTvSearch() {
    widget.navVisible.value = true;
    setState(() => _tvEditing = true);
  }

  @override
  void dispose() {
    widget.searchRequest?.removeListener(_onSearchRequest);
    widget.addRequest?.removeListener(_onAddRequest);
    TvKeyboardHost.visibleNotifier.removeListener(_onKbVisible);
    _hintTimer?.cancel();
    widget.menuRequest?.removeListener(_onMenuRequest);
    _searchFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Videos shared from the YouTube app land in the file while we are away.
    if (state == AppLifecycleState.resumed && _ready) _refresh();
  }

  void _snack(String msg, {bool success = false, SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.green : Colors.redAccent,
      action: action,
    ));
  }

  // ------------------------------------------------------------------ loading
  List<M3uFile> get _scopeFiles {
    switch (_scope) {
      case _Scope.all:
        return _files;
      case _Scope.custom:
        final l = _files.where((f) => _customPaths.contains(f.path)).toList();
        return l.isEmpty && _active != null ? [_active!] : l;
      case _Scope.current:
        return _active == null ? <M3uFile>[] : [_active!];
    }
  }

  bool _showShareHint = false;
  Timer? _hintTimer;

  /// "Share → TubeBox saves into X.m3u" reminder: shown for a few seconds on start / file change.
  void _flashShareHint() {
    _hintTimer?.cancel();
    if (mounted) setState(() => _showShareHint = true);
    _hintTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _showShareHint = false);
    });
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _grid = prefs.getBool('m3u_grid') ?? true;
      var files = await _store.listFiles();
      if (files.isEmpty) files = [await _store.create(_defaultFile)];
      _files = files;
      final savedPath = prefs.getString('m3u_active_file');
      _active = files.firstWhere(
        (f) => f.path == savedPath,
        orElse: () => files.firstWhere((f) => f.name == _defaultFile, orElse: () => files.first),
      );
      await prefs.setString('m3u_active_file', _active!.path);
      await _importPending();
      await _loadScope();
      await _store.writeShareConfig(_active!);
    } catch (e) {
      _snack('Could not open files: $e');
    }
    if (!mounted) return;
    setState(() => _ready = true);
    _flashShareHint();
    _postProcess();
  }

  Future<void> _importPending() async {
    final file = _active;
    if (file == null) return;
    final pending = await _store.takePendingShares();
    if (pending.isEmpty) return;
    await _store.update(file, (items) {
      final known = items.map((e) => e.key).toSet();
      for (final p in pending) {
        if (known.add(p.key)) items.add(p);
      }
    });
  }

  Future<void> _loadScope() async {
    final fresh = <String, List<YtItem>>{};
    for (final f in _scopeFiles) {
      fresh[f.path] = await _store.load(f);
    }
    _data
      ..clear()
      ..addAll(fresh);
    final ids = _data.entries.expand((e) => e.value.map((i) => '${e.key}|${i.key}')).toSet();
    _selected.removeWhere((k) => !ids.contains(k));
    if (_group != null && !_groups().contains(_group)) _group = null;
  }

  Future<void> _refresh() async {
    if (_active == null) return;
    try {
      final files = await _store.listFiles();
      if (files.isNotEmpty) _files = files;
      if (!_files.contains(_active)) _active = _files.first;
      await _importPending();
      await _loadScope();
      if (!mounted) return;
      setState(() {});
      _postProcess();
    } catch (_) {}
  }

  Future<void> _switchTo(M3uFile f) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('m3u_active_file', f.path);
    _active = f;
    _scope = _Scope.current;
    _selected.clear();
    _group = null;
    await _loadScope();
    await _store.writeShareConfig(f);
    if (!mounted) return;
    setState(() {});
    _flashShareHint();
    _postProcess();
  }

  Future<void> _setScope(_Scope s, {Set<String>? custom}) async {
    _scope = s;
    if (custom != null) {
      final copy = Set<String>.from(custom); // `custom` may be _customPaths itself
      _customPaths
        ..clear()
        ..addAll(copy);
    }
    _selected.clear();
    await _loadScope();
    if (mounted) setState(() {});
    _postProcess();
  }

  /// Change one file on disk, then refresh the view.
  Future<void> _mutate(M3uFile f, void Function(List<YtItem> items) change) async {
    await _store.update(f, change);
    await _loadScope();
    if (mounted) setState(() {});
  }

  // ------------------------------------------------- background processing
  Future<void> _postProcess() async {
    if (_working || _active == null) return;
    _working = true;
    try {
      for (final f in List<M3uFile>.from(_scopeFiles)) {
        await _expandPlaylists(f);
        await _fillTitles(f);
      }
    } finally {
      _working = false;
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Turns playlist entries into their videos (in place).
  Future<void> _expandPlaylists(M3uFile file, {String? onlyId}) async {
    final items = _data[file.path] ?? [];
    final targets = items.where((e) => e.isPlaylist && (onlyId == null ? !_failedPlaylists.contains(e.id) : e.id == onlyId)).toList();
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
      int added = 0;
      await _mutate(file, (fresh) {
        final known = fresh.where((e) => !e.isPlaylist || !results.containsKey(e.id)).map((e) => e.key).toSet();
        final out = <YtItem>[];
        for (final it in fresh) {
          final r = it.isPlaylist ? results[it.id] : null;
          if (r == null) {
            out.add(it);
            continue;
          }
          for (final v in r.videos) {
            if (known.add(v.key)) {
              v.group = it.group; // keep the playlist's category
              out.add(v);
              added++;
            }
          }
        }
        fresh
          ..clear()
          ..addAll(out);
        renumberGroups(fresh, out.map((e) => e.group));
      });
      _snack('Playlist expanded: $added video(s) added', success: true);
    }
    if (lastError != null) _snack(lastError);
  }

  /// Fills in missing titles and flags ids that do not exist at all.
  Future<void> _fillTitles(M3uFile file) async {
    final items = _data[file.path] ?? [];
    final missing = items.where((e) => e.isVideo && !e.hasRealTitle).toList();
    if (missing.isEmpty) return;
    final titles = <String, String>{};
    final dead = <String>{};
    for (final it in missing) {
      final info = await fetchYtInfo(it);
      if (info.title != null) titles[it.key] = info.title!;
      if (info.notFound) dead.add(it.key);
    }
    if (titles.isEmpty && dead.isEmpty) return;
    await _mutate(file, (fresh) {
      for (final it in fresh) {
        final t = titles[it.key];
        if (t != null && !it.hasRealTitle) {
          it.title = it.chapter != null ? 'CH${it.chapter}: $t' : t;
        }
        if (dead.contains(it.key) && it.status == 'working') it.status = 'unavailable';
      }
    });
    if (dead.isNotEmpty) {
      _snack('${dead.length} video(s) do not exist on YouTube and were marked unavailable.');
    }
  }

  /// Accurate check of every video in [entries] (deleted / private / invalid id).
  Future<void> _checkAvailability(List<Entry> entries) async {
    final videos = entries.where((e) => e.item.isVideo).toList();
    if (videos.isEmpty) {
      _snack('No videos to check.');
      return;
    }
    final results = <String, bool?>{};
    int done = 0;
    for (int i = 0; i < videos.length; i += 3) {
      final batch = videos.sublist(i, i + 3 > videos.length ? videos.length : i + 3);
      final r = await Future.wait(batch.map((e) => checkVideoPlayable(e.item.id)));
      for (int k = 0; k < batch.length; k++) {
        results[batch[k].id] = r[k];
      }
      done += batch.length;
      if (mounted) setState(() => _busy = 'Checking videos… $done/${videos.length}');
    }
    if (mounted) setState(() => _busy = null);

    int bad = 0;
    int unknown = 0;
    final byFile = <String, List<Entry>>{};
    for (final e in videos) {
      byFile.putIfAbsent(e.file.path, () => []).add(e);
    }
    for (final group in byFile.values) {
      final file = group.first.file;
      await _mutate(file, (fresh) {
        for (final it in fresh) {
          final r = results['${file.path}|${it.key}'];
          if (!results.containsKey('${file.path}|${it.key}')) continue;
          if (r == false) {
            it.status = 'unavailable';
          } else if (r == true && it.status == 'unavailable') {
            it.status = 'working';
          }
        }
      });
      for (final e in group) {
        final r = results[e.id];
        if (r == false) bad++;
        if (r == null) unknown++;
      }
    }
    _snack(
      bad == 0 ? 'All checked videos can play${unknown > 0 ? ' ($unknown could not be checked)' : ''}.' : '$bad video(s) cannot play on YouTube (deleted, private or wrong link).',
      success: bad == 0,
      action: bad == 0
          ? null
          : SnackBarAction(
              label: 'SHOW',
              textColor: Colors.white,
              onPressed: () => setState(() => _status = 'unavailable'),
            ),
    );
  }

  // ------------------------------------------------------------- adding
  Future<void> _showAddSheet() async {
    final file = _active;
    if (file == null) return;
    final req = await showModalBottomSheet<_AddRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AddSheet(store: _store, files: _files, active: file),
    );
    if (req == null) return;
    await _addLinks(req);
  }

  Future<void> _addLinks(_AddRequest req) async {
    final text = req.text.trim();
    if (text.isEmpty) return;

    List<YtItem> toAdd = [];
    final notes = <String>[];

    if (text.contains('#EXTINF')) {
      toAdd = parseM3uLines(text.split('\n'));
      if (toAdd.isEmpty) {
        _snack('No playable entries found in the pasted M3U text.');
        return;
      }
    } else {
      final parsed = parseYtText(text);
      if (parsed.isEmpty) {
        _snack('No YouTube video or playlist links found in the text.');
        return;
      }
      for (final p in parsed) {
        if (!p.isPlaylist) {
          toAdd.add(p);
          continue;
        }
        if (mounted) setState(() => _busy = 'Reading playlist…');
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
    }

    int added = 0;
    int firstChapter = 0;
    await _mutate(req.file, (items) {
      final known = items.map((e) => e.key).toSet();
      int chapter = req.startChapter ?? (req.numbered ? nextChapter(items, req.group) : 0);
      firstChapter = chapter;
      final fresh = toAdd.where((e) => known.add(e.key)).toList();
      for (int i = 0; i < fresh.length; i++) {
        final it = fresh[i];
        if (req.numbered) {
          it.group = req.group;
          String base;
          if (req.customName.isNotEmpty) {
            base = fresh.length > 1 ? '${req.customName} (Part ${i + 1})' : req.customName;
          } else if (it.hasRealTitle) {
            base = it.plainTitle;
          } else {
            base = it.isPlaylist ? '${req.subject} Playlist' : '${req.subject} Lesson';
          }
          it.title = base;
          it.setChapter(chapter++);
        } else if (req.customName.isNotEmpty) {
          it.title = fresh.length > 1 ? '${req.customName} (Part ${i + 1})' : req.customName;
        }
        items.add(it);
        added++;
      }
    });

    // Make sure the user sees what they just added.
    if (_active != req.file) {
      await _switchTo(req.file);
    } else if (_scope == _Scope.custom && !_customPaths.contains(req.file.path)) {
      _customPaths.add(req.file.path);
      await _loadScope();
    }
    if (!mounted) return;
    setState(() {});
    _snack(
      added == 0
          ? 'Everything was already in "${req.file.name}.m3u".'
          : 'Added $added to "${req.file.name}.m3u"${req.numbered ? ' from CH$firstChapter' : ''} (${toAdd.length - added} already there)${notes.isEmpty ? '' : '\n${notes.first}'}',
      success: notes.isEmpty && added > 0,
    );
    _postProcess();
  }

  // ------------------------------------------------------------- file ops
  Future<String?> _askName(String title, {String initial = '', String hint = 'Name', TextInputType? type}) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: type,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
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
    _files = await _store.listFiles();
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
    _files = await _store.listFiles();
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
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.delete(cur);
    var files = await _store.listFiles();
    if (files.isEmpty) files = [await _store.create(_defaultFile)];
    _files = files;
    await _switchTo(files.first);
  }

  Future<void> _openEditor() async {
    final cur = _active;
    if (cur == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => M3uEditorScreen(file: cur)));
    await _refresh();
  }

  Future<void> _sendToTv() async {
    final cur = _active;
    if (cur == null) return;
    _snack('Sending "${cur.name}.m3u" to your TV…', success: true);
    final r = await quickSendToTv(cur.path, cur.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (r.needSetup) {
      widget.onGoToTvSync();
    }
    _snack(r.message, success: r.ok);
  }

  Future<void> _toggleGrid() async {
    setState(() => _grid = !_grid);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('m3u_grid', _grid);
    } catch (_) {}
  }

  // ------------------------------------------------------------ item ops
  Future<void> _copyLinks(Iterable<YtItem> items) async {
    final list = items.toList();
    if (list.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: list.map((e) => e.webUrl).join('\n')));
    _snack('Copied ${list.length} link(s)', success: true);
  }

  Future<void> _open(YtItem item) async {
    if (item.isOther) {
      _snack('This entry is not a YouTube link.');
      return;
    }
    if (!item.isOther) {
      // Same link the YouTube share button gives (youtu.be/ID), sent straight
      // to the YouTube app, so it behaves exactly like tapping a shared link.
      for (final pkg in const ['com.google.android.youtube', 'com.google.android.youtube.tv']) {
        try {
          await AndroidIntent(action: 'action_view', data: item.webUrl, package: pkg).launch();
          return;
        } catch (_) {}
      }
    }
    try {
      final ok = await launchUrl(Uri.parse(item.webUrl), mode: LaunchMode.externalApplication);
      if (!ok) _snack('Could not open YouTube.');
    } catch (_) {
      _snack('Could not open YouTube.');
    }
  }

  List<Entry> _chosen() {
    final out = <Entry>[];
    for (final f in _scopeFiles) {
      for (final it in _data[f.path] ?? const <YtItem>[]) {
        if (_selected.contains('${f.path}|${it.key}')) out.add(Entry(f, it));
      }
    }
    return out;
  }

  Map<M3uFile, List<Entry>> _byFile(List<Entry> entries) {
    final m = <M3uFile, List<Entry>>{};
    for (final e in entries) {
      m.putIfAbsent(e.file, () => []).add(e);
    }
    return m;
  }

  Future<void> _deleteEntries(List<Entry> entries) async {
    for (final g in _byFile(entries).entries) {
      final keys = g.value.map((e) => e.item.key).toSet();
      await _mutate(g.key, (items) {
        final groups = items.where((e) => keys.contains(e.key)).map((e) => e.group).toSet();
        items.removeWhere((e) => keys.contains(e.key));
        renumberGroups(items, groups);
      });
    }
    if (mounted) setState(_selected.clear);
  }

  Future<void> _setStatus(List<Entry> entries, String status) async {
    for (final g in _byFile(entries).entries) {
      final keys = g.value.map((e) => e.item.key).toSet();
      await _mutate(g.key, (items) {
        for (final it in items) {
          if (keys.contains(it.key)) it.status = status;
        }
      });
    }
    _snack('Marked ${entries.length} as ${status.replaceAll('_', ' ')}', success: true);
  }

  Future<void> _moveEntries(List<Entry> entries) async {
    if (entries.isEmpty) return;
    final sources = _byFile(entries).keys.toSet();
    final others = _files.where((f) => !(sources.length == 1 && sources.contains(f))).toList();
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
    final moving = entries.where((e) => e.file != target).toList();
    await _mutate(target, (items) {
      final known = items.map((e) => e.key).toSet();
      final groups = <String>{};
      for (final e in moving) {
        if (known.add(e.item.key)) {
          items.add(e.item);
          groups.add(e.item.group);
        }
      }
      renumberGroups(items, groups);
    });
    for (final g in _byFile(moving).entries) {
      final keys = g.value.map((e) => e.item.key).toSet();
      await _mutate(g.key, (items) {
        final groups = items.where((e) => keys.contains(e.key)).map((e) => e.group).toSet();
        items.removeWhere((e) => keys.contains(e.key));
        renumberGroups(items, groups);
      });
    }
    if (mounted) setState(_selected.clear);
    _snack('Moved ${moving.length} to "${target.name}.m3u"', success: true);
  }

  Future<void> _setGroup(List<Entry> entries) async {
    if (entries.isEmpty) return;
    final groups = _allGroups();
    final ctrl = TextEditingController(text: entries.first.item.group);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to category'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'e.g. Lakshya - Maths')),
              if (groups.isNotEmpty) const SizedBox(height: 12),
              if (groups.isNotEmpty) const Text('Existing categories', style: TextStyle(color: Colors.grey, fontSize: 12)),
              Wrap(
                spacing: 8,
                children: groups.map((g) => ActionChip(label: Text(g), onPressed: () => ctrl.text = g)).toList(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Move')),
        ],
      ),
    );
    if (value == null) return;
    for (final g in _byFile(entries).entries) {
      final keys = g.value.map((e) => e.item.key).toSet();
      await _mutate(g.key, (items) {
        final affected = <String>{value};
        for (final it in items) {
          if (keys.contains(it.key)) {
            affected.add(it.group);
            it.group = value;
          }
        }
        renumberGroups(items, affected);
      });
    }
    if (mounted) setState(_selected.clear);
    _snack('Moved ${entries.length} to "${value.isEmpty ? 'no category' : value}"', success: true);
  }

  Future<void> _editEntry(Entry e) async {
    final titleCtrl = TextEditingController(text: e.item.title);
    final groupCtrl = TextEditingController(text: e.item.group);
    final linkCtrl = TextEditingController(text: e.item.webUrl);
    String status = e.item.status;
    final groups = _allGroups();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Edit video'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Title')),
                const SizedBox(height: 10),
                TextField(controller: groupCtrl, decoration: const InputDecoration(labelText: 'Category (group)')),
                if (groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      children: groups.map((g) => ActionChip(label: Text(g), onPressed: () => groupCtrl.text = g)).toList(),
                    ),
                  ),
                const SizedBox(height: 10),
                TextField(controller: linkCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'YouTube link')),
                const SizedBox(height: 12),
                const Text('Status', style: TextStyle(color: Colors.grey, fontSize: 12)),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final s in const ['working', 'unavailable', 'kodi_error'])
                      ChoiceChip(
                        label: Text(s.replaceAll('_', ' ')),
                        selected: status == s,
                        onSelected: (_) => setD(() => status = s),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final oldKey = e.item.key;
    final newTitle = titleCtrl.text.trim();
    final newGroup = groupCtrl.text.trim();
    final parsed = parseYtText(linkCtrl.text);
    await _mutate(e.file, (items) {
      final idx = items.indexWhere((x) => x.key == oldKey);
      if (idx < 0) return;
      var it = items[idx];
      final oldGroup = it.group;
      if (parsed.isNotEmpty && parsed.first.key != oldKey) {
        final np = parsed.first;
        np.attrs.addAll(it.attrs);
        np.duration = it.duration;
        np.title = it.title;
        it = np;
        items[idx] = it;
      }
      if (newTitle.isNotEmpty) it.title = newTitle;
      it.group = newGroup;
      it.status = status;
      renumberGroups(items, {oldGroup, newGroup});
    });
  }

  // ------------------------------------------------------------- derived
  List<String> _groups() {
    final s = <String>{};
    for (final f in _scopeFiles) {
      for (final it in _data[f.path] ?? const <YtItem>[]) {
        if (it.group.isNotEmpty) s.add(it.group);
      }
    }
    final l = s.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return l;
  }

  List<String> _allGroups() => _groups();

  List<Entry> _visible() {
    final q = _query.trim().toLowerCase();
    final out = <Entry>[];
    for (final f in _scopeFiles) {
      for (final it in _data[f.path] ?? const <YtItem>[]) {
        if (_type == 'video' && !it.isVideo) continue;
        if (_type == 'playlist' && !it.isPlaylist) continue;
        if (_status != 'all' && it.status != _status) continue;
        if (_group != null && it.group != _group) continue;
        if (q.isNotEmpty && !('${it.title} ${it.group} ${it.id}'.toLowerCase().contains(q))) continue;
        out.add(Entry(f, it));
      }
    }
    if (_sort == 'newest') {
      out.setAll(0, out.reversed.toList());
    } else if (_sort == 'title') {
      out.sort((a, b) => a.item.plainTitle.toLowerCase().compareTo(b.item.plainTitle.toLowerCase()));
    } else if (_sort == 'chapter') {
      out.sort((a, b) {
        final g = a.item.group.compareTo(b.item.group);
        if (g != 0) return g;
        return (a.item.chapter ?? 1 << 30).compareTo(b.item.chapter ?? 1 << 30);
      });
    }
    return out;
  }

  int get _unavailableCount {
    int n = 0;
    for (final f in _scopeFiles) {
      for (final it in _data[f.path] ?? const <YtItem>[]) {
        if (it.status == 'unavailable') n++;
      }
    }
    return n;
  }

  bool get _filtersActive => _type != 'all' || _status != 'all' || _group != null || _scope == _Scope.custom || _sort != 'file';

  void _resetFilters() {
    setState(() {
      _type = 'all';
      _status = 'all';
      _group = null;
      _sort = 'file';
    });
  }

  // ------------------------------------------------------- filter sheet
  Future<void> _showFilterSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          void both(VoidCallback f) {
            setState(f);
            setS(() {});
          }

          Widget label(String t) => Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 6),
                child: Text(t, style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600)),
              );

          bool inView(M3uFile f) => _scope == _Scope.current ? f == _active : (_scope == _Scope.custom && _customPaths.contains(f.path));

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Filters', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      TextButton(
                        onPressed: () async {
                          _resetFilters();
                          if (_scope != _Scope.current) await _setScope(_Scope.current);
                          setS(() {});
                        },
                        child: const Text('Reset', style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                  label('FILES'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        avatar: const Icon(Icons.library_books_outlined, size: 16),
                        label: const Text('All files'),
                        selected: _scope == _Scope.all,
                        onSelected: (_) async {
                          await _setScope(_Scope.all);
                          setS(() {});
                        },
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.checklist, size: 16),
                        label: const Text('Pick several'),
                        selected: _scope == _Scope.custom,
                        onSelected: (_) async {
                          await _setScope(_Scope.custom, custom: _customPaths.isEmpty && _active != null ? {_active!.path} : _customPaths);
                          setS(() {});
                        },
                      ),
                      for (final f in _files)
                        FilterChip(
                          avatar: f == _active ? const Icon(Icons.download_done, size: 16) : null,
                          label: Text('${f.name}.m3u'),
                          selected: inView(f),
                          onSelected: (v) async {
                            if (_scope == _Scope.custom) {
                              final next = Set<String>.from(_customPaths);
                              v ? next.add(f.path) : next.remove(f.path);
                              if (next.isEmpty) return;
                              await _setScope(_Scope.custom, custom: next);
                            } else {
                              await _switchTo(f);
                            }
                            setS(() {});
                          },
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('New file'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _newFile();
                        },
                      ),
                    ],
                  ),
                  label('SHOW'),
                  Wrap(spacing: 8, children: [
                    for (final t in const [('all', 'Everything'), ('video', 'Videos'), ('playlist', 'Playlists')])
                      ChoiceChip(label: Text(t.$2), selected: _type == t.$1, onSelected: (_) => both(() => _type = t.$1)),
                  ]),
                  if (_groups().isNotEmpty) label('CATEGORY'),
                  if (_groups().isNotEmpty)
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      ChoiceChip(label: const Text('All'), selected: _group == null, onSelected: (_) => both(() => _group = null)),
                      for (final g in _groups())
                        ChoiceChip(label: Text(g), selected: _group == g, onSelected: (_) => both(() => _group = g)),
                    ]),
                  label('VIDEO STATUS'),
                  Wrap(spacing: 8, children: [
                    for (final t in [('all', 'Any'), ('working', 'Plays fine'), ('unavailable', 'Unavailable ($_unavailableCount)')])
                      ChoiceChip(label: Text(t.$2), selected: _status == t.$1, onSelected: (_) => both(() => _status = t.$1)),
                  ]),
                  label('SORT BY'),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final t in const [('file', 'Saved order'), ('newest', 'Newest first'), ('title', 'Title A–Z'), ('chapter', 'Category & chapter')])
                      ChoiceChip(label: Text(t.$2), selected: _sort == t.$1, onSelected: (_) => both(() => _sort = t.$1)),
                  ]),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(onPressed: () => Navigator.pop(ctx), child: Text('Show ${_visible().length} items')),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- UI
  Widget _thumb(Entry e) {
    final item = e.item;
    Widget placeholder(IconData icon) => Container(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF2A2250), Color(0xFF3B2A6E)])),
          child: Center(child: Icon(icon, size: 40, color: Colors.white54)),
        );
    final selected = _selected.contains(e.id);
    final bad = item.status != 'working';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.isVideo)
              Image.network(
                item.thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (c, err, s) => placeholder(Icons.play_circle_outline),
                loadingBuilder: (c, child, p) => p == null ? child : placeholder(Icons.play_circle_outline),
              )
            else
              placeholder(item.isPlaylist ? Icons.playlist_play : Icons.link),
            if (bad) Container(color: Colors.black.withOpacity(0.45)),
            if (bad)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: _statusColor(item.status), borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    item.status == 'unavailable' ? 'UNAVAILABLE' : 'KODI ERROR',
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
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

  Widget _itemMenu(Entry e) {
    final item = e.item;
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'play':
            _play(e);
            break;
          case 'open':
            _open(item);
            break;
          case 'copy':
            _copyLinks([item]);
            break;
          case 'edit':
            _editEntry(e);
            break;
          case 'expand':
            _failedPlaylists.remove(item.id);
            _expandPlaylists(e.file, onlyId: item.id);
            break;
          case 'working':
          case 'unavailable':
          case 'kodi_error':
            _setStatus([e], v);
            break;
          case 'check':
            _checkAvailability([e]);
            break;
          case 'move':
            _moveEntries([e]);
            break;
          case 'delete':
            _deleteEntries([e]);
            break;
        }
      },
      itemBuilder: (c) => [
        const PopupMenuItem(value: 'play', child: Text('Play in TubeBox')),
        const PopupMenuItem(value: 'open', child: Text('Open in YouTube')),
        const PopupMenuItem(value: 'copy', child: Text('Copy link')),
        const PopupMenuItem(value: 'edit', child: Text('Edit details')),
        if (item.isPlaylist) const PopupMenuItem(value: 'expand', child: Text('Expand into videos')),
        if (item.isVideo) const PopupMenuItem(value: 'check', child: Text('Check if it plays')),
        if (item.status != 'working') const PopupMenuItem(value: 'working', child: Text('Mark as working')),
        if (item.status != 'unavailable') const PopupMenuItem(value: 'unavailable', child: Text('Mark as unavailable')),
        if (item.status != 'kodi_error') const PopupMenuItem(value: 'kodi_error', child: Text('Mark as Kodi error')),
        const PopupMenuItem(value: 'move', child: Text('Move to another file')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  void _tap(Entry e) {
    if (_selected.isNotEmpty) {
      setState(() {
        if (!_selected.add(e.id)) _selected.remove(e.id);
      });
    } else {
      _play(e);
    }
  }

  /// Plays inside TubeBox; the queue is every playable item currently shown.
  void _play(Entry e) {
    if (e.item.isOther) {
      _open(e.item);
      return;
    }
    final shown = _visible().where((x) => !x.item.isOther).toList();
    int start = shown.indexWhere((x) => x.id == e.id);
    final queue = shown.map((x) => x.item).toList();
    if (start < 0) {
      queue.insert(0, e.item);
      start = 0;
    }
    PlayerHost.instance.open(queue, start);
  }

  Widget _card(Entry e, {required bool compact}) {
    final item = e.item;
    final showFile = _scope != _Scope.current;
    return TvFocusable(
      onTap: () => _tap(e),
      onLongPress: () => setState(() => _selected.add(e.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _thumb(e),
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
                      if (!compact || showFile)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            [
                              if (item.group.isNotEmpty) item.group,
                              if (showFile) '${e.file.name}.m3u',
                            ].join('  •  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: 44, height: 44, child: _itemMenu(e)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One compact row under the search box: which file(s) you are looking at,
  /// plus every active filter as a removable chip. Everything else lives in the
  /// filter popup (top-right button).
  Widget _contextRow() {
    const sortNames = {'newest': 'Newest first', 'title': 'Title A–Z', 'chapter': 'Category & chapter'};
    Widget pill(Widget c) => Padding(padding: const EdgeInsets.only(right: 8), child: c);
    // YouTube-style chip: the chosen one is white with dark text.
    Widget yt(String label, bool sel, VoidCallback tap) => pill(ChoiceChip(
          label: Text(label),
          selected: sel,
          showCheckmark: false,
          onSelected: (_) => tap(),
          selectedColor: Colors.white,
          backgroundColor: const Color(0xFF2A2545),
          labelStyle: TextStyle(color: sel ? Colors.black : Colors.white, fontWeight: FontWeight.w600),
        ));
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          if (_scope == _Scope.custom) yt('${_customPaths.length} files', true, _showFilterSheet),
          yt('All', _scope == _Scope.all, () {
            if (_scope != _Scope.all) _setScope(_Scope.all);
          }),
          for (final f in _files)
            yt(f.name, _scope == _Scope.current && _active?.path == f.path, () {
              if (!(_scope == _Scope.current && _active?.path == f.path)) _switchTo(f);
            }),
          if (_type != 'all')
            pill(InputChip(
              label: Text(_type == 'video' ? 'Videos' : 'Playlists'),
              onPressed: _showFilterSheet,
              onDeleted: () => setState(() => _type = 'all'),
            )),
          if (_group != null)
            pill(InputChip(label: Text(_group!), onPressed: _showFilterSheet, onDeleted: () => setState(() => _group = null))),
          if (_status != 'all')
            pill(InputChip(
              label: Text(_status == 'unavailable' ? 'Unavailable' : 'Plays fine'),
              onPressed: _showFilterSheet,
              onDeleted: () => setState(() => _status = 'all'),
            )),
          if (_sort != 'file')
            pill(InputChip(label: Text(sortNames[_sort] ?? _sort), onPressed: _showFilterSheet, onDeleted: () => setState(() => _sort = 'file'))),
        ],
      ),
    );
  }

  bool get _isTv {
    final size = MediaQuery.of(context).size;
    return size.width >= 900 && size.width > size.height;
  }

  Future<void> _openSearch({bool listen = false}) async {
    final r = await showSearchDialog(
      context,
      initial: _query,
      hint: _scope == _Scope.current ? 'Search in ${_active?.name ?? ''}.m3u' : 'Search ${_scopeFiles.length} files',
      startListening: listen,
    );
    if (r == null || !mounted) return;
    _searchCtrl.text = r;
    setState(() => _query = r);
  }

  Widget _searchField() {
    final hint = _scope == _Scope.current ? 'Search in ${_active?.name ?? ''}.m3u' : 'Search ${_scopeFiles.length} files';
    if (_isTv && !_tvEditing) {
      // TV: a focusable box; OK turns it into a real text box with the on-screen keyboard.
      return Focus(
        onKeyEvent: (n, e) {
          if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.browserSearch || e.logicalKey == LogicalKeyboardKey.launchAssistant)) {
            _openSearch(listen: true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TvFocusable(
          radius: 24,
          onTap: _startTvSearch,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(24)),
            child: Row(children: [
              const Icon(Icons.search),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_query.isEmpty ? hint : _query, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _query.isEmpty ? Colors.grey : null)),
              ),
              if (_query.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
              IconButton(tooltip: 'Voice search', icon: const Icon(Icons.mic), onPressed: () => _openSearch(listen: true)),
            ]),
          ),
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        autofocus: true,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: _scope == _Scope.current ? 'Search in ${_active?.name ?? ''}.m3u' : 'Search ${_scopeFiles.length} files',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? IconButton(tooltip: 'Voice search', icon: const Icon(Icons.mic_none), onPressed: () => _openSearch(listen: true))
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _normalBar() {
    final phone = !_isTv;
    return SliverAppBar(
      floating: true,
      snap: true,
      pinned: false,
      toolbarHeight: 58,
      titleSpacing: 12,
      leading: phone && _phoneSearching
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                _searchCtrl.clear();
                setState(() {
                  _phoneSearching = false;
                  _query = '';
                });
              },
            )
          : null,
      title: phone && !_phoneSearching
          ? Row(children: [
              ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.asset('assets/logo.png', width: 30, height: 30)),
              const SizedBox(width: 10),
              const Text('TubeBox', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            ])
          : _searchField(),
      actions: [
        if (phone && !_phoneSearching)
          IconButton(tooltip: 'Search', onPressed: () => setState(() => _phoneSearching = true), icon: const Icon(Icons.search)),
        IconButton(
          tooltip: 'Filters',
          onPressed: _showFilterSheet,
          icon: Badge(isLabelVisible: _filtersActive, smallSize: 9, child: const Icon(Icons.tune)),
        ),
        if (!phone) _fileMenuButton(),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: _contextRow(),
      ),
    );
  }

  Widget _fileMenuButton() {
    return
PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'view':
                _toggleGrid();
                break;
              case 'edit':
                _openEditor();
                break;
              case 'check':
                _checkAvailability(_visible());
                break;
              case 'tv':
                _sendToTv();
                break;
              case 'copy':
                _copyLinks(_visible().map((e) => e.item));
                break;
              case 'select':
                setState(() => _selected.addAll(_visible().map((e) => e.id)));
                break;
              case 'expand':
                _failedPlaylists.clear();
                _postProcess();
                break;
              case 'new':
                _newFile();
                break;
              case 'rename':
                _renameFile();
                break;
              case 'delete':
                _deleteFile();
                break;
            }
          },
          itemBuilder: (c) => [
            PopupMenuItem(value: 'view', child: Text(_grid ? 'Switch to big cards' : 'Switch to grid')),
            const PopupMenuItem(value: 'edit', child: Text('Edit .m3u as text (full page)')),
            const PopupMenuItem(value: 'check', child: Text('Check which videos play')),
            const PopupMenuItem(value: 'tv', child: Text('Send this file to my TV')),
            const PopupMenuItem(value: 'select', child: Text('Select all')),
            const PopupMenuItem(value: 'copy', child: Text('Copy links')),
            const PopupMenuItem(value: 'expand', child: Text('Expand playlists / fetch titles')),
            const PopupMenuItem(value: 'new', child: Text('New .m3u file')),
            const PopupMenuItem(value: 'rename', child: Text('Rename this file')),
            const PopupMenuItem(value: 'delete', child: Text('Delete this file')),
          ],
        );
  }

  Widget _selectionBar(List<Entry> visible) {
    final chosen = _chosen();
    final allSelected = visible.isNotEmpty && visible.every((e) => _selected.contains(e.id));
    return SliverAppBar(
      pinned: true,
      leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          tooltip: allSelected ? 'Deselect all' : 'Select all',
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          onPressed: () => setState(() {
            if (allSelected) {
              _selected.clear();
            } else {
              _selected.addAll(visible.map((e) => e.id));
            }
          }),
        ),
        IconButton(tooltip: 'Copy links', icon: const Icon(Icons.copy), onPressed: () => _copyLinks(chosen.map((e) => e.item))),
        IconButton(tooltip: 'Move to another file', icon: const Icon(Icons.drive_file_move_outline), onPressed: () => _moveEntries(chosen)),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => _deleteEntries(chosen),
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'group':
                _setGroup(chosen);
                break;
              case 'check':
                _checkAvailability(chosen);
                break;
              default:
                _setStatus(chosen, v);
            }
          },
          itemBuilder: (c) => const [
            PopupMenuItem(value: 'group', child: Text('Move to category…')),
            PopupMenuItem(value: 'check', child: Text('Check which play')),
            PopupMenuItem(value: 'working', child: Text('Mark as working')),
            PopupMenuItem(value: 'unavailable', child: Text('Mark as unavailable')),
            PopupMenuItem(value: 'kodi_error', child: Text('Mark as Kodi error')),
          ],
        ),
      ],
    );
  }

  Widget _infoHeader(int shown) {
    final primary = Theme.of(context).colorScheme.primary;
    final unav = _unavailableCount;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showShareHint)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: primary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primary.withOpacity(0.5)),
              ),
              child: Row(children: [
                const Icon(Icons.share, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'YouTube → Share → TubeBox saves straight into "${_active?.name}.m3u"',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: Row(children: [
                Text(
                  '$shown item(s)${_scope == _Scope.current ? '' : ' in ${_scopeFiles.length} files'}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                if (unav > 0)
                  Text('  •  $unav unavailable', style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                if (_busy != null) ...[
                  const SizedBox(width: 10),
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 6),
                  Flexible(child: Text(_busy!, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey))),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    final filtered = _query.isNotEmpty || _type != 'all' || _status != 'all' || _group != null;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(filtered ? Icons.search_off : Icons.video_library_outlined, size: 56, color: Colors.white24),
              const SizedBox(height: 12),
              Text(
                filtered
                    ? 'Nothing matches your search or filters.'
                    : 'No videos in "${_active?.name}.m3u" yet.\nTap "Add links", or share a video from the YouTube app.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              if (filtered)
                TextButton(
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                    _resetFilters();
                  },
                  child: const Text('Clear search & filters'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _ready ? _visible() : <Entry>[];
    final selecting = _selected.isNotEmpty;
    final fullWidth = MediaQuery.of(context).size.width;
    final width = fullWidth - widget.railInset;
    const pad = 12.0, gap = 12.0;
    final cols = fullWidth >= 900 ? 3 : 2;
    final cellW = (width - pad * 2 - gap * (cols - 1)) / cols;

    Widget content;
    if (visible.isEmpty) {
      content = _emptyState();
    } else if (_grid) {
      content = SliverPadding(
        padding: const EdgeInsets.fromLTRB(pad, 4, pad, 96),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: gap,
            mainAxisSpacing: 14,
            mainAxisExtent: cellW * 9 / 16 + (_scope == _Scope.current ? 66 : 84),
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _card(visible[i], compact: true),
            childCount: visible.length,
          ),
        ),
      );
    } else {
      content = SliverPadding(
        padding: const EdgeInsets.fromLTRB(pad, 4, pad, 96),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => i.isOdd ? const SizedBox(height: 18) : _card(visible[i ~/ 2], compact: false),
            childCount: visible.length * 2 - 1,
          ),
        ),
      );
    }

    return Scaffold(
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: widget.navVisible,
        builder: (context, vis, _) => AnimatedScale(
          scale: (vis && !selecting && _ready && widget.railInset > 0) ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: FloatingActionButton.extended(
            onPressed: _showAddSheet,
            icon: const Icon(Icons.add_link),
            label: const Text('Add links'),
          ),
        ),
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : NotificationListener<UserScrollNotification>(
              onNotification: (n) {
                if (n.depth != 0) return false;
                if (n.metrics.pixels <= 8 || n.direction == ScrollDirection.forward) {
                  widget.navVisible.value = true;
                } else if (n.direction == ScrollDirection.reverse) {
                  widget.navVisible.value = false;
                }
                return false;
              },
              child: RefreshIndicator(
                onRefresh: _refresh,
                edgeOffset: 60,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    selecting ? _selectionBar(visible) : _normalBar(),
                    _infoHeader(visible.length),
                    content,
                  ],
                ),
              ),
            ),
    );
  }
}

// ============================================================================
// ADD SHEET: paste links (videos, playlists or whole M3U text) and choose the
// target file; optionally Kodi style category + chapter numbering.
// ============================================================================
class _AddSheet extends StatefulWidget {
  final YtStore store;
  final List<M3uFile> files;
  final M3uFile active;
  const _AddSheet({required this.store, required this.files, required this.active});

  @override
  _AddSheetState createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _chapter = TextEditingController();
  final TextEditingController _name = TextEditingController();

  late M3uFile _file;
  bool _numbered = false;
  List<String> _children = ['Lakshya'];
  List<String> _subjects = ['English', 'Math'];
  String _child = 'Lakshya';
  String _subject = 'English';
  List<YtItem> _fileItems = [];

  String get _group => '$_child - $_subject';

  @override
  void initState() {
    super.initState();
    _file = widget.active;
    _load();
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _text.dispose();
    _chapter.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _prefillFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final t = data?.text ?? '';
    if (mounted && _text.text.isEmpty && (t.contains('youtu') || t.contains('#EXTINF'))) {
      setState(() => _text.text = t);
    }
  }

  Future<void> _load() async {
    final children = await widget.store.loadChildren();
    final subjects = await widget.store.loadSubjects();
    if (!mounted) return;
    setState(() {
      _children = children;
      _subjects = subjects;
      _child = children.first;
      _subject = subjects.first;
    });
    await _loadFile();
  }

  Future<void> _loadFile() async {
    final items = await widget.store.load(_file);
    if (!mounted) return;
    setState(() {
      _fileItems = items;
      _numbered = items.any((e) => e.chapter != null) || _file.name == 'Master_Playlist';
    });
    _updateChapter();
  }

  void _updateChapter() {
    _chapter.text = nextChapter(_fileItems, _group).toString();
  }

  Future<String?> _prompt(String title, String hint) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.words, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
  }

  Widget _selector({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
    required VoidCallback onAdd,
    required VoidCallback onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: value,
              isExpanded: true,
              decoration: InputDecoration(labelText: label),
              items: items.map((c) => DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filledTonal(onPressed: onAdd, tooltip: 'Add', icon: const Icon(Icons.add)),
          IconButton.filledTonal(
            onPressed: onRemove,
            tooltip: 'Remove this one',
            style: IconButton.styleFrom(foregroundColor: Colors.redAccent),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(
      context,
      _AddRequest(
        text: text,
        file: _file,
        numbered: _numbered,
        group: _group,
        subject: _subject,
        startChapter: _numbered ? int.tryParse(_chapter.text.trim()) : null,
        customName: _name.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Add links', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'Paste video links, playlist links, or full M3U text…'),
            ),
            Row(children: [
              TextButton.icon(
                onPressed: () async {
                  final d = await Clipboard.getData('text/plain');
                  if (d?.text != null) setState(() => _text.text = d!.text!);
                },
                icon: const Icon(Icons.paste, size: 18),
                label: const Text('Paste'),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _text.clear()),
                icon: const Icon(Icons.clear, size: 18),
                label: const Text('Clear'),
              ),
            ]),
            const SizedBox(height: 4),
            DropdownButtonFormField<M3uFile>(
              value: widget.files.contains(_file) ? _file : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Save into file'),
              items: widget.files.map((f) => DropdownMenuItem(value: f, child: Text('${f.name}.m3u'))).toList(),
              onChanged: (f) {
                if (f == null) return;
                setState(() => _file = f);
                _loadFile();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kodi style: category + chapter numbers'),
              subtitle: const Text('Titles become "CH3: …" inside "Child - Subject"', style: TextStyle(fontSize: 12)),
              value: _numbered,
              onChanged: (v) {
                setState(() => _numbered = v);
                _updateChapter();
              },
            ),
            if (_numbered) ...[
              _selector(
                label: 'Child profile',
                value: _child,
                items: _children,
                onChanged: (v) {
                  setState(() => _child = v);
                  _updateChapter();
                },
                onAdd: () async {
                  final n = await _prompt('Add child profile', 'Enter name');
                  if (n == null || n.isEmpty || _children.contains(n)) return;
                  setState(() {
                    _children = [..._children, n];
                    _child = n;
                  });
                  await widget.store.saveChildren(_children);
                  _updateChapter();
                },
                onRemove: () async {
                  if (_children.length <= 1) return;
                  setState(() {
                    _children = _children.where((c) => c != _child).toList();
                    _child = _children.first;
                  });
                  await widget.store.saveChildren(_children);
                  _updateChapter();
                },
              ),
              _selector(
                label: 'Subject',
                value: _subject,
                items: _subjects,
                onChanged: (v) {
                  setState(() => _subject = v);
                  _updateChapter();
                },
                onAdd: () async {
                  final n = await _prompt('Add subject', 'e.g. Hindi, GK');
                  if (n == null || n.isEmpty || _subjects.contains(n)) return;
                  setState(() {
                    _subjects = [..._subjects, n];
                    _subject = n;
                  });
                  await widget.store.saveSubjects(_subjects);
                  _updateChapter();
                },
                onRemove: () async {
                  if (_subjects.length <= 1) return;
                  setState(() {
                    _subjects = _subjects.where((s) => s != _subject).toList();
                    _subject = _subjects.first;
                  });
                  await widget.store.saveSubjects(_subjects);
                  _updateChapter();
                },
              ),
              Row(children: [
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _chapter,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Chapter No.'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Custom name (optional)')),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Category: $_group', style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.add_link),
                label: Text('Add to ${_file.name}.m3u', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
