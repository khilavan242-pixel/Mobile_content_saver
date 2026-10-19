import 'package:flutter/material.dart';

import 'tv_sync.dart';
import 'youtube_core.dart';

/// Phone: manage what is on the TV. Delete whole .m3u files, or open a file and
/// delete one or many videos from it. Works over the same Wi-Fi as TV Sync.
class TvManageScreen extends StatefulWidget {
  const TvManageScreen({Key? key}) : super(key: key);

  @override
  State<TvManageScreen> createState() => _TvManageScreenState();
}

class _TvManageScreenState extends State<TvManageScreen> {
  SavedTv? _tv;
  List<({String name, int size})>? _files;
  final Set<String> _sel = <String>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final tv = await SavedTv.load();
    if (tv == null || tv.pin.isEmpty) {
      if (!mounted) return;
      setState(() {
        _tv = null;
        _loading = false;
        _error = 'Set up your TV first: TV Sync tab -> Find my TV.';
      });
      return;
    }
    final files = await TvClient.listFiles(tv.ip, tv.pin);
    if (!mounted) return;
    setState(() {
      _tv = tv;
      _files = files;
      _sel.removeWhere((n) => files == null || !files.any((f) => f.name == n));
      _loading = false;
      _error = files == null ? 'Cannot reach ${tv.name}. Is TubeBox open on the TV, on the same Wi-Fi?' : null;
    });
  }

  Future<void> _deleteSelected() async {
    final tv = _tv;
    if (tv == null || _sel.isEmpty) return;
    final names = _sel.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${names.length} file${names.length == 1 ? '' : 's'} from the TV?'),
        content: Text(names.join('\n'), maxLines: 8, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final err = await TvClient.deleteFiles(tv.ip, tv.pin, names);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Deleted from ${tv.name}')));
    _sel.clear();
    _load();
  }

  Future<void> _open(String name) async {
    final tv = _tv;
    if (tv == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _TvFileScreen(tv: tv, fileName: name)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: Text(_sel.isEmpty ? 'TV content${_tv == null ? '' : ' - ${_tv!.name}'}' : '${_sel.length} selected'),
        actions: [
          if (_sel.isNotEmpty)
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: _deleteSelected)
          else
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent))))
              : files == null || files.isEmpty
                  ? const Center(child: Text('No .m3u files on the TV yet.', style: TextStyle(color: Colors.white54)))
                  : ListView(children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                        child: Text('Tap a file to see and delete its videos. Tick files to delete them.', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      ),
                      for (final f in files)
                        ListTile(
                          leading: Checkbox(
                            value: _sel.contains(f.name),
                            onChanged: (v) => setState(() => v == true ? _sel.add(f.name) : _sel.remove(f.name)),
                          ),
                          title: Text(f.name.replaceAll(RegExp(r'\.m3u$', caseSensitive: false), '')),
                          subtitle: Text('${(f.size / 1024).toStringAsFixed(1)} KB'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(f.name),
                          onLongPress: () => setState(() => _sel.add(f.name)),
                        ),
                    ]),
    );
  }
}

/// The videos inside one .m3u file on the TV.
class _TvFileScreen extends StatefulWidget {
  final SavedTv tv;
  final String fileName;
  const _TvFileScreen({Key? key, required this.tv, required this.fileName}) : super(key: key);

  @override
  State<_TvFileScreen> createState() => _TvFileScreenState();
}

class _TvFileScreenState extends State<_TvFileScreen> {
  List<YtItem>? _items;
  final Set<int> _sel = <int>{};
  bool _busy = true;
  String? _error;

  String get _base => widget.fileName.replaceAll(RegExp(r'\.m3u$', caseSensitive: false), '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final text = await TvClient.readFile(widget.tv.ip, widget.tv.pin, widget.fileName);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _sel.clear();
      if (text == null) {
        _error = 'Could not read the file from the TV.';
      } else {
        _items = parseM3uLines(text.split('\n'));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final items = _items;
    if (items == null || _sel.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${_sel.length} video${_sel.length == 1 ? '' : 's'} from the TV?'),
        content: Text('They are removed from "$_base.m3u" on ${widget.tv.name}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final keep = [for (int i = 0; i < items.length; i++) if (!_sel.contains(i)) items[i]];
    final err = await TvClient.upload(widget.tv.ip, widget.tv.pin, _base, buildM3uText(keep, fallbackGroup: _base.replaceAll('"', '')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Removed from the TV')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(_sel.isEmpty ? _base : '${_sel.length} selected'),
        actions: [
          if (items != null && items.isNotEmpty)
            IconButton(
              tooltip: _sel.length == items.length ? 'Select none' : 'Select all',
              icon: Icon(_sel.length == items.length ? Icons.deselect : Icons.select_all),
              onPressed: () => setState(() {
                if (_sel.length == items.length) {
                  _sel.clear();
                } else {
                  _sel
                    ..clear()
                    ..addAll(List<int>.generate(items.length, (i) => i));
                }
              }),
            ),
          if (_sel.isNotEmpty) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: _deleteSelected),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.orangeAccent)))
              : items == null || items.isEmpty
                  ? const Center(child: Text('This file has no videos.', style: TextStyle(color: Colors.white54)))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final it = items[i];
                        final on = _sel.contains(i);
                        return ListTile(
                          selected: on,
                          selectedTileColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(it.thumbUrl, width: 96, height: 54, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox(width: 96, height: 54)),
                          ),
                          title: Text(it.hasRealTitle ? it.plainTitle : 'YouTube ${it.isPlaylist ? 'playlist' : 'video'}', maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Checkbox(value: on, onChanged: (v) => setState(() => v == true ? _sel.add(i) : _sel.remove(i))),
                          onTap: () => setState(() => on ? _sel.remove(i) : _sel.add(i)),
                        );
                      },
                    ),
    );
  }
}
