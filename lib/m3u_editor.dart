import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'm3u_store.dart';

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
