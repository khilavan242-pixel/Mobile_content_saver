import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Search box that works with a TV remote (D-pad moves between the field, the
/// "Speak" button and the actions) and with voice. Returns the text to search
/// for, or null when cancelled.
Future<String?> showSearchDialog(
  BuildContext context, {
  String initial = '',
  String hint = 'Search',
  bool startListening = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SearchDialog(initial: initial, hint: hint, startListening: startListening),
  );
}

class _SearchDialog extends StatefulWidget {
  final String initial;
  final String hint;
  final bool startListening;
  const _SearchDialog({Key? key, required this.initial, required this.hint, required this.startListening}) : super(key: key);

  @override
  _SearchDialogState createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _ready = false;
  bool _listening = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    if (widget.startListening) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toggleMic());
    }
  }

  @override
  void dispose() {
    _speech.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_ready) {
      try {
        _ready = await _speech.initialize(
          onStatus: (s) {
            if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
          },
          onError: (e) {
            if (mounted) {
              setState(() {
                _listening = false;
                _msg = 'Voice search problem: ${e.errorMsg}';
              });
            }
          },
        );
      } catch (_) {
        _ready = false;
      }
    }
    if (!_ready) {
      if (mounted) setState(() => _msg = 'Voice search is not available on this device (needs the Google app and microphone permission).');
      return;
    }
    setState(() {
      _listening = true;
      _msg = null;
    });
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _ctrl.text = r.recognizedWords;
          _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
          if (r.finalResult) _listening = false;
        });
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          Navigator.of(context).pop(r.recognizedWords.trim());
        }
      },
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
    );
  }

  /// Up / Down leave the text field (otherwise the remote gets stuck in it).
  KeyEventResult _escapeKeys(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      FocusScope.of(context).focusInDirection(TraversalDirection.down);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      FocusScope.of(context).focusInDirection(TraversalDirection.up);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Focus(
            canRequestFocus: false,
            onKeyEvent: _escapeKeys,
            child: TextField(
              controller: _ctrl,
              autofocus: !widget.startListening,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
              decoration: InputDecoration(
                hintText: widget.hint,
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _toggleMic,
            icon: Icon(_listening ? Icons.mic : Icons.mic_none),
            label: Text(_listening ? 'Listening... speak now' : 'Speak to search'),
          ),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_msg!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(''), child: const Text('Clear')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()), child: const Text('Search')),
      ],
    );
  }
}
