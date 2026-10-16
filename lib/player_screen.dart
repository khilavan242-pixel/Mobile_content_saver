import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'tv_focus.dart';
import 'youtube_core.dart';

/// YouTube asks apps to identify themselves with a Referer made from the app id.
const String kAppReferer = 'https://com.example.homework_companion';

/// Plays videos inside TubeBox with YouTube's embedded player. All controls are
/// TubeBox's own (so they work with touch AND a TV remote), links out of the
/// player are blocked, and the next video always comes from your saved list.
class PlayerScreen extends StatefulWidget {
  final List<YtItem> queue;
  final int startIndex;
  const PlayerScreen({Key? key, required this.queue, this.startIndex = 0}) : super(key: key);

  @override
  _PlayerScreenState createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  late final WebViewController _web;
  final FocusNode _root = FocusNode(debugLabel: 'player-root');
  final FocusNode _playNode = FocusNode(debugLabel: 'player-play');
  final ScrollController _strip = ScrollController();
  bool _inited = false;
  bool _captions = false;
  bool _ended = false;
  final ValueNotifier<double> _pos = ValueNotifier<double>(0);
  final ValueNotifier<double> _dur = ValueNotifier<double>(0);

  int _mode = 0; // 0 = player A, 1 = player B (privacy host)
  late int _index;
  bool _ready = false;
  bool _playing = true;
  bool _full = false;
  bool _controlsVisible = true;
  bool _autoNext = true;
  int _repeat = 0; // 0 off, 1 all, 2 one
  double _speed = 1.0;
  int? _errorCode;
  String? _flash;
  Timer? _hideTimer;
  Timer? _flashTimer;
  Timer? _seekTimer;
  Timer? _skipTimer;

  YtItem get _current => widget.queue[_index];
  bool get _hasNext => _index < widget.queue.length - 1;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex.clamp(0, widget.queue.length - 1).toInt();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('Tube', onMessageReceived: (m) => _onMessage(m.message))
      // Nothing may navigate the page away (no jumping to YouTube).
      ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (r) => NavigationDecision.prevent));
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _seekTimer?.cancel();
    _skipTimer?.cancel();
    _root.dispose();
    _playNode.dispose();
    _strip.dispose();
    _pos.dispose();
    _dur.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return;
    _inited = true;
    final size = MediaQuery.of(context).size;
    if (size.width > size.height && size.width >= 700) {
      // TV / wide screen: open straight in full screen like the YouTube TV app.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_full) _toggleFull();
      });
    }
  }

  // ---------------------------------------------------------------- loading
  String get _host => _mode == 1 ? 'https://www.youtube-nocookie.com' : 'https://www.youtube.com';

  String _html(YtItem first) {
    final vars = first.isPlaylist ? "listType:'playlist',list:'${first.id}'," : '';
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
    width:'100%', height:'100%', host:'$_host', $vid
    playerVars:{ $vars autoplay:1, controls:0, disablekb:1, playsinline:1, rel:0, fs:0, modestbranding:1, iv_load_policy:3, origin:'$kAppReferer' },
    events:{
      onReady:function(){ post('ready'); },
      onStateChange:function(e){ post('state:'+e.data); },
      onError:function(e){ post('error:'+e.data); }
    }
  });
  setInterval(function(){
    try{ if(player && player.getCurrentTime){ post('time:'+player.getCurrentTime()+':'+player.getDuration()); } }catch(e){}
  }, 500);
}
function loadVideo(id){ player.loadVideoById(id); }
function loadPlaylist(id){ player.loadPlaylist({listType:'playlist', list:id}); }
</script></body></html>''';
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _ready = false;
        _errorCode = null;
      });
    }
    await _web.loadHtmlString(_html(_current), baseUrl: kAppReferer);
  }

  void _nextMode() {
    setState(() => _mode = (_mode + 1) % 2);
    _load();
  }

  void _js(String code) {
    _web.runJavaScript('try{ $code }catch(e){}');
  }

  // --------------------------------------------------------------- messages
  void _onMessage(String m) {
    if (!mounted) return;
    if (m.startsWith('time:')) {
      final p = m.split(':');
      if (p.length >= 3) {
        final c = double.tryParse(p[1]) ?? 0;
        final d = double.tryParse(p[2]) ?? 0;
        if (!_seeking) _pos.value = c.isNaN ? 0 : c;
        _dur.value = d.isNaN ? 0 : d;
      }
    } else if (m == 'ready') {
      setState(() => _ready = true);
      _js("player.unloadModule('captions')");
    } else if (m.startsWith('error:')) {
      final code = int.tryParse(m.substring(6)) ?? 0;
      setState(() => _errorCode = code);
      _showControls();
      if ((code == 100 || code == 101 || code == 150) && _hasNext && _autoNext) {
        _skipTimer?.cancel();
        _skipTimer = Timer(const Duration(seconds: 4), () {
          if (mounted && _errorCode != null) _go(_index + 1);
        });
      }
    } else if (m.startsWith('state:')) {
      final st = int.tryParse(m.substring(6)) ?? -1;
      if (st == 1) {
        if (!_playing || _errorCode != null || _ended) setState(() {
          _playing = true;
          _errorCode = null;
          _ended = false;
        });
        if (_speed != 1.0) _js('player.setPlaybackRate($_speed)');
        _scheduleHide();
      } else if (st == 2) {
        setState(() => _playing = false);
        _showControls();
      } else if (st == 0) {
        _onEnded();
      }
    }
  }

  void _onEnded() {
    if (_current.isPlaylist) {
      if (_hasNext && _autoNext) _go(_index + 1);
      return;
    }
    if (_repeat == 2) {
      _js('player.seekTo(0,true); player.playVideo();');
    } else if (_hasNext && _autoNext) {
      _go(_index + 1);
    } else if (_repeat == 1 && _autoNext) {
      _go(0);
    } else {
      setState(() {
        _playing = false;
        _ended = true;
      });
      _showControls();
    }
  }

  // ---------------------------------------------------------------- actions
  bool _seeking = false;

  void _go(int i) {
    if (i < 0 || i >= widget.queue.length) return;
    _skipTimer?.cancel();
    setState(() {
      _index = i;
      _errorCode = null;
      _playing = true;
      _ended = false;
    });
    _pos.value = 0;
    _dur.value = 0;
    final it = widget.queue[i];
    _js(it.isPlaylist ? "loadPlaylist('${it.id}')" : "loadVideo('${it.id}')");
  }

  void _togglePlay() {
    if (_playing) {
      _js('player.pauseVideo()');
    } else {
      _js('player.playVideo()');
    }
    setState(() => _playing = !_playing);
    _showControls();
  }

  void _seekBy(int seconds) {
    _js('player.seekTo(Math.max(0, player.getCurrentTime() + ($seconds)), true)');
    _pos.value = (_pos.value + seconds).clamp(0, _dur.value > 0 ? _dur.value : double.infinity).toDouble();
    _flashText(seconds > 0 ? '+$seconds s' : '$seconds s');
    _showControls();
  }

  void _seekTo(double s, {bool now = false}) {
    _pos.value = s;
    _seeking = true;
    _seekTimer?.cancel();
    void doSeek() {
      _js('player.seekTo($s, true)');
      _seeking = false;
    }

    if (now) {
      doSeek();
    } else {
      _seekTimer = Timer(const Duration(milliseconds: 400), doSeek);
    }
    _showControls();
  }

  void _cycleSpeed() {
    final i = _speeds.indexOf(_speed);
    setState(() => _speed = _speeds[(i + 1) % _speeds.length]);
    _js('player.setPlaybackRate($_speed)');
    _flashText('Speed ${_speedLabel(_speed)}');
  }

  void _cycleRepeat() {
    setState(() => _repeat = (_repeat + 1) % 3);
    _flashText(const ['Repeat off', 'Repeat all', 'Repeat this video'][_repeat]);
  }

  void _toggleCaptions() {
    setState(() => _captions = !_captions);
    _js(_captions ? "player.loadModule('captions')" : "player.unloadModule('captions')");
    _flashText(_captions ? 'Captions on' : 'Captions off');
  }

  void _replay() {
    setState(() {
      _ended = false;
      _playing = true;
    });
    _js('player.seekTo(0,true); player.playVideo();');
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Settings'),
          content: SizedBox(
            width: 360,
            child: ListView(shrinkWrap: true, children: [
              const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('Playback speed', style: TextStyle(fontWeight: FontWeight.w700))),
              for (final v in _speeds)
                ListTile(
                  autofocus: v == _speed,
                  dense: true,
                  leading: Icon(v == _speed ? Icons.radio_button_checked : Icons.radio_button_off),
                  title: Text(v == 1.0 ? 'Normal' : '${v}x'),
                  onTap: () {
                    setState(() => _speed = v);
                    _js('player.setPlaybackRate($v)');
                    setD(() {});
                  },
                ),
              const Divider(),
              SwitchListTile(
                dense: true,
                title: const Text('Play next automatically'),
                value: _autoNext,
                onChanged: (v) {
                  setState(() => _autoNext = v);
                  setD(() {});
                },
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      ),
    );
    _showControls();
  }

  String _speedLabel(double v) => v == 1.0 ? '1x' : '${v}x';

  void _flashText(String t) {
    _flashTimer?.cancel();
    setState(() => _flash = t);
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      // Put the remote's focus on the play button, like the YouTube TV app.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _full && !_playNode.hasFocus) _playNode.requestFocus();
      });
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_full || !_playing) return;
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
      _root.requestFocus();
    });
  }

  Future<void> _toggleFull() async {
    final next = !_full;
    setState(() {
      _full = next;
      _controlsVisible = true;
    });
    if (next) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _root.requestFocus();
    _scheduleHide();
  }

  Future<void> _openInYouTube() async {
    try {
      await AndroidIntent(action: 'action_view', data: _current.webUrl, package: 'com.google.android.youtube').launch();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('YouTube app not found.')));
    }
  }

  // ------------------------------------------------------------- remote keys
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlay) {
      if (!_playing) _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPause) {
      if (_playing) _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      _go(_index + 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      _go(_index - 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (_full) {
      if (!_controlsVisible) {
        // Controls hidden: arrows seek, OK pauses/plays, anything shows controls.
        if (k == LogicalKeyboardKey.arrowRight) {
          _seekBy(10);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowLeft) {
          _seekBy(-10);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) {
          _togglePlay();
          return KeyEventResult.handled;
        }
        _showControls();
        return KeyEventResult.handled;
      }
      _scheduleHide();
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ build
  String _fmt(double s) {
    final t = s.isNaN || s < 0 ? 0 : s.floor();
    final h = t ~/ 3600, m = (t % 3600) ~/ 60, sec = t % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  String _errorText(int code) {
    switch (code) {
      case 152:
      case 153:
        return 'YouTube refused this player setup (error $code). Tap "Try other player".';
      case 101:
      case 150:
        return _hasNext && _autoNext
            ? 'The owner does not allow this video outside YouTube. Skipping to the next one...'
            : 'The owner of this video does not allow playing it outside YouTube.';
      case 100:
        return _hasNext && _autoNext ? 'This video was removed or is private. Skipping...' : 'This video was removed or is private.';
      case 2:
        return 'This video link is not valid.';
      default:
        return 'This video could not be played (error $code).';
    }
  }

  Widget _video() {
    return ColoredBox(
      color: Colors.black,
      child: Stack(children: [
        // The web page must never take the remote's focus (that froze the buttons).
        Positioned.fill(child: ExcludeFocus(child: WebViewWidget(controller: _web))),
        if (!_ready) const Center(child: CircularProgressIndicator()),
        // Touch layer on top of the player: tap, double-tap to skip 10 s.
        Positioned.fill(
          child: _TouchLayer(
            onTap: () {
              if (_full) {
                if (_controlsVisible) {
                  setState(() => _controlsVisible = false);
                  _root.requestFocus();
                } else {
                  _showControls();
                }
              } else {
                _togglePlay();
              }
            },
            onSeek: _seekBy,
          ),
        ),
        // Paused / finished: hide YouTube's own "more videos" suggestions.
        if (_ready && (!_playing || _ended))
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withOpacity(_ended ? 1.0 : 0.82),
                child: Center(
                  child: Icon(_ended ? Icons.replay : Icons.play_circle_outline, size: 72, color: Colors.white70),
                ),
              ),
            ),
          ),
        if (_flash != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(_flash!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ),
        if (_errorCode != null && _full)
          Positioned(left: 16, right: 16, top: 16, child: _errorCard()),
      ]),
    );
  }

  Widget _seekBar() {
    return ValueListenableBuilder<double>(
      valueListenable: _dur,
      builder: (context, dur, _) => ValueListenableBuilder<double>(
        valueListenable: _pos,
        builder: (context, pos, __) {
          final max = dur > 0 ? dur : 1.0;
          final value = pos.clamp(0, max).toDouble();
          return Row(children: [
            Text(_fmt(pos), style: const TextStyle(fontSize: 13)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  trackHeight: 5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                ),
                child: Slider(
                value: value,
                min: 0,
                max: max,
                divisions: dur >= 20 ? (dur / 10).round() : null,
                onChanged: dur > 0 ? (v) => _seekTo(v) : null,
                onChangeEnd: dur > 0 ? (v) => _seekTo(v, now: true) : null,
              ),
              ),
            ),
            Text(_fmt(dur), style: const TextStyle(fontSize: 13)),
          ]);
        },
      ),
    );
  }

  Widget _controls({required bool dense}) {
    final gap = SizedBox(width: dense ? 4 : 8);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _seekBar(),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: dense ? 4 : 8,
        runSpacing: 4,
        children: [
          IconButton.filledTonal(tooltip: 'Previous', onPressed: _index > 0 ? () => _go(_index - 1) : null, icon: const Icon(Icons.skip_previous)),
          IconButton.filledTonal(tooltip: 'Back 10 s', onPressed: () => _seekBy(-10), icon: const Icon(Icons.replay_10)),
          IconButton.filled(
            tooltip: _playing ? 'Pause' : 'Play',
            iconSize: 32,
            focusNode: _playNode,
            onPressed: _ended ? _replay : _togglePlay,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton.filledTonal(tooltip: 'Forward 10 s', onPressed: () => _seekBy(10), icon: const Icon(Icons.forward_10)),
          IconButton.filledTonal(tooltip: 'Next', onPressed: _hasNext ? () => _go(_index + 1) : null, icon: const Icon(Icons.skip_next)),
          gap,
          FilledButton.tonal(onPressed: _cycleSpeed, child: Text(_speedLabel(_speed))),
          IconButton.filledTonal(
            tooltip: 'Repeat',
            onPressed: _cycleRepeat,
            icon: Icon(_repeat == 2 ? Icons.repeat_one : Icons.repeat, color: _repeat == 0 ? null : Theme.of(context).colorScheme.primary),
          ),
          IconButton.filledTonal(
            tooltip: 'Captions',
            onPressed: _toggleCaptions,
            icon: Icon(_captions ? Icons.closed_caption : Icons.closed_caption_off_outlined),
          ),
          IconButton.filledTonal(
            tooltip: _full ? 'Exit full screen' : 'Full screen',
            onPressed: _toggleFull,
            icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen),
          ),
        ],
      ),
    ]);
  }

  /// YouTube-TV style overlay: title on top, seek bar, three button groups and
  /// the "Up next" strip underneath. Every part is reachable with the D-pad.
  Widget _fullOverlay() {
    final it = _current;
    final primary = Theme.of(context).colorScheme.primary;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_strip.hasClients && widget.queue.length > 1) {
        final target = (_index * 196.0 - 40).clamp(0.0, _strip.position.maxScrollExtent).toDouble();
        if ((_strip.offset - target).abs() > 400) _strip.jumpTo(target);
      }
    });
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 36),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black, Colors.transparent]),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                it.hasRealTitle ? it.plainTitle : 'YouTube ${it.isPlaylist ? 'playlist' : 'video'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.2),
              ),
              if (widget.queue.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Playing ${_index + 1} of ${widget.queue.length}', style: const TextStyle(color: Colors.white70)),
                ),
            ]),
          ),
          if (_errorCode != null) const SizedBox(width: 12),
        ]),
      ),
      if (_errorCode != null)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 28), child: _errorCard()),
      const Spacer(),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black]),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _seekBar(),
          Row(children: [
            // left group
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, children: [
                  FilledButton.tonalIcon(onPressed: _openSettings, icon: const Icon(Icons.settings), label: Text(_speedLabel(_speed))),
                  IconButton.filledTonal(
                    tooltip: 'Repeat',
                    onPressed: _cycleRepeat,
                    icon: Icon(_repeat == 2 ? Icons.repeat_one : Icons.repeat, color: _repeat == 0 ? null : primary),
                  ),
                ]),
              ),
            ),
            // centre group
            IconButton.filledTonal(tooltip: 'Previous', onPressed: _index > 0 ? () => _go(_index - 1) : null, icon: const Icon(Icons.skip_previous)),
            const SizedBox(width: 6),
            IconButton.filledTonal(tooltip: 'Back 10 s', onPressed: () => _seekBy(-10), icon: const Icon(Icons.replay_10)),
            const SizedBox(width: 6),
            IconButton.filled(
              tooltip: _playing ? 'Pause' : 'Play',
              iconSize: 36,
              focusNode: _playNode,
              autofocus: true,
              onPressed: _ended ? _replay : _togglePlay,
              icon: Icon(_ended ? Icons.replay : (_playing ? Icons.pause : Icons.play_arrow)),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(tooltip: 'Forward 10 s', onPressed: () => _seekBy(10), icon: const Icon(Icons.forward_10)),
            const SizedBox(width: 6),
            IconButton.filledTonal(tooltip: 'Next', onPressed: _hasNext ? () => _go(_index + 1) : null, icon: const Icon(Icons.skip_next)),
            // right group
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(spacing: 8, children: [
                  IconButton.filledTonal(
                    tooltip: 'Captions',
                    onPressed: _toggleCaptions,
                    icon: Icon(_captions ? Icons.closed_caption : Icons.closed_caption_off_outlined),
                  ),
                  IconButton.filledTonal(tooltip: 'Exit full screen', onPressed: _toggleFull, icon: const Icon(Icons.fullscreen_exit)),
                ]),
              ),
            ),
          ]),
          if (widget.queue.length > 1) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 128,
              child: ListView.builder(
                controller: _strip,
                scrollDirection: Axis.horizontal,
                itemCount: widget.queue.length,
                itemBuilder: (context, i) {
                  final q = widget.queue[i];
                  return SizedBox(
                    width: 196,
                    child: TvFocusable(
                      onTap: () => _go(i),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(children: [
                            Image.network(
                              q.thumbUrl,
                              width: 190,
                              height: 80,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const SizedBox(width: 190, height: 80),
                            ),
                            if (i == _index)
                              Positioned.fill(
                                child: ColoredBox(
                                  color: Colors.black45,
                                  child: Center(child: Text('NOW PLAYING', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: primary))),
                                ),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          q.hasRealTitle ? q.plainTitle : 'YouTube video',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, height: 1.2),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ],
        ]),
      ),
    ]);
  }

  Widget _errorCard() {
    return Card(
      color: const Color(0xFF3B1D1D),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_errorText(_errorCode ?? 0)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_hasNext) FilledButton(onPressed: () => _go(_index + 1), child: const Text('Skip to next')),
            if (_errorCode == 152 || _errorCode == 153) FilledButton.tonal(onPressed: _nextMode, child: const Text('Try other player')),
            OutlinedButton(onPressed: _openInYouTube, child: const Text('Open in YouTube')),
          ]),
        ]),
      ),
    );
  }

  Widget _panel({required bool wide}) {
    final it = _current;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Row(children: [
          IconButton(tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back)),
          Expanded(
            child: Text(
              widget.queue.length > 1 ? 'Playing ${_index + 1} of ${widget.queue.length}' : 'TubeBox player',
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ),
          TextButton(onPressed: _nextMode, child: Text(_mode == 0 ? 'Player A' : 'Player B')),
        ]),
        const SizedBox(height: 4),
        Text(
          it.hasRealTitle ? it.plainTitle : 'YouTube ${it.isPlaylist ? 'playlist' : 'video'}',
          style: TextStyle(fontSize: wide ? 18 : 17, fontWeight: FontWeight.w600, height: 1.25),
        ),
        const SizedBox(height: 10),
        if (_errorCode != null) ...[_errorCard(), const SizedBox(height: 10)],
        _controls(dense: wide),
        const SizedBox(height: 8),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Play next automatically'),
          value: _autoNext,
          onChanged: (v) => setState(() => _autoNext = v),
        ),
        OutlinedButton.icon(onPressed: _openInYouTube, icon: const Icon(Icons.open_in_new), label: const Text('Open in YouTube app')),
        if (widget.queue.length > 1) ...[
          const SizedBox(height: 18),
          const Text('Up next', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          for (int i = 0; i < widget.queue.length; i++)
            TvFocusable(
              onTap: () => _go(i),
              child: Container(
                color: i == _index ? Theme.of(context).colorScheme.primary.withOpacity(0.25) : null,
                padding: const EdgeInsets.all(4),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      widget.queue[i].thumbUrl,
                      width: 96,
                      height: 54,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 96, height: 54),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.queue[i].hasRealTitle ? widget.queue[i].plainTitle : 'YouTube video',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: i == _index ? FontWeight.w700 : FontWeight.w400),
                    ),
                  ),
                ]),
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_full,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Back: first hides the controls, then leaves full screen.
        if (_controlsVisible && _playing && !_ended) {
          setState(() => _controlsVisible = false);
          _root.requestFocus();
        } else {
          _toggleFull();
        }
      },
      child: Focus(
        focusNode: _root,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            top: !_full,
            bottom: !_full,
            left: !_full,
            right: !_full,
            child: LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth > c.maxHeight && c.maxWidth >= 700;
              if (_full) {
                return Stack(children: [
                  Positioned.fill(child: Center(child: AspectRatio(aspectRatio: 16 / 9, child: _video()))),
                  if (_controlsVisible) Positioned.fill(child: _fullOverlay()),
                ]);
              }
              if (wide) {
                // TV / landscape: video on the left, everything else on the right,
                // nothing is pushed off the screen.
                final panelW = (c.maxWidth * 0.34).clamp(320.0, 460.0).toDouble();
                return Row(children: [
                  Expanded(child: Center(child: AspectRatio(aspectRatio: 16 / 9, child: _video()))),
                  SizedBox(width: panelW, child: _panel(wide: true)),
                ]);
              }
              return Column(children: [
                AspectRatio(aspectRatio: 16 / 9, child: _video()),
                Expanded(child: _panel(wide: false)),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

/// Transparent layer: single tap and double-tap on the left / right half to
/// jump back / forward 10 seconds (like the YouTube app).
class _TouchLayer extends StatelessWidget {
  final VoidCallback onTap;
  final void Function(int seconds) onSeek;
  const _TouchLayer({Key? key, required this.onTap, required this.onSeek}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      Offset? last;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onDoubleTapDown: (d) => last = d.localPosition,
        onDoubleTap: () {
          final x = last?.dx ?? c.maxWidth / 2;
          onSeek(x < c.maxWidth / 2 ? -10 : 10);
        },
      );
    });
  }
}
