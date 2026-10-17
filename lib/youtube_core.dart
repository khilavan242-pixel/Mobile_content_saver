import 'dart:convert';
import 'dart:io';

// ============================================================================
// YOUTUBE CORE: link parsing, title lookup and playlist expansion.
// Shared by the Kodi TV Manager screen and the M3U Files screen.
// ============================================================================

class YtItem {
  /// 'video', 'playlist', or 'other' (any non-YouTube entry kept untouched)
  final String kind;
  final String id; // video id, playlist id, or the raw url for 'other'
  String title;

  /// All #EXTINF attributes (group-title, play-status, tvg-logo, ...), kept so
  /// files such as Master_Playlist.m3u round-trip without losing information.
  final Map<String, String> attrs;
  String duration;

  YtItem({
    required this.kind,
    required this.id,
    required this.title,
    Map<String, String>? attrs,
    this.duration = '-1',
  }) : attrs = attrs ?? <String, String>{};

  bool get isPlaylist => kind == 'playlist';
  bool get isVideo => kind == 'video';
  bool get isOther => kind == 'other';

  String get key => '$kind:$id';

  /// Kodi group (category), e.g. "Lakshya - Maths".
  String get group => attrs['group-title'] ?? '';
  set group(String v) {
    if (v.isEmpty) {
      attrs.remove('group-title');
    } else {
      attrs['group-title'] = v;
    }
  }

  /// 'working' | 'unavailable' | 'kodi_error'
  String get status => attrs['play-status'] ?? 'working';
  set status(String v) => attrs['play-status'] = v;

  int? get chapter {
    final m = RegExp(r'^CH(\d+):\s*').firstMatch(title);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  String get plainTitle => title.replaceFirst(RegExp(r'^CH\d+:\s*'), '').trim();

  void setChapter(int? n) {
    title = n == null ? plainTitle : 'CH$n: $plainTitle';
  }

  String get webUrl => isPlaylist
      ? 'https://www.youtube.com/playlist?list=$id'
      : (isOther ? id : 'https://youtu.be/$id');

  String get kodiUrl => isPlaylist
      ? 'plugin://plugin.video.youtube/play/?playlist_id=$id&order=default&play=1'
      : (isOther ? id : 'plugin://plugin.video.youtube/play/?video_id=$id');

  String get thumbUrl => 'https://img.youtube.com/vi/$id/mqdefault.jpg';
  String get thumbUrlHq => 'https://img.youtube.com/vi/$id/hqdefault.jpg';

  // Placeholder titles start with "YouTube " (e.g. "YouTube video").
  bool get hasRealTitle => title.isNotEmpty && !title.startsWith('YouTube ');
}

// ----------------------------------------------------------------------------
// M3U text <-> items
// ----------------------------------------------------------------------------
({String duration, Map<String, String> attrs, String title}) parseExtinf(String line) {
  final colon = line.indexOf(':');
  final s = colon < 0 ? '' : line.substring(colon + 1);
  bool inQuote = false;
  int comma = -1;
  for (int k = 0; k < s.length; k++) {
    final c = s[k];
    if (c == '"') {
      inQuote = !inQuote;
    } else if (c == ',' && !inQuote) {
      comma = k;
      break;
    }
  }
  final header = comma < 0 ? s : s.substring(0, comma);
  final title = comma < 0 ? '' : s.substring(comma + 1).trim();
  final duration = RegExp(r'^\s*(-?\d+(?:\.\d+)?)').firstMatch(header)?.group(1) ?? '-1';
  final attrs = <String, String>{};
  for (final m in RegExp(r'([A-Za-z0-9_-]+)="([^"]*)"').allMatches(header)) {
    attrs[m.group(1)!] = m.group(2)!;
  }
  return (duration: duration, attrs: attrs, title: title);
}

/// Turns the lines of an .m3u file (or pasted M3U text) into items.
List<YtItem> parseM3uLines(List<String> lines) {
  final items = <YtItem>[];
  for (int i = 0; i < lines.length; i++) {
    if (!lines[i].trim().startsWith('#EXTINF')) continue;
    final info = parseExtinf(lines[i].trim());

    String url = '';
    for (int j = i + 1; j < lines.length && j <= i + 3; j++) {
      final t = lines[j].trim();
      if (t.isNotEmpty && !t.startsWith('#')) {
        url = t.replaceAll('*', '_');
        break;
      }
    }
    if (url.isEmpty) continue;

    // Markdown-style logos pasted from chat apps: tvg-logo="[x](y)" -> x
    final logo = info.attrs['tvg-logo'];
    if (logo != null) {
      final md = RegExp(r'^\[(.*?)\]\(.*?\)$').firstMatch(logo);
      if (md != null) info.attrs['tvg-logo'] = md.group(1)!;
    }

    final p = RegExp(r'playlist_id=([A-Za-z0-9_-]+)').firstMatch(url);
    final v = RegExp(r'video_id=([A-Za-z0-9_-]{11})').firstMatch(url);
    YtItem item;
    if (p != null) {
      item = YtItem(kind: 'playlist', id: p.group(1)!, title: info.title);
    } else if (v != null) {
      item = YtItem(kind: 'video', id: v.group(1)!, title: info.title);
    } else {
      final yt = parseYtText(url);
      if (yt.isNotEmpty) {
        item = yt.first;
        item.title = info.title;
      } else {
        item = YtItem(kind: 'other', id: url, title: info.title);
      }
    }
    item.attrs.addAll(info.attrs);
    item.duration = info.duration;
    items.add(item);
  }
  return items;
}

String buildExtinf(YtItem it, {String fallbackGroup = ''}) {
  final a = Map<String, String>.from(it.attrs);
  if ((a['group-title'] ?? '').isEmpty && fallbackGroup.isNotEmpty) a['group-title'] = fallbackGroup;
  a['play-status'] = it.status;
  a['tvg-logo'] = a['tvg-logo'] ?? (it.isVideo ? it.thumbUrlHq : '');

  final ordered = <String>['group-title', 'play-status', 'tvg-logo'];
  final sb = StringBuffer('#EXTINF:${it.duration}');
  for (final k in ordered) {
    if (a.containsKey(k) && !(k == 'group-title' && a[k]!.isEmpty)) {
      sb.write(' $k="${a[k]!.replaceAll('"', "'")}"');
    }
  }
  for (final e in a.entries) {
    if (ordered.contains(e.key)) continue;
    sb.write(' ${e.key}="${e.value.replaceAll('"', "'")}"');
  }
  final title = it.title.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  sb.write(', $title');
  return sb.toString();
}

String buildM3uText(List<YtItem> items, {String fallbackGroup = ''}) {
  final sb = StringBuffer('#EXTM3U\n');
  for (final it in items) {
    sb.write('\n${buildExtinf(it, fallbackGroup: fallbackGroup)}\n${it.kodiUrl}\n');
  }
  return sb.toString();
}

final RegExp _videoIdRe = RegExp(r'(?:[?&]v=|youtu\.be/|/shorts/|/embed/|/live/|/vi/|video_id=)([A-Za-z0-9_-]{11})');
final RegExp _playlistIdRe = RegExp(r'(?:[?&]list=|playlist_id=)([A-Za-z0-9_-]{10,})');

/// Finds every YouTube video / playlist link inside any pasted text.
/// A link that points at a video wins over a playlist id in the same link
/// (e.g. watch?v=...&list=... is treated as that one video).
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
    if (item != null && seen.add(item.key)) found.add(item);
  }
  return found;
}

const String _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

Future<String?> _httpGet(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _desktopUa);
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set(HttpHeaders.cookieHeader, 'SOCS=CAI; CONSENT=YES+1'); // skip EU consent wall
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) return null;
    return await res.transform(utf8.decoder).join().timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

Future<String?> _httpPostJson(String url, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _desktopUa);
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set(HttpHeaders.cookieHeader, 'SOCS=CAI; CONSENT=YES+1');
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) return null;
    return await res.transform(utf8.decoder).join().timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

Future<({int status, String body})?> _request(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _desktopUa);
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set(HttpHeaders.cookieHeader, 'SOCS=CAI; CONSENT=YES+1');
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join().timeout(timeout);
    return (status: res.statusCode, body: body);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

class YtInfo {
  final int? code; // HTTP status of the oEmbed call (null = no network)
  final String? title;
  YtInfo(this.code, this.title);
  bool get notFound => code == 404 || code == 400;
}

/// Cheap lookup of a title (and a hint whether the id exists at all).
Future<YtInfo> fetchYtInfo(YtItem item) async {
  if (item.isOther) return YtInfo(null, null);
  final r = await _request('https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(item.webUrl)}');
  if (r == null) return YtInfo(null, null);
  String? title;
  if (r.status == 200) {
    try {
      final t = (jsonDecode(r.body)['title'] as String?)?.trim();
      if (t != null && t.isNotEmpty) title = t;
    } catch (_) {}
  }
  return YtInfo(r.status, title);
}

Future<String?> fetchYtTitle(YtItem item) async => (await fetchYtInfo(item)).title;

/// Accurate "will this video play?" check using the watch page's playability
/// status. true = plays, false = deleted / private / invalid id / blocked,
/// null = could not tell (no network, bot check, age gate...).
Future<bool?> checkVideoPlayable(String videoId) async {
  final r = await _request('https://www.youtube.com/watch?v=$videoId&hl=en');
  if (r == null || r.status != 200) return r?.status == 404 ? false : null;
  final m = RegExp(r'"playabilityStatus":\{"status":"([A-Z_]+)"').firstMatch(r.body);
  if (m == null) return null;
  final status = m.group(1)!;
  if (status == 'OK' || status == 'LIVE_STREAM_OFFLINE') return true;
  if (status == 'ERROR' || status == 'UNPLAYABLE') return false;
  if (status == 'LOGIN_REQUIRED') {
    final end = m.start + 900 > r.body.length ? r.body.length : m.start + 900;
    final tail = r.body.substring(m.start, end);
    final reason = RegExp(r'"reason":"([^"]*)"').firstMatch(tail)?.group(1) ?? '';
    if (RegExp(r'private|unavailable|removed|deleted', caseSensitive: false).hasMatch(reason)) return false;
  }
  return null;
}

// ============================================================================
// PLAYLIST EXPANSION
// ============================================================================
class PlaylistResult {
  final String? title;
  final List<YtItem> videos;
  final bool partial; // true when only part of the playlist could be read
  final String? error;
  PlaylistResult({this.title, required this.videos, this.partial = false, this.error});
}

String? _textOf(dynamic n) {
  if (n is Map) {
    if (n['simpleText'] is String) return n['simpleText'] as String;
    if (n['content'] is String) return n['content'] as String;
    final runs = n['runs'];
    if (runs is List && runs.isNotEmpty) {
      return runs.map((r) => r is Map ? (r['text'] ?? '') : '').join();
    }
  }
  return null;
}

class _Scan {
  final List<YtItem> videos = [];
  final Set<String> seen = {};
  String? continuation;
  String? playlistTitle;
}

void _scan(dynamic n, _Scan out) {
  if (n is List) {
    for (final e in n) {
      _scan(e, out);
    }
    return;
  }
  if (n is! Map) return;

  final pv = n['playlistVideoRenderer'];
  if (pv is Map) {
    final id = pv['videoId'];
    final title = _textOf(pv['title']) ?? '';
    if (id is String && id.length == 11 && title != '[Private video]' && title != '[Deleted video]') {
      if (out.seen.add(id)) out.videos.add(YtItem(kind: 'video', id: id, title: title.isEmpty ? 'YouTube video' : title));
    }
    return;
  }

  final lv = n['lockupViewModel'];
  if (lv is Map && lv['contentType'] == 'LOCKUP_CONTENT_TYPE_VIDEO' && lv['contentId'] is String) {
    final id = lv['contentId'] as String;
    final meta = lv['metadata'];
    String? title;
    if (meta is Map && meta['lockupMetadataViewModel'] is Map) {
      title = _textOf(meta['lockupMetadataViewModel']['title']);
    }
    if (id.length == 11 && out.seen.add(id)) {
      out.videos.add(YtItem(kind: 'video', id: id, title: (title == null || title.isEmpty) ? 'YouTube video' : title));
    }
    return;
  }

  final cir = n['continuationItemRenderer'];
  if (cir is Map) {
    final token = cir['continuationEndpoint']?['continuationCommand']?['token'];
    if (token is String) out.continuation = token;
  }

  final pm = n['playlistMetadataRenderer'];
  if (pm is Map && out.playlistTitle == null) {
    out.playlistTitle = pm['title'] is String ? pm['title'] as String : _textOf(pm['title']);
  }

  for (final v in n.values) {
    if (v is Map || v is List) _scan(v, out);
  }
}

String _unxml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");

/// Reads every video of a public / unlisted YouTube playlist, no API key needed.
/// 1) the playlist web page (first ~100 videos) + "continuation" pages for the rest
/// 2) fallback: the playlist RSS feed (latest 15 videos)
Future<PlaylistResult> fetchPlaylist(String playlistId, {void Function(int found)? onProgress}) async {
  final scan = _Scan();
  String apiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  String clientVersion = '2.20250101.00.00';

  final html = await _httpGet('https://www.youtube.com/playlist?list=$playlistId&hl=en');
  if (html != null) {
    final k = RegExp(r'"INNERTUBE_API_KEY":"([^"]+)"').firstMatch(html);
    if (k != null) apiKey = k.group(1)!;
    final cv = RegExp(r'"INNERTUBE_CONTEXT_CLIENT_VERSION":"([^"]+)"').firstMatch(html);
    if (cv != null) clientVersion = cv.group(1)!;

    final m = RegExp(r'ytInitialData\s*=\s*(\{.*?\});\s*</script>', dotAll: true).firstMatch(html);
    if (m != null) {
      try {
        _scan(jsonDecode(m.group(1)!), scan);
      } catch (_) {}
    }
    onProgress?.call(scan.videos.length);

    // Playlists longer than ~100 videos continue on further pages.
    int guard = 0;
    while (scan.continuation != null && guard < 60) {
      guard++;
      final token = scan.continuation!;
      scan.continuation = null;
      final before = scan.videos.length;
      final resp = await _httpPostJson(
        'https://www.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false',
        {
          'context': {
            'client': {'clientName': 'WEB', 'clientVersion': clientVersion, 'hl': 'en', 'gl': 'US'}
          },
          'continuation': token,
        },
      );
      if (resp == null) break;
      try {
        _scan(jsonDecode(resp), scan);
      } catch (_) {
        break;
      }
      onProgress?.call(scan.videos.length);
      if (scan.videos.length == before) break;
    }

    if (scan.videos.isNotEmpty) {
      return PlaylistResult(
        title: scan.playlistTitle,
        videos: scan.videos,
        partial: scan.continuation != null,
      );
    }
  }

  // Fallback: RSS feed (only the newest 15 videos, but works without scripts).
  final feed = await _httpGet('https://www.youtube.com/feeds/videos.xml?playlist_id=$playlistId');
  if (feed != null) {
    final videos = <YtItem>[];
    final seen = <String>{};
    for (final m in RegExp(r'<entry>(.*?)</entry>', dotAll: true).allMatches(feed)) {
      final e = m.group(1)!;
      final id = RegExp(r'<yt:videoId>([^<]+)</yt:videoId>').firstMatch(e)?.group(1);
      final title = RegExp(r'<title>([^<]*)</title>').firstMatch(e)?.group(1);
      if (id != null && seen.add(id)) {
        videos.add(YtItem(kind: 'video', id: id, title: _unxml(title ?? 'YouTube video')));
      }
    }
    if (videos.isNotEmpty) {
      return PlaylistResult(videos: videos, partial: true, error: 'Only the latest ${videos.length} videos could be read.');
    }
  }

  return PlaylistResult(
    videos: [],
    error: html == null
        ? 'Could not reach YouTube. Check the internet connection.'
        : 'This playlist is private, empty or deleted, so its videos cannot be read.',
  );
}


final Map<String, bool> _shortCache = {};

/// True when [id] is a YouTube Short. youtube.com/shorts/ID answers 200 for a
/// Short and redirects for a normal video (checked without following it).
Future<bool> isShortVideo(String id) async {
  final cached = _shortCache[id];
  if (cached != null) return cached;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(Uri.parse('https://www.youtube.com/shorts/$id'));
    req.followRedirects = false;
    req.headers.set(HttpHeaders.userAgentHeader, _desktopUa);
    req.headers.set(HttpHeaders.cookieHeader, 'SOCS=CAI; CONSENT=YES+1');
    final res = await req.close().timeout(const Duration(seconds: 8));
    await res.drain<void>();
    final r = res.statusCode == 200;
    _shortCache[id] = r;
    return r;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}
