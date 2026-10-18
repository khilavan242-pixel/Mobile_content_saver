import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'prefs.dart';

import 'm3u_store.dart';
import 'player_host.dart';
import 'youtube_core.dart';

// ============================================================================
// TV SYNC: send / update the .m3u files on an Android TV over the same Wi-Fi.
//
//  TV    : TubeBox -> TV Sync -> Receive.  A tiny web server (port 8765) accepts
//          .m3u files and writes them into the TV's TubeBox folder.
//  Phone : TubeBox -> TV Sync -> Send.  Finds the TV on the Wi-Fi (or type its
//          IP), asks for the PIN shown on the TV once, then sends the files.
// ============================================================================
const int kTvPort = 8765;

class TvDevice {
  final String ip;
  final String name;
  TvDevice(this.ip, this.name);
}

// ----------------------------------------------------------------------------
// RECEIVER (runs on the TV)
// ----------------------------------------------------------------------------
class TvReceiver {
  TvReceiver._();
  static final TvReceiver instance = TvReceiver._();

  HttpServer? _server;
  String folder = '';
  String pin = '0000';
  final ValueNotifier<bool> running = ValueNotifier(false);
  final ValueNotifier<List<String>> log = ValueNotifier(<String>[]);
  final ValueNotifier<List<String>> addresses = ValueNotifier(<String>[]);

  String get deviceName => Platform.localHostname.isEmpty ? 'Android TV' : Platform.localHostname;

  Future<void> loadPin() async {
    final prefs = await SharedPreferences.getInstance();
    var p = prefs.getString('tv_receiver_pin');
    if (p == null || p.length != 4) {
      p = (1000 + Random.secure().nextInt(9000)).toString();
      await prefs.setString('tv_receiver_pin', p);
    }
    pin = p;
  }

  Future<void> regeneratePin() async {
    final prefs = await SharedPreferences.getInstance();
    pin = (1000 + Random.secure().nextInt(9000)).toString();
    await prefs.setString('tv_receiver_pin', pin);
    running.value = running.value; // nudge listeners
  }

  Future<List<String>> localAddresses() async {
    final out = <String>[];
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in i.addresses) {
          out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  /// Returns an error text, or null when the server is running.
  Future<String?> start(String targetFolder) async {
    await loadPin();
    folder = targetFolder;
    if (_server != null) {
      addresses.value = await localAddresses();
      running.value = true;
      return null;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, kTvPort, shared: true);
      _server!.listen(_handle, onError: (_) {});
      addresses.value = await localAddresses();
      running.value = true;
      return null;
    } catch (e) {
      _server = null;
      running.value = false;
      return 'Could not start the receiver: $e';
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    running.value = false;
    await s?.close(force: true);
  }

  void _addLog(String line) {
    final now = DateTime.now();
    final t = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    log.value = ['$t  $line', ...log.value].take(30).toList();
  }

  Future<void> _reply(HttpRequest req, int code, Map<String, dynamic> body) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/ping') {
        return await _reply(req, 200, {'app': 'tubebox', 'name': deviceName, 'v': 1});
      }
      if (req.headers.value('x-pin') != pin) {
        return await _reply(req, 403, {'error': 'Wrong PIN'});
      }

      // Cast: the phone sends the videos, the TV plays them full screen.
      if (path == '/play' && req.method == 'POST') {
        final text = await utf8.decoder.bind(req).join();
        final j = jsonDecode(text) as Map<String, dynamic>;
        final items = <YtItem>[];
        for (final e in (j['items'] as List)) {
          final m = e as Map<String, dynamic>;
          items.add(YtItem(kind: (m['kind'] as String?) ?? 'video', id: (m['id'] as String?) ?? '', title: (m['title'] as String?) ?? ''));
        }
        if (items.isEmpty) return await _reply(req, 400, {'error': 'Nothing to play'});
        final idx = ((j['index'] as num?) ?? 0).toInt().clamp(0, items.length - 1).toInt();
        _addLog('Cast: ${items[idx].title}');
        PlayerHost.instance.open(items, idx);
        return await _reply(req, 200, {'playing': true});
      }
      if (path == '/cmd' && req.method == 'POST') {
        PlayerHost.instance.command(req.uri.queryParameters['c'] ?? '');
        return await _reply(req, 200, {'ok': true});
      }

      if (path == '/files' && req.method == 'GET') {
        final list = <Map<String, dynamic>>[];
        final dir = Directory(folder);
        if (await dir.exists()) {
          await for (final e in dir.list(followLinks: false)) {
            if (e is File && e.path.toLowerCase().endsWith('.m3u')) {
              list.add({'name': e.path.split('/').last, 'size': await e.length()});
            }
          }
        }
        return await _reply(req, 200, {'files': list});
      }

      if (path == '/upload' && req.method == 'POST') {
        final raw = req.uri.queryParameters['name'] ?? '';
        final safe = YtStore.safeName(raw);
        if (safe.isEmpty) return await _reply(req, 400, {'error': 'Missing file name'});

        final bytes = <int>[];
        await for (final chunk in req) {
          bytes.addAll(chunk);
          if (bytes.length > 10 * 1024 * 1024) {
            return await _reply(req, 413, {'error': 'File too large'});
          }
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        if (!text.contains('#EXTM3U') && !text.contains('#EXTINF')) {
          return await _reply(req, 400, {'error': 'Not an M3U file'});
        }

        final dir = Directory(folder);
        if (!await dir.exists()) await dir.create(recursive: true);
        final target = File('$folder/$safe.m3u');
        if (await target.exists()) {
          await target.copy('$folder/$safe.m3u.bak'); // one-step undo on the TV
        }
        await target.writeAsString(text);
        final count = parseM3uLines(text.split('\n')).length;
        _addLog('$safe.m3u  ($count items)');
        return await _reply(req, 200, {'saved': true, 'items': count});
      }

      await _reply(req, 404, {'error': 'Not found'});
    } catch (e) {
      try {
        await _reply(req, 500, {'error': '$e'});
      } catch (_) {}
    }
  }
}

// ----------------------------------------------------------------------------
// CLIENT (runs on the phone)
// ----------------------------------------------------------------------------
class TvClient {
  static Future<TvDevice?> ping(String ip, {Duration timeout = const Duration(milliseconds: 900)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse('http://$ip:$kTvPort/ping'));
      final res = await req.close().timeout(timeout * 2);
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join().timeout(timeout * 2);
      final j = jsonDecode(body);
      if (j is Map && j['app'] == 'tubebox') return TvDevice(ip, (j['name'] as String?) ?? ip);
    } catch (_) {
      // not a TubeBox TV, or nothing listening
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Looks for TVs running the receiver on every /24 network this phone is on.
  static Future<List<TvDevice>> scan({void Function(int done, int total)? onProgress}) async {
    final prefixes = <String>{};
    final own = <String>{};
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in i.addresses) {
          final p = a.address.split('.');
          if (p.length == 4) {
            prefixes.add('${p[0]}.${p[1]}.${p[2]}');
            own.add(a.address);
          }
        }
      }
    } catch (_) {}

    final ips = <String>[];
    for (final pre in prefixes) {
      for (int n = 1; n <= 254; n++) {
        final ip = '$pre.$n';
        if (!own.contains(ip)) ips.add(ip);
      }
    }
    final found = <TvDevice>[];
    int done = 0;
    for (int i = 0; i < ips.length; i += 64) {
      final batch = ips.sublist(i, min(i + 64, ips.length));
      final results = await Future.wait(batch.map((ip) => ping(ip, timeout: const Duration(milliseconds: 700))));
      for (final r in results) {
        if (r != null) found.add(r);
      }
      done += batch.length;
      onProgress?.call(done, ips.length);
    }
    return found;
  }

  /// Cast: ask the TV to play [items] from [index]. Returns null on success.
  static Future<String?> cast(String ip, String pin, List<YtItem> items, int index) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.parse('http://$ip:$kTvPort/play'));
      req.headers.set('x-pin', pin);
      req.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode({
        'index': index,
        'items': [for (final i in items) {'kind': i.kind, 'id': i.id, 'title': i.title}],
      }));
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain();
      if (res.statusCode == 200) return null;
      if (res.statusCode == 403) return 'Wrong PIN. Set up the TV again in TV Sync.';
      return 'TV answered ${res.statusCode}';
    } on TimeoutException {
      return 'The TV did not answer in time';
    } catch (e) {
      return 'Cannot reach the TV';
    } finally {
      client.close(force: true);
    }
  }

  /// Returns null on success, otherwise a readable error.
  static Future<String?> upload(String ip, String pin, String fileName, String content) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('http://$ip:$kTvPort/upload?name=${Uri.encodeQueryComponent(fileName)}');
      final req = await client.postUrl(uri);
      req.headers.set('x-pin', pin);
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      final bytes = utf8.encode(content);
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) return null;
      if (res.statusCode == 403) return 'Wrong PIN';
      try {
        return (jsonDecode(body)['error'] as String?) ?? 'TV answered ${res.statusCode}';
      } catch (_) {
        return 'TV answered ${res.statusCode}';
      }
    } on TimeoutException {
      return 'The TV did not answer in time';
    } catch (e) {
      return 'Cannot reach the TV ($e)';
    } finally {
      client.close(force: true);
    }
  }
}

/// Saved TV (phone side).
class SavedTv {
  final String ip;
  final String pin;
  final String name;
  SavedTv(this.ip, this.pin, this.name);

  static Future<SavedTv?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('tv_ip');
    if (ip == null || ip.isEmpty) return null;
    return SavedTv(ip, prefs.getString('tv_pin') ?? '', prefs.getString('tv_name') ?? ip);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tv_ip', ip);
    await prefs.setString('tv_pin', pin);
    await prefs.setString('tv_name', name);
  }

  static Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('tv_ip');
    await prefs.remove('tv_pin');
    await prefs.remove('tv_name');
  }
}

/// One-tap "send this file to my TV" used from the M3U Files screen.
/// Returns a short message; [ok] tells whether it worked, [needSetup] that no
/// TV is saved yet.
Future<({bool ok, bool needSetup, String message})> quickSendToTv(String filePath, String fileName) async {
  final tv = await SavedTv.load();
  if (tv == null || tv.pin.isEmpty) {
    return (ok: false, needSetup: true, message: 'Set up your TV first (TV Sync tab).');
  }
  try {
    final content = await File(filePath).readAsString();
    final err = await TvClient.upload(tv.ip, tv.pin, fileName, content);
    if (err == null) return (ok: true, needSetup: false, message: 'Sent "$fileName.m3u" to ${tv.name}');
    return (ok: false, needSetup: false, message: err);
  } catch (e) {
    return (ok: false, needSetup: false, message: 'Could not send: $e');
  }
}

// ============================================================================
// SCREEN
// ============================================================================
class TvSyncScreen extends StatefulWidget {
  final String basePath;
  final VoidCallback onChangeFolder;
  const TvSyncScreen({Key? key, required this.basePath, required this.onChangeFolder}) : super(key: key);

  @override
  _TvSyncScreenState createState() => _TvSyncScreenState();
}

class _TvSyncScreenState extends State<TvSyncScreen> {
  late final YtStore _store;
  bool _sendMode = true;

  // send side
  SavedTv? _tv;
  bool? _tvOnline;
  bool _scanning = false;
  String _scanText = '';
  List<TvDevice> _found = [];
  List<M3uFile> _files = [];
  final Map<String, int> _counts = {};
  final Set<String> _picked = {};
  bool _sending = false;
  final Map<String, String> _results = {}; // file path -> 'ok' or error

  @override
  void initState() {
    super.initState();
    _store = YtStore(widget.basePath);
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _sendMode = !(prefs.getBool('tv_receive') ?? false);
    _tv = await SavedTv.load();
    await TvReceiver.instance.loadPin();
    await _loadFiles();
    if (!mounted) return;
    setState(() {});
    _checkTv();
  }

  Future<void> _loadFiles() async {
    final files = await _store.listFiles();
    for (final f in files) {
      try {
        _counts[f.path] = (await _store.load(f)).length;
      } catch (_) {
        _counts[f.path] = 0;
      }
    }
    _files = files;
    if (_picked.isEmpty && files.isNotEmpty) {
      // sensible default: everything
      _picked.addAll(files.map((f) => f.path));
    }
  }

  Future<void> _checkTv() async {
    final tv = _tv;
    if (tv == null) return;
    setState(() => _tvOnline = null);
    final d = await TvClient.ping(tv.ip, timeout: const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _tvOnline = d != null);
  }

  void _snack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.green : Colors.redAccent,
    ));
  }

  // ------------------------------------------------------------- send side
  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = [];
      _scanText = 'Looking for your TV on the Wi-Fi…';
    });
    final found = await TvClient.scan(onProgress: (d, t) {
      if (mounted) setState(() => _scanText = 'Looking for your TV on the Wi-Fi… ${(d * 100 ~/ t)}%');
    });
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _found = found;
    });
    if (found.isEmpty) {
      _snack('No TV found. On the TV open TubeBox → TV Sync → Receive, and make sure both are on the same Wi-Fi. You can also type the IP shown on the TV.');
    }
  }

  Future<String?> _askText(String title, {String initial = '', String hint = '', TextInputType? type}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, keyboardType: type, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _selectDevice(TvDevice d) async {
    final pin = await _askText('PIN shown on ${d.name}', hint: '4-digit PIN', type: TextInputType.number);
    if (pin == null || pin.isEmpty) return;
    final tv = SavedTv(d.ip, pin, d.name);
    await tv.save();
    setState(() {
      _tv = tv;
      _found = [];
    });
    _checkTv();
  }

  Future<void> _manualTv() async {
    final ip = await _askText('TV address', initial: _tv?.ip ?? '', hint: 'e.g. 192.168.1.20', type: TextInputType.number);
    if (ip == null || ip.isEmpty) return;
    final pin = await _askText('PIN shown on the TV', initial: _tv?.pin ?? '', hint: '4-digit PIN', type: TextInputType.number);
    if (pin == null || pin.isEmpty) return;
    final dev = await TvClient.ping(ip, timeout: const Duration(seconds: 2));
    final tv = SavedTv(ip, pin, dev?.name ?? ip);
    await tv.save();
    setState(() => _tv = tv);
    _checkTv();
    if (dev == null) _snack('Saved, but the TV did not answer yet. Is Receive turned on?');
  }

  Future<void> _send() async {
    final tv = _tv;
    if (tv == null) return;
    final chosen = _files.where((f) => _picked.contains(f.path)).toList();
    if (chosen.isEmpty) return;
    setState(() {
      _sending = true;
      _results.clear();
    });
    int ok = 0;
    for (final f in chosen) {
      try {
        final content = await File(f.path).readAsString();
        final err = await TvClient.upload(tv.ip, tv.pin, f.name, content);
        _results[f.path] = err ?? 'ok';
        if (err == null) ok++;
        if (err == 'Wrong PIN') break;
      } catch (e) {
        _results[f.path] = '$e';
      }
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _tvOnline = _results.values.any((v) => v == 'ok') ? true : _tvOnline;
    });
    _snack(
      ok == chosen.length ? 'Sent $ok file(s) to ${tv.name}. The TV now has the latest version.' : '$ok of ${chosen.length} sent. See the list for details.',
      success: ok == chosen.length,
    );
  }

  // ---------------------------------------------------------- receive side
  Future<void> _toggleReceive(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tv_receive', on);
    if (on) {
      final err = await TvReceiver.instance.start(widget.basePath);
      if (err != null) _snack(err);
    } else {
      await TvReceiver.instance.stop();
    }
    if (mounted) setState(() {});
  }

  Widget _card({required String title, required IconData icon, required Widget child}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: const Color(0xFF1B1633),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: 0.3)),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildSend() {
    final primary = Theme.of(context).colorScheme.primary;
    final tv = _tv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          title: 'YOUR TV',
          icon: Icons.tv,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (tv == null)
                const Text('No TV saved yet. Open TubeBox on the TV → TV Sync → Receive, then tap "Find my TV".',
                    style: TextStyle(color: Colors.grey))
              else
                Row(children: [
                  const Icon(Icons.tv, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tv.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('${tv.ip}  •  PIN ${'•' * tv.pin.length}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ]),
                  ),
                  Chip(
                    label: Text(_tvOnline == null ? 'Checking…' : (_tvOnline! ? 'Online' : 'Offline')),
                    backgroundColor: _tvOnline == true ? Colors.green.withOpacity(0.25) : Colors.orange.withOpacity(0.25),
                  ),
                  IconButton(tooltip: 'Check again', onPressed: _checkTv, icon: const Icon(Icons.refresh)),
                ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: const Icon(Icons.wifi_find),
                  label: Text(tv == null ? 'Find my TV' : 'Find again'),
                ),
                OutlinedButton.icon(onPressed: _manualTv, icon: const Icon(Icons.edit), label: const Text('Enter IP & PIN')),
                if (tv != null)
                  TextButton(
                    onPressed: () async {
                      await SavedTv.forget();
                      setState(() {
                        _tv = null;
                        _tvOnline = null;
                      });
                    },
                    child: const Text('Forget TV', style: TextStyle(color: Colors.redAccent)),
                  ),
              ]),
              if (_scanning)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_scanText, style: const TextStyle(fontSize: 12.5, color: Colors.grey))),
                  ]),
                ),
              ..._found.map((d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.tv, color: primary),
                    title: Text(d.name),
                    subtitle: Text(d.ip),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _selectDevice(d),
                  )),
            ],
          ),
        ),
        _card(
          title: 'FILES TO SEND  (replaces the same file on the TV)',
          icon: Icons.folder_copy_outlined,
          child: _files.isEmpty
              ? const Text('No .m3u files yet.', style: TextStyle(color: Colors.grey))
              : Column(
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Select all'),
                      value: _picked.length == _files.length,
                      onChanged: (v) => setState(() {
                        _picked.clear();
                        if (v == true) _picked.addAll(_files.map((f) => f.path));
                      }),
                    ),
                    ..._files.map((f) {
                      final r = _results[f.path];
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('${f.name}.m3u'),
                        subtitle: Text(
                          r == null ? '${_counts[f.path] ?? 0} items' : (r == 'ok' ? '✔ Sent' : '✖ $r'),
                          style: TextStyle(color: r == null ? Colors.grey : (r == 'ok' ? Colors.greenAccent : Colors.redAccent), fontSize: 12),
                        ),
                        value: _picked.contains(f.path),
                        onChanged: (v) => setState(() => v == true ? _picked.add(f.path) : _picked.remove(f.path)),
                      );
                    }),
                  ],
                ),
        ),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: (_sending || tv == null || _picked.isEmpty) ? null : _send,
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.send_to_mobile),
            label: Text(_sending ? 'Sending…' : 'Send ${_picked.length} file(s) to TV', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'The TV keeps the previous version of a replaced file as "name.m3u.bak".',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _buildReceive() {
    final rx = TvReceiver.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: rx.running,
      builder: (context, running, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _card(
              title: 'RECEIVE ON THIS DEVICE',
              icon: Icons.download_for_offline_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(running ? 'Ready to receive' : 'Receiver is off'),
                    subtitle: const Text('Keep TubeBox open on the TV while sending.'),
                    value: running,
                    onChanged: _toggleReceive,
                  ),
                  if (running) ...[
                    const Divider(),
                    const Text('On your phone: TV Sync → Send → "Find my TV"', style: TextStyle(color: Colors.grey, fontSize: 12.5)),
                    const SizedBox(height: 12),
                    const Text('PIN', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    Text(rx.pin, style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, letterSpacing: 8)),
                    const SizedBox(height: 8),
                    const Text('TV address (if the phone cannot find it)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ValueListenableBuilder<List<String>>(
                      valueListenable: rx.addresses,
                      builder: (context, addrs, _) => Text(
                        addrs.isEmpty ? 'No Wi-Fi / network detected' : addrs.map((a) => '$a:$kTvPort').join('\n'),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        await rx.regeneratePin();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.autorenew, size: 18),
                      label: const Text('New PIN'),
                    ),
                  ],
                ],
              ),
            ),
            _card(
              title: 'SAVED INTO THIS FOLDER',
              icon: Icons.folder_open,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.basePath, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  const Text('Point Kodi (or your TV player) at this folder to play the received .m3u files.',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(onPressed: widget.onChangeFolder, icon: const Icon(Icons.folder), label: const Text('Change folder')),
                ],
              ),
            ),
            _card(
              title: 'RECEIVED',
              icon: Icons.history,
              child: ValueListenableBuilder<List<String>>(
                valueListenable: rx.log,
                builder: (context, lines, _) => lines.isEmpty
                    ? const Text('Nothing received yet.', style: TextStyle(color: Colors.grey))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: lines.map((l) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('✔ $l'))).toList(),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TV Sync')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.smartphone), label: Text('Send to TV')),
              ButtonSegment(value: false, icon: Icon(Icons.tv), label: Text('Receive on TV')),
            ],
            selected: {_sendMode},
            onSelectionChanged: (s) {
              setState(() => _sendMode = s.first);
              if (_sendMode) {
                _loadFiles().then((_) {
                  if (mounted) setState(() {});
                });
              }
            },
          ),
          const SizedBox(height: 16),
          _sendMode ? _buildSend() : _buildReceive(),
        ],
      ),
    );
  }
}
