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

  /// Text of the original #EXTINF line up to (and including) the comma before
  /// the title. Kept so files such as Master_Playlist.m3u keep their
  /// group-title / play-status attributes when this app rewrites them.
  String? infoPrefix;

  YtItem({required this.kind, required this.id, required this.title, this.infoPrefix});

  bool get isPlaylist => kind == 'playlist';
  bool get isVideo => kind == 'video';
  bool get isOther => kind == 'other';

  String get key => '$kind:$id';

  String get webUrl => isPlaylist
      ? 'https://www.youtube.com/playlist?list=$id'
      : (isOther ? id : 'https://www.youtube.com/watch?v=$id');

  String get kodiUrl => isPlaylist
      ? 'plugin://plugin.video.youtube/play/?playlist_id=$id&order=default&play=1'
      : (isOther ? id : 'plugin://plugin.video.youtube/play/?video_id=$id');

  String get thumbUrl => 'https://img.youtube.com/vi/$id/mqdefault.jpg';
  String get thumbUrlHq => 'https://img.youtube.com/vi/$id/hqdefault.jpg';

  // Placeholder titles start with "YouTube " (e.g. "YouTube video").
  bool get hasRealTitle => title.isNotEmpty && !title.startsWith('YouTube ');
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

Future<String?> fetchYtTitle(YtItem item) async {
  if (item.isOther) return null;
  final body = await _httpGet('https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(item.webUrl)}');
  if (body == null) return null;
  try {
    final title = (jsonDecode(body)['title'] as String?)?.trim();
    return (title == null || title.isEmpty) ? null : title;
  } catch (_) {
    return null;
  }
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
