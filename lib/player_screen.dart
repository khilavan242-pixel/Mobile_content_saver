import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'youtube_core.dart';

/// Plays videos inside TubeBox with YouTube's embedded player, so nobody ends
/// up in the YouTube app and its recommendations. Links out of the player are
/// blocked. Videos whose owner disabled embedding show a clear message.
class PlayerScreen extends StatefulWidget {
  final List<YtItem> queue;
  final int startIndex;
  const PlayerScreen({Key? key, required this.queue, this.startIndex = 0}) : super(key: key);

  @override
  _PlayerScreenState createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final WebViewController _web;
  late int _index;
  bool _ready = false;
  bool _full = false;
  int? _errorCode;
  int _played = 0;

  YtItem get _current => widget.queue[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex.clamp(0, widget.queue.length - 1).toInt();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('Tube', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        // Nothing may navigate the page away (no jumping to YouTube).
        onNavigationRequest: (r) => NavigationDecision.prevent,
      ));
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _web.loadHtmlString(_html(_current), baseUrl: 'https://www.youtube.com');
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  String _html(YtItem first) {
    final vars = first.isPlaylist
        ? "listType:'playlist',list:'${first.id}',"
        : '';
    final vid = first.isPlaylist ? '' : "videoId:'${first.id}',";
    return '''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0}</style>
</head><body><div id="p"></div>
<script src="https://www.youtube.com/iframe_api"></script>
<script>
var player;
function post(m){ try{ Tube.postMessage(m); }catch(e){} }
function onYouTubeIframeAPIReady(){
  player = new YT.Player('p',{
    width:'100%', height:'100%', $vid
    playerVars:{ $vars autoplay:1, playsinline:1, rel:0, fs:0, modestbranding:1, iv_load_policy:3, origin:'https://www.youtube.com' },
    events:{
      onReady:function(){ post('ready'); },
      onStateChange:function(e){ post('state:'+e.data); },
      onError:function(e){ post('error:'+e.data); }
    }
  });
}
function loadVideo(id){ player.loadVideoById(id); }
function loadPlaylist(id){ player.loadPlaylist({listType:'playlist', list:id}); }
</script></body></html>''';
  }

  void _onMessage(String m) {
    if (!mounted) return;
    if (m == 'ready') {
      setState(() => _ready = true);
    } else if (m.startsWith('error:')) {
      setState(() => _errorCode = int.tryParse(m.substring(6)) ?? 0);
    } else if (m == 'state:1') {
      if (_errorCode != null || _played == 0) {
        setState(() {
          _errorCode = null;
          _played++;
        });
      }
    } else if (m == 'state:0') {
      // Finished: continue with the next saved video, never YouTube's picks.
      if (!_current.isPlaylist) _go(_index + 1, auto: true);
    }
  }

  void _go(int i, {bool auto = false}) {
    if (i < 0 || i >= widget.queue.length) {
      if (auto && mounted) Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _index = i;
      _errorCode = null;
    });
    final it = widget.queue[i];
    _web.runJavaScript(it.isPlaylist ? "loadPlaylist('${it.id}')" : "loadVideo('${it.id}')");
  }

  Future<void> _toggleFull() async {
    final next = !_full;
    setState(() => _full = next);
    if (next) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _openInYouTube() async {
    try {
      await AndroidIntent(action: 'action_view', data: _current.webUrl, package: 'com.google.android.youtube').launch();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('YouTube app not found.')));
    }
  }

  String _errorText(int code) {
    switch (code) {
      case 101:
      case 150:
      case 153:
        return 'The owner of this video does not allow playing it outside YouTube.';
      case 100:
        return 'This video was removed or is private.';
      case 2:
        return 'This video link is not valid.';
      default:
        return 'This video could not be played (error $code).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ColoredBox(
      color: Colors.black,
      child: Stack(children: [
        Positioned.fill(child: WebViewWidget(controller: _web)),
        if (!_ready) const Center(child: CircularProgressIndicator()),
      ]),
    );

    return PopScope(
      canPop: !_full,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _toggleFull();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _full
            ? null
            : AppBar(
                title: Text(
                  widget.queue.length > 1 ? 'Playing ${_index + 1} of ${widget.queue.length}' : 'TubeBox player',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
        body: _full
            ? Stack(children: [
                Positioned.fill(child: player),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton.filledTonal(onPressed: _toggleFull, icon: const Icon(Icons.fullscreen_exit)),
                ),
                if (_errorCode != null)
                  Positioned(left: 16, right: 16, bottom: 16, child: _errorCard()),
              ])
            : Column(children: [
                AspectRatio(aspectRatio: 16 / 9, child: player),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        _current.hasRealTitle ? _current.plainTitle : 'YouTube ${_current.isPlaylist ? 'playlist' : 'video'}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      if (_errorCode != null) ...[_errorCard(), const SizedBox(height: 12)],
                      Row(children: [
                        IconButton.filledTonal(
                          onPressed: _index > 0 ? () => _go(_index - 1) : null,
                          icon: const Icon(Icons.skip_previous),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: _index < widget.queue.length - 1 ? () => _go(_index + 1) : null,
                          icon: const Icon(Icons.skip_next),
                        ),
                        const Spacer(),
                        IconButton.filledTonal(onPressed: _toggleFull, icon: const Icon(Icons.fullscreen)),
                      ]),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _openInYouTube,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open in YouTube app instead'),
                      ),
                      if (widget.queue.length > 1) ...[
                        const SizedBox(height: 20),
                        const Text('Up next', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        for (int i = 0; i < widget.queue.length; i++)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            selected: i == _index,
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.network(
                                widget.queue[i].thumbUrl,
                                width: 80,
                                height: 45,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(width: 80, height: 45),
                              ),
                            ),
                            title: Text(widget.queue[i].plainTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => _go(i),
                          ),
                      ],
                    ],
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _errorCard() {
    final hasNext = _index < widget.queue.length - 1;
    return Card(
      color: const Color(0xFF3B1D1D),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_errorText(_errorCode ?? 0)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (hasNext) FilledButton(onPressed: () => _go(_index + 1), child: const Text('Skip to next')),
            OutlinedButton(onPressed: _openInYouTube, child: const Text('Open in YouTube')),
          ]),
        ]),
      ),
    );
  }
}
