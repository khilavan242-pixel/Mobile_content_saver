import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'media.dart';
import 'tv_sync.dart';
import 'pip.dart';
import 'player_host.dart';
import 'tv_focus.dart';
import 'watch_history.dart';
import 'youtube_core.dart';

/// YouTube asks apps to identify themselves with a Referer made from the app id.
const String kAppReferer = 'https://com.example.homework_companion';

/// Skip length of the back / forward buttons and the remote's Left / Right keys.
const int kSkipBack = 10;
const int kSkipFwd = 30;

/// Plays videos inside TubeBox with YouTube's embedded player. All controls are
/// TubeBox's own (so they work with touch AND a TV remote), links out of the
/// player are blocked, and the next video always comes from your saved list.
class PlayerScreen extends StatefulWidget {
  final List<YtItem> queue;
  final int startIndex;
  /// Seconds to start the first video at.
  final double startAt;
  /// Shown as the little bar at the bottom while you browse (like YouTube).
  final bool minimized;
  /// Shown inside the floating window (Picture-in-Picture).
  final bool inPip;
  const PlayerScreen({Key? key, required this.queue, this.startIndex = 0, this.startAt = 0, this.minimized = false, this.inPip = false}) : super(key: key);

  @override
  _PlayerScreenState createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  static const List<double> _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  late final WebViewController _web;
  final FocusNode _root = FocusNode(debugLabel: 'player-root');
  final FocusNode _playNode = FocusNode(debugLabel: 'player-play');
  final FocusNode _firstCardNode = FocusNode(debugLabel: 'player-first-card');
  final FocusNode _seekNode = FocusNode(debugLabel: 'player-seek');
  final ScrollController _overlayScroll = ScrollController();
  bool _wide = false;
  bool _seekFocused = false;
  int _repeatCount = 0;
  bool _inited = false;
  bool _captions = false;
  bool _ended = false;
  bool _browse = false; // TV: "Up next" rows are open
  bool _settingsOpen = false;
  final GlobalKey _webKey = GlobalKey(debugLabel: 'player-web');
  DateTime _lastGo = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _keepAlive; // restarts playback while the app is in the background
  bool _wantPlay = true; // false only when the user paused on purpose
  DateTime _lastShift = DateTime.now();
  AppLifecycleState _app = AppLifecycleState.resumed;
  bool _short = false; // current video is a YouTube Short
  bool _fill = false; // zoom to fill the screen (pinch out)
  bool _audio = false; // MP3-player style audio mode
  bool _queueEdit = false; // phone: drag-to-order mode for Up next
  int _cardMenu = -1; // phone: Up next card whose options are open
  bool _blackout = false; // black screen while listening
  String _settingsPage = 'main'; // main | quality | speed
  List<String> _qualities = [];
  String _quality = 'auto';
  final ValueNotifier<double> _pos = ValueNotifier<double>(0);
  final ValueNotifier<double> _dur = ValueNotifier<double>(0);

  int _mode = 0; // 0 = player A, 1 = player B (privacy host)
  late int _index;
  late double _resumeAt = widget.startAt;
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
  bool get _shortUi => _short && !_wide;
  bool get _inPip => widget.inPip;

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
    // Keep the screen awake while a video is open (like the YouTube app).
    try {
      WakelockPlus.enable();
    } catch (_) {}
    WidgetsBinding.instance.addObserver(this);
    Media.listen(_onMediaCmd);
    PlayerHost.instance.backHandler = _handleBack;
    PlayerHost.instance.commandHandler = _onMediaCmd;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.minimized) _root.requestFocus();
    });
    _checkShort();
    _keepAlive = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted || !_wantPlay || !_ready || _ended || _errorCode != null) return;
      if (_app != AppLifecycleState.resumed && !widget.inPip) _js('player.playVideo()');
    });
  }

  @override
  void didUpdateWidget(PlayerScreen old) {
    super.didUpdateWidget(old);
    if (old.minimized != widget.minimized) {
      _lastShift = DateTime.now();
      if (widget.minimized) {
        _full = false;
        _settingsOpen = false;
        _blackout = false;
        _controlsVisible = true;
      } else {
        _scheduleHide();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _root.requestFocus();
        });
      }
      _syncSystemUi();
      _resumeSoon();
    }
    if (old.inPip != widget.inPip) {
      _lastShift = DateTime.now();
      if (widget.inPip) _settingsOpen = false;
      _resumeSoon();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _app = state;
    _lastShift = DateTime.now();
    _resumeSoon();
  }

  /// YouTube sometimes pauses when the window changes (floating window, screen
  /// off). If the user did not pause, start again.
  void _resumeSoon() {
    for (final ms in const [350, 1200, 2600]) {
      Timer(Duration(milliseconds: ms), () {
        if (mounted && _wantPlay && _ready) _js('player.playVideo()');
      });
    }
  }

  void _onMediaCmd(String c) {
    if (!mounted) return;
    if (c.startsWith('seek:')) {
      final ms = double.tryParse(c.substring(5));
      if (ms != null) _seekTo(ms / 1000, now: true);
      return;
    }
    switch (c) {
      case 'play':
        if (!_playing) _togglePlay();
        break;
      case 'pause':
        if (_playing) _togglePlay();
        break;
      case 'next':
        _go(_index + 1);
        break;
      case 'prev':
        _go(_index - 1);
        break;
      case 'close':
        // Notification X: with TubeBox open only the player closes; from outside it closes the app.
        if (_app == AppLifecycleState.resumed) {
          PlayerHost.instance.close();
        } else {
          PlayerHost.instance.closeAndQuit();
        }
        break;
    }
  }

  void _leave() {
    if (_wide) {
      PlayerHost.instance.close();
    } else {
      PlayerHost.instance.minimize();
    }
  }

  /// Android Back. Closes whatever is open on top first; the last step leaves
  /// the player (phone: it shrinks to the mini bar and keeps playing).
  bool _handleBack() {
    if (!mounted) return false;
    if (_settingsOpen) {
      if (_settingsPage != 'main') {
        setState(() => _settingsPage = 'main');
      } else {
        _closeSettings();
      }
      return true;
    }
    if (_blackout) {
      setState(() => _blackout = false);
      return true;
    }
    if (_audio && !_wide) {
      PlayerHost.instance.minimize();
      return true;
    }
    if (_browse) {
      setState(() => _browse = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _playNode.requestFocus());
      return true;
    }
    if (_wide && _full && _controlsVisible) {
      _hideControls();
      return true;
    }
    if (!_wide && _full) {
      _toggleFull();
      return true;
    }
    _leave();
    return true;
  }

  @override
  void dispose() {
    WatchHistory.instance.flush();
    _keepAlive?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    Media.release(_onMediaCmd);
    if (PlayerHost.instance.backHandler == _handleBack) PlayerHost.instance.backHandler = null;
    if (PlayerHost.instance.commandHandler == _onMediaCmd) PlayerHost.instance.commandHandler = null;
    // A new player may already have started (another video was opened).
    final stillActive = PlayerHost.instance.active;
    if (!stillActive) {
      try {
        WakelockPlus.disable();
      } catch (_) {}
      Media.stop();
      Pip.auto(false);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _seekTimer?.cancel();
    _skipTimer?.cancel();
    _root.dispose();
    _playNode.dispose();
    _seekNode.dispose();
    _firstCardNode.dispose();
    _overlayScroll.dispose();
    _pos.dispose();
    _dur.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return;
    _inited = true;
    final size = MediaQuery.of(context).size;
    if (size.width > size.height && size.width >= 700) {
      _wide = true;
      // TV / wide screen: open straight in full screen like the YouTube TV app.
      _full = true;
      _controlsVisible = false; // video only; no player buttons until a key is pressed
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _root.requestFocus();
        await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      });
    }
  }

  // ------------------------------------------------- shorts / orientation / pip
  Future<void> _checkShort() async {
    final it = _current;
    if (it.isPlaylist) {
      if (_short) {
        setState(() => _short = false);
        _syncSystemUi();
      }
      return;
    }
    final id = it.id;
    final r = await isShortVideo(id);
    if (!mounted || _current.id != id) return;
    if (r != _short) {
      setState(() {
        _short = r;
        if (r && !_wide) _full = false;
      });
      _syncSystemUi();
    }
  }

  Future<void> _syncSystemUi() async {
    if (_wide) return;
    if (widget.minimized) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      return;
    }
    if (_audio) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else if (_short) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (_full) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// Pressing Home while a video plays turns it into the floating mini player.
  void _syncPipAuto() {
    // Audio mode plays under the notification (never as a floating window).
    Pip.auto(_playing && !_wide && !_audio && _errorCode == null, wide: !_shortUi);
    // Media notification: lock screen / headset / notification buttons.
    Media.show(
      title: _current.hasRealTitle ? _current.plainTitle : 'YouTube video',
      subtitle: widget.queue.length > 1 ? '${_index + 1} of ${widget.queue.length}' : 'TubeBox',
      playing: _playing,
      hasPrev: _index > 0,
      hasNext: _hasNext,
      art: _current.isPlaylist ? '' : _current.thumbUrl,
    );
  }

  /// Cast: play the current list on the saved TV (TubeBox on the TV, same Wi-Fi).
  Future<void> _cast() async {
    final tv = await SavedTv.load();
    if (!mounted) return;
    if (tv == null || tv.pin.isEmpty) {
      _flashText('Set up your TV first: TV Sync tab');
      return;
    }
    _flashText('Casting to ${tv.name}...');
    final err = await TvClient.cast(tv.ip, tv.pin, widget.queue, _index);
    if (!mounted) return;
    if (err != null) {
      _flashText(err);
      return;
    }
    _flashText('Playing on ${tv.name}');
    if (_playing) _togglePlay();
    Timer(const Duration(milliseconds: 1300), () {
      if (mounted) PlayerHost.instance.close();
    });
  }

  Future<void> _enterPip() async {
    if (_wide) return;
    if (_settingsOpen) setState(() => _settingsOpen = false);
    final ok = await Pip.enter(wide: !_shortUi);
    if (!ok && mounted) _flashText('Mini player is not available on this phone');
  }

  void _setAudio(bool on) {
    setState(() {
      _audio = on;
      PlayerHost.instance.audioMode = on;
      // Audio mode: lowest picture quality = least mobile data.
      _js(on ? "player.setPlaybackQuality('tiny')" : (_quality == 'auto' ? "player.setPlaybackQuality('default')" : "player.setPlaybackQuality('$_quality')"));
      _blackout = false;
      _settingsOpen = false;
    });
    _syncSystemUi();
    _syncPipAuto();
  }

  // ---------------------------------------------------------------- loading
  String get _host => _mode == 1 ? 'https://www.youtube-nocookie.com' : 'https://www.youtube.com';

  String _html(YtItem first) {
    final vars = first.isPlaylist ? "listType:'playlist',list:'${first.id}'," : '';
    final vid = first.isPlaylist ? '' : "videoId:'${first.id}',";
    final startVar = (!first.isPlaylist && _resumeAt > 0 && first.id == widget.queue[widget.startIndex].id) ? 'start:${_resumeAt.floor()}, ' : '';
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
    playerVars:{ $vars $startVar autoplay:1, controls:0, disablekb:1, playsinline:1, rel:0, fs:0, modestbranding:1, iv_load_policy:3, origin:'$kAppReferer' },
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
        if (_playing && c > 0 && _index < widget.queue.length) WatchHistory.instance.update(_current, c, d);
        _dur.value = d.isNaN ? 0 : d;
        // Timeline in the notification (only while it matters).
        if ((_audio || _app != AppLifecycleState.resumed) && DateTime.now().difference(_lastProgress) > const Duration(seconds: 2)) {
          _lastProgress = DateTime.now();
          Media.progress(_pos.value, _dur.value, _playing);
        }
      }
    } else if (m.startsWith('q:')) {
      try {
        final rest = m.substring(2);
        final cut = rest.lastIndexOf('|');
        final list = (jsonDecode(rest.substring(0, cut)) as List).map((e) => e.toString()).where((e) => e != 'auto').toList();
        setState(() => _qualities = list);
      } catch (_) {}
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
          if (mounted && _errorCode != null) _go(_index + 1, fromList: _wide);
        });
      }
    } else if (m.startsWith('state:')) {
      final st = int.tryParse(m.substring(6)) ?? -1;
      if (st == 1) {
        _wantPlay = true;
        if (!_playing || _errorCode != null || _ended) setState(() {
          _playing = true;
          _errorCode = null;
          _ended = false;
        });
        if (_speed != 1.0) _js('player.setPlaybackRate($_speed)');
        if (_audio) _js("player.setPlaybackQuality('tiny')");
        if (_qualities.isEmpty) _js("post('q:'+JSON.stringify(player.getAvailableQualityLevels())+'|'+player.getPlaybackQuality())");
        _scheduleHide();
        _syncPipAuto();
      } else if (st == 2) {
        final shifting = _app != AppLifecycleState.resumed || widget.inPip || DateTime.now().difference(_lastShift) < const Duration(seconds: 3);
        if (_wantPlay && shifting) {
          // Not the user: the window changed. Keep playing.
          _js('player.playVideo()');
          return;
        }
        setState(() => _playing = false);
        // A new video often reports "paused" while it loads: keep the screen clean.
        if (DateTime.now().difference(_lastGo) > const Duration(seconds: 6) && DateTime.now().isAfter(_quietUntil)) _showControls();
        _syncPipAuto();
      } else if (st == 0) {
        _onEnded();
      }
    }
  }

  void _onEnded() {
    if (_current.isPlaylist) {
      if (_hasNext && _autoNext) _go(_index + 1, fromList: _wide);
      return;
    }
    if (_repeat == 2) {
      _js('player.seekTo(0,true); player.playVideo();');
    } else if (_hasNext && _autoNext) {
      _go(_index + 1, fromList: _wide);
    } else if (_repeat == 1 && _autoNext) {
      _go(0, fromList: _wide);
    } else {
      _wantPlay = false;
      setState(() {
        _playing = false;
        _ended = true;
      });
      _showControls();
    }
  }

  // ---------------------------------------------------------------- actions
  bool _seeking = false;

  void _go(int i, {bool fromList = false}) {
    if (i < 0 || i >= widget.queue.length) return;
    _skipTimer?.cancel();
    _lastGo = DateTime.now();
    setState(() {
      _index = i;
      _errorCode = null;
      _playing = true;
      _ended = false;
      _qualities = [];
      if (fromList) {
        // Picked from the "Up next" rows: straight to full screen playback.
        _browse = false;
        _controlsVisible = false;
      }
    });
    _pos.value = 0;
    _dur.value = 0;
    if (fromList) {
      _hideTimer?.cancel();
      _root.requestFocus();
    } else if (_full) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsVisible) _playNode.requestFocus();
      });
    }
    _resumeAt = 0;
    final it = widget.queue[i];
    _wantPlay = true;
    _js(it.isPlaylist ? "loadPlaylist('${it.id}')" : "loadVideo('${it.id}')");
    _checkShort();
    _syncPipAuto();
  }

  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// [quiet]: pause / play without opening the player buttons (OK on the TV remote).
  void _togglePlay({bool quiet = false}) {
    if (quiet) _quietUntil = DateTime.now().add(const Duration(seconds: 3));
    if (_playing) {
      _js('player.pauseVideo()');
    } else {
      _js('player.playVideo()');
    }
    setState(() => _playing = !_playing);
    _wantPlay = _playing;
    if (!quiet) _showControls();
    _syncPipAuto();
  }

  /// [showUi] false = skip quietly without opening the player menu.
  void _seekBy(int seconds, {bool showUi = true}) {
    _js('player.seekTo(Math.max(0, player.getCurrentTime() + ($seconds)), true)');
    _pos.value = (_pos.value + seconds).clamp(0, _dur.value > 0 ? _dur.value : double.infinity).toDouble();
    _flashText(seconds > 0 ? '+$seconds s' : '$seconds s');
    if (showUi) _showControls();
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
    _wantPlay = true;
    setState(() {
      _ended = false;
      _playing = true;
    });
    _js('player.seekTo(0,true); player.playVideo();');
  }

  void _openSettings() {
    _hideTimer?.cancel();
    setState(() {
      _settingsOpen = true;
      _settingsPage = 'main';
    });
  }

  void _closeSettings() {
    setState(() => _settingsOpen = false);
    _showControls();
    if (_full && _wide) WidgetsBinding.instance.addPostFrameCallback((_) => _playNode.requestFocus());
  }

  static const Map<String, String> _qualityNames = {
    'tiny': '144p',
    'small': '240p',
    'medium': '360p',
    'large': '480p',
    'hd720': '720p',
    'hd1080': '1080p',
    'hd1440': '1440p',
    'hd2160': '2160p (4K)',
    'highres': 'Highest',
  };

  void _setQuality(String q) {
    setState(() {
      _quality = q;
      _settingsPage = 'main';
    });
    _js(q == 'auto' ? "player.setPlaybackQuality('default')" : "player.setPlaybackQuality('$q')");
  }

  String _speedLabel(double v) => v == 1.0 ? '1x' : '${v}x';

  void _flashText(String t) {
    _flashTimer?.cancel();
    setState(() => _flash = t);
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  void _showControls({bool focusSeek = false}) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      // Remote focus goes to the play button (Up goes to the time bar first).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_full || !_wide) return;
        (focusSeek ? _seekNode : _playNode).requestFocus();
      });
    }
    _scheduleHide();
  }

  /// Moves the remote focus to [n] and scrolls it into view.
  void _focusAndReveal(FocusNode n) {
    n.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = n.context;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 180), alignment: 0.5);
      }
    });
    _scheduleHide();
  }

  /// Up / Down on the button row: Up = time bar, Down = the video rows.
  KeyEventResult _onButtonRowKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focusAndReveal(_seekNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && widget.queue.length > 1) {
      setState(() => _browse = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _firstCardNode.requestFocus());
      _scheduleHide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible) return;
    setState(() {
      _controlsVisible = false;
      _browse = false;
    });
    _root.requestFocus();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing) return;
    _hideTimer = Timer(Duration(seconds: _wide ? 7 : 4), () {
      if (!mounted) return;
      // Stay open while a menu or the video rows are in use.
      if (_settingsOpen || _browse) {
        _scheduleHide();
        return;
      }
      _hideControls();
    });
  }

  Future<void> _toggleFull() async {
    final next = !_full;
    setState(() {
      _full = next;
      _controlsVisible = true;
    });
    if (_wide) {
      if (next) {
        await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } else {
      await _syncSystemUi();
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
    // Back must never open the menu: leave it to the normal back handling.
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.browserBack) {
      return KeyEventResult.ignored;
    }
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
      _seekBy(kSkipFwd);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-kSkipBack);
      return KeyEventResult.handled;
    }
    if (_full) {
      if (!_controlsVisible) {
        // Controls hidden. Left / right skip, Up / Down / OK open the controls
        // together with the "up next" videos (like the YouTube TV app).
        if (k == LogicalKeyboardKey.arrowRight) {
          _seekBy(kSkipFwd, showUi: false);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowLeft) {
          _seekBy(-kSkipBack, showUi: false);
          return KeyEventResult.handled;
        }
        // OK / centre button: only play or pause, the buttons stay hidden.
        if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.gameButtonA) {
          _togglePlay(quiet: true);
          return KeyEventResult.handled;
        }
        // Shorts: Down = next short, Up = previous short (like swiping).
        if (_short) {
          if (k == LogicalKeyboardKey.arrowDown) {
            if (_hasNext) _go(_index + 1, fromList: true);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowUp) {
            if (_index > 0) _go(_index - 1, fromList: true);
            return KeyEventResult.handled;
          }
        }
        // Always open on the Play/Pause button; Up from there reaches the time bar.
        _showControls();
        return KeyEventResult.handled;
      }
      _scheduleHide();
    }
    return KeyEventResult.ignored;
  }

  /// Time bar: hold Right / Left to keep scrubbing forward / back, faster the
  /// longer the key is held. The video jumps there when the key is released.
  KeyEventResult _onSeekKey(FocusNode node, KeyEvent event) {
    final k = event.logicalKey;
    final left = k == LogicalKeyboardKey.arrowLeft;
    final right = k == LogicalKeyboardKey.arrowRight;
    if (event is! KeyUpEvent && k == LogicalKeyboardKey.arrowDown) {
      _focusAndReveal(_playNode);
      return KeyEventResult.handled;
    }
    if (event is! KeyUpEvent && k == LogicalKeyboardKey.arrowUp) return KeyEventResult.handled;
    if (!left && !right) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _repeatCount = 0;
      if (_seeking) _seekTo(_pos.value, now: true);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      _repeatCount = 0;
    } else {
      _repeatCount++;
    }
    final step = (5 + _repeatCount * 2).clamp(5, 60).toInt();
    final dur = _dur.value;
    final next = (_pos.value + (right ? step : -step)).clamp(0.0, dur > 0 ? dur : double.infinity).toDouble();
    _seekTo(next);
    return KeyEventResult.handled;
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

  Widget _video({Size? webSize, bool bare = false}) {
    Widget web = WebViewWidget(key: _webKey, controller: _web);
    if (webSize != null) {
      web = ClipRect(
        child: OverflowBox(
          minWidth: webSize.width,
          maxWidth: webSize.width,
          minHeight: webSize.height,
          maxHeight: webSize.height,
          child: web,
        ),
      );
    }
    // The web page must never take the remote's focus (that froze the buttons).
    if (bare) return ColoredBox(color: Colors.black, child: ExcludeFocus(child: web));
    return ColoredBox(
      color: Colors.black,
      child: Stack(children: [
        Positioned.fill(child: ExcludeFocus(child: web)),
        if (!_ready) const Center(child: CircularProgressIndicator()),
        // Touch layer on top of the player: tap, double-tap to skip, pinch to zoom.
        Positioned.fill(
          child: _TouchLayer(
            onTap: () {
              if (_shortUi) {
                _togglePlay();
              } else if (_controlsVisible) {
                _hideControls();
              } else {
                _showControls();
              }
            },
            onSeek: _shortUi ? null : (s) => _seekBy(s, showUi: false),
            onPinch: (_full && !_wide && !_shortUi)
                ? (zoomIn) {
                    setState(() => _fill = zoomIn);
                    _flashText(zoomIn ? 'Zoom to fill' : 'Original');
                  }
                : null,
            onSwipe: _shortUi
                ? (dir) {
                    if (dir < 0) {
                      _go(_index + 1);
                    } else {
                      _go(_index - 1);
                    }
                  }
                : (!_wide && !_full
                    ? (dir) {
                        // Swipe down on the video: shrink to the mini bar.
                        if (dir > 0) PlayerHost.instance.minimize();
                      }
                    : null),
          ),
        ),
        // Finished: cover YouTube's own "more videos" suggestions. A plain pause keeps the picture clear.
        if (_ready && _ended)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black,
                child: const Center(child: Icon(Icons.replay, size: 72, color: Colors.white70)),
              ),
            ),
          ),
        if (_ready && !_playing && !_ended && _wide && !_controlsVisible)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(child: Icon(Icons.play_circle_outline, size: 72, color: Colors.white, shadows: [Shadow(blurRadius: 12, color: Colors.black87)])),
            ),
          ),
        // Phone: YouTube-app style buttons on the video itself.
        if (!_wide && !_shortUi && _controlsVisible) Positioned.fill(child: _mobileOverlay()),
        if (_shortUi) Positioned.fill(child: _shortOverlay()),
        if (_flash != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(_flash!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ),
        if (_errorCode != null && ((_wide && !_controlsVisible) || (!_wide && (_full || _shortUi))))
          Positioned(left: 16, right: 16, top: 56, child: _errorCard()),
      ]),
    );
  }

  /// Shorts: full-screen vertical video. Tap = pause / play, swipe up = next
  /// Short, swipe down = previous.
  Widget _shortOverlay() {
    final it = _current;
    return Stack(children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Container(height: 120, decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent]))),
        ),
      ),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Container(height: 190, decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]))),
        ),
      ),
      Positioned(
        top: 0,
        left: 4,
        child: SafeArea(child: IconButton(tooltip: 'Back', iconSize: 28, onPressed: _leave, icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white))),
      ),
      Positioned(
        top: 0,
        right: 4,
        child: SafeArea(
          child: Row(children: [
            IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.more_vert, color: Colors.white)),
          ]),
        ),
      ),
      Positioned(
        left: 16,
        right: 16,
        bottom: 28,
        child: IgnorePointer(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              it.hasRealTitle ? it.plainTitle : 'YouTube Short',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.25),
            ),
            if (widget.queue.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${_index + 1} of ${widget.queue.length}  -  swipe up for next', style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ),
          ]),
        ),
      ),
      Positioned(left: 0, right: 0, bottom: -4, child: _seekBar(times: false)),
    ]);
  }

  Widget _seekBar({bool times = true}) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      focusNode: _seekNode,
      onFocusChange: (f) => setState(() => _seekFocused = f),
      onKeyEvent: _onSeekKey,
      child: ValueListenableBuilder<double>(
        valueListenable: _dur,
        builder: (context, dur, _) => ValueListenableBuilder<double>(
          valueListenable: _pos,
          builder: (context, pos, __) {
            final frac = dur > 0 ? (pos / dur).clamp(0.0, 1.0).toDouble() : 0.0;
            final h = _seekFocused ? 12.0 : 6.0;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              if (times) ...[
                Row(children: [
                  Text(_fmt(pos), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(_fmt(dur), style: const TextStyle(fontSize: 15, color: Colors.white70)),
                ]),
                const SizedBox(height: 6),
              ],
              LayoutBuilder(builder: (context, c) {
                void touch(double dx) {
                  if (dur > 0) _seekTo((dx / c.maxWidth).clamp(0.0, 1.0) * dur, now: true);
                }

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => touch(d.localPosition.dx),
                  onHorizontalDragUpdate: (d) => touch(d.localPosition.dx),
                  child: SizedBox(
                    height: 24,
                    child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        height: h,
                        decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(h)),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        height: h,
                        width: c.maxWidth * frac,
                        decoration: BoxDecoration(color: primary, borderRadius: BorderRadius.circular(h)),
                      ),
                      Positioned(
                        left: (c.maxWidth * frac - (_seekFocused ? 11 : 7)).clamp(0.0, c.maxWidth).toDouble(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: _seekFocused ? 22 : 14,
                          height: _seekFocused ? 22 : 14,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: primary, width: _seekFocused ? 4 : 2),
                          ),
                        ),
                      ),
                    ]),
                  ),
                );
              }),
            ]);
          },
        ),
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback? onTap, {double size = 30, double pad = 10, String? tip}) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tip,
        iconSize: size,
        padding: EdgeInsets.all(pad),
        onPressed: onTap,
        icon: Icon(icon, color: onTap == null ? Colors.white30 : Colors.white),
      ),
    );
  }

  /// Phone controls drawn on the video, laid out like the YouTube app:
  /// collapse (top left), captions and settings (top right), previous /
  /// play-pause / next in the middle, time and full screen at the bottom,
  /// thin progress bar along the bottom edge.
  Widget _mobileOverlay() {
    return Stack(children: [
      const Positioned.fill(child: IgnorePointer(child: ColoredBox(color: Colors.black38))),
      Positioned(
        top: 2,
        left: 2,
        child: IconButton(
          tooltip: _full ? 'Exit full screen' : 'Close player',
          iconSize: 34,
          onPressed: _full ? _toggleFull : _leave,
          icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
        ),
      ),
      Positioned(
        top: 2,
        right: 2,
        child: Row(children: [
          IconButton(tooltip: 'Cast to TV', onPressed: _cast, icon: const Icon(Icons.cast, color: Colors.white)),
          _autoPill(),
          TextButton(
            onPressed: () {
              _openSettings();
              setState(() => _settingsPage = 'speed');
            },
            style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(40, 40), padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text(_speedLabel(_speed), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: 'Captions',
            onPressed: _toggleCaptions,
            icon: Icon(_captions ? Icons.closed_caption : Icons.closed_caption_off_outlined, color: Colors.white),
          ),
          IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings_outlined, color: Colors.white)),
        ]),
      ),
      Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _roundBtn(Icons.skip_previous, _index > 0 ? () => _go(_index - 1) : null, tip: 'Previous'),
          const SizedBox(width: 28),
          _roundBtn(_ended ? Icons.replay : (_playing ? Icons.pause : Icons.play_arrow), _ended ? _replay : _togglePlay, size: 44, pad: 14, tip: _playing ? 'Pause' : 'Play'),
          const SizedBox(width: 28),
          _roundBtn(Icons.skip_next, _hasNext ? () => _go(_index + 1) : null, tip: 'Next'),
        ]),
      ),
      Positioned(
        left: 14,
        right: 6,
        bottom: 12,
        child: Row(children: [
          ValueListenableBuilder<double>(
            valueListenable: _dur,
            builder: (context, dur, _) => ValueListenableBuilder<double>(
              valueListenable: _pos,
              builder: (context, pos, __) => Text('${_fmt(pos)} / ${_fmt(dur)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
          const Spacer(),
          if (_full)
            IconButton(
              tooltip: _fill ? 'Original size' : 'Zoom to fill',
              onPressed: () {
                setState(() => _fill = !_fill);
                _flashText(_fill ? 'Zoom to fill' : 'Original');
              },
              icon: Icon(_fill ? Icons.zoom_in_map : Icons.zoom_out_map, color: Colors.white),
            ),
          IconButton(
            tooltip: _full ? 'Exit full screen' : 'Full screen',
            onPressed: _toggleFull,
            icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
          ),
        ]),
      ),
      Positioned(left: 0, right: 0, bottom: -4, child: _seekBar(times: false)),
    ]);
  }

  // ---------------------------------------------------------------- settings
  Widget _settingsRow(IconData icon, String title, {String? value, VoidCallback? onTap, Widget? trailing, bool autofocus = false, bool selected = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TvFocusable(
        autofocus: autofocus,
        onTap: onTap,
        radius: 12,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? Theme.of(context).colorScheme.primary.withOpacity(0.35) : Colors.white10,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            Icon(icon, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                if (value != null) Text(value, style: const TextStyle(fontSize: 13, color: Colors.white70)),
              ]),
            ),
            trailing ?? (onTap != null ? const Icon(Icons.chevron_right) : const SizedBox.shrink()),
          ]),
        ),
      ),
    );
  }

  Widget _settingsContent() {
    final List<Widget> rows;
    String title = 'Settings';
    if (_settingsPage == 'quality') {
      title = 'Quality';
      rows = [
        _settingsRow(Icons.hd_outlined, 'Auto', autofocus: true, selected: _quality == 'auto', onTap: () => _setQuality('auto'), trailing: _quality == 'auto' ? const Icon(Icons.check) : const SizedBox.shrink()),
        for (final q in _qualities)
          _settingsRow(Icons.hd_outlined, _qualityNames[q] ?? q, selected: _quality == q, onTap: () => _setQuality(q), trailing: _quality == q ? const Icon(Icons.check) : const SizedBox.shrink()),
        if (_qualities.isEmpty)
          const Padding(padding: EdgeInsets.all(14), child: Text('Other qualities appear once the video has started.', style: TextStyle(color: Colors.white70))),
      ];
    } else if (_settingsPage == 'speed') {
      title = 'Playback speed';
      rows = [
        for (final v in _speeds)
          _settingsRow(Icons.speed, v == 1.0 ? 'Normal' : '${_speedLabel(v)}', autofocus: v == _speed, selected: v == _speed, trailing: v == _speed ? const Icon(Icons.check) : const SizedBox.shrink(), onTap: () {
            setState(() {
              _speed = v;
              _settingsPage = 'main';
            });
            _js('player.setPlaybackRate($v)');
          }),
      ];
    } else {
      rows = [
        _settingsRow(Icons.hd_outlined, 'Quality', autofocus: true, value: _quality == 'auto' ? 'Auto' : (_qualityNames[_quality] ?? _quality), onTap: () => setState(() => _settingsPage = 'quality')),
        _settingsRow(Icons.closed_caption_outlined, 'Captions', value: _captions ? 'On' : 'Off', onTap: _toggleCaptions),
        _settingsRow(Icons.speed, _wide ? 'Speed' : 'Playback speed', value: _speed == 1.0 ? 'Normal' : '${_speed}x', onTap: () => setState(() => _settingsPage = 'speed')),
        _settingsRow(
          Icons.repeat,
          'Repeat',
          onTap: () => setState(() => _repeat = _repeat == 2 ? 0 : 2),
          trailing: Icon(_repeat == 2 ? Icons.check_box : Icons.check_box_outline_blank),
        ),
        _settingsRow(
          Icons.skip_next_outlined,
          'Play next automatically',
          onTap: () => setState(() => _autoNext = !_autoNext),
          trailing: Icon(_autoNext ? Icons.check_box : Icons.check_box_outline_blank),
        ),
        _settingsRow(Icons.swap_horiz, 'Player type', value: _mode == 0 ? 'A (try B if videos fail)' : 'B', onTap: () {
          _nextMode();
          _closeSettings();
        }),
        if (!_wide) _settingsRow(_audio ? Icons.videocam_outlined : Icons.headphones, _audio ? 'Video mode' : 'Audio mode (MP3 player)', onTap: () => _setAudio(!_audio)),
        _settingsRow(Icons.open_in_new, 'Open in YouTube app', onTap: () {
          _closeSettings();
          _openInYouTube();
        }),
      ];
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (_settingsPage != 'main')
          IconButton(onPressed: () => setState(() => _settingsPage = 'main'), icon: const Icon(Icons.arrow_back))
        else
          const SizedBox(width: 12),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(tooltip: 'Close', onPressed: _closeSettings, icon: const Icon(Icons.close)),
      ]),
      const SizedBox(height: 6),
      Flexible(child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 12), children: rows)),
      const SizedBox(height: 12),
    ]);
  }

  /// TV: panel on the right (like the YouTube TV settings). Phone: bottom sheet.
  Widget _settingsLayer() {
    final size = MediaQuery.of(context).size;
    final panel = Material(
      color: const Color(0xF2161616),
      borderRadius: _wide ? BorderRadius.zero : const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(child: _settingsContent()),
    );
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closeSettings, child: const ColoredBox(color: Colors.black38)),
      ),
      if (_wide)
        Positioned(right: 0, top: 0, bottom: 0, width: (size.width * 0.38).clamp(340.0, 520.0).toDouble(), child: panel)
      else
        Positioned(left: 0, right: 0, bottom: 0, child: ConstrainedBox(constraints: BoxConstraints(maxHeight: size.height * 0.75), child: panel)),
    ]);
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
          IconButton.filledTonal(tooltip: 'Back 10 s', onPressed: () => _seekBy(-kSkipBack), icon: const Icon(Icons.replay_10)),
          IconButton.filled(
            tooltip: _playing ? 'Pause' : 'Play',
            iconSize: 32,
            focusNode: _playNode,
            onPressed: _ended ? _replay : _togglePlay,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton.filledTonal(tooltip: 'Forward 30 s', onPressed: () => _seekBy(kSkipFwd), icon: const Icon(Icons.forward_30)),
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

  /// YouTube-TV style overlay. Controls view: title, time bar and all buttons at
  /// the bottom with the first row of "up next" videos peeking in. Press Down
  /// and the controls make room for the "Up next" rows (3 per row): every new
  /// Down replaces the upper row with the next one, like the YouTube TV app.
  Widget _fullOverlay() {
    final order = <int>[
      for (int i = _index + 1; i < widget.queue.length; i++) i,
      for (int i = 0; i < _index; i++) i,
    ];
    return LayoutBuilder(builder: (context, c) {
      final cardW = (c.maxWidth - 56 - 24) / 3;
      final rowH = cardW * 9 / 16 + 76;
      if (_browse && order.isNotEmpty) return _browseView(c, order, cardW, rowH);
      return _controlsView(c, order, cardW, rowH);
    });
  }

  Widget _controlsView(BoxConstraints c, List<int> order, double cardW, double rowH) {
    final it = _current;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 36),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withOpacity(_playing ? 0.85 : 1.0), Colors.transparent]),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            it.hasRealTitle ? it.plainTitle : 'YouTube ${it.isPlaylist ? 'playlist' : 'video'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.2),
          ),
          if (widget.queue.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Playing ${_index + 1} of ${widget.queue.length}', style: const TextStyle(color: Colors.white70, fontSize: 15)),
            ),
        ]),
      ),
      if (_errorCode != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 28), child: _errorCard()),
      const Spacer(),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(28, 36, 28, 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(0.92)]),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _seekBar(),
          const SizedBox(height: 6),
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onButtonRowKey,
            child: Row(children: [
              // left group
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 10, children: [
                    IconButton.filledTonal(
                      tooltip: 'Repeat',
                      onPressed: _cycleRepeat,
                      icon: Icon(_repeat == 2 ? Icons.repeat_one : Icons.repeat, color: _repeat == 0 ? null : primary),
                    ),
                    FilledButton.tonalIcon(onPressed: _cycleSpeed, icon: const Icon(Icons.speed), label: Text(_speedLabel(_speed))),
                  ]),
                ),
              ),
              // centre group
              IconButton.filledTonal(tooltip: 'Previous', iconSize: 30, onPressed: _index > 0 ? () => _go(_index - 1) : null, icon: const Icon(Icons.skip_previous)),
              const SizedBox(width: 8),
              IconButton.filledTonal(tooltip: 'Back $kSkipBack s', iconSize: 30, onPressed: () => _seekBy(-kSkipBack), icon: const Icon(Icons.replay_10)),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: _playing ? 'Pause' : 'Play',
                iconSize: 44,
                focusNode: _playNode,
                autofocus: true,
                onPressed: _ended ? _replay : _togglePlay,
                icon: Icon(_ended ? Icons.replay : (_playing ? Icons.pause : Icons.play_arrow)),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(tooltip: 'Forward $kSkipFwd s', iconSize: 30, onPressed: () => _seekBy(kSkipFwd), icon: const Icon(Icons.forward_30)),
              const SizedBox(width: 8),
              IconButton.filledTonal(tooltip: 'Next', iconSize: 30, onPressed: _hasNext ? () => _go(_index + 1) : null, icon: const Icon(Icons.skip_next)),
              // right group
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(spacing: 10, children: [
                    IconButton.filledTonal(
                      tooltip: 'Captions',
                      onPressed: _toggleCaptions,
                      icon: Icon(_captions ? Icons.closed_caption : Icons.closed_caption_off_outlined),
                    ),
                    IconButton.filledTonal(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings)),
                    IconButton.filledTonal(tooltip: 'Close player', onPressed: PlayerHost.instance.close, icon: const Icon(Icons.close)),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
      // First row of "up next" peeking in from the bottom edge.
      if (order.isNotEmpty)
        Container(
          height: 118,
          width: double.infinity,
          color: Colors.black.withOpacity(0.92),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ExcludeFocus(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: rowH,
                child: SizedBox(height: rowH, child: _cardRow(order, 0, cardW, focusable: false)),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _cardRow(List<int> order, int r, double cardW, {required bool focusable}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (int j = r; j < r + 3; j++) ...[
        if (j > r) const SizedBox(width: 12),
        SizedBox(
          width: cardW,
          child: j < order.length ? _nextCard(order[j], cardW, focusable: focusable, node: (focusable && j == 0) ? _firstCardNode : null, rowIndex: r ~/ 3) : const SizedBox.shrink(),
        ),
      ],
    ]);
  }

  Widget _browseView(BoxConstraints c, List<int> order, double cardW, double rowH) {
    final rows = (order.length + 2) ~/ 3;
    return Column(children: [
      // The video stays visible above the rows.
      const Expanded(child: IgnorePointer(child: SizedBox.expand())),
      Container(
        height: c.maxHeight * 0.64,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.0), Colors.black.withOpacity(0.92), Colors.black],
            stops: const [0.0, 0.18, 1.0],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 14, 28, 6),
            child: Row(children: [
              Icon(Icons.queue_music),
              SizedBox(width: 8),
              Text('Up next', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              controller: _overlayScroll,
              itemExtent: rowH,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              itemCount: rows,
              itemBuilder: (context, r) => _firstRowKeys(first: r == 0, child: _cardRow(order, r * 3, cardW, focusable: true)),
            ),
          ),
        ]),
      ),
    ]);
  }

  /// Up from the first row of videos goes back to the controls.
  Widget _firstRowKeys({required bool first, required Widget child}) {
    if (!first) return child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (n, e) {
        if (e is! KeyUpEvent && e.logicalKey == LogicalKeyboardKey.arrowUp) {
          setState(() => _browse = false);
          WidgetsBinding.instance.addPostFrameCallback((_) => _playNode.requestFocus());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  Widget _nextCard(int i, double w, {FocusNode? node, bool focusable = true, int rowIndex = 0}) {
    final q = widget.queue[i];
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Image.network(
            q.thumbUrlHq,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        q.hasRealTitle ? q.plainTitle : 'YouTube video',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.25),
      ),
    ]);
    if (!focusable) return body;
    return TvFocusable(
      focusNode: node,
      // The focused row slides up to the top of the list, replacing the row above.
      onFocus: (f) {
        if (f && _overlayScroll.hasClients) {
          final rowH = w * 9 / 16 + 76;
          final max = _overlayScroll.position.maxScrollExtent;
          _overlayScroll.animateTo((rowIndex * rowH).clamp(0.0, max).toDouble(), duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
        }
      },
      // Picked a video: close the rows and play it full screen.
      onTap: () => _go(i, fromList: true),
      child: body,
    );
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

  /// Round colourful action button with a small caption (phone panel).
  Widget _actionTile(IconData icon, Color color, String label, VoidCallback onTap, {bool on = true}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: on
                    ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, color.withOpacity(0.6)])
                    : const LinearGradient(colors: [Color(0xFF3A3A3A), Color(0xFF2A2A2A)]),
                boxShadow: on ? [BoxShadow(color: color.withOpacity(0.35), blurRadius: 10)] : null,
              ),
              child: Icon(icon, color: on ? Colors.white : Colors.white54, size: 26),
            ),
            const SizedBox(height: 6),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
          ]),
        ),
      ),
    );
  }

  Widget _panel({required bool wide}) {
    final it = _current;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Row(children: [
          IconButton(tooltip: 'Minimize', onPressed: _leave, icon: const Icon(Icons.keyboard_arrow_down)),
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
        Row(children: [
          if (widget.queue.length > 1)
            const Text('Up next', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          const Spacer(),
          if (widget.queue.length > 2)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chipBtn(_queueEdit ? Icons.check : Icons.swap_vert, _queueEdit ? 'Done' : 'Order', () => setState(() {
                _queueEdit = !_queueEdit;
                _cardMenu = -1;
              })),
            ),
          _chipBtn(Icons.headphones, 'Audio', () => _setAudio(true)),
        ]),
        if (widget.queue.length > 1) ...[
          const SizedBox(height: 10),
          if (_queueEdit) ..._orderList() else ..._cardList(),
        ],
      ],
    );
  }

  /// Small, quiet pill button (same look for Audio / Order).
  Widget _chipBtn(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: Colors.white10,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 17, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70)),
          ]),
        ),
      ),
    );
  }

  /// YouTube style "Auto-play" switch shown on the video next to CC / settings.
  Widget _autoPill() {
    return Tooltip(
      message: _autoNext ? 'Auto-play is on' : 'Auto-play is off',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() => _autoNext = !_autoNext);
          _flashText(_autoNext ? 'Auto-play is on' : 'Auto-play is off');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 36,
            height: 18,
            padding: const EdgeInsets.all(2),
            alignment: _autoNext ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: _autoNext ? Colors.white70 : Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
              child: Icon(_autoNext ? Icons.play_arrow : Icons.pause, size: 10, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  // ---- queue editing (changes only what plays next, not the saved .m3u file)
  void _qMove(int from, int to) {
    final q = widget.queue;
    if (from < 0 || from >= q.length || to < 0 || to >= q.length || from == to) return;
    final cur = q[_index];
    final it = q.removeAt(from);
    q.insert(to, it);
    setState(() => _index = q.indexOf(cur));
    _syncPipAuto();
  }

  void _qRemove(int i) {
    final q = widget.queue;
    if (i == _index || i < 0 || i >= q.length) return;
    q.removeAt(i);
    setState(() {
      if (i < _index) _index--;
      _cardMenu = -1;
    });
    _syncPipAuto();
  }

  String _cardTitle(YtItem it) => it.hasRealTitle ? it.plainTitle : 'YouTube ${it.isPlaylist ? 'playlist' : 'video'}';

  Widget _bigCard(int i, String badge) {
    final it = widget.queue[i];
    final current = i == _index;
    final primary = Theme.of(context).colorScheme.primary;
    final menuOpen = _cardMenu == i;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: current ? null : () => _go(i),
          child: Stack(children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(it.thumbUrl, fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.white10)),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: current ? primary : Colors.black87, borderRadius: BorderRadius.circular(6)),
                child: Text(current ? 'Now playing' : badge, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: GestureDetector(
                onTap: current ? null : () => _go(i),
                child: Text(_cardTitle(it), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.25)),
              ),
            ),
            if (!current)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Options',
                onPressed: () => setState(() => _cardMenu = menuOpen ? -1 : i),
                icon: const Icon(Icons.more_vert, size: 22),
              ),
          ]),
        ),
        if (menuOpen)
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (i != _index + 1) _chipBtn(Icons.vertical_align_top, 'Play next', () {
              _qMove(i, i > _index ? _index + 1 : _index);
              setState(() => _cardMenu = -1);
              _flashText('Will play next');
            }),
            if (i > _index + 1) _chipBtn(Icons.arrow_upward, 'Move up', () {
              _qMove(i, i - 1);
              setState(() => _cardMenu = i - 1);
            }),
            if (i > _index && i < widget.queue.length - 1) _chipBtn(Icons.arrow_downward, 'Move down', () {
              _qMove(i, i + 1);
              setState(() => _cardMenu = i + 1);
            }),
            if (i > _index) _chipBtn(Icons.vertical_align_bottom, 'Play last', () {
              _qMove(i, widget.queue.length - 1);
              setState(() => _cardMenu = -1);
            }),
            _chipBtn(Icons.close, 'Remove', () => _qRemove(i)),
          ]),
      ]),
    );
  }

  List<Widget> _cardList() {
    final n = widget.queue.length;
    return [
      _bigCard(_index, ''),
      for (int i = _index + 1; i < n; i++) _bigCard(i, 'Next #${i - _index}'),
      if (_index > 0) ...[
        const Padding(padding: EdgeInsets.only(bottom: 10), child: Text('Played earlier', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white70))),
        for (int i = 0; i < _index; i++) _bigCard(i, 'Earlier'),
      ],
    ];
  }

  /// Compact drag-to-reorder list of the upcoming videos.
  List<Widget> _orderList() {
    final start = _index + 1;
    final count = widget.queue.length - start;
    if (count <= 0) return [const Padding(padding: EdgeInsets.all(12), child: Text('No upcoming videos.', style: TextStyle(color: Colors.white54)))];
    return [
      const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Hold the handle and drag to set the order. The top one plays next.', style: TextStyle(fontSize: 12.5, color: Colors.white54))),
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: count,
        onReorder: (o, n) {
          if (n > o) n--;
          _qMove(start + o, start + n);
        },
        itemBuilder: (context, k) {
          final it = widget.queue[start + k];
          return Container(
            key: ObjectKey(it),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.all(6),
            child: Row(children: [
              SizedBox(width: 22, child: Text('${k + 1}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w700))),
              const SizedBox(width: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(it.thumbUrl, width: 96, height: 54, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox(width: 96, height: 54)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(_cardTitle(it), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
              IconButton(visualDensity: VisualDensity.compact, tooltip: 'Remove', onPressed: () => _qRemove(start + k), icon: const Icon(Icons.close, size: 20)),
              ReorderableDragStartListener(index: k, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle, color: Colors.white70))),
            ]),
          );
        },
      ),
    ];
  }

  // -------------------------------------------------------------- audio mode
  Widget _audioView() {
    final it = _current;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2A1B5C), Color(0xFF0F0B1E), Colors.black]),
      ),
      child: SafeArea(
        child: Column(children: [
          Row(children: [
            IconButton(tooltip: 'Minimize', onPressed: _leave, icon: const Icon(Icons.keyboard_arrow_down, size: 32)),
            const Expanded(child: Text('Audio mode', textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: Colors.white70))),
            IconButton(tooltip: 'Black screen (double-tap to wake)', onPressed: () => setState(() => _blackout = true), icon: const Icon(Icons.brightness_2_outlined)),
            IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.more_vert)),
          ]),
          // Compact "now playing" header: small cover + title, so the list gets the room.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Row(children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: primary.withOpacity(0.35), blurRadius: 18)]),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(it.thumbUrlHq, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26, child: Icon(Icons.music_note, size: 36))),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.hasRealTitle ? it.plainTitle : 'YouTube video', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, height: 1.25)),
                  const SizedBox(height: 4),
                  Text(widget.queue.length > 1 ? 'Track ${_index + 1} of ${widget.queue.length}  ·  low data' : 'Now playing  ·  low data', style: const TextStyle(color: Colors.white60, fontSize: 12.5)),
                ]),
              ),
            ]),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _seekBar()),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Repeat', iconSize: 24, onPressed: _cycleRepeat, icon: Icon(_repeat == 2 ? Icons.repeat_one : Icons.repeat, color: _repeat == 0 ? Colors.white70 : primary)),
            IconButton(tooltip: 'Previous', iconSize: 38, onPressed: _index > 0 ? () => _go(_index - 1) : null, icon: const Icon(Icons.skip_previous)),
            IconButton.filled(tooltip: _playing ? 'Pause' : 'Play', iconSize: 40, onPressed: _ended ? _replay : _togglePlay, icon: Icon(_ended ? Icons.replay : (_playing ? Icons.pause : Icons.play_arrow))),
            IconButton(tooltip: 'Next', iconSize: 38, onPressed: _hasNext ? () => _go(_index + 1) : null, icon: const Icon(Icons.skip_next)),
            TextButton(onPressed: _cycleSpeed, child: Text(_speedLabel(_speed), style: const TextStyle(fontSize: 15))),
          ]),
          const Divider(height: 1, color: Colors.white12),
          if (widget.queue.length > 1)
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                itemCount: widget.queue.length,
                itemBuilder: (context, i) {
                  final q = widget.queue[i];
                  final cur = i == _index;
                  return ListTile(
                    dense: true,
                    selected: cur,
                    selectedTileColor: primary.withOpacity(0.2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    leading: SizedBox(
                      width: 28,
                      child: Center(child: cur ? Icon(Icons.equalizer, color: primary) : Text('${i + 1}', style: const TextStyle(color: Colors.white54))),
                    ),
                    title: Text(q.hasRealTitle ? q.plainTitle : 'YouTube video', maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _go(i),
                  );
                },
              ),
            )
          else
            const Spacer(),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ build
  Widget _body() {
    // Floating mini player: video only.
    if (_inPip) return SizedBox.expand(child: _video(bare: true));

    // Audio mode: the player shrinks to a few pixels, the music UI is shown.
    if (_audio && !_wide) {
      return Stack(children: [
        Positioned(left: 0, top: 0, width: 4, height: 4, child: _video(bare: true)),
        Positioned.fill(child: _audioView()),
        if (_blackout)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => setState(() => _blackout = false),
              child: const ColoredBox(color: Colors.black, child: Center(child: Text('Double-tap to wake', style: TextStyle(color: Colors.white24)))),
            ),
          ),
        if (_settingsOpen) Positioned.fill(child: _settingsLayer()),
      ]);
    }

    return Stack(children: [
      Positioned.fill(
        child: SafeArea(
          top: !(_full || _shortUi),
          bottom: !(_full || _shortUi),
          left: !_full,
          right: !_full,
          child: LayoutBuilder(builder: (context, c) {
            if (_shortUi) return _video();
            if (_full) {
              final fitW = math.min(c.maxWidth, c.maxHeight * 16 / 9);
              final fitH = fitW * 9 / 16;
              final zoom = _fill && !_wide;
              final k = zoom ? math.max(c.maxWidth / fitW, c.maxHeight / fitH) : 1.0;
              return Stack(children: [
                Positioned.fill(
                  child: zoom ? _video(webSize: Size(fitW * k, fitH * k)) : Center(child: AspectRatio(aspectRatio: 16 / 9, child: _video())),
                ),
                if (_wide && _controlsVisible) Positioned.fill(child: _fullOverlay()),
              ]);
            }
            return Column(children: [
              AspectRatio(aspectRatio: 16 / 9, child: _video()),
              Expanded(child: _panel(wide: false)),
            ]);
          }),
        ),
      ),
      if (_settingsOpen) Positioned.fill(child: _settingsLayer()),
    ]);
  }

  /// Small floating video window: drag it anywhere, tap to enlarge.
  Widget _miniWindow() {
    final host = PlayerHost.instance;
    final mq = MediaQuery.of(context);
    return Material(
      color: Colors.black,
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        _video(bare: true),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: host.expand,
            onPanUpdate: (d) => host.dragMini(d.delta, mq.size, mq.padding),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ValueListenableBuilder<double>(
            valueListenable: _dur,
            builder: (context, dur, _) => ValueListenableBuilder<double>(
              valueListenable: _pos,
              builder: (context, pos, __) => LinearProgressIndicator(
                value: dur > 0 ? (pos / dur).clamp(0.0, 1.0).toDouble() : 0,
                minHeight: 2.5,
                backgroundColor: Colors.white24,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: _miniBtn(Icons.close, host.close),
        ),
        Positioned(
          top: 0,
          left: 0,
          child: _miniBtn(Icons.open_in_full, host.expand),
        ),
        Center(child: _miniBtn(_ended ? Icons.replay : (_playing ? Icons.pause : Icons.play_arrow), _ended ? _replay : _togglePlay, big: true)),
      ]),
    );
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap, {bool big = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          padding: EdgeInsets.all(big ? 8 : 4),
          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
          child: Icon(icon, size: big ? 26 : 16, color: Colors.white),
        ),
      ),
    );
  }

  /// The little bar shown at the bottom while you browse the app.
  Widget _miniBar() {
    final it = _current;
    final primary = Theme.of(context).colorScheme.primary;
    final title = it.hasRealTitle ? it.plainTitle : 'YouTube video';
    return Material(
      color: const Color(0xFF1F1A3A),
      elevation: 10,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: PlayerHost.instance.expand,
        child: Stack(children: [
          Row(children: [
            SizedBox(
              width: 117,
              height: 66,
              child: Stack(fit: StackFit.expand, children: [
                if (_audio)
                  Image.network(it.thumbUrl, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26))
                else
                  _video(bare: true),
                if (_audio) Positioned(left: 0, top: 0, width: 4, height: 4, child: _video(bare: true)),
                Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: PlayerHost.instance.expand)),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.2)),
                  if (widget.queue.length > 1) Text('${_index + 1} of ${widget.queue.length}', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ]),
              ),
            ),
            IconButton(tooltip: _playing ? 'Pause' : 'Play', onPressed: _ended ? _replay : _togglePlay, icon: Icon(_ended ? Icons.replay : (_playing ? Icons.pause : Icons.play_arrow))),
            if (_hasNext) IconButton(tooltip: 'Next', onPressed: () => _go(_index + 1), icon: const Icon(Icons.skip_next)),
            IconButton(tooltip: 'Close', onPressed: PlayerHost.instance.close, icon: const Icon(Icons.close)),
          ]),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _dur,
              builder: (context, dur, _) => ValueListenableBuilder<double>(
                valueListenable: _pos,
                builder: (context, pos, __) => LinearProgressIndicator(
                  value: dur > 0 ? (pos / dur).clamp(0.0, 1.0).toDouble() : 0,
                  minHeight: 2.5,
                  backgroundColor: Colors.white12,
                  color: primary,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _root,
      autofocus: true,
      onKeyEvent: _onKey,
      child: (widget.minimized && !_inPip) ? (_audio ? _miniBar() : _miniWindow()) : Scaffold(backgroundColor: Colors.black, body: _body()),
    );
  }
}

/// Transparent layer: tap, double-tap on the left / right half to skip,
/// pinch to zoom, vertical swipe (Shorts).
class _TouchLayer extends StatefulWidget {
  final VoidCallback onTap;
  final void Function(int seconds)? onSeek;
  final void Function(bool zoomIn)? onPinch;
  final void Function(int dir)? onSwipe;
  const _TouchLayer({Key? key, required this.onTap, this.onSeek, this.onPinch, this.onSwipe}) : super(key: key);

  @override
  State<_TouchLayer> createState() => _TouchLayerState();
}

class _TouchLayerState extends State<_TouchLayer> {
  Offset? _last;
  double _scale = 1;
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: widget.onSeek == null ? null : (d) => _last = d.localPosition,
        onDoubleTap: widget.onSeek == null
            ? null
            : () {
                final x = _last?.dx ?? c.maxWidth / 2;
                widget.onSeek!(x < c.maxWidth / 2 ? -kSkipBack : kSkipBack);
              },
        onScaleStart: widget.onPinch == null ? null : (_) => _scale = 1,
        onScaleUpdate: widget.onPinch == null
            ? null
            : (d) {
                if (d.pointerCount >= 2) _scale = d.scale;
              },
        onScaleEnd: widget.onPinch == null
            ? null
            : (_) {
                if (_scale > 1.12) {
                  widget.onPinch!(true);
                } else if (_scale < 0.88) {
                  widget.onPinch!(false);
                }
                _scale = 1;
              },
        onVerticalDragStart: widget.onSwipe == null ? null : (_) => _dy = 0,
        onVerticalDragUpdate: widget.onSwipe == null ? null : (d) => _dy += d.delta.dy,
        onVerticalDragEnd: widget.onSwipe == null
            ? null
            : (d) {
                final v = d.primaryVelocity ?? 0;
                if (v < -300 || _dy < -80) {
                  widget.onSwipe!(-1);
                } else if (v > 300 || _dy > 80) {
                  widget.onSwipe!(1);
                }
              },
      );
    });
  }
}
