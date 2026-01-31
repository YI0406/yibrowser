import 'dart:async';
import 'dart:io';
import 'dart:ui'
    show Offset, Rect; // for mini player free-positioning & PiP sync
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:dio/dio.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/session_state.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image/image.dart' as img;
import 'package:local_auth/local_auth.dart';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_localizations.dart';
import 'dart:math' as math;
import 'package:dio/io.dart';
import 'package:crypto/crypto.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_hls_parser/flutter_hls_parser.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'notification_service.dart';
import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'live_activity_service.dart';
import 'package:xml/xml.dart' as xml;
import 'ads.dart';
// NOTE: The `download` package targets Flutter Web (browser-triggered save). It is not
// applicable to iOS/Android file-system saving. Kept here for web builds if needed.
import 'package:download/download.dart' as web_download; // unused on mobile
import 'yt.dart';

final ValueNotifier<String?> uaNotifier = ValueNotifier<String?>(null);

/// A utility class providing functions to initialize WebView debugging and
/// supply JavaScript hooks for sniffing media resources in WebView.
class Sniffer {
  /// Enables debugging for web contents in WebView, helpful for development.
  static Future<void> initWebViewDebug() async {
    try {
      // Only Android implements this API; on iOS/macOS it throws UnimplementedError.
      if (Platform.isAndroid) {
        await InAppWebViewController.setWebContentsDebuggingEnabled(true);
      }
    } catch (_) {
      // Not critical if it fails; ignore.
    }
  }

  /// Returns a small JS snippet to turn the sniffer on/off inside the page.
  /// This now controls both the network sniffing hooks and the in-page media
  /// element observer used for automatic playback detection.
  static String jsSetEnabled(bool on) =>
      jsSetModes(networkOn: on, autoDetectOn: on);

  /// Returns JS to independently control the network sniffing hooks and the
  /// DOM media element observer. `networkOn` controls whether fetch/XHR
  /// interception is active, while `autoDetectOn` controls whether `<video>`
  /// or `<audio>` element events are forwarded for auto detection.
  static String jsSetModes({
    required bool networkOn,
    required bool autoDetectOn,
  }) =>
      "window._SNF_ON = " +
      (networkOn ? "true" : "false") +
      ";window._SNF_AUTO_ON = " +
      (autoDetectOn ? "true" : "false") +
      ";";

  /// JavaScript code injected into webpages to intercept media/image requests.
  /// It hooks into fetch, XMLHttpRequest, and media tags (video/audio/img) to
  /// capture URLs of resources, reporting them back to Flutter via the
  /// 'sniffer' handler. It also grabs duration from <video>/<audio> when ready
  /// and filters OUT everything that is not image/video/audio.
  static const jsHook = r"""
  (function(){
      // On/off toggle flags (Flutter can update them later)
    if (typeof window._SNF_ON === 'undefined') window._SNF_ON = true;
    if (typeof window._SNF_AUTO_ON === 'undefined') window._SNF_AUTO_ON = false;

    const send = (p) => {
      if (!p) return;
      let origin = 'network';
      try { origin = (p.origin || 'network') + ''; } catch (_) {}
      origin = origin.toLowerCase();
      const isElement = origin.startsWith('element');
      if (isElement) {
        if (!window._SNF_AUTO_ON && !window._SNF_ON) return;
      } else if (!window._SNF_ON) {
        return;
      }
      try { window.flutter_inappwebview.callHandler('sniffer', p); } catch(_) {}
    };

    const extType = (u) => {
      try { u = (u||'')+''; } catch(_) { u=''; }
      const l = u.toLowerCase().split('?')[0];
      if (/\.(m3u8|mp4|mov|m4v|webm)$/i.test(l)) return 'video';
      if (/\.(mpd)$/i.test(l)) return 'video'; // DASH
      if (/\.(mp3|m4a|aac|ogg|wav|flac)$/i.test(l)) return 'audio';
      if (/\.(png|jpg|jpeg|gif|webp|bmp|svg)$/i.test(l)) return 'image';
      if (/\.(ts)$/i.test(l)) return 'hls-seg';
      if (/\.(key)$/i.test(l)) return 'hls-key';
      return '';
    };

    const sniffable = (u, ct='') => {
      u = (u||'')+''; ct = (ct||'')+'';
      if (/^data:/i.test(u)) return false; // ignore data URLs
      // Allow blob: only for media elements (handled in tag hooks). Network hooks skip blob: to reduce noise.
      if (/^blob:/i.test(u)) return false;
      if (/^image\//i.test(ct) || /^video\//i.test(ct) || /^audio\//i.test(ct)) return true;
      return extType(u) !== '';
    };

    const kindFrom = (u, ct='') => {
      ct = (ct||'')+'';
      if (/^video\//i.test(ct)) return 'video';
      if (/^audio\//i.test(ct)) return 'audio';
      if (/^image\//i.test(ct)) return 'image';
      const k = extType(u);
      return k || 'video';
    };

    // --- FETCH HOOK (captures Request inputs and content-type) ---
    const wrapFetch = () => {
      if (window._origFetch) return;
      window._origFetch = window.fetch;
      window.fetch = async function(input, init){
        const inUrl = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
        const res = await window._origFetch(input, init);
        try {
          const url = (res && res.url) ? res.url : inUrl || '';
          const ct = (res && res.headers && res.headers.get) ? (res.headers.get('content-type') || '') : (init && init.headers && (init.headers['Content-Type']||init.headers['content-type']||'')) || '';
          if (sniffable(url, ct)) {
            const type = kindFrom(url, ct);
            send({url, type, contentType: ct, duration: null, poster: '', origin: 'network-fetch'});
          }
        } catch(e){}
        return res;
      };
    };

    // --- XHR HOOK ---
    const wrapXHR = () => {
      if (window._origXHR) return;
      window._origXHR = window.XMLHttpRequest;
      window.XMLHttpRequest = function(){
        const xhr = new window._origXHR();
        const origOpen = xhr.open;
        xhr.open = function(method, url){
          try { this._u = url; } catch(_) {}
          return origOpen.apply(this, arguments);
        };
        xhr.addEventListener('readystatechange', function(){
          if (this.readyState===2){
            try{
              const url = this._u || this.responseURL || '';
              const ct = this.getResponseHeader ? (this.getResponseHeader('Content-Type') || this.getResponseHeader('content-type') || '') : '';
              if (sniffable(url, ct)) {
                const type = kindFrom(url, ct);
                send({url, type, contentType: ct, duration: null, poster: '', origin: 'network-xhr'});
              }
            }catch(e){}
          }
        });
        return xhr;
      };
    };

    // --- MEDIA TAG HOOKS (capture blob: assignments and durations) ---
    const hookMediaTags = () => {
      const els = document.querySelectorAll('video, audio, img');
      els.forEach(el => {
        const go = () => {
          let u = (el.currentSrc || el.src || '')+'';
          // For blob: we still report (useful to show "playing via MSE"), but mark contentType empty.
          if (!/^blob:/i.test(u) && !sniffable(u, '')) return;
          let type = (el.tagName||'').toLowerCase();
          if (type === 'img') type = 'image';
          if (type !== 'video' && type !== 'audio' && type !== 'image') {
            type = kindFrom(u, '');
          }
          let d = null;
          if (type === 'video' || type === 'audio') {
            const dur = el.duration;
            if (typeof dur === 'number' && isFinite(dur) && dur > 0) d = dur;
          }
          send({url: u, type: type, contentType: '', duration: d, poster: (el.poster || ''), origin: 'element-media'});
        };
        // Listen to various events that are fired on HLS/DASH players as they attach mediasource/blob
        el.addEventListener('loadedmetadata', go, {once:true});
        el.addEventListener('durationchange', go);
        el.addEventListener('play', go);
        // capture explicit src changes
        const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'src');
        if (desc && desc.set && !el._snf_srcPatched) {
          const set = desc.set.bind(el);
          Object.defineProperty(el, 'src', {
            configurable: true,
            get: desc.get ? desc.get.bind(el) : function(){ return ''; },
            set: function(v){ try { set(v); } finally { go(); } }
          });
          el._snf_srcPatched = true;
        }
        if ((el.tagName||'').toLowerCase() === 'img') {
          if (el.complete) go(); else el.addEventListener('load', go, {once:true});
        }
        // Trigger once immediately so existing media gets reported even if
        // events have already fired before the hook was installed.
        try { go(); } catch (_) {}
      });
    };

    wrapFetch();
    wrapXHR();
    hookMediaTags();
    new MutationObserver(hookMediaTags).observe(document.documentElement,{subtree:true, childList:true});
  })();
  """;

  /// Returns a JS snippet that serializes active media (video/audio) elements with url/poster/duration.
  static const String jsQueryActiveMedia = r"""
(function(){
  try{
    var arr=[];
    var els = Array.prototype.slice.call(document.querySelectorAll('video,audio'));
    els.forEach(function(el){
      var u = '' + (el.currentSrc || el.src || '');
      var poster = '';
      try { poster = el.poster || ''; } catch(e){}
      var d = null;
      try {
        var dd = el.duration;
        if (typeof dd === 'number' && isFinite(dd) && dd > 0) d = dd;
      } catch(e){}
      var type = (el.tagName||'').toLowerCase()==='audio' ? 'audio' : 'video';
      arr.push({url:u, poster:poster, duration:d, type:type});
    });
    return JSON.stringify(arr);
  }catch(e){ return "[]"; }
})();
""";

  /// Utility to check whether a URL or content type looks like a media/image resource.
  static bool looksLikeMedia(String url, {String contentType = ''}) {
    final u = url.toLowerCase();
    // Avoid treating HLS TS segments as independent media. Skip .ts URLs and
    // MPEG-2 transport streams indicated by content type video/mp2t.
    if (u.endsWith('.ts') ||
        contentType.toLowerCase().startsWith('video/mp2t')) {
      return false;
    }
    final bool extMatch =
        u.contains('.m3u8') ||
        u.contains('.mp4') ||
        u.contains('.mov') ||
        u.contains('.m4v') ||
        u.contains('.webm') ||
        u.contains('.mp3') ||
        u.contains('.m4a') ||
        u.contains('.aac') ||
        u.contains('.ogg') ||
        u.contains('.wav') ||
        u.contains('.flac') ||
        u.contains('.png') ||
        u.contains('.jpg') ||
        u.contains('.jpeg') ||
        u.contains('.gif') ||
        u.contains('.webp') ||
        u.contains('.bmp') ||
        u.contains('.svg');
    final bool ctMatch =
        contentType.toLowerCase().startsWith('video/') ||
        contentType.toLowerCase().startsWith('audio/') ||
        contentType.toLowerCase().startsWith('image/');
    return extMatch || ctMatch;
  }
}

/// Represents a detected media resource from a webpage.
class MediaHit {
  final String url;
  final String type; // 'video' | 'audio' | 'image'
  final String contentType;
  final String poster; // optional poster URL for video
  final double? durationSeconds; // nullable
  const MediaHit({
    required this.url,
    required this.type,
    required this.contentType,
    this.poster = '',
    this.durationSeconds,
  });

  MediaHit copyWith({
    String? url,
    String? type,
    String? contentType,
    String? poster,
    double? durationSeconds,
  }) => MediaHit(
    url: url ?? this.url,
    type: type ?? this.type,
    contentType: contentType ?? this.contentType,
    poster: poster ?? this.poster,
    durationSeconds: durationSeconds ?? this.durationSeconds,
  );
}

/// Snapshot of a video that the user long-pressed while it was playing.
class PlayingVideoCandidate {
  final String id;
  final String url;
  final String pageUrl;
  final String title;
  final double? durationSeconds;
  final double? positionSeconds;
  final int? videoWidth;
  final int? videoHeight;
  final Uint8List? snapshot;
  final String? posterUrl;
  final DateTime detectedAt;

  const PlayingVideoCandidate({
    required this.id,
    required this.url,
    required this.pageUrl,
    required this.title,
    this.durationSeconds,
    this.positionSeconds,
    this.videoWidth,
    this.videoHeight,
    this.snapshot,
    this.posterUrl,
    required this.detectedAt,
  });

  PlayingVideoCandidate copyWith({
    String? id,
    String? url,
    String? pageUrl,
    String? title,
    double? durationSeconds,
    double? positionSeconds,
    int? videoWidth,
    int? videoHeight,
    Uint8List? snapshot,
    String? posterUrl,
    DateTime? detectedAt,
  }) {
    return PlayingVideoCandidate(
      id: id ?? this.id,
      url: url ?? this.url,
      pageUrl: pageUrl ?? this.pageUrl,
      title: title ?? this.title,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      snapshot: snapshot ?? this.snapshot,
      posterUrl: posterUrl ?? this.posterUrl,
      detectedAt: detectedAt ?? this.detectedAt,
    );
  }
}

/// Represents a browsing history entry. Each entry stores the URL visited,
/// the page title at the time of visit, and a timestamp. History entries
/// are persisted across app restarts and shown in the side drawer and
/// dedicated history page.
class HistoryEntry {
  /// The URL of the visited page.
  final String url;

  /// The title of the page when it was visited. May be empty if unknown.
  final String title;

  /// When the page was visited.
  final DateTime timestamp;

  HistoryEntry({
    required this.url,
    required this.title,
    required this.timestamp,
  });

  /// Construct a history entry from persisted JSON.
  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      url: json['url'] as String,
      title: json['title'] as String? ?? '',
      timestamp:
          json['timestamp'] != null
              ? DateTime.parse(json['timestamp'] as String)
              : DateTime.now(),
    );
  }

  /// Serialises this history entry to a JSON map for persistence.
  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'timestamp': timestamp.toIso8601String(),
  };
}

/// Data model for the mini player overlay. When non‑null, the mini player
/// overlay is shown in the root widget to allow the user to continue
/// watching a video while browsing or navigating. The mini player stores
/// only the file path and title of the media, plus an optional start position.
class MiniPlayerData {
  final String path;
  final String title;
  final Duration? startAt;
  const MiniPlayerData({required this.path, required this.title, this.startAt});
}

/// A home shortcut item representing a bookmarked page on the custom home
/// screen. Each item stores the URL of the page, a user friendly name and a
/// cached favicon path so icons remain available offline. Favicons are
/// downloaded lazily and refreshed as needed by [AppRepo].
String _generateHomeItemId() {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = math.Random().nextInt(1 << 30).toRadixString(36);
  return '$ts$rand';
}

class HomeItem {
  String id;
  /// The destination URL that will be loaded when this item is tapped.
  String url;

  /// A user defined title shown under the favicon. If empty, the host part
  /// of [url] will be used as a fallback in the UI.
  String name;

  /// Local path to the cached favicon for this shortcut. May be null if the
  /// icon has not been downloaded yet or failed to download.
  String? iconPath;

  HomeItem({String? id, required this.url, required this.name, this.iconPath})
      : id = (id == null || id.isEmpty) ? _generateHomeItemId() : id;

  factory HomeItem.fromJson(Map<String, dynamic> json) {
    return HomeItem(
      id: json['id'] as String?,
      url: json['url'] as String? ?? '',
      name: json['name'] as String? ?? '',
      iconPath: json['iconPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'name': name,
      if (iconPath != null && iconPath!.isNotEmpty) 'iconPath': iconPath,
    };
  }
}

/// Persisted browser tab session containing address bar text and navigation history.
/// The browser restores these sessions to keep tab stacks (back/forward) after restarts.
class TabSessionState {
  final List<String> history;
  final int currentIndex;
  final String urlText;

  final String? thumbnailBase64;

  TabSessionState({
    List<String>? history,
    int? currentIndex,
    String? urlText,
    String? thumbnailBase64,
  }) : this._internal(
         _cleanHistory(history),
         currentIndex,
         urlText,
         thumbnailBase64,
       );
  TabSessionState._internal(
    List<String> history,
    int? index,
    String? text,
    String? thumbnail,
  ) : history = List<String>.from(history),
      currentIndex = _normalizeIndex(history, index),
      urlText = text?.trim() ?? '',
      thumbnailBase64 =
          (thumbnail != null && thumbnail.isNotEmpty) ? thumbnail : null;
  static List<String> _cleanHistory(List<String>? values) {
    if (values == null) return <String>[];
    return values
        .map((e) => e.toString().trim())
        .where(
          (element) =>
              element.isNotEmpty &&
              !element.toLowerCase().startsWith('about:blank'),
        )
        .toList();
  }

  static int _normalizeIndex(List<String> history, int? index) {
    if (history.isEmpty) return -1;
    if (index == null) return history.length - 1;
    if (index < 0) return history.length - 1;
    if (index >= history.length) return history.length - 1;
    return index;
  }

  factory TabSessionState.fromJson(Map<String, dynamic> json) {
    final rawHistory =
        (json['history'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
    final idx = (json['index'] as num?)?.toInt();
    final text = json['urlText'] as String? ?? '';
    final thumb = json['thumbnail'] as String?;
    return TabSessionState(
      history: rawHistory,
      currentIndex: idx,
      urlText: text,
      thumbnailBase64: thumb,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'history': history,
      'index': currentIndex,
      'urlText': urlText,
    };
    if (thumbnailBase64 != null && thumbnailBase64!.isNotEmpty) {
      map['thumbnail'] = thumbnailBase64;
    }
    return map;
  }

  String? get currentUrl {
    if (currentIndex < 0 || currentIndex >= history.length) return null;
    return history[currentIndex];
  }
}

/// Represents a download task for either a direct media file or HLS playlist.
/// Represents a download job. Each task knows where it came from (url),
/// where it is stored on disk (savePath), what kind of download it is
/// (HLS playlist vs direct file), its progress, state and metadata such
/// as the detected type (video/audio/image/other), a custom name, when it
/// was created, whether the user has favourited it, a local thumbnail
/// preview and the duration of the media if applicable.
class DownloadTask {
  /// Source URL of the media.
  final String url;

  /// Local file path where this task writes its downloaded content.
  String savePath;

  /// Either `'hls'` for M3U8/HLS playlists or `'file'` for direct files.
  final String kind;

  /// Bytes received so far during downloading. Only populated while
  /// [state] is `'downloading'`.
  int received;

  /// Total bytes expected. May be null if unknown or not yet discovered.
  int? total;

  /// Current state of the task: `'queued'`, `'downloading'`, `'done'` or `'error'`.
  String state;

  /// Timestamp when the task was created. Used for sorting and display.
  final DateTime timestamp;

  /// Optional custom name set by the user. If null the UI falls back to
  /// displaying the file name derived from [savePath].
  String? name;

  /// Detected media type: `'video'`, `'audio'`, `'image'` or `'file'`.
  String type;

  /// Whether this task is marked as a favourite by the user.
  bool favorite;

  /// Identifier of the custom folder this task belongs to. When null the task
  /// appears in the default "我的下載" section.
  String? folderId;

  /// Whether this task has been moved to the hidden media tab.
  bool hidden;

  /// Local path to a thumbnail image extracted from the downloaded file.
  String? thumbnailPath;

  /// Duration of the media file, if known. Null for non‑media files.
  Duration? duration;

  /// Whether the task is paused (UI uses this to show ▶/⏸).
  bool paused;

  /// Optional progress unit hint for special kinds. For HLS we set to
  /// 'time-ms' to indicate that [received]/[total] are milliseconds of
  /// processed media duration instead of bytes/segments, so UI can render
  ///百分比與時間式進度。
  String? progressUnit;

  /// Arbitrary metadata (e.g. YouTube stream pairing info) persisted with the task.
  Map<String, dynamic>? extra;

  DownloadTask({
    required this.url,
    required this.savePath,
    required this.kind,
    this.received = 0,
    this.total,
    this.state = 'queued',
    DateTime? timestamp,
    this.name,
    required this.type,
    this.favorite = false,
    this.folderId,
    this.hidden = false,
    this.thumbnailPath,
    this.duration,
    this.paused = false,
    this.progressUnit,
    this.extra,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Construct a task from persisted JSON. Unknown fields are ignored.
  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      url: json['url'] as String,
      savePath: json['savePath'] as String,
      kind: json['kind'] as String,
      received: json['received'] as int? ?? 0,
      total: json['total'] as int?,
      state: json['state'] as String? ?? 'queued',
      timestamp:
          json['timestamp'] != null
              ? DateTime.parse(json['timestamp'] as String)
              : DateTime.now(),
      name: json['name'] as String?,
      type: json['type'] as String? ?? 'file',
      favorite: json['favorite'] as bool? ?? false,
      folderId: json['folderId'] as String?,
      hidden: json['hidden'] as bool? ?? false,
      thumbnailPath: json['thumbnailPath'] as String?,
      duration:
          json['duration'] != null
              ? Duration(milliseconds: json['duration'] as int)
              : null,
      paused: json['paused'] as bool? ?? false,
      progressUnit: json['progressUnit'] as String?,
      extra:
          json['extra'] is Map
              ? Map<String, dynamic>.from(json['extra'] as Map)
              : null,
    );
  }

  /// Serialises this task to a JSON map for persistence.
  Map<String, dynamic> toJson() => {
    'url': url,
    'savePath': savePath,
    'kind': kind,
    'received': received,
    'total': total,
    'state': state,
    'timestamp': timestamp.toIso8601String(),
    'name': name,
    'type': type,
    'favorite': favorite,
    'folderId': folderId,
    'hidden': hidden,
    'thumbnailPath': thumbnailPath,
    // store duration in milliseconds for portability
    'duration': duration?.inMilliseconds,
    'paused': paused,
    'progressUnit': progressUnit,
    'extra': extra,
  };
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

class SpriteSheetInfo {
  final String videoPath;
  final String imagePath;
  final int columns;
  final int rows;
  final int intervalMs;
  final int frameCount;

  const SpriteSheetInfo({
    required this.videoPath,
    required this.imagePath,
    required this.columns,
    required this.rows,
    required this.intervalMs,
    required this.frameCount,
  });

  Map<String, dynamic> toJson() => {
    'videoPath': videoPath,
    'imagePath': imagePath,
    'columns': columns,
    'rows': rows,
    'intervalMs': intervalMs,
    'frameCount': frameCount,
  };

  factory SpriteSheetInfo.fromJson(Map<String, dynamic> json) {
    return SpriteSheetInfo(
      videoPath: json['videoPath'] as String? ?? '',
      imagePath: json['imagePath'] as String,
      columns: json['columns'] as int? ?? 1,
      rows: json['rows'] as int? ?? 1,
      intervalMs: json['intervalMs'] as int? ?? 1000,
      frameCount: json['frameCount'] as int? ?? 1,
    );
  }
}

/// Represents a user-defined folder that groups download tasks on the media
/// page. The order of folders in [AppRepo.mediaFolders] determines their
/// display order.
class MediaFolder {
  final String id;
  final String name;

  const MediaFolder({required this.id, required this.name});

  MediaFolder copyWith({String? name}) {
    return MediaFolder(id: id, name: name ?? this.name);
  }

  factory MediaFolder.fromJson(Map<String, dynamic> json) {
    final rawName = (json['name'] as String?)?.trim();
    return MediaFolder(
      id: json['id'] as String,
      name:
          rawName == null || rawName.isEmpty
              ? LanguageService.instance.translate('media.folder.unnamed')
              : rawName,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class _HlsResumeManifest {
  _HlsResumeManifest({List<String>? parts, int? completedMs})
    : parts = parts ?? <String>[],
      completedMs = completedMs ?? 0;

  final List<String> parts;
  int completedMs;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'parts': parts,
    'completedMs': completedMs,
  };

  static _HlsResumeManifest fromJson(Map<String, dynamic> json) {
    final parts =
        (json['parts'] as List?)?.whereType<String>().toList(growable: true) ??
        <String>[];
    final completed = json['completedMs'] as int? ?? 0;
    return _HlsResumeManifest(parts: parts, completedMs: completed);
  }
}

class _HlsImageResumeData {
  _HlsImageResumeData({
    required this.playlistHash,
    required this.frameExt,
    required this.frameCount,
    Set<int>? completed,
  }) : completed = completed ?? <int>{};

  final String playlistHash;
  String frameExt;
  int frameCount;
  final Set<int> completed;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'playlistHash': playlistHash,
    'frameExt': frameExt,
    'frameCount': frameCount,
    'completed': completed.toList(),
  };

  static _HlsImageResumeData? fromJson(Map<String, dynamic> json) {
    final hash = json['playlistHash'] as String?;
    final ext = json['frameExt'] as String? ?? '';
    final count = (json['frameCount'] as num?)?.toInt();
    if (hash == null || hash.isEmpty || count == null || count < 0) {
      return null;
    }
    final completedList = (json['completed'] as List?)?.whereType<num>();
    final completed = <int>{
      if (completedList != null)
        ...completedList.map((e) => e.toInt()).where((e) => e >= 0),
    };
    final extWithDot =
        ext.isEmpty ? '.jpeg' : (ext.startsWith('.') ? ext : '.$ext');
    return _HlsImageResumeData(
      playlistHash: hash,
      frameExt: extWithDot,
      frameCount: count,
      completed: completed,
    );
  }
}

enum _YtMergePart { video, audio }

class _YtBgMeta {
  const _YtBgMeta({
    required this.parentKey,
    required this.part,
    this.totalBytes,
    this.name,
  });

  final String parentKey;
  final _YtMergePart part;
  final int? totalBytes;
  final String? name;

  static _YtBgMeta? fromMetaData(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != 'yt-merge') return null;
      final parent = decoded['parent'] as String?;
      final partRaw = decoded['part'] as String?;
      if (parent == null || parent.isEmpty || partRaw == null) {
        return null;
      }
      final part =
          partRaw == 'video'
              ? _YtMergePart.video
              : partRaw == 'audio'
                  ? _YtMergePart.audio
                  : null;
      if (part == null) return null;
      final total = (decoded['total'] as num?)?.toInt();
      final name = decoded['name'] as String?;
      return _YtBgMeta(
        parentKey: parent,
        part: part,
        totalBytes: total,
        name: name,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() {
    final Map<String, Object?> payload = {
      'kind': 'yt-merge',
      'parent': parentKey,
      'part': part.name,
    };
    final total = totalBytes;
    if (total != null && total > 0) {
      payload['total'] = total;
    }
    if (name != null && name!.isNotEmpty) {
      payload['name'] = name;
    }
    return jsonEncode(payload);
  }
}

class _HlsBgMeta {
  const _HlsBgMeta({
    required this.parentKey,
    required this.index,
    this.total,
    this.completed,
    this.session,
  });

  final String parentKey;
  final int index;
  final int? total;
  final int? completed;
  final int? session;

  static _HlsBgMeta? fromMetaData(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != 'hls-seg') return null;
      final parent = decoded['parent'] as String?;
      final index = (decoded['index'] as num?)?.toInt();
      final total = (decoded['total'] as num?)?.toInt();
      final completed = (decoded['completed'] as num?)?.toInt();
      final session = (decoded['session'] as num?)?.toInt();
      if (parent == null || parent.isEmpty || index == null || index < 0) {
        return null;
      }
      return _HlsBgMeta(
        parentKey: parent,
        index: index,
        total: total,
        completed: completed,
        session: session,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() {
    final payload = <String, Object?>{
      'kind': 'hls-seg',
      'parent': parentKey,
      'index': index,
    };
    if (total != null) {
      payload['total'] = total;
    }
    if (completed != null) {
      payload['completed'] = completed;
    }
    if (session != null) {
      payload['session'] = session;
    }
    return jsonEncode(payload);
  }
}

class _HlsSegmentBinding {
  const _HlsSegmentBinding({required this.parentKey, required this.index});

  final String parentKey;
  final int index;
}

class _HlsBgState {
  const _HlsBgState({
    required this.playlistUrl,
    required this.segmentUrls,
    required this.segmentFiles,
    required this.segmentDurations,
    required this.completed,
    required this.playlistPath,
    this.playlistLines,
  });

  final String playlistUrl;
  final List<String> segmentUrls;
  final List<String> segmentFiles;
  final List<double> segmentDurations;
  final Set<int> completed;
  final String playlistPath;
  final List<String>? playlistLines;

  int get total => segmentFiles.length;

  Map<String, dynamic> toJson() => {
        'playlistUrl': playlistUrl,
        'segmentUrls': segmentUrls,
        'segmentFiles': segmentFiles,
        'segmentDurations': segmentDurations,
        'completed': completed.toList(),
        'playlistPath': playlistPath,
        if (playlistLines != null) 'playlistLines': playlistLines,
      };

  static _HlsBgState? fromJson(Map<String, dynamic> json) {
    final playlistUrl = json['playlistUrl'] as String?;
    final playlistPath = json['playlistPath'] as String?;
    final urls = (json['segmentUrls'] as List?)?.cast<String>();
    final files = (json['segmentFiles'] as List?)?.cast<String>();
    final durations = (json['segmentDurations'] as List?)?.map((e) {
      if (e is num) return e.toDouble();
      return 0.0;
    }).toList();
    final playlistLines = (json['playlistLines'] as List?)?.cast<String>();
    final completedRaw = (json['completed'] as List?)?.whereType<num>();
    if (playlistUrl == null ||
        playlistUrl.isEmpty ||
        playlistPath == null ||
        playlistPath.isEmpty ||
        urls == null ||
        files == null ||
        durations == null ||
        urls.length != files.length ||
        files.length != durations.length) {
      return null;
    }
    final completed = <int>{
      if (completedRaw != null)
        ...completedRaw.map((e) => e.toInt()).where((e) => e >= 0),
    };
    return _HlsBgState(
      playlistUrl: playlistUrl,
      segmentUrls: urls,
      segmentFiles: files,
      segmentDurations: durations,
      completed: completed,
      playlistPath: playlistPath,
      playlistLines: playlistLines,
    );
  }
}

enum _DashTrackType { video, audio }

class _DashBgMeta {
  const _DashBgMeta({
    required this.parentKey,
    required this.track,
    required this.index,
    required this.isInit,
    this.videoTotalSegments,
    this.audioTotalSegments,
    this.videoCompletedSegments,
    this.audioCompletedSegments,
    this.videoInitComplete,
    this.audioInitComplete,
    this.hasVideo,
    this.hasAudio,
    this.session,
  });

  final String parentKey;
  final _DashTrackType track;
  final int index;
  final bool isInit;
  final int? videoTotalSegments;
  final int? audioTotalSegments;
  final int? videoCompletedSegments;
  final int? audioCompletedSegments;
  final bool? videoInitComplete;
  final bool? audioInitComplete;
  final bool? hasVideo;
  final bool? hasAudio;
  final int? session;

  static _DashBgMeta? fromMetaData(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != 'dash-seg') return null;
      final parent = decoded['parent'] as String?;
      final trackRaw = decoded['track'] as String?;
      final index = (decoded['index'] as num?)?.toInt();
      final isInit = decoded['init'] == true;
      final videoTotal = (decoded['videoTotalSegments'] as num?)?.toInt();
      final audioTotal = (decoded['audioTotalSegments'] as num?)?.toInt();
      final videoCompleted = (decoded['videoCompletedSegments'] as num?)?.toInt();
      final audioCompleted = (decoded['audioCompletedSegments'] as num?)?.toInt();
      final videoInit = decoded['videoInitComplete'] == true;
      final audioInit = decoded['audioInitComplete'] == true;
      final hasVideo = decoded['hasVideo'] == true;
      final hasAudio = decoded['hasAudio'] == true;
      final session = (decoded['session'] as num?)?.toInt();
      if (parent == null || parent.isEmpty || trackRaw == null) {
        return null;
      }
      final track =
          trackRaw == 'video'
              ? _DashTrackType.video
              : trackRaw == 'audio'
                  ? _DashTrackType.audio
                  : null;
      if (track == null) return null;
      return _DashBgMeta(
        parentKey: parent,
        track: track,
        index: index ?? 0,
        isInit: isInit,
        videoTotalSegments: videoTotal,
        audioTotalSegments: audioTotal,
        videoCompletedSegments: videoCompleted,
        audioCompletedSegments: audioCompleted,
        videoInitComplete: videoInit,
        audioInitComplete: audioInit,
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        session: session,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() {
    final payload = <String, Object?>{
      'kind': 'dash-seg',
      'parent': parentKey,
      'track': track.name,
      'index': index,
      'init': isInit,
    };
    if (videoTotalSegments != null) {
      payload['videoTotalSegments'] = videoTotalSegments;
    }
    if (audioTotalSegments != null) {
      payload['audioTotalSegments'] = audioTotalSegments;
    }
    if (videoCompletedSegments != null) {
      payload['videoCompletedSegments'] = videoCompletedSegments;
    }
    if (audioCompletedSegments != null) {
      payload['audioCompletedSegments'] = audioCompletedSegments;
    }
    if (videoInitComplete != null) {
      payload['videoInitComplete'] = videoInitComplete;
    }
    if (audioInitComplete != null) {
      payload['audioInitComplete'] = audioInitComplete;
    }
    if (hasVideo != null) {
      payload['hasVideo'] = hasVideo;
    }
    if (hasAudio != null) {
      payload['hasAudio'] = hasAudio;
    }
    if (session != null) {
      payload['session'] = session;
    }
    return jsonEncode(payload);
  }
}

class _DashSegmentBinding {
  const _DashSegmentBinding({
    required this.parentKey,
    required this.track,
    required this.index,
    required this.isInit,
  });

  final String parentKey;
  final _DashTrackType track;
  final int index;
  final bool isInit;
}

class _DashTrackState {
  const _DashTrackState({
    required this.initUrl,
    required this.initFile,
    required this.initComplete,
    required this.segmentUrls,
    required this.segmentFiles,
    required this.segmentDurations,
    required this.completed,
  });

  final String initUrl;
  final String initFile;
  final bool initComplete;
  final List<String> segmentUrls;
  final List<String> segmentFiles;
  final List<double> segmentDurations;
  final Set<int> completed;

  int get total => segmentFiles.length;

  Map<String, dynamic> toJson() => {
        'initUrl': initUrl,
        'initFile': initFile,
        'initComplete': initComplete,
        'segmentUrls': segmentUrls,
        'segmentFiles': segmentFiles,
        'segmentDurations': segmentDurations,
        'completed': completed.toList(),
      };

  static _DashTrackState? fromJson(Map<String, dynamic> json) {
    final initUrl = json['initUrl'] as String?;
    final initFile = json['initFile'] as String?;
    final initComplete = json['initComplete'] == true;
    final urls = (json['segmentUrls'] as List?)?.cast<String>();
    final files = (json['segmentFiles'] as List?)?.cast<String>();
    final durations = (json['segmentDurations'] as List?)?.map((e) {
      if (e is num) return e.toDouble();
      return 0.0;
    }).toList();
    final completedRaw = (json['completed'] as List?)?.whereType<num>();
    if (initUrl == null ||
        initUrl.isEmpty ||
        initFile == null ||
        initFile.isEmpty ||
        urls == null ||
        files == null ||
        durations == null ||
        urls.length != files.length ||
        files.length != durations.length) {
      return null;
    }
    final completed = <int>{
      if (completedRaw != null)
        ...completedRaw.map((e) => e.toInt()).where((e) => e >= 0),
    };
    return _DashTrackState(
      initUrl: initUrl,
      initFile: initFile,
      initComplete: initComplete,
      segmentUrls: urls,
      segmentFiles: files,
      segmentDurations: durations,
      completed: completed,
    );
  }
}

class _DashBgState {
  const _DashBgState({
    required this.mpdUrl,
    required this.video,
    required this.audio,
    required this.workspacePath,
  });

  final String mpdUrl;
  final _DashTrackState? video;
  final _DashTrackState? audio;
  final String workspacePath;

  int get totalSegments =>
      (video?.total ?? 0) + (audio?.total ?? 0) +
      ((video != null) ? 1 : 0) +
      ((audio != null) ? 1 : 0);

  int completedSegments() {
    final videoCompleted =
        (video?.completed.length ?? 0) + ((video?.initComplete ?? false) ? 1 : 0);
    final audioCompleted =
        (audio?.completed.length ?? 0) + ((audio?.initComplete ?? false) ? 1 : 0);
    return videoCompleted + audioCompleted;
  }

  Map<String, dynamic> toJson() => {
        'mpdUrl': mpdUrl,
        'video': video?.toJson(),
        'audio': audio?.toJson(),
        'workspacePath': workspacePath,
      };

  static _DashBgState? fromJson(Map<String, dynamic> json) {
    final mpdUrl = json['mpdUrl'] as String?;
    final workspacePath = json['workspacePath'] as String?;
    if (mpdUrl == null || mpdUrl.isEmpty || workspacePath == null) {
      return null;
    }
    final videoRaw = json['video'];
    final audioRaw = json['audio'];
    final video = videoRaw is Map<String, dynamic>
        ? _DashTrackState.fromJson(videoRaw)
        : null;
    final audio = audioRaw is Map<String, dynamic>
        ? _DashTrackState.fromJson(audioRaw)
        : null;
    if (video == null && audio == null) {
      return null;
    }
    return _DashBgState(
      mpdUrl: mpdUrl,
      video: video,
      audio: audio,
      workspacePath: workspacePath,
    );
  }
}

class _YtMergePartBinding {
  const _YtMergePartBinding({required this.sessionKey, required this.part});

  final String sessionKey;
  final _YtMergePart part;
}

class _YtMergeSession {
  _YtMergeSession({
    required this.task,
    required this.key,
    required this.workspacePath,
    required this.videoPath,
    required this.audioPath,
    required this.videoUrl,
    required this.audioUrl,
    required this.videoHeaders,
    required this.audioHeaders,
    this.videoId,
    this.videoItag,
    this.audioItag,
  });

  final DownloadTask task;
  final String key;
  final String workspacePath;
  final String videoPath;
  final String audioPath;
  final String videoUrl;
  final String audioUrl;
  final Map<String, String> videoHeaders;
  final Map<String, String> audioHeaders;
  final String? videoId;
  final int? videoItag;
  final int? audioItag;

  String? videoTaskId;
  String? audioTaskId;
  int videoReceived = 0;
  int videoTotal = 0;
  bool videoComplete = false;
  int audioReceived = 0;
  int audioTotal = 0;
  bool audioComplete = false;
  bool merging = false;
  int lastNotifiedBytes = 0;

  int get expectedTotalBytes {
    var total = 0;
    if (videoTotal > 0) {
      total += videoTotal;
    } else if (videoReceived > 0) {
      total += videoReceived;
    }
    if (audioTotal > 0) {
      total += audioTotal;
    } else if (audioReceived > 0) {
      total += audioReceived;
    }
    return total;
  }

  int get downloadedBytes {
    final videoDone =
        videoComplete ? (videoTotal > 0 ? videoTotal : videoReceived) : videoReceived;
    final audioDone =
        audioComplete ? (audioTotal > 0 ? audioTotal : audioReceived) : audioReceived;
    return math.max(0, videoDone) + math.max(0, audioDone);
  }

  bool get partsComplete => videoComplete && audioComplete;
}

class _DownloadPlan {
  final String url;
  final String kind;
  final String type;
  final String extension;
  final String? suggestedName;

  const _DownloadPlan({
    required this.url,
    required this.kind,
    required this.type,
    required this.extension,
    required this.suggestedName,
  });
}

/// Application repository managing detected media hits, download tasks, and favorites.
/// It also handles downloading/ converting HLS media to MP4/MOV and saving
/// downloaded files into the photo gallery.
class AppRepo extends ChangeNotifier {
  static const int freeHomeShortcutLimit = 5;

  final ValueNotifier<bool> premiumUnlocked = ValueNotifier<bool>(false);

  bool get isPremiumUnlocked => premiumUnlocked.value;

  bool get hasReachedFreeHomeShortcutLimit =>
      !isPremiumUnlocked && homeItems.value.length >= freeHomeShortcutLimit;

  void setPremiumUnlocked(bool value) {
    if (premiumUnlocked.value == value) return;
    premiumUnlocked.value = value;
    if (!value) {
      if (snifferEnabled.value) {
        snifferEnabled.value = false;
      }
      if (hits.value.isNotEmpty) {
        hits.value = [];
      }
    }
    notifyListeners();
  }

  // --- HLS 探測參數（降低前置判斷時間） ---
  static const int _hlsProbeTimeoutMs = 1800; // 每個候選最長 1.8s
  static const int _hlsCandidateLimit = 8; // 最多嘗試 8 個候選
  /// When a YouTube URL is detected, this notifier exposes the available
  /// quality/type choices to the UI to show a picker. Set to null when idle.
  final ValueNotifier<List<YtStreamOption>?> ytOptions =
      ValueNotifier<List<YtStreamOption>?>(null);
  final ValueNotifier<String?> ytTitle = ValueNotifier<String?>(null);
  final ValueNotifier<String?> ytHlsUrl = ValueNotifier<String?>(null);
  // 由 BrowserPage 即時同步的目前頁面 URL（供建 Referer 用）
  final ValueNotifier<String?> currentPageUrl = ValueNotifier<String?>(null);
  // 由 BrowserPage 更新的當前網頁標題，用於預設下載檔名。
  final ValueNotifier<String?> currentPageTitle = ValueNotifier<String?>(null);
  bool isYoutubeUrl(String url) => _isYouTubeUrl(url);

  Future<YtVideoInfo?> prepareYoutubeOptions(String url) async {
    try {
      return await _collectYtVideoInfo(url);
    } catch (e) {
      if (kDebugMode) {
        print('prepareYoutubeOptions error: $e');
      }
      return null;
    }
  }

  static final AppRepo I = AppRepo._();
  AppRepo._();

  final Map<String, int> _resumePositionsMs = {};
  final Map<String, SpriteSheetInfo> _spriteSheetCache = {};
  final Map<String, Future<SpriteSheetInfo?>> _spriteSheetPending = {};
  int _downloadAdCount = 0;
  static const String _bgDownloadGroup = 'yibrowser_file_downloads';
  static const String _bgCompletionVerifiedKey = '__bgCompletionVerified';
  static const String _bgNotificationConfiguredKey =
      '__bgNotificationConfigured';
  static const String _hlsBgReadyKey = '__hlsBgReady';
  static const String _hlsBgNotifiedKey = '__hlsBgNotified';
  static const String _dashBgReadyKey = '__dashBgReady';
  static const String _dashBgNotifiedKey = '__dashBgNotified';
  static const String _hlsFfmpegFallbackKey = '__hlsFfmpegFallback';
  static const String _dashFfmpegFallbackKey = '__dashFfmpegFallback';
  static const String _hlsNativeActiveKey = '__hlsNativeActive';
  static const String _hlsNativeOfflineKey = '__hlsNativeOffline';
  static const String _hlsPendingPreviewKey = '__hlsPendingPreview';
  static const String _hlsRefreshAttemptKey = '__hlsRefreshAttempt';
  static const String _hlsRefreshUrlKey = '__hlsRefreshUrl';
  static const String _hlsProgressAtKey = '__hlsProgressAtMs';
  static const Duration _hlsStallCheckInterval = Duration(minutes: 1);
  static const Duration _hlsStallThreshold = Duration(minutes: 3);
  static const String _bgFailedNotifiedKey = '__bgFailedNotified';
  static const MethodChannel _hlsNativeChannel = MethodChannel('hls.downloader');
  static const MethodChannel _playerChannel = MethodChannel('app.player');
  static const EventChannel _hlsNativeEvents =
      EventChannel('hls.downloader/events');
  final bg.FileDownloader _bgDownloader = bg.FileDownloader();
  final Map<String, DownloadTask> _bgTasksById = {};
  final Map<String, bg.DownloadTask> _bgTaskHandles = {};
  final Map<String, _HlsSegmentBinding> _hlsSegmentBindings = {};
  final Map<String, _DashSegmentBinding> _dashSegmentBindings = {};
  final Map<String, _YtMergeSession> _ytMergeSessions = {};
  final Map<String, _YtMergePartBinding> _ytMergeTaskBindings = {};
  StreamSubscription<dynamic>? _hlsNativeSub;
  final Map<String, DownloadTask> _hlsNativeTasksById = {};
  bool _callbacksRegistered = false;
  bool _initialized = false;
  bool _appInForeground = true;
  Timer? _liveActivityDebounce;
  DateTime? _lastLiveActivityPushAt;
  Timer? _hlsStallTimer;
  Map<String, Object?>? _lastLiveActivityPayload;

  bool get appInForeground => _appInForeground;

  void setAppInForeground(bool value) {
    if (_appInForeground == value) return;
    _appInForeground = value;
    if (_appInForeground) {
      unawaited(_resumeForegroundOnlyTasks());
      unawaited(_resumeHlsMergesIfReady());
      unawaited(_resumeDashMergesIfReady());
      unawaited(_processPendingHlsPreviews());
      _scheduleLiveActivityUpdate();
    } else {
      unawaited(_pauseForegroundOnlyTasks());
      _scheduleLiveActivityUpdate();
    }
  }

  Future<void> _processPendingHlsPreviews() async {
    if (!Platform.isIOS) return;
    for (final task in downloads.value) {
      if (task.type != 'video') continue;
      final extra = task.extra;
      if (extra == null || extra[_hlsPendingPreviewKey] != true) {
        continue;
      }
      extra.remove(_hlsPendingPreviewKey);
      try {
        await _generatePreview(task);
      } catch (_) {}
    }
  }

  Duration? resumePositionFor(String path) {
    final key = _canonicalPath(path);
    final ms = _resumePositionsMs[key] ?? _resumePositionsMs[path];
    if (ms == null) return null;
    if (ms <= 0) return Duration.zero;
    return Duration(milliseconds: ms);
  }

  void setResumePosition(String path, Duration position) {
    final canonical = _canonicalPath(path);
    final clamped = position.inMilliseconds.clamp(0, 1 << 31);
    _resumePositionsMs[canonical] = clamped;
    unawaited(_saveState());
  }

  String? _backgroundTaskIdFor(DownloadTask task) {
    final raw = task.extra?['bgTaskId'];
    if (raw is String && raw.isNotEmpty) {
      return raw;
    }
    return null;
  }

  bool _isBackgroundCompletionVerified(DownloadTask task) {
    return task.extra?[_bgCompletionVerifiedKey] == true;
  }

  bool _isBackgroundNotificationConfigured(DownloadTask task) {
    return task.extra?[_bgNotificationConfiguredKey] == true;
  }

  void _markBackgroundCompletionVerified(DownloadTask task) {
    (task.extra ??= {})[_bgCompletionVerifiedKey] = true;
  }

  void _markBackgroundNotificationConfigured(DownloadTask task) {
    (task.extra ??= {})[_bgNotificationConfiguredKey] = true;
  }

  void _clearBackgroundCompletionVerified(DownloadTask task) {
    task.extra?.remove(_bgCompletionVerifiedKey);
  }

  void _maybeConfigureBackgroundNotification(
    DownloadTask local,
    bg.DownloadTask remote,
  ) {
    if (!Platform.isIOS) return;
    if (!downloadNotificationsEnabled.value) return;
    if (_isBackgroundNotificationConfigured(local)) return;
    final title = LanguageService.instance.translate(
      'download.notification.title',
    );
    final body = LanguageService.instance.translate(
      'download.notification.body',
      params: {'name': '{displayName}'},
    );
    final errorTitle = LanguageService.instance.translate(
      'download.notification.failed.title',
    );
    final errorBody = LanguageService.instance.translate(
      'download.notification.failed.body',
      params: {'name': '{displayName}'},
    );
    _bgDownloader.configureNotificationForTask(
      remote,
      complete: bg.TaskNotification(title, body),
      error: bg.TaskNotification(errorTitle, errorBody),
    );
    _markBackgroundNotificationConfigured(local);
  }

  Future<void> _configureBackgroundNotificationsForActiveTasks() async {
    if (!Platform.isIOS || !downloadNotificationsEnabled.value) {
      return;
    }
    for (final entry in _bgTasksById.entries) {
      final local = entry.value;
      if (_isBackgroundNotificationConfigured(local)) {
        continue;
      }
      final cached = _bgTaskHandles[entry.key];
      final remote = cached ?? await _bgDownloader.taskForId(entry.key);
      if (remote is bg.DownloadTask) {
        _bgTaskHandles[entry.key] = remote;
        _maybeConfigureBackgroundNotification(local, remote);
      }
    }
  }

  void _registerBackgroundTaskHandle(
    DownloadTask task,
    bg.DownloadTask handle,
  ) {
    _clearBackgroundCompletionVerified(task);
    (task.extra ??= {})['bgTaskId'] = handle.taskId;
    _bgTasksById[handle.taskId] = task;
    _bgTaskHandles[handle.taskId] = handle;
  }

  void _detachBackgroundTask(String taskId) {
    final task = _bgTasksById.remove(taskId);
    _bgTaskHandles.remove(taskId);
    if (task != null) {
      final extra = task.extra;
      if (extra != null) {
        extra.remove('bgTaskId');
      }
    }
  }

  Future<bg.DownloadTask?> _backgroundHandleForTask(DownloadTask task) async {
    final id = _backgroundTaskIdFor(task);
    if (id == null) return null;
    final cached = _bgTaskHandles[id];
    if (cached != null) return cached;
    final remote = await _bgDownloader.taskForId(id);
    if (remote is bg.DownloadTask) {
      _bgTaskHandles[id] = remote;
      return remote;
    }
    return null;
  }

  void _handleBackgroundStatusUpdate(bg.TaskStatusUpdate update) {
    if (_handleHlsBackgroundStatus(update)) {
      return;
    }
    if (_handleDashBackgroundStatus(update)) {
      return;
    }
    if (_handleYtBackgroundStatus(update)) {
      return;
    }
    final taskId = update.task.taskId;
    if (update.task is bg.DownloadTask) {
      _bgTaskHandles[taskId] = update.task as bg.DownloadTask;
    }
    final local = _bgTasksById[taskId];
    if (local == null) {
      return;
    }
    _applyBackgroundStatus(local, update);
  }

  bool _handleDashBackgroundStatus(bg.TaskStatusUpdate update) {
    final meta = _DashBgMeta.fromMetaData(update.task.metaData);
    if (meta == null) {
      return false;
    }
    final task = _downloadTaskForKey(meta.parentKey);
    if (task == null) {
      return true;
    }
    if (update.status == bg.TaskStatus.complete) {
      _dashSegmentBindings.remove(update.task.taskId);
      unawaited(_markDashSegmentComplete(task, meta));
    } else if (update.status == bg.TaskStatus.failed ||
        update.status == bg.TaskStatus.notFound) {
      task.state = 'error';
      task.paused = false;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadFailed(task);
      unawaited(_saveState());
    }
    return true;
  }

  Future<void> _markDashSegmentComplete(
    DownloadTask task,
    _DashBgMeta meta,
  ) async {
    var state = await _loadDashBgState(task);
    if (state == null) return;
    var currentState = state;
    _DashTrackState? track =
        meta.track == _DashTrackType.video
            ? currentState.video
            : currentState.audio;
    if (track == null) return;
    if (!meta.isInit) {
      track.completed.add(meta.index);
    } else if (!track.initComplete) {
      final updated = _DashTrackState(
        initUrl: track.initUrl,
        initFile: track.initFile,
        initComplete: true,
        segmentUrls: track.segmentUrls,
        segmentFiles: track.segmentFiles,
        segmentDurations: track.segmentDurations,
        completed: track.completed,
      );
      if (meta.track == _DashTrackType.video) {
        currentState = _DashBgState(
          mpdUrl: currentState.mpdUrl,
          video: updated,
          audio: currentState.audio,
          workspacePath: currentState.workspacePath,
        );
      } else {
        currentState = _DashBgState(
          mpdUrl: currentState.mpdUrl,
          video: currentState.video,
          audio: updated,
          workspacePath: currentState.workspacePath,
        );
      }
      track = updated;
    }
    final total = currentState.totalSegments;
    final completed = currentState.completedSegments();
    task.total = total;
    task.received = completed;
    task.progressUnit = 'segments';
    task.state = 'downloading';
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveDashBgState(task, currentState);
    if (completed >= total && total > 0) {
      (task.extra ??= {})[_dashBgReadyKey] = true;
      task.state = 'paused';
      task.paused = true;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadComplete(task);
      task.extra?[_dashBgNotifiedKey] = true;
      await _saveState();
      if (_appInForeground) {
        unawaited(_runTaskDashMergeFromLocal(task));
      }
    }
  }

  DownloadTask? _downloadTaskForKey(String key) {
    final canonical = _canonicalPath(key);
    for (final task in downloads.value) {
      if (_canonicalPath(task.savePath) == canonical) {
        return task;
      }
    }
    return null;
  }

  bool _handleHlsBackgroundStatus(bg.TaskStatusUpdate update) {
    final meta = _HlsBgMeta.fromMetaData(update.task.metaData);
    if (meta == null) {
      return false;
    }
    final task = _downloadTaskForKey(meta.parentKey);
    if (task == null) {
      return true;
    }
    if (update.status == bg.TaskStatus.complete) {
      _hlsSegmentBindings.remove(update.task.taskId);
      unawaited(_markHlsSegmentComplete(task, meta.index));
    } else if (update.status == bg.TaskStatus.failed ||
        update.status == bg.TaskStatus.notFound) {
      unawaited(() async {
        final forceRefreshFfmpeg =
            !Platform.isIOS || task.extra?[_hlsFfmpegFallbackKey] == true;
        final refreshed = await _attemptHlsRefreshAndRestart(
          task,
          preferNative: !forceRefreshFfmpeg,
          forceFfmpeg: forceRefreshFfmpeg,
        );
        if (refreshed) return;
        task.state = 'error';
        task.paused = false;
        _notifyDownloadsUpdated();
        notifyListeners();
        _maybeNotifyDownloadFailed(task);
        await _saveState();
      }());
    }
    return true;
  }

  Future<void> _markHlsSegmentComplete(
    DownloadTask task,
    int index,
  ) async {
    final state = await _loadHlsBgState(task);
    if (state == null) return;
    if (index < 0 || index >= state.segmentFiles.length) return;
    final segmentsDir = await _hlsBgSegmentsDir(task);
    final filePath = p.join(segmentsDir.path, state.segmentFiles[index]);
    final valid = await _isValidHlsSegmentFile(filePath);
    if (!valid) {
      state.completed.remove(index);
      task.total = state.total;
      task.received = state.completed.length;
      task.progressUnit = 'segments';
      task.state = 'downloading';
      _notifyDownloadsUpdated();
      notifyListeners();
      await _saveHlsBgState(task, state);
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
      final headers = await _headersFor(state.playlistUrl);
      unawaited(
        _enqueueHlsSegmentDownload(
          task,
          state,
          index,
          headers: headers,
        ),
      );
      return;
    }
    state.completed.add(index);
    final completedCount = state.completed.length;
    task.total = state.total;
    task.received = completedCount;
    task.progressUnit = 'segments';
    task.state = 'downloading';
    _markHlsProgress(task);
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveHlsBgState(task, state);
    if (completedCount >= state.total) {
      (task.extra ??= {})[_hlsBgReadyKey] = true;
      task.state = 'paused';
      task.paused = true;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadComplete(task);
      task.extra?[_hlsBgNotifiedKey] = true;
      await _saveState();
      if (_appInForeground) {
        unawaited(_runTaskHlsMergeFromLocal(task));
      }
    }
  }

  void _applyBackgroundStatus(DownloadTask local, bg.TaskStatusUpdate update) {
    final status = update.status;
    switch (status) {
      case bg.TaskStatus.enqueued:
      case bg.TaskStatus.waitingToRetry:
        local.state = 'queued';
        local.paused = false;
        break;
      case bg.TaskStatus.running:
        local.state = 'downloading';
        local.paused = false;
        break;
      case bg.TaskStatus.paused:
        local.state = 'paused';
        local.paused = true;
        break;
      case bg.TaskStatus.canceled:
        local.state = 'paused';
        local.paused = true;
        _detachBackgroundTask(update.task.taskId);
        break;
      case bg.TaskStatus.notFound:
      case bg.TaskStatus.failed:
        _detachBackgroundTask(update.task.taskId);
        if (_isBackgroundCompletionVerified(local)) {
          break;
        }
        local.state = 'error';
        local.paused = false;
        unawaited(_reconcileTaskIfCompletedFileExists(local));
        _maybeNotifyDownloadFailed(local);
        break;
      case bg.TaskStatus.complete:
        local.state = 'done';
        local.paused = false;
        if (update.task is bg.DownloadTask) {
          final remote = update.task as bg.DownloadTask;
          unawaited(_onBackgroundTaskComplete(remote, local));
        } else {
          _detachBackgroundTask(update.task.taskId);
        }
        break;
    }
    if (status != bg.TaskStatus.complete) {
      _notifyDownloadsUpdated();
      notifyListeners();
      unawaited(_saveState());
    }
  }

  void _handleBackgroundProgressUpdate(bg.TaskProgressUpdate update) {
    if (_handleYtBackgroundProgress(update)) {
      return;
    }
    final taskId = update.task.taskId;
    if (update.task is bg.DownloadTask) {
      _bgTaskHandles[taskId] = update.task as bg.DownloadTask;
    }
    final local = _bgTasksById[taskId];
    if (local == null) {
      return;
    }
    final expected = update.expectedFileSize;
    if (expected > 0) {
      local.total = expected;
      if (update.progress >= 0) {
        final received = (update.progress * expected).round();
        local.received = received.clamp(0, expected);
      }
    } else {
      if (local.total != null && local.total! <= 0) {
        local.total = null;
      }
    }
    local.state = 'downloading';
    local.paused = false;
    _notifyDownloadsUpdated();
    notifyListeners();
  }

  Future<void> _onBackgroundTaskComplete(
    bg.DownloadTask remote,
    DownloadTask local,
  ) async {
    _detachBackgroundTask(remote.taskId);
    var verified = false;
    try {
      final path = await remote.filePath();
      if (path.isNotEmpty) {
        final canonical = _canonicalPath(path);
        if (canonical != local.savePath) {
          local.savePath = canonical;
        }
        final file = File(canonical);
        if (await file.exists()) {
          final length = await file.length();
          local.received = length;
          local.total = length;
          if (length > 0) {
            verified = true;
          }
        }
      }
    } catch (_) {}
    if (verified) {
      _markBackgroundCompletionVerified(local);
    }
    _notifyDownloadsUpdated();
    notifyListeners();
    if (autoSave.value) {
      try {
        await saveFileToGallery(local.savePath);
      } catch (_) {}
    }
    _maybeNotifyDownloadComplete(local);
    try {
      await _generatePreview(local);
    } catch (_) {}
    unawaited(_cleanupTaskResiduals(local));
    try {
      await FirebaseAnalytics.instance.logEvent(
        name: 'download_complete',
        parameters: {
          'kind': local.kind,
          'type': local.type,
          'bytes': local.received,
        },
      );
    } catch (_) {}
    unawaited(_saveState());
  }

  void _applyBackgroundRecord(DownloadTask local, bg.TaskRecord record) {
    switch (record.status) {
      case bg.TaskStatus.enqueued:
      case bg.TaskStatus.waitingToRetry:
        local.state = 'queued';
        local.paused = false;
        break;
      case bg.TaskStatus.running:
        local.state = 'downloading';
        local.paused = false;
        break;
      case bg.TaskStatus.paused:
        local.state = 'paused';
        local.paused = true;
        break;
      case bg.TaskStatus.canceled:
        local.state = 'paused';
        local.paused = true;
        break;
      case bg.TaskStatus.notFound:
      case bg.TaskStatus.failed:
        if (_isBackgroundCompletionVerified(local)) {
          break;
        }
        local.state = 'error';
        local.paused = false;
        break;
      case bg.TaskStatus.complete:
        local.state = 'done';
        local.paused = false;
        break;
    }
    final expected = record.expectedFileSize;
    if (expected > 0) {
      local.total = expected;
      if (record.progress >= 0) {
        local.received = (record.progress * expected).round().clamp(
          0,
          expected,
        );
      }
    } else if (expected <= 0) {
      if (local.total != null && local.total! <= 0) {
        local.total = null;
      }
    }
  }

  Future<void> _rehydrateBackgroundTasks() async {
    for (final task in downloads.value) {
      final id = _backgroundTaskIdFor(task);
      if (id != null) {
        _bgTasksById[id] = task;
      }
    }
    final records = await _bgDownloader.database.allRecords(
      group: _bgDownloadGroup,
    );
    bool changed = false;
    for (final record in records) {
      final meta = (record.task is bg.DownloadTask)
          ? _YtBgMeta.fromMetaData(
              (record.task as bg.DownloadTask).metaData,
            )
          : null;
      if (meta != null) {
        final didChange = await _applyYtBackgroundRecord(record, meta);
        if (didChange) {
          changed = true;
        }
        continue;
      }
      final dashMeta = (record.task is bg.DownloadTask)
          ? _DashBgMeta.fromMetaData(
              (record.task as bg.DownloadTask).metaData,
            )
          : null;
      if (dashMeta != null) {
        if (record.status == bg.TaskStatus.complete) {
          final parent = _downloadTaskForKey(dashMeta.parentKey);
          if (parent != null) {
            await _markDashSegmentComplete(parent, dashMeta);
            changed = true;
          }
        }
        continue;
      }
      final hlsMeta = (record.task is bg.DownloadTask)
          ? _HlsBgMeta.fromMetaData(
              (record.task as bg.DownloadTask).metaData,
            )
          : null;
      if (hlsMeta != null) {
        if (record.status == bg.TaskStatus.complete) {
          final parent = _downloadTaskForKey(hlsMeta.parentKey);
          if (parent != null) {
            await _markHlsSegmentComplete(parent, hlsMeta.index);
            changed = true;
          }
        }
        continue;
      }
      final taskId = record.taskId;
      final local = _bgTasksById[taskId];
      if (local == null) {
        continue;
      }
      if (record.task is bg.DownloadTask) {
        _bgTaskHandles[taskId] = record.task as bg.DownloadTask;
      }
      _applyBackgroundRecord(local, record);
      changed = true;
    }
    if (changed) {
      _notifyDownloadsUpdated();
      notifyListeners();
    }
  }

  /// Tracks the last emitted file size for HLS conversion progress. Used to
  /// throttle UI updates during FFmpeg processing so that the UI remains
  /// responsive without flooding with notifications. The key is the task and
  /// the value is the last reported file size in bytes.
  final Map<DownloadTask, int> _lastHlsSize = {};

  /// Initialise the repository. Must be called before using [AppRepo.I].
  /// It loads previously persisted state from disk and prepares directories.
  Future<void> init() async {
    if (_initialized) {
      await syncBackgroundDownloader();
      return;
    }
    _initialized = true;

    final dir = await getApplicationDocumentsDirectory();
    // Place the state file in the app documents directory. This directory
    // persists across restarts and appears in the Files app on iOS.
    _stateFilePath = '${dir.path}/app_state.json';
    await _loadState();
    await _cleanupStaleProcessingOnLaunch();
    await importExistingFiles();
    await _bgDownloader.ready;
    if (!_callbacksRegistered) {
      _bgDownloader.registerCallbacks(
        group: _bgDownloadGroup,
        taskStatusCallback: _handleBackgroundStatusUpdate,
        taskProgressCallback: _handleBackgroundProgressUpdate,
      );
      _callbacksRegistered = true;
    }
    unawaited(
      Future<void>.delayed(const Duration(seconds: 5), () async {
        try {
          await _bgDownloader.rescheduleKilledTasks();
        } catch (_) {}
      }),
    );
    await syncBackgroundDownloader();
    _scheduleLiveActivityUpdate();
    await _ensureHlsNativeEvents();
    await _resumeNativeHlsTasks();
    _startHlsStallMonitor();
  }

  Future<void> _ensureHlsNativeEvents() async {
    if (!Platform.isIOS) return;
    if (_hlsNativeSub != null) return;
    _hlsNativeSub = _hlsNativeEvents.receiveBroadcastStream().listen(
      _handleHlsNativeEvent,
      onError: (Object err) {
        if (kDebugMode) {
          debugPrint('HLS native event error: $err');
        }
      },
    );
  }

  void _startHlsStallMonitor() {
    _hlsStallTimer?.cancel();
    _hlsStallTimer = Timer.periodic(_hlsStallCheckInterval, (_) {
      unawaited(_checkHlsStalls());
    });
  }

  void _markHlsProgress(DownloadTask t, {DateTime? now}) {
    final extra = t.extra ??= {};
    extra[_hlsProgressAtKey] = (now ?? DateTime.now()).millisecondsSinceEpoch;
  }

  Future<void> _cancelHlsBackgroundSegments(DownloadTask t) async {
    final parentKey = _canonicalPath(t.savePath);
    final ids = _hlsSegmentBindings.entries
        .where((e) => e.value.parentKey == parentKey)
        .map((e) => e.key)
        .toList(growable: false);
    for (final id in ids) {
      try {
        await _bgDownloader.cancelTaskWithId(id);
      } catch (_) {}
      _hlsSegmentBindings.remove(id);
    }
  }

  Future<void> _checkHlsStalls() async {
    final now = DateTime.now();
    for (final task in downloads.value) {
      if (task.kind != 'hls') continue;
      if (task.state != 'downloading' || task.paused) continue;
      final extra = task.extra ??= {};
      final lastMs = (extra[_hlsProgressAtKey] as num?)?.toInt();
      if (lastMs == null || lastMs <= 0) {
        _markHlsProgress(task, now: now);
        continue;
      }
      final lastAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (now.difference(lastAt) < _hlsStallThreshold) {
        continue;
      }

      if (extra[_hlsNativeActiveKey] == true) {
        await _cancelNativeHls(task);
      }
      final ffmpegId = _ffmpegSessions.remove(task);
      if (ffmpegId != null) {
        try {
          await FFmpegKit.cancel(ffmpegId);
        } catch (_) {}
      }
      await _cancelHlsBackgroundSegments(task);
      _hlsBootstrapTasks.remove(task);
      final forceRefreshFfmpeg = extra[_hlsFfmpegFallbackKey] == true;
      final refreshed = await _attemptHlsRefreshAndRestart(
        task,
        preferNative: Platform.isIOS ? true : !forceRefreshFfmpeg,
        forceFfmpeg: Platform.isIOS ? false : forceRefreshFfmpeg,
      );
      if (refreshed) {
        _markHlsProgress(task, now: now);
      }
    }
  }

  Future<void> _resumeNativeHlsTasks() async {
    if (!Platform.isIOS) return;
    for (final task in downloads.value) {
      if (task.kind != 'hls') continue;
      if (task.state != 'downloading' && task.state != 'queued') continue;
      try {
        await _startNativeHlsDownload(task);
      } catch (_) {}
    }
  }

  Future<void> syncBackgroundDownloader() async {
    try {
      await _bgDownloader.ready;
      await _bgDownloader.trackTasksInGroup(_bgDownloadGroup);
      await _bgDownloader.resumeFromBackground();
      await _rehydrateBackgroundTasks();
      await _cleanupTerminalBgRecords();
      await _configureBackgroundNotificationsForActiveTasks();
      _checkPendingYtMerges();
      await debugPrintBgRecords();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('syncBackgroundDownloader error: $e');
      }
    }
  }

  Future<void> _cleanupTerminalBgRecords() async {
    try {
      final records = await _bgDownloader.database.allRecords(
        group: _bgDownloadGroup,
      );
      if (records.isEmpty) return;
      const terminal = {
        bg.TaskStatus.complete,
        bg.TaskStatus.failed,
        bg.TaskStatus.canceled,
        bg.TaskStatus.notFound,
      };
      final ids =
          records
              .where((record) => terminal.contains(record.status))
              .map((record) => record.taskId)
              .toList();
      if (ids.isEmpty) return;
      await _bgDownloader.database.deleteRecordsWithIds(ids);
    } catch (_) {}
  }

  Future<void> debugPrintBgRecords({bool force = false}) async {
    if (!force && !kDebugMode) {
      return;
    }
    try {
      final records = await _bgDownloader.database.allRecords(
        group: _bgDownloadGroup,
      );
      debugPrint('BD DB has ${records.length} records');
      for (final record in records) {
        debugPrint(
          ' - ${record.taskId} status=${record.status} progress=${record.progress} expected=${record.expectedFileSize}',
        );
      }
    } catch (e) {
      debugPrint('debugPrintBgRecords error: $e');
    }
  }

  /// Returns the persistent downloads directory inside the app's Documents.
  Future<Directory> _downloadsDir() async {
    final Directory base =
        Platform.isIOS
            ? await getApplicationSupportDirectory()
            : await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'downloads'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (Platform.isIOS) {
      await _migrateDownloadsToSupport(dir);
    }
    return dir;
  }

  bool _didMigrateDownloads = false;

  Future<void> _migrateDownloadsToSupport(Directory target) async {
    if (_didMigrateDownloads) return;
    _didMigrateDownloads = true;
    final docs = await getApplicationDocumentsDirectory();
    final legacy = Directory(p.join(docs.path, 'downloads'));
    if (!await legacy.exists()) {
      return;
    }
    try {
      final targetEntries = await target.list().toList();
      if (targetEntries.isNotEmpty) {
        return;
      }
    } catch (_) {}
    try {
      await for (final entity in legacy.list(recursive: false)) {
        final name = p.basename(entity.path);
        final dest = p.join(target.path, name);
        try {
          if (entity is File) {
            await entity.rename(dest);
          } else if (entity is Directory) {
            await entity.rename(dest);
          }
        } catch (_) {}
      }
      try {
        await legacy.delete(recursive: true);
      } catch (_) {}
    } catch (_) {}
  }

  /// Returns a persistent directory for storing generated media thumbnails.
  ///
  /// Thumbnails used to live inside the temporary cache directory which iOS
  /// may purge at any time. When that happened the app would lose previews for
  /// older downloads after a restart. Keeping them inside Documents ensures
  /// they survive restarts and are not deleted unexpectedly.
  Future<Directory> _thumbnailsDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, '.thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    try {
      final legacyDocs = await getApplicationDocumentsDirectory();
      final legacyDir = Directory(p.join(legacyDocs.path, '.thumbnails'));
      if (await legacyDir.exists()) {
        final entries = await legacyDir.list(followLinks: false).toList();
        for (final entry in entries) {
          if (entry is! File) continue;
          final destPath = p.join(dir.path, p.basename(entry.path));
          if (!File(destPath).existsSync()) {
            await entry.copy(destPath);
          }
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return dir;
  }

  Future<Directory> _spritesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, '.sprites'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<SpriteSheetInfo?> ensureSpriteSheet(
    String videoPath, {
    Duration? duration,
  }) async {
    if (videoPath.isEmpty) return null;
    if (_isNativeHlsOfflinePath(videoPath)) {
      return null;
    }
    if (!_pathExistsSync(videoPath)) return null;
    final canonical = _canonicalPath(videoPath);

    final cached = _spriteSheetCache[canonical];
    if (cached != null && File(cached.imagePath).existsSync()) {
      return cached;
    }

    final pending = _spriteSheetPending[canonical];
    if (pending != null) {
      return await pending;
    }

    final completer = Completer<SpriteSheetInfo?>();
    _spriteSheetPending[canonical] = completer.future;

    () async {
      try {
        final spritesDir = await _spritesDir();
        final key = sha1.convert(utf8.encode(canonical)).toString();
        final imagePath = p.join(spritesDir.path, '$key.jpg');
        final metaPath = p.join(spritesDir.path, '$key.json');

        if (await File(imagePath).exists() && await File(metaPath).exists()) {
          try {
            final json =
                jsonDecode(await File(metaPath).readAsString())
                    as Map<String, dynamic>;
            final loaded = SpriteSheetInfo.fromJson(json);
            final info = SpriteSheetInfo(
              videoPath: canonical,
              imagePath: loaded.imagePath,
              columns: loaded.columns,
              rows: loaded.rows,
              intervalMs: loaded.intervalMs,
              frameCount: loaded.frameCount,
            );
            if (File(info.imagePath).existsSync()) {
              _spriteSheetCache[canonical] = info;
              completer.complete(info);
              _spriteSheetPending.remove(canonical);
              return;
            }
          } catch (_) {}
        }

        final resolvedDuration =
            duration ?? await _probeVideoDuration(videoPath);
        if (resolvedDuration == null || resolvedDuration <= Duration.zero) {
          completer.complete(null);
          _spriteSheetPending.remove(canonical);
          return;
        }

        final totalSeconds = math.max(1, resolvedDuration.inSeconds);
        const maxThumbs = 100;
        final intervalSec = math.max(1, (totalSeconds / maxThumbs).ceil());
        final thumbCount = math.max(1, (totalSeconds / intervalSec).ceil());
        final columns = math.min(10, thumbCount);
        final rows = math.max(1, ((thumbCount + columns - 1) / columns).ceil());
        const thumbWidth = 160;

        final frames = <img.Image>[];
        img.Image? lastFrame;
        int? tileWidth;
        int? tileHeight;

        for (var index = 0; index < thumbCount; index++) {
          final timeMs =
              ((resolvedDuration.inMilliseconds * index) / thumbCount).round();
          Uint8List? data;
          try {
            data = await VideoThumbnail.thumbnailData(
              video: videoPath,
              timeMs: timeMs,
              imageFormat: ImageFormat.JPEG,
              maxWidth: thumbWidth,
              quality: 60,
            );
          } catch (_) {
            data = null;
          }
          img.Image? frame;
          if (data != null && data.isNotEmpty) {
            try {
              frame = img.decodeImage(data);
            } catch (_) {
              frame = null;
            }
          }
          frame ??= lastFrame;
          tileWidth ??= frame?.width;
          tileHeight ??= frame?.height;
          tileWidth ??= thumbWidth;
          tileHeight ??= math.max((thumbWidth * 9 / 16).round(), 1);
          if (frame == null) {
            frame = img.Image(
              width: tileWidth!,
              height: tileHeight!,
              numChannels: 3,
            );
          } else if (frame.width != tileWidth || frame.height != tileHeight) {
            frame = img.copyResize(
              frame,
              width: tileWidth!,
              height: tileHeight!,
              interpolation: img.Interpolation.linear,
            );
          }
          frames.add(frame);
          lastFrame = frame;
        }

        if (frames.isEmpty || tileWidth == null || tileHeight == null) {
          completer.complete(null);
          _spriteSheetPending.remove(canonical);
          return;
        }

        final sheet = img.Image(
          width: tileWidth! * columns,
          height: tileHeight! * rows,
          numChannels: 3,
        );
        for (var idx = 0; idx < frames.length; idx++) {
          final frame = frames[idx];
          final row = idx ~/ columns;
          final col = idx % columns;
          final offsetX = col * tileWidth!;
          final offsetY = row * tileHeight!;
          for (var y = 0; y < tileHeight!; y++) {
            for (var x = 0; x < tileWidth!; x++) {
              final pixel = frame.getPixel(x, y);
              sheet.setPixel(offsetX + x, offsetY + y, pixel);
            }
          }
        }

        final encoded = img.encodeJpg(sheet, quality: 80);
        await File(imagePath).writeAsBytes(encoded, flush: true);

        final info = SpriteSheetInfo(
          videoPath: canonical,
          imagePath: imagePath,
          columns: columns,
          rows: rows,
          intervalMs: intervalSec * 1000,
          frameCount: thumbCount,
        );
        try {
          await File(
            metaPath,
          ).writeAsString(jsonEncode(info.toJson())).catchError((_) {});
        } catch (_) {}
        _spriteSheetCache[canonical] = info;
        completer.complete(info);
      } catch (_) {
        completer.complete(null);
      } finally {
        _spriteSheetPending.remove(canonical);
      }
    }();

    return await completer.future;
  }

  Future<void> _ensureThumbnailPersistence(DownloadTask t) async {
    final thumbPath = t.thumbnailPath;
    if (thumbPath == null || thumbPath.isEmpty) {
      return;
    }

    final file = File(thumbPath);
    if (!await file.exists()) {
      t.thumbnailPath = null;
      return;
    }

    final thumbsDir = await _thumbnailsDir();
    final normalizedDir = p.normalize(thumbsDir.path);
    final normalizedThumb = p.normalize(file.path);
    if (normalizedThumb == normalizedDir ||
        p.isWithin(normalizedDir, normalizedThumb)) {
      return; // Already persisted in the new location.
    }

    final baseName = p.basename(file.path);
    String destPath = p.join(thumbsDir.path, baseName);
    if (await File(destPath).exists()) {
      final uniqueSuffix =
          '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(1 << 32)}';
      final extension = p.extension(baseName);
      destPath = p.join(thumbsDir.path, 'thumb_$uniqueSuffix$extension');
    }

    try {
      await file.copy(destPath);
      t.thumbnailPath = destPath;
      try {
        await file.delete();
      } catch (_) {}
    } catch (_) {
      // If copying fails keep the existing thumbnail path so a later rescan
      // can regenerate it instead of leaving the task without a preview.
    }
  }

  Future<Duration?> _probeVideoDuration(String path) async {
    try {
      final probe = await FFprobeKit.getMediaInformation(path);
      final info = probe.getMediaInformation();
      final durationStr = info?.getDuration();
      final seconds = double.tryParse(durationStr ?? '');
      if (seconds != null && seconds.isFinite && seconds > 0) {
        return Duration(milliseconds: (seconds * 1000).round());
      }
    } catch (_) {}
    return null;
  }

  /// Copies an externally provided media file (from iOS share extension or
  /// other integrations) into the persistent downloads folder, adds it to the
  /// downloads list and optionally kicks off preview generation. Returns the
  /// created [DownloadTask] so callers can immediately present it.
  Future<DownloadTask?> importSharedMediaFile({
    required String sourcePath,
    String? displayName,
    String? typeHint,
    Duration? durationHint,
  }) async {
    try {
      debugPrint(
        '[Share] Import request: '
        'source=$sourcePath, displayName=$displayName, typeHint=$typeHint',
      );
      final sourceFile = File(sourcePath);
      final exists = await sourceFile.exists();
      debugPrint('[Share] Source exists: $exists');
      if (!exists) {
        return null;
      }

      final downloadsDir = await _downloadsDir();

      String baseName = (displayName ?? p.basename(sourcePath)).trim();
      if (baseName.isEmpty || baseName == '.' || baseName == '..') {
        baseName = 'shared_${DateTime.now().millisecondsSinceEpoch}';
      }
      baseName = baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

      String extension = p.extension(baseName);
      if (extension.isEmpty) {
        extension = p.extension(sourcePath);
      }
      String inferredType = typeHint ?? '';
      if (extension.isEmpty && inferredType.isNotEmpty) {
        extension = '.${_defaultExtensionForType(inferredType)}';
      }
      if (extension.isEmpty) {
        extension = '.${_defaultExtensionForType('file')}';
      }
      if (!extension.startsWith('.')) {
        extension = '.$extension';
      }

      String stem = p.basenameWithoutExtension(baseName);
      if (stem.isEmpty) {
        stem = 'shared_${DateTime.now().millisecondsSinceEpoch}';
      }

      String candidateName = '$stem$extension';
      String destinationPath = p.join(downloadsDir.path, candidateName);
      int counter = 1;
      while (File(destinationPath).existsSync()) {
        candidateName = '$stem ($counter)$extension';
        destinationPath = p.join(downloadsDir.path, candidateName);
        counter += 1;
      }

      File copied;
      try {
        copied = await sourceFile.copy(destinationPath);
      } catch (err, stackTrace) {
        debugPrint(
          '[Share] Failed to copy shared file to $destinationPath: $err',
        );
        debugPrint(stackTrace.toString());
        return null;
      }
      debugPrint('[Share] Copied file to $destinationPath');

      final canonical = _canonicalPath(copied.path);
      final newFile = File(canonical);

      int size = 0;
      try {
        size = await newFile.length();
      } catch (_) {}

      DateTime timestamp;
      try {
        final stat = await newFile.stat();
        timestamp = stat.modified;
      } catch (_) {
        timestamp = DateTime.now();
      }

      if (inferredType.isEmpty) {
        final extWithoutDot = extension.replaceFirst('.', '');
        inferredType = _typeFromExtension(extWithoutDot);
      }
      if (inferredType.isEmpty || inferredType == 'file') {
        inferredType = _inferType(canonical);
      }
      if (inferredType.isEmpty) {
        inferredType = 'file';
      }

      final task = DownloadTask(
        url: canonical,
        savePath: canonical,
        kind: 'file',
        received: size,
        total: size,
        state: 'done',
        timestamp: timestamp,
        name: p.basename(canonical),
        type: inferredType,
        favorite: false,
        thumbnailPath: null,
        duration: durationHint,
        paused: false,
      );

      final List<DownloadTask> updated = [
        task,
        ...downloads.value.where(
          (existing) => _canonicalPath(existing.savePath) != canonical,
        ),
      ];
      updated.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      downloads.value = updated;
      notifyListeners();
      unawaited(_saveState());
      if (task.type == 'video') {
        unawaited(_generatePreview(task));
      }
      debugPrint('[Share] Import finished for ${task.name} (${task.type})');
      return task;
    } catch (e, stackTrace) {
      debugPrint('[Share] importSharedMediaFile error: $e');
      debugPrint(stackTrace.toString());
      return null;
    }
  }

  // 在 AppRepo class 裡新增
  Future<void> rescanDownloadsFolder({
    bool regenerateThumbnails = false,
  }) async {
    await importExistingFiles();
    if (!regenerateThumbnails) return;

    final tasks = [...downloads.value];
    bool clearedAnyThumb = false;
    for (final task in tasks) {
      if (task.type != 'video') continue;
      if (task.state != 'done') continue;
      if (!_pathExistsSync(task.savePath)) continue;
      final thumbPath = task.thumbnailPath;
      if (thumbPath != null && thumbPath.isNotEmpty) {
        try {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            await thumbFile.delete();
          }
        } catch (_) {}
        task.thumbnailPath = null;
        clearedAnyThumb = true;
      }
      unawaited(_generatePreview(task));
    }

    if (clearedAnyThumb) {
      try {
        downloads.value = [...downloads.value];
        notifyListeners();
        unawaited(_saveState());
      } catch (_) {}
    }
  }

  /// Scan the downloads folder and import any media files that are not yet tracked.
  Future<void> importExistingFiles() async {
    try {
      final dir = await _downloadsDir();
      final entries = await dir.list(followLinks: false).toList();
      final current = [...downloads.value];
      for (final t in current) {
        final canon = _canonicalPath(t.savePath);
        if (canon != t.savePath) t.savePath = canon;
        _normalizeTaskType(t);
      }
      final existing = current.map((t) => _canonicalPath(t.savePath)).toSet();

      // Track tasks whose files are currently missing so we can re-bind them
      // if the underlying file was renamed outside the app (e.g. via Files).
      final List<DownloadTask> missing = [];
      final Map<int, List<DownloadTask>> missingBySize = {};
      for (final task in current) {
        final exists = _pathExistsSync(task.savePath);
        if (!exists) {
          missing.add(task);
          final int? expectedSize;
          if (task.total != null && task.total! > 0) {
            expectedSize = task.total;
          } else if (task.progressUnit != 'time-ms' && task.received > 0) {
            expectedSize = task.received;
          } else {
            expectedSize = null;
          }
          if (expectedSize != null) {
            final list = missingBySize.putIfAbsent(expectedSize, () => []);
            list.add(task);
          }
        }
      }

      bool changed = false;
      for (final e in entries) {
        final path = e.path;
        // Skip hidden/system files to avoid importing metadata artefacts.
        if (p.basename(path).startsWith('.')) continue;
        final norm = _canonicalPath(path);
        final lower = path.toLowerCase();
        final isMovpkg = lower.endsWith('.movpkg');
        // Filter by common media extensions
        final isMedia =
            isMovpkg ||
            lower.endsWith('.mp4') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.m4v') ||
            lower.endsWith('.webm') ||
            lower.endsWith('.mkv') ||
            lower.endsWith('.mp3') ||
            lower.endsWith('.m4a') ||
            lower.endsWith('.aac') ||
            lower.endsWith('.ogg') ||
            lower.endsWith('.wav') ||
            lower.endsWith('.flac') ||
            lower.endsWith('.png') ||
            lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.gif') ||
            lower.endsWith('.webp') ||
            lower.endsWith('.bmp') ||
            lower.endsWith('.svg');
        if (!isMedia) continue;
        if (existing.contains(norm)) continue;
        final stat = await e.stat();
        final int fileSize;
        if (e is Directory || isMovpkg) {
          fileSize = await _directorySize(Directory(path));
        } else {
          fileSize = stat.size;
        }

        DownloadTask? rebound;
        final sameSize = missingBySize[fileSize];
        if (sameSize != null && sameSize.isNotEmpty) {
          rebound = sameSize.firstWhereOrNull((t) => t.state == 'done');
        }
        rebound ??= missing.firstWhereOrNull((t) {
          if (t.state != 'done') return false;
          if (t.progressUnit == 'time-ms') return false;
          // Prefer tasks that originally lived in the same downloads dir.
          return p.dirname(_canonicalPath(t.savePath)) == p.dirname(norm);
        });
        if (rebound == null) {
          final fileBase = p.basename(norm);
          rebound = missing.firstWhereOrNull((t) {
            if (t.state != 'done') return false;
            final canonicalSave = _canonicalPath(t.savePath);
            final saveBase = p.basename(canonicalSave);
            if (saveBase == fileBase) {
              return true;
            }
            final name = t.name?.trim();
            if (name == null || name.isEmpty) return false;
            final nameBase = p.basename(name);
            return nameBase == fileBase;
          });
        }
        if (rebound != null) {
          final oldPath = rebound.savePath;
          final oldBase = p.basename(oldPath);
          rebound.savePath = norm;
          rebound.total = fileSize;
          rebound.received = fileSize;
          rebound.type = _inferType(path);
          _normalizeTaskType(rebound);
          // If the name simply mirrored the filename, refresh it to the new one.
          if (rebound.name == null ||
              rebound.name!.isEmpty ||
              rebound.name == oldBase) {
            rebound.name = p.basename(path);
          }
          // Carry over resume position to the renamed file path.
          final oldKey = _canonicalPath(oldPath);
          final resume =
              _resumePositionsMs.remove(oldKey) ??
              _resumePositionsMs.remove(oldPath);
          if (resume != null) {
            _resumePositionsMs[norm] = resume;
          }
          if (rebound.thumbnailPath == null ||
              !File(rebound.thumbnailPath!).existsSync()) {
            // ignore: unawaited_futures
            _generatePreview(rebound);
          }
          existing.add(norm);
          missing.remove(rebound);
          final sizedList = missingBySize[fileSize];
          sizedList?.remove(rebound);
          if (sizedList != null && sizedList.isEmpty) {
            missingBySize.remove(fileSize);
          }
          changed = true;
          continue;
        }

        final size = fileSize;
        final type = _inferType(path);

        final canonicalPath = _canonicalPath(path);
        final task = DownloadTask(
          url:
              canonicalPath, // For imported files, use local path as url placeholder
          savePath: canonicalPath,
          kind: 'file',
          received: size,
          total: size,
          state: 'done',
          timestamp: stat.modified,
          name: p.basename(path),
          type: type,
          favorite: false,
          thumbnailPath: null,
          duration: null,
          paused: false,
        );
        current.add(task);
        existing.add(norm);
        changed = true;
        // Generate preview/duration in background for videos
        // ignore: unawaited_futures
        _generatePreview(task);
      }

      for (final task in current) {
        if (task.type != 'video') continue;
        if (!_pathExistsSync(task.savePath)) continue;
        final thumb = task.thumbnailPath;
        if (thumb == null || thumb.isEmpty || !File(thumb).existsSync()) {
          // ignore: unawaited_futures
          _generatePreview(task);
        }
      }

      // Deduplicate by normalised path while keeping richest metadata.
      final Map<String, DownloadTask> byPath = {};
      int score(DownloadTask t) {
        var s = 0;
        if (_pathExistsSync(t.savePath)) s += 3;
        if (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync())
          s += 2;
        if (t.duration != null && t.duration! > Duration.zero) s += 2;
        if ((t.name ?? '').isNotEmpty) s += 1;
        if (t.favorite) s += 1;
        if (t.total != null && t.total! > 0) s += 1;
        if (t.folderId != null && t.folderId!.isNotEmpty) s += 1;
        if (t.hidden) s += 50;
        return s;
      }

      for (final t in current) {
        final key = _canonicalPath(t.savePath);
        final existingTask = byPath[key];
        if (existingTask == null || score(t) >= score(existingTask)) {
          if (existingTask != null &&
              t.folderId == null &&
              existingTask.folderId != null) {
            t.folderId = existingTask.folderId;
          }
          byPath[key] = t;
        } else if (existingTask.folderId == null && t.folderId != null) {
          existingTask.folderId = t.folderId;
        }
      }
      final deduped =
          byPath.values.toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

      if (changed || deduped.length != current.length) {
        downloads.value = deduped;
        notifyListeners();
        await _saveState();
      }
    } catch (e) {
      if (kDebugMode) print('importExistingFiles error: $e');
    }
  }

  /// Persist the current downloads, favourites and settings to disk.
  Future<void> _saveState() async {
    try {
      final file = File(_stateFilePath);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final data = <String, dynamic>{
        // Persist download tasks so they survive restarts. Tasks are stored
        // along with their metadata (name, state, thumbnail etc.).
        'downloads': downloads.value.map((t) => t.toJson()).toList(),
        'mediaFolders': mediaFolders.value.map((f) => f.toJson()).toList(),
        // Persist favourited page URLs.
        'favorites': favorites.value,
        // Persist the list of browsing history entries.
        'history': history.value.map((e) => e.toJson()).toList(),
        // Persist the pop‑up blocking setting.
        'blockPopup': blockPopup.value,
        // Persist the Adblocker toggle so it survives restarts.
        'adBlockEnabled': adBlockEnabled.value,
        'adBlockFilterSets': adBlockFilterSets.value.toList(),
        // Persist the auto save setting (whether downloads are automatically
        // saved to the system photo gallery).
        'autoSave': autoSave.value,
        'downloadNotificationsEnabled': downloadNotificationsEnabled.value,
        // Persist user defined home shortcuts. Each entry stores a URL and
        // label. Without including this array the user's custom home page
        // would reset on next launch.
        'homeItems': homeItems.value.map((e) => e.toJson()).toList(),
        'homeTilesOrder': homeTilesOrder.value,

        'resume': _resumePositionsMs,
        'downloadAdCount': _downloadAdCount,

        // Persist the list of open browser tabs. Each entry is a URL. This
        // ensures the user’s open tabs are restored on the next launch.
        'openTabs': openTabs.value,
        'openTabsV2': tabSessions.value.map((e) => e.toJson()).toList(),
      };

      final jsonString = jsonEncode(data);
      final tmpPath =
          '$_stateFilePath.tmp.${DateTime.now().microsecondsSinceEpoch}';
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsString(jsonString, flush: true);
      if (await file.exists()) {
        final backup = File('$_stateFilePath.bak');
        try {
          await file.copy(backup.path);
        } catch (_) {}
      }
      try {
        await tmpFile.rename(_stateFilePath);
      } on FileSystemException {
        try {
          await tmpFile.copy(_stateFilePath);
        } finally {
          try {
            await tmpFile.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) print('Failed to save state: $e');
    }
  }

  void _resetStateToDefaults() {
    downloads.value = [];
    favorites.value = [];
    history.value = [];
    blockPopup.value = false;
    adBlockEnabled.value = false;
    adBlockFilterSets.value = {'plus'};
    autoSave.value = true;
    downloadNotificationsEnabled.value = true;
    homeItems.value = [];
    mediaFolders.value = [];
    openTabs.value = [];
    tabSessions.value = [];
    _resumePositionsMs.clear();
    _downloadAdCount = 0;
  }

  /// Load persisted state from disk. Missing fields fall back to defaults.
  Future<void> _loadState() async {
    final file = File(_stateFilePath);
    if (!file.existsSync()) {
      _resetStateToDefaults();

      return;
    }
    Future<Map<String, dynamic>> decode(File f) async {
      final jsonString = await f.readAsString();
      final dynamic raw = jsonDecode(jsonString);
      if (raw is! Map) {
        throw const FormatException('State file is not a JSON object');
      }
      return Map<String, dynamic>.from(raw as Map);
    }

    Map<String, dynamic>? data;
    var loadedFromBackup = false;
    try {
      data = await decode(file);
    } catch (e) {
      if (kDebugMode) print('Failed to load state: $e');
      final backupFile = File('$_stateFilePath.bak');
      if (backupFile.existsSync()) {
        try {
          data = await decode(backupFile);
          loadedFromBackup = true;
        } catch (backupError) {
          if (kDebugMode) print('Failed to load state backup: $backupError');
        }
      }
      if (data == null) {
        _resetStateToDefaults();
        return;
      }
    }

    try {
      final List<dynamic> dl = data['downloads'] as List<dynamic>? ?? [];
      final tasks =
          dl
              .map(
                (e) =>
                    DownloadTask.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
      final List<dynamic> folderRaw =
          data['mediaFolders'] as List<dynamic>? ?? const [];
      final folders =
          folderRaw
              .map(
                (e) =>
                    MediaFolder.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
      final allowedFolderIds = folders.map((f) => f.id).toSet();
      for (final t in tasks) {
        t.savePath = _canonicalPath(t.savePath);
        _normalizeTaskType(t);
        await _ensureThumbnailPersistence(t);
        if (kDebugMode) {
          final thumb = t.thumbnailPath;
          if (thumb != null && thumb.isNotEmpty) {
            final exists = File(thumb).existsSync();
            debugPrint(
              '[Thumb] load ${t.name ?? p.basename(t.savePath)} -> $thumb exists=$exists',
            );
          }
        }
        if (t.folderId != null && !allowedFolderIds.contains(t.folderId)) {
          t.folderId = null;
        }
      }
      // Do not remove tasks even if their files are missing. Users may wish
      // to reattempt downloads or view history of previous downloads.
      downloads.value = tasks;
      mediaFolders.value = folders;
      favorites.value =
          (data['favorites'] as List<dynamic>? ?? [])
              .map((e) => e.toString())
              .toList();
      // Restore browsing history.
      final hist =
          (data['history'] as List<dynamic>? ?? [])
              .map(
                (e) =>
                    HistoryEntry.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
      history.value = hist;
      _resumePositionsMs
        ..clear()
        ..addAll(
          (data['resume'] as Map<String, dynamic>? ?? {}).map(
            (key, value) =>
                MapEntry(_canonicalPath(key), (value as num).toInt()),
          ),
        );
      _downloadAdCount = (data['downloadAdCount'] as num?)?.toInt() ?? 0;
      // Restore pop‑up blocking preference.
      blockPopup.value = data['blockPopup'] as bool? ?? false;
      adBlockEnabled.value = data['adBlockEnabled'] as bool? ?? false;
      final List<dynamic> adblockRaw =
          data['adBlockFilterSets'] as List<dynamic>? ?? const [];
      adBlockFilterSets.value = _normalizeAdBlockProfiles(
        adblockRaw.map((e) => e.toString()),
      );
      autoSave.value = data['autoSave'] as bool? ?? true;
      downloadNotificationsEnabled.value =
          data['downloadNotificationsEnabled'] as bool? ?? true;

      // Restore custom home screen items. If absent, leave empty.
      final List<dynamic> homeRaw = data['homeItems'] as List<dynamic>? ?? [];
      final List<HomeItem> homes =
          homeRaw
              .map(
                (e) => HomeItem.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
      var needsHomeSave = false;
      for (final item in homes) {
        if (item.id.isEmpty) {
          item.id = _generateHomeItemId();
          needsHomeSave = true;
        }
        final path = item.iconPath;
        if (path != null && path.isNotEmpty) {
          final file = File(path);
          if (!file.existsSync()) {
            item.iconPath = null;
            needsHomeSave = true;
          }
        }
      }
      homeItems.value = homes;
      final List<dynamic> tilesRaw =
          data['homeTilesOrder'] as List<dynamic>? ??
          data['homeQuickActionsOrder'] as List<dynamic>? ??
          const [];
      final normalizedTiles = _normalizeHomeTilesOrder(
        tilesRaw.map((e) => e.toString()).toList(),
        homeItems.value,
      );
      homeTilesOrder.value = normalizedTiles;
      _applyHomeItemsOrderFromTiles(normalizedTiles);
      if (needsHomeSave) {
        unawaited(_saveState());
      }
      unawaited(refreshMissingHomeIcons());
      // Restore open browser tabs (with full history when available).
      final List<dynamic> sessionRaw =
          data['openTabsV2'] as List<dynamic>? ?? const [];
      if (sessionRaw.isNotEmpty) {
        final sessions =
            sessionRaw
                .map(
                  (e) => TabSessionState.fromJson(
                    Map<String, dynamic>.from(e as Map),
                  ),
                )
                .toList();
        tabSessions.value = sessions;
        openTabs.value = sessions.map((e) => e.urlText).toList();
      } else {
        final List<dynamic> tabRaw = data['openTabs'] as List<dynamic>? ?? [];
        final urls = tabRaw.map((e) => e.toString()).toList();
        openTabs.value = urls;
        tabSessions.value =
            urls
                .map(
                  (url) => TabSessionState(
                    history: [url],
                    currentIndex: 0,
                    urlText: url,
                  ),
                )
                .toList();
      }
      if (loadedFromBackup) {
        unawaited(_saveState());
      }
    } catch (e) {
      if (kDebugMode) print('Failed to load state: $e');
      _resetStateToDefaults();
    }
  }

  // ---- Helpers for YouTube detection and resolving real media URLs ----
  bool _isYouTubeUrl(String url) =>
      url.contains('youtube.com') || url.contains('youtu.be');

  Future<YtVideoInfo> _collectYtVideoInfo(String url) async {
    return fetchYoutubeVideoInfo(url);
  }

  bool _isBlobUrl(String url) => url.trim().toLowerCase().startsWith('blob:');

  String? _hostFromAny(String url) {
    try {
      var s = url.trim();
      if (s.startsWith('blob:')) s = s.substring(5);
      final u = Uri.parse(s);
      return (u.hasAuthority ? u.host : null);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _pickBestHlsVariant(String masterUrl) async {
    try {
      final dio = _createDio();
      final hdrs = await _headersFor(masterUrl);
      // Fetch playlist text with headers
      final resp = await dio.get<String>(
        masterUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: hdrs,
          followRedirects: true,
        ),
      );
      final content = resp.data ?? '';
      final baseUri = Uri.parse(masterUrl);

      final parser = HlsPlaylistParser.create();
      final parsed = await parser.parseString(baseUri, content);

      // If already a media playlist, let ensure logic validate/playable-ize it.
      if (parsed is HlsMediaPlaylist) {
        return await _ensurePlayableHls(masterUrl);
      }

      // Master playlist: pick highest bitrate variant that looks playable.
      if (parsed is HlsMasterPlaylist) {
        final variants = List.of(parsed.variants);
        if (variants.isEmpty) {
          // Fallback: try ensure on original
          return await _ensurePlayableHls(masterUrl);
        }
        // Sort by bitrate desc (nulls last)
        variants.sort(
          (a, b) => (b.format?.bitrate ?? 0).compareTo(a.format?.bitrate ?? 0),
        );
        for (final v in variants) {
          final candidate = v.url.toString(); // already absolute
          final ok = await _looksPlayableMediaPlaylist(candidate, hdrs);
          if (ok) return candidate;
        }
        // If none passed the quick check, just return the first as a fallback.
        return variants.first.url.toString();
      }

      // Unknown playlist type — fallback to original URL.
      return masterUrl;
    } catch (_) {
      // On any failure, fallback to original URL so the caller can still try.
      return masterUrl;
    }
  }

  Future<String> _ensurePlayableHls(String url) async {
    // Quick helper remains class-level: _looksPlayableMediaPlaylist
    try {
      final hdrs = await _headersFor(url);

      // 1) Fetch and parse the playlist at `url`
      final dio = _createDio();
      final r = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: hdrs,
          followRedirects: true,
        ),
      );
      final txt = r.data ?? '';

      final baseUri = Uri.parse(url);

      // Strengthen: detect i-frames-only tag
      final isIFramesOnlyTag = txt.contains('#EXT-X-I-FRAMES-ONLY');

      final parser = HlsPlaylistParser.create();
      final playlist = await parser.parseString(baseUri, txt);

      // 2) If it's a master playlist, iterate its variants by bitrate
      if (playlist is HlsMasterPlaylist) {
        final vars = List.of(playlist.variants);
        vars.sort(
          (a, b) => (b.format?.bitrate ?? 0).compareTo(a.format?.bitrate ?? 0),
        );
        for (final v in vars) {
          final cand = v.url.toString();
          if (await _looksPlayableMediaPlaylist(cand, hdrs)) {
            return cand;
          }
        }
        // If none looked clearly playable, return the first variant as a best-effort
        if (vars.isNotEmpty) return vars.first.url.toString();
        return url;
      }

      // 3) If it's a media playlist, verify it is not a trick-play image list
      if (playlist is HlsMediaPlaylist) {
        final hasSeg = playlist.segments.isNotEmpty;
        String? firstSegLow;
        if (hasSeg) {
          final segUrl = playlist.segments.first.url?.toString();
          firstSegLow = segUrl?.toLowerCase();
        }
        final looksImage =
            (firstSegLow != null) &&
            (firstSegLow.endsWith('.jpg') ||
                firstSegLow.endsWith('.jpeg') ||
                firstSegLow.endsWith('.png') ||
                firstSegLow.endsWith('.webp'));

        // Strengthen: treat i-frames-only as trick-play
        // If not trick-play, double-check with text-based probe to avoid false positives when segment urls are null.
        if (hasSeg && !looksImage && !isIFramesOnlyTag) {
          final ok = await _looksPlayableMediaPlaylist(url, hdrs);
          if (ok) {
            return url; // Good to go
          }
          // fall through to try sibling/parent candidates
        }

        // 3b) Looks like a trick-play / thumbnails list — try少量常見候選（限額制）

        final file = p.basename(baseUri.path);
        final dirUri = baseUri.replace(
          path: baseUri.path.substring(0, baseUri.path.length - file.length),
        );
        String dir = dirUri.toString();
        if (!dir.endsWith('/')) dir = '$dir/';

        // 按優先順序收集候選，並限制數量
        final List<String> candList = <String>[];
        void add(String u) {
          if (u.isEmpty) return;
          if (candList.length >= _hlsCandidateLimit) return;
          if (!candList.contains(u)) candList.add(u);
        }

        // Same folder candidates
        void addCommonNamesAt(String base) {
          // Normalize: ensure exactly one trailing slash
          String b = base;
          if (!b.endsWith('/')) {
            b = '$b/';
          } else {
            // collapse multiple slashes at the end to one
            b = b.replaceFirst(RegExp(r'/+$'), '/');
          }
          // 優先嘗試最常見幾個檔名
          add('${b}index.m3u8');
          add('${b}master.m3u8');
          add('${b}playlist.m3u8');
          add('${b}prog_index.m3u8');
          // 保留少數備用名
          add('${b}media.m3u8');
          add(
            baseUri.toString().replaceFirst(
              RegExp(r'video\.m3u8$', caseSensitive: false),
              'playlist.m3u8',
            ),
          );
          add(
            baseUri.toString().replaceFirst(
              RegExp(r'video\.m3u8$', caseSensitive: false),
              'media.m3u8',
            ),
          );
        }

        addCommonNamesAt(dir);

        // If pattern like ".../1080p/video.m3u8", go up one folder and try master/index
        final parts = baseUri.path.split('/');
        if (parts.length >= 3) {
          // remove last element (file)
          final parentPath = parts.sublist(0, parts.length - 1).join('/');
          final parentDirPath =
              parentPath.contains('/')
                  ? parentPath.substring(0, parentPath.lastIndexOf('/') + 1)
                  : '/';
          final parent = baseUri.replace(path: parentDirPath).toString();
          addCommonNamesAt(parent);
        }

        // Go up two levels (grandparent) and try again — many CDNs place master at root of asset
        if (parts.length >= 4) {
          final gpPath = parts.sublist(0, parts.length - 2).join('/') + '/';
          final gp = baseUri.replace(path: gpPath).toString();
          addCommonNamesAt(gp);
        }

        // Also try replacing common file names directly
        add(
          baseUri.toString().replaceFirst(
            RegExp(r'video\.m3u8$', caseSensitive: false),
            'index.m3u8',
          ),
        );
        add(
          baseUri.toString().replaceFirst(
            RegExp(r'video\.m3u8$', caseSensitive: false),
            'prog_index.m3u8',
          ),
        );
        add(
          baseUri.toString().replaceFirst(
            RegExp(r'video\.m3u8$', caseSensitive: false),
            'master.m3u8',
          ),
        );

        int attempts = 0;
        for (final c in candList) {
          attempts++;

          // Quick accept if looks like a media playlist
          if (await _looksPlayableMediaPlaylist(c, hdrs)) {
            if (kDebugMode) return c;
          }
          // If it's not a media playlist, it might be a master. Try resolving via parser again.
          try {
            final resolved = await _pickBestHlsVariant(c);
            if (resolved != null && resolved != c) {
              if (kDebugMode)
                // Double check resolved media
                if (await _looksPlayableMediaPlaylist(resolved, hdrs)) {
                  return resolved;
                }
            }
          } catch (e) {}
          if (attempts >= _hlsCandidateLimit) break;
        }

        // As a last resort, return the original url
        return url;
      }

      // Unknown type: return original
      return url;
    } catch (_) {
      return url;
    }
  }

  Future<bool> _looksPlayableMediaPlaylist(
    String u,
    Map<String, String> hdrs,
  ) async {
    try {
      final dio = _createDio();
      final r = await dio.get<String>(
        u,
        options: Options(
          responseType: ResponseType.plain,
          headers: hdrs,
          followRedirects: true,
          // 縮短探測逾時，避免前置等待過久
          sendTimeout: Duration(milliseconds: _hlsProbeTimeoutMs),
          receiveTimeout: Duration(milliseconds: _hlsProbeTimeoutMs),
          receiveDataWhenStatusError: true,
        ),
      );
      final txt = r.data ?? '';
      // 拒絕縮圖或 I-frame 清單（trick-play）
      if (txt.contains('#EXT-X-IMAGE-STREAM-INF') ||
          txt.contains('#EXT-X-I-FRAMES-ONLY')) {
        return false;
      }
      if (!txt.contains('#EXTM3U')) return false;
      // Must have at least one media segment marker
      if (!txt.contains('#EXTINF')) return false;

      // First non-comment line should not be an image (thumbnail trick playlists)
      String firstUri = '';
      for (final line in txt.split('\n')) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('#')) continue;
        firstUri = l;
        break;
      }
      final low = firstUri.toLowerCase();
      if (low.endsWith('.jpg') ||
          low.endsWith('.jpeg') ||
          low.endsWith('.png') ||
          low.endsWith('.webp')) {
        return false;
      }
      // If we see explicit TS/M4S segments, treat as playable
      if (low.endsWith('.ts') || low.endsWith('.m4s') || low.endsWith('.mp4')) {
        return true;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Try to resolve a real downloadable URL (.m3u8 or .mp4) from sniffer hits
  /// using the same host as [pageOrBlobUrl]. Returns null if none found.
  Future<String?> _resolveRealMediaFromHits(String pageOrBlobUrl) async {
    final host = _hostFromAny(pageOrBlobUrl);
    if (host == null) return null;
    final list = List<MediaHit>.from(hits.value);
    for (final h in list.reversed) {
      // newest first
      final hHost = _hostFromAny(h.url);
      if (hHost != host) continue;
      if (_isBlobUrl(h.url)) continue;
      final uLow = h.url.toLowerCase();
      final isM3u8 = uLow.contains('.m3u8');
      final isMp4 =
          uLow.contains('.mp4') ||
          uLow.contains('.mov') ||
          uLow.contains('.m4v') ||
          uLow.contains('.webm');
      final isTs = uLow.endsWith('.ts');
      if (isM3u8) {
        return await _pickBestHlsVariant(h.url);
      }
      if (isMp4) return h.url;
      if (isTs) {
        final pl = await _derivePlaylistFromTs(h.url);
        if (pl != null) return pl;
      }
    }
    return null;
  }

  Future<String?> _derivePlaylistFromTs(String tsUrl) async {
    try {
      final hdrs = await _headersFor(tsUrl);
      Uri u = Uri.parse(tsUrl);
      // Strip the file name
      final file = p.basename(u.path);
      final dirUri = u.replace(
        path: u.path.substring(0, u.path.length - file.length),
      );
      String dir = dirUri.toString();
      if (!dir.endsWith('/')) dir = '$dir/';

      final tried = <String>{};
      void add(String s) {
        if (s.isNotEmpty) tried.add(s);
      }

      String _normBase(String base) {
        if (!base.endsWith('/')) return '$base/';
        return base.replaceFirst(RegExp(r'/+$'), '/');
      }

      void addCommonAt(String base) {
        final b = _normBase(base);
        add('${b}index.m3u8');
        add('${b}prog_index.m3u8');
        add('${b}master.m3u8');
        add('${b}playlist.m3u8');
        add('${b}stream.m3u8');
        add('${b}hls.m3u8');
        add('${b}chunklist.m3u8');
        add('${b}media.m3u8');
        add('${b}index-v1-a1.m3u8');
      }

      addCommonAt(dir);

      // Parent folder
      final parts = u.path.split('/');
      if (parts.length >= 2) {
        final parentPath = parts.sublist(0, parts.length - 1).join('/') + '/';
        final parent = u.replace(path: parentPath).toString();
        addCommonAt(parent);
      }
      // Grandparent
      if (parts.length >= 3) {
        final gpPath = parts.sublist(0, parts.length - 2).join('/') + '/';
        final gp = u.replace(path: gpPath).toString();
        addCommonAt(gp);
      }

      int tries = 0;
      for (final cand in tried) {
        tries++;
        if (kDebugMode && tries <= 6) print('[deriveFromTs] try $cand');
        if (await _looksPlayableMediaPlaylist(cand, hdrs)) return cand;
        try {
          final resolved = await _pickBestHlsVariant(cand);
          if (resolved != null && resolved != cand) {
            if (await _looksPlayableMediaPlaylist(resolved, hdrs))
              return resolved;
          }
        } catch (_) {}
        if (tries >= _hlsCandidateLimit) break;
      }
    } catch (_) {}
    return null;
  }

  /// Build request headers (UA/Referer/Cookie) based on WebView state for a given media URL.
  Future<Map<String, String>> _headersFor(String url) async {
    final Map<String, String> h = {};
    final lo = url.toLowerCase();
    final wantsHls = lo.contains('.m3u8');
    // UA: prefer user's chosen UA; fall back to a reasonable default if null
    final ua = uaNotifier.value?.trim();
    if (ua != null && ua.isNotEmpty) {
      h['User-Agent'] = ua;
    }
    // Referer: prefer currentPageUrl (if same host), else recent history, else origin of the media URL
    final host = _hostFromAny(url);
    String? ref;
    final cur = currentPageUrl.value;
    if (cur != null && _hostFromAny(cur) == host) {
      ref = cur;
    }
    if (ref == null) {
      try {
        for (final e in history.value.reversed) {
          if (_hostFromAny(e.url) == host) {
            ref = e.url;
            break;
          }
        }
      } catch (_) {}
    }
    ref ??= _originOf(url);
    if (ref != null && ref.isNotEmpty) {
      h['Referer'] = ref;
    }
    // Add Origin when available (some HLS hosts require it)
    final origin = _originOf(ref ?? url);
    if (origin != null && origin.isNotEmpty) {
      h['Origin'] = origin;
    }
    // Add common browser-ish headers to improve success rate on anti-leech CDNs
    h.putIfAbsent(
      'Accept',
      () =>
          wantsHls
              ? 'application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8'
              : 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    );
    h.putIfAbsent(
      'Accept-Language',
      () => 'zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7',
    );
    h.putIfAbsent('Accept-Encoding', () => 'identity');

    // Cookie: collect cookies for the media URL from WebView cookie store
    try {
      final cm = CookieManager.instance();
      final ck = await cm.getCookies(url: WebUri(url));
      if (ck.isNotEmpty) {
        final cookieStr = ck.map((c) => '${c.name}=${c.value}').join('; ');
        if (cookieStr.isNotEmpty) h['Cookie'] = cookieStr;
      }
    } catch (_) {}
    return h;
  }

  String? _originOf(String url) {
    try {
      final u = Uri.parse(url);
      if (u.hasScheme && u.hasAuthority) {
        return Uri(
          scheme: u.scheme,
          host: u.host,
          port: u.hasPort ? u.port : null,
        ).toString();
      }
    } catch (_) {}
    return null;
  }

  String _extensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final dot = path.lastIndexOf('.');
      if (dot == -1 || dot < path.lastIndexOf('/')) return 'bin';
      final ext = path.substring(dot + 1);
      return ext.toLowerCase();
    } catch (_) {
      return 'bin';
    }
  }

  String _canonicalPath(String path) {
    try {
      var normalized = p.normalize(path);
      if (normalized.startsWith('/private/')) {
        normalized = normalized.replaceFirst('/private', '');
        if (!normalized.startsWith('/')) {
          normalized = '/$normalized';
        }
      }
      return normalized;
    } catch (_) {
      return path;
    }
  }

  String _defaultExtensionForType(String type) {
    switch (type) {
      case 'video':
        return 'mp4';
      case 'audio':
        return 'mp3';
      case 'image':
        return 'jpg';
      default:
        return 'bin';
    }
  }

  String _typeFromExtension(String? ext) {
    if (ext == null || ext.isEmpty) return 'file';
    if (ext.startsWith('.')) ext = ext.substring(1);
    final lower = ext.toLowerCase();
    if (lower == 'mp4' ||
        lower == 'mov' ||
        lower == 'movpkg' ||
        lower == 'm4v' ||
        lower == 'webm' ||
        lower == 'mkv' ||
        lower == 'ts' ||
        lower == 'm3u8') {
      return 'video';
    }
    if (lower == 'mp3' ||
        lower == 'm4a' ||
        lower == 'aac' ||
        lower == 'ogg' ||
        lower == 'wav' ||
        lower == 'flac' ||
        lower == 'opus') {
      return 'audio';
    }
    if (lower == 'png' ||
        lower == 'jpg' ||
        lower == 'jpeg' ||
        lower == 'gif' ||
        lower == 'webp' ||
        lower == 'bmp' ||
        lower == 'svg' ||
        lower == 'heic' ||
        lower == 'heif') {
      return 'image';
    }
    return 'file';
  }

  void _normalizeTaskType(DownloadTask t) {
    final current = t.type;
    final resolved = resolvedTaskType(t, explicitOverride: current);
    if (resolved != current) {
      t.type = resolved;
    }
  }

  void _maybeNotifyDownloadComplete(DownloadTask t) {
    if (!downloadNotificationsEnabled.value) {
      return;
    }
    if (t.extra?[_hlsBgNotifiedKey] == true) {
      return;
    }
    if (t.extra?[_dashBgNotifiedKey] == true) {
      return;
    }
    if (Platform.isIOS &&
        !_appInForeground &&
        _isBackgroundNotificationConfigured(t)) {
      if (t.kind != 'hls' && t.kind != 'dash' && t.kind != 'yt-merge') {
        return;
      }
    }
    final rawName = t.name?.trim();
    final displayName =
        (rawName != null && rawName.isNotEmpty)
            ? rawName
            : p.basename(t.savePath);
    final title = LanguageService.instance.translate(
      'download.notification.title',
    );
    final body = LanguageService.instance.translate(
      'download.notification.body',
      params: {'name': displayName},
    );
    unawaited(
      NotificationService.instance.showDownloadCompleted(
        title: title,
        body: body,
      ),
    );
  }

  void _maybeNotifyDownloadFailed(DownloadTask t) {
    if (!downloadNotificationsEnabled.value) {
      return;
    }
    if (t.extra?[_bgFailedNotifiedKey] == true) {
      return;
    }
    if (Platform.isIOS &&
        !_appInForeground &&
        _isBackgroundNotificationConfigured(t)) {
      return;
    }
    final rawName = t.name?.trim();
    final displayName =
        (rawName != null && rawName.isNotEmpty)
            ? rawName
            : p.basename(t.savePath);
    final title = LanguageService.instance.translate(
      'download.notification.failed.title',
    );
    final body = LanguageService.instance.translate(
      'download.notification.failed.body',
      params: {'name': displayName},
    );
    unawaited(
      NotificationService.instance.showDownloadFailed(
        title: title,
        body: body,
      ),
    );
    (t.extra ??= {})[_bgFailedNotifiedKey] = true;
  }

  Future<void> _reconcileTaskIfCompletedFileExists(DownloadTask t) async {
    if (t.state != 'error') {
      return;
    }
    try {
      final type = await FileSystemEntity.type(t.savePath);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      int length = 0;
      if (type == FileSystemEntityType.directory) {
        length = await _directorySize(Directory(t.savePath));
      } else {
        length = await File(t.savePath).length();
      }
      if (length <= 0 && type != FileSystemEntityType.directory) {
        return;
      }
      t.received = length;
      t.total = length;
      t.state = 'done';
      t.progressUnit = null;
      _markBackgroundCompletionVerified(t);
      _normalizeTaskType(t);
      _notifyDownloadsUpdated();
      notifyListeners();
      if (t.thumbnailPath == null ||
          t.thumbnailPath!.isEmpty ||
          !File(t.thumbnailPath!).existsSync()) {
        try {
          await _generatePreview(t);
        } catch (_) {}
      }
      _maybeNotifyDownloadComplete(t);
      if (autoSave.value) {
        try {
          await saveFileToGallery(t.savePath);
        } catch (_) {}
      }
      await _saveState();
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('reconcileTaskIfCompletedFileExists failed: $e\n$stack');
      }
    }
  }

  String resolvedTaskType(DownloadTask t, {String? explicitOverride}) {
    final explicit = explicitOverride ?? t.type;
    if (explicit == 'video' || explicit == 'audio' || explicit == 'image') {
      return explicit;
    }
    final ext = p.extension(t.savePath).replaceFirst('.', '');
    final mapped = _typeFromExtension(ext);
    if (mapped != 'file') return mapped;
    final inferred = _inferType(t.savePath);
    if (inferred != 'file') return inferred;
    return explicit;
  }

  String? _extractInnerUrl(String url) {
    try {
      final uri = Uri.parse(url);
      for (final entry in uri.queryParameters.entries) {
        final value = entry.value;
        if (value.isEmpty) continue;
        final decoded = Uri.decodeComponent(value);
        if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
          return decoded;
        }
      }
    } catch (_) {}
    return null;
  }

  String? _detectExtensionFromFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = file.openSync().readSync(16);
      if (bytes.length >= 12) {
        final ftyp = String.fromCharCodes(bytes.sublist(4, 8));
        if (ftyp == 'ftyp') return 'mp4';
      }
      if (bytes.length >= 4) {
        final b0 = bytes[0];
        final b1 = bytes[1];
        final b2 = bytes[2];
        final b3 = bytes[3];
        if (b0 == 0x49 && b1 == 0x44 && b2 == 0x33) return 'mp3';
        if (b0 == 0x4F && b1 == 0x67 && b2 == 0x67 && b3 == 0x53) return 'ogg';
        if (b0 == 0x1A && b1 == 0x45 && b2 == 0xDF && b3 == 0xA3) return 'mkv';
        if (b0 == 0x52 && b1 == 0x49 && b2 == 0x46 && b3 == 0x46) {
          try {
            final tag = String.fromCharCodes(bytes.sublist(8, 12));
            if (tag == 'AVI ') return 'avi';
            if (tag == 'WAVE') return 'wav';
          } catch (_) {}
        }
        if (b0 == 0x66 && b1 == 0x4C && b2 == 0x61 && b3 == 0x43) return 'flac';
      }
    } catch (_) {}
    return null;
  }

  String? _extensionFromContentType(String? contentType) {
    if (contentType == null) return null;
    final lower = contentType.toLowerCase();
    if (lower.contains('audio/mp4')) return 'm4a';
    if (lower.contains('audio/mpeg')) return 'mp3';
    if (lower.contains('mp4') || lower.contains('mpeg-4')) return 'mp4';
    if (lower.contains('quicktime')) return 'mov';
    if (lower.contains('webm')) return 'webm';
    if (lower.contains('matroska')) return 'mkv';
    if (lower.contains('mp3')) return 'mp3';
    if (lower.contains('aac')) return 'aac';
    if (lower.contains('m4a')) return 'm4a';
    if (lower.contains('wav')) return 'wav';
    if (lower.contains('ogg')) return 'ogg';
    if (lower.contains('image/png')) return 'png';
    if (lower.contains('image/jpeg')) return 'jpg';
    if (lower.contains('image/gif')) return 'gif';
    if (lower.contains('image/webp')) return 'webp';
    return null;
  }

  String? _filenameFromContentDisposition(String? header) {
    if (header == null || header.isEmpty) return null;
    final utf8Match = RegExp(
      r"filename\*=(?:UTF-8'')?([^;]+)",
      caseSensitive: false,
    ).firstMatch(header);
    if (utf8Match != null) {
      final raw = utf8Match.group(1);
      if (raw != null) {
        try {
          final decoded = Uri.decodeFull(raw);
          return decoded;
        } catch (_) {
          return _decodeHeaderFilename(raw);
        }
      }
    }
    final quotedMatch = RegExp(
      r'filename="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(header);
    if (quotedMatch != null) {
      final raw = quotedMatch.group(1);
      return raw == null ? null : _decodeHeaderFilename(raw);
    }
    final bareMatch = RegExp(
      r'filename=([^;]+)',
      caseSensitive: false,
    ).firstMatch(header);
    if (bareMatch != null) {
      final raw = bareMatch.group(1)?.trim();
      return raw == null ? null : _decodeHeaderFilename(raw);
    }
    return null;
  }

  String _decodeHeaderFilename(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.runes.any((r) => r > 255)) {
      return trimmed;
    }
    final codeUnits = trimmed.codeUnits.map((c) => c & 0xFF).toList();
    try {
      final decoded = utf8.decode(codeUnits, allowMalformed: true).trim();
      if (decoded.isNotEmpty) {
        return decoded;
      }
    } catch (_) {}
    return trimmed;
  }

  String? _extensionFromFilename(String? filename) {
    if (filename == null || filename.isEmpty) return null;
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return null;
    return filename.substring(dot + 1).toLowerCase();
  }

  /// Guess the media type from a URL extension. Defaults to 'video' if
  /// the extension is unknown. Used when enqueuing downloads.
  String _inferType(String url) {
    final nested = _extractInnerUrl(url);
    final target = (nested ?? url).toLowerCase();
    if (target.contains('mime%3daudio') || target.contains('mime=audio')) {
      return 'audio';
    }
    if (target.contains('mime%3dimage') || target.contains('mime=image')) {
      return 'image';
    }
    if (target.contains('mime%3dvideo') || target.contains('mime=video')) {
      return 'video';
    }
    if (target.contains('.mp3') ||
        target.contains('.m4a') ||
        target.contains('.aac') ||
        target.contains('.ogg') ||
        target.contains('.wav') ||
        target.contains('.flac')) {
      return 'audio';
    }
    if (target.contains('.png') ||
        target.contains('.jpg') ||
        target.contains('.jpeg') ||
        target.contains('.gif') ||
        target.contains('.webp') ||
        target.contains('.bmp') ||
        target.contains('.svg')) {
      return 'image';
    }
    if (target.contains('.m3u8') ||
        target.contains('.mpd') ||
        target.contains('.mp4') ||
        target.contains('.mov') ||
        target.contains('.movpkg') ||
        target.contains('.m4v') ||
        target.contains('.webm') ||
        target.contains('.mkv')) {
      return 'video';
    }
    return 'file';
  }

  /// Generate a thumbnail and duration for a completed task. Only applicable
  /// to video files. Uses FFprobe for metadata, generates a lightweight
  /// thumbnail via FFmpeg, and falls back to VideoPlayer only when duration
  /// remains unknown.
  Future<void> _generatePreview(DownloadTask t) async {
    if (t.type != 'video') return;
    if (_isNativeHlsOfflinePath(t.savePath)) {
      return;
    }
    double? durationSeconds;
    try {
      final probe = await FFprobeKit.getMediaInformation(t.savePath);
      final info = probe.getMediaInformation();
      final durationStr = info?.getDuration();
      durationSeconds = double.tryParse(durationStr ?? '');
    } catch (_) {}

    Duration? detectedDuration;
    if (durationSeconds != null &&
        durationSeconds.isFinite &&
        durationSeconds > 0) {
      detectedDuration = Duration(
        milliseconds: (durationSeconds * 1000).round(),
      );
      t.duration = detectedDuration;
    }

    try {
      final thumbsDir = await _thumbnailsDir();
      final baseName = p.basenameWithoutExtension(t.savePath);
      var sanitized = baseName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      if (sanitized.length > 24) {
        sanitized = sanitized.substring(0, 24);
      }
      if (sanitized.isEmpty) {
        sanitized = 'item';
      }
      final uniqueSuffix =
          '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(1 << 32)}';
      final thumbPath = p.join(
        thumbsDir.path,
        'thumb_${sanitized}_$uniqueSuffix.jpg',
      );

      double capturePoint = 0.5;
      if (durationSeconds != null && durationSeconds.isFinite) {
        if (durationSeconds < 0.6) {
          capturePoint = math.max(durationSeconds - 0.1, 0.0);
        }
      }
      final int? timeMs =
          durationSeconds != null
              ? math.max(0, (durationSeconds * capturePoint * 1000).round())
              : null;

      final Uint8List? data = await VideoThumbnail.thumbnailData(
        video: t.savePath,
        timeMs: timeMs ?? 0,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 320,
        quality: 75,
      );
      if (data != null && data.isNotEmpty) {
        final file = File(thumbPath);
        await file.writeAsBytes(data, flush: true);
        final previousThumb = t.thumbnailPath;
        t.thumbnailPath = thumbPath;
        if (previousThumb != null && previousThumb != thumbPath) {
          try {
            final oldFile = File(previousThumb);
            if (await oldFile.exists()) {
              await oldFile.delete();
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) print('Failed to generate thumbnail: $e');
    }

    if (t.duration == null) {
      try {
        final controller = VideoPlayerController.file(File(t.savePath));
        await controller.initialize();
        t.duration = controller.value.duration;
        await controller.dispose();
      } catch (_) {}
    }

    try {
      downloads.value = [...downloads.value];
      notifyListeners();
      unawaited(_saveState());
    } catch (_) {}

    if (t.type == 'video') {
      try {
        await ensureSpriteSheet(t.savePath, duration: t.duration);
      } catch (_) {}
    }
  }

  /// Change the display name of a task. Updates persistent state.
  void renameTask(DownloadTask t, String newName) {
    t.name = newName;
    downloads.value = [...downloads.value];
    _saveState();
  }

  /// Assign one or more tasks to a custom media folder. When [folderId] is
  /// null the tasks are moved back to the default section.
  void setTasksFolder(List<DownloadTask> tasks, String? folderId) {
    final availableFolders = mediaFolders.value;
    final String? target =
        (folderId != null &&
                availableFolders.any((folder) => folder.id == folderId))
            ? folderId
            : null;
    var changed = false;
    for (final task in tasks) {
      if (task.folderId != target) {
        task.folderId = target;
        changed = true;
      }
    }
    if (!changed) return;
    downloads.value = [...downloads.value];
    unawaited(_saveState());
  }

  /// Update the hidden status for a collection of tasks. Hidden tasks are
  /// removed from the main media list and displayed in the hidden tab only.
  void setTasksHidden(List<DownloadTask> tasks, bool hidden) {
    var changed = false;
    for (final task in tasks) {
      if (task.hidden != hidden) {
        task.hidden = hidden;
        changed = true;
      }
    }
    if (!changed) return;
    downloads.value = [...downloads.value];
    unawaited(_saveState());
  }

  /// Convenience helper for toggling the hidden state of a single task.
  void setTaskHidden(DownloadTask task, bool hidden) {
    setTasksHidden([task], hidden);
  }

  /// Create a new folder used to organise downloads on the media page.
  MediaFolder createMediaFolder(String name) {
    final trimmed = name.trim();
    final folderName =
        trimmed.isEmpty
            ? LanguageService.instance.translate('media.folder.newDefault')
            : trimmed;
    final folder = MediaFolder(
      id: 'folder_${DateTime.now().microsecondsSinceEpoch}',
      name: folderName,
    );
    mediaFolders.value = [...mediaFolders.value, folder];
    unawaited(_saveState());
    return folder;
  }

  /// Rename an existing custom media folder.
  void renameMediaFolder(String id, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final list = [...mediaFolders.value];
    final idx = list.indexWhere((f) => f.id == id);
    if (idx < 0) return;
    list[idx] = list[idx].copyWith(name: trimmed);
    mediaFolders.value = list;
    unawaited(_saveState());
  }

  /// Delete a folder and move any contained tasks back to the default section.
  void deleteMediaFolder(String id) {
    final list = mediaFolders.value;
    if (!list.any((f) => f.id == id)) return;
    mediaFolders.value = list.where((f) => f.id != id).toList();
    var touched = false;
    for (final task in downloads.value) {
      if (task.folderId == id) {
        task.folderId = null;
        touched = true;
      }
    }
    if (touched) {
      downloads.value = [...downloads.value];
    }
    unawaited(_saveState());
  }

  /// Persist a new ordering of custom folders.
  void reorderMediaFolders(List<MediaFolder> folders) {
    mediaFolders.value = [...folders];
    unawaited(_saveState());
  }

  /// Mark or unmark a task as favourite.
  void setFavorite(DownloadTask t, bool value) {
    t.favorite = value;
    downloads.value = [...downloads.value];
    _saveState();
  }

  /// Update a single download task and persist changes.
  /// If the task instance is not found by identity, we match by savePath,
  /// then by url, to avoid creating duplicates after app restarts.
  void updateDownload(DownloadTask t) {
    final list = [...downloads.value];
    int idx = list.indexWhere((e) => identical(e, t));
    if (idx < 0) {
      idx = list.indexWhere((e) => e.savePath == t.savePath);
    }
    if (idx < 0) {
      idx = list.indexWhere((e) => e.url == t.url);
    }
    if (idx >= 0) {
      list[idx] = t;
    } else {
      // As a last resort, append; this should be rare.
      list.add(t);
    }
    downloads.value = list; // trigger listeners
    notifyListeners();
    // persist asynchronously so we don't block UI
    unawaited(_saveState());
  }

  /// Update the automatic saving setting. When true newly downloaded files
  /// will be copied into the photo gallery. Persists the preference.
  void setAutoSave(bool value) {
    autoSave.value = value;
    _saveState();
  }

  /// Enable or disable download completion notifications.
  void setDownloadNotificationsEnabled(bool value) {
    if (downloadNotificationsEnabled.value == value) {
      return;
    }
    downloadNotificationsEnabled.value = value;
    if (value) {
      unawaited(_configureBackgroundNotificationsForActiveTasks());
    }
    _saveState();
  }

  Future<void> _deletePathIfExists(String path) async {
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
    } catch (_) {}
  }

  bool _pathExistsSync(String path) {
    try {
      return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  bool pathExistsSync(String path) => _pathExistsSync(path);

  Future<int> _directorySize(Directory dir) async {
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  Future<void> saveThumbnailForPath(String path, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final task = _downloadTaskForKey(path);
    if (task == null) return;
    final thumbsDir = await _thumbnailsDir();
    final baseName = p.basenameWithoutExtension(path);
    var sanitized = baseName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    if (sanitized.length > 24) {
      sanitized = sanitized.substring(0, 24);
    }
    if (sanitized.isEmpty) {
      sanitized = 'item';
    }
    final uniqueSuffix =
        '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(1 << 32)}';
    final thumbPath = p.join(
      thumbsDir.path,
      'thumb_${sanitized}_$uniqueSuffix.jpg',
    );
    final file = File(thumbPath);
    await file.writeAsBytes(bytes, flush: true);
    final previousThumb = task.thumbnailPath;
    task.thumbnailPath = thumbPath;
    if (kDebugMode) {
      debugPrint('[Thumb] saved for ${_canonicalPath(path)} -> $thumbPath');
    }
    if (previousThumb != null && previousThumb != thumbPath) {
      try {
        final oldFile = File(previousThumb);
        if (await oldFile.exists()) {
          await oldFile.delete();
        }
      } catch (_) {}
    }
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveState();
  }

  /// Remove tasks from the list and delete their associated files. Also
  /// deletes thumbnails. Updates persistent state.
  Future<void> removeTasks(
    List<DownloadTask> tasks, {
    bool deleteFiles = true,
  }) async {
    final current = [...downloads.value];
    for (final t in tasks) {
      final bgId = _backgroundTaskIdFor(t);
      if (bgId != null) {
        try {
          await _bgDownloader.cancelTaskWithId(bgId);
        } catch (_) {}
        _detachBackgroundTask(bgId);
      }
      final ffmpegSessionId = _ffmpegSessions.remove(t);
      if (ffmpegSessionId != null) {
        try {
          await FFmpegKit.cancel(ffmpegSessionId);
        } catch (_) {}
      }
      if (t.kind == 'hls' && Platform.isIOS) {
        await _cancelNativeHls(t);
      }
      _cleanupSegmentBindingsForTask(t);
      current.remove(t);
      if (deleteFiles) {
        await _deletePathIfExists(t.savePath);
      }
      _resumePositionsMs.remove(_canonicalPath(t.savePath));
      if (t.thumbnailPath != null && deleteFiles) {
        try {
          final f2 = File(t.thumbnailPath!);
          if (await f2.exists()) {
            await f2.delete();
          }
        } catch (_) {}
      }
      await _cleanupTaskResiduals(t);
    }
    downloads.value = current;
    await _saveState();
    // Force listeners (e.g. AnimatedBuilder/ValueListenableBuilder) to
    // rebuild immediately after tasks are removed. Without this call the
    // surrounding widgets subscribed directly to AppRepo (not just the
    // downloads ValueNotifier) will not rebuild until another event occurs.
    notifyListeners();
  }

  /// Compute the total size of files stored in the temporary cache directory.
  Future<int> getCacheSize() async {
    final dir = await getTemporaryDirectory();
    int size = 0;
    try {
      final list = dir.list(recursive: true, followLinks: false);
      await for (final entity in list) {
        if (entity is File) {
          size += await entity.length();
        }
      }
    } catch (_) {}
    cacheSizeBytes.value = size;
    return size;
  }

  /// Append a new history entry for the given URL and title. This method
  /// records the current timestamp. Duplicate entries are allowed and will
  /// appear in chronological order. Invoking this will persist the updated
  /// history list.
  void addHistory(String url, String title) {
    final entry = HistoryEntry(
      url: url,
      title: title,
      timestamp: DateTime.now(),
    );
    final list = [...history.value, entry];
    history.value = list;
    _saveState();
  }

  /// Remove a specific history entry. If the entry is not found, nothing
  /// happens. Persists the updated history.
  void removeHistoryEntry(HistoryEntry entry) {
    final list = [...history.value];
    list.remove(entry);
    history.value = list;
    _saveState();
  }

  /// Clear all browsing history. Persists the empty history list.
  void clearHistory() {
    history.value = [];
    _saveState();
  }

  /// Toggle whether a given page URL is in the favourites list. If it is
  /// already favourited it will be removed, otherwise it will be added. The
  /// updated favourites list is persisted immediately.
  void toggleFavoriteUrl(String url) {
    final list = [...favorites.value];
    if (list.contains(url)) {
      list.remove(url);
    } else {
      list.add(url);
    }
    favorites.value = list;
    _saveState();
  }

  /// Add a page URL to favourites if it is not already present.
  void addFavoriteUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final list = [...favorites.value];
    if (list.contains(trimmed)) {
      return;
    }
    list.add(trimmed);
    favorites.value = list;
    _saveState();
  }

  /// Remove a specific favourite URL. Persists the updated list.
  void removeFavoriteUrl(String url) {
    final list = [...favorites.value];
    list.remove(url);
    favorites.value = list;
    _saveState();
  }

  /// Remove all favourite URLs. Persists the empty list.
  void clearFavorites() {
    favorites.value = [];
    _saveState();
  }

  /// Toggle the pop‑up blocking setting. When enabled, new window requests
  /// from the WebView will be blocked and instead opened in the same page.
  void setBlockPopup(bool v) {
    blockPopup.value = v;
    _saveState();
  }

  /// Toggle the Adblocker feature which relies on WebView content blockers.
  void setAdBlockEnabled(bool v) {
    if (adBlockEnabled.value == v) return;
    adBlockEnabled.value = v;
    _saveState();
  }

  static const Set<String> _kAdBlockProfiles = {'lite', 'plus', 'privacy'};
  static const SetEquality<String> _adBlockSetEquality = SetEquality();

  Set<String> _normalizeAdBlockProfiles(Iterable<String> source) {
    final normalized = <String>{};
    for (final raw in source) {
      final candidate = raw.trim().toLowerCase();
      if (_kAdBlockProfiles.contains(candidate)) {
        normalized.add(candidate);
      }
    }
    if (normalized.isEmpty) {
      normalized.add('plus');
    }
    return normalized;
  }

  void setAdBlockFilterSets(Set<String> sets) {
    final normalized = _normalizeAdBlockProfiles(sets);
    if (_adBlockSetEquality.equals(adBlockFilterSets.value, normalized)) {
      return;
    }
    adBlockFilterSets.value = normalized;
    _saveState();
  }

  Future<void> _trackDownloadAd(DownloadTask task) async {
    if (isPremiumUnlocked) return;
    _downloadAdCount += 1;
    unawaited(_saveState());
    if (_downloadAdCount % 3 != 0) {
      unawaited(AdService.instance.ensureReady());
      return;
    }
    if (!_appInForeground) {
      unawaited(AdService.instance.ensureReady());
      return;
    }
    await AdService.instance.ensureReady();
    await AdService.instance.showInterstitial();
  }

  Future<bool> clearDownloadTasks({bool deleteFiles = false}) async {
    final tasks = [...downloads.value];
    if (tasks.isEmpty) {
      return false;
    }

    final completed = <DownloadTask>[];
    final failed = <DownloadTask>[];
    for (final t in tasks) {
      final state = t.state.toLowerCase();
      if (state == 'done') {
        completed.add(t);
      } else if (state == 'error') {
        failed.add(t);
      }
    }

    if (completed.isEmpty && failed.isEmpty) {
      return false;
    }

    if (completed.isNotEmpty) {
      await removeTasks(completed, deleteFiles: deleteFiles);
    }
    if (failed.isNotEmpty) {
      await removeTasks(failed, deleteFiles: true);
    }

    if (completed.isNotEmpty && !deleteFiles) {
      await importExistingFiles();
    }
    return true;
  }

  /// Remove all download tasks and their associated files. Uses [removeTasks]
  /// under the hood. This is useful for clearing the downloads list from the
  /// side drawer.
  Future<void> clearDownloads() async {
    await removeTasks([...downloads.value]);
  }

  /// Show the mini player overlay for the given file path and title. The
  /// overlay will remain visible until [closeMiniPlayer] is called. This
  /// method does not perform any navigation or UI changes; callers should
  /// listen to [miniPlayer] and display the appropriate UI.
  void openMiniPlayer(String path, String title, {Duration? startAt}) {
    miniPlayer.value = MiniPlayerData(
      path: path,
      title: title,
      startAt: startAt,
    );
  }

  /// Hide the mini player overlay. Clears any previously set mini player
  /// information.
  void closeMiniPlayer() {
    miniPlayer.value = null;
  }

  /// Update the mini player start position while it is visible.
  void updateMiniPlayerStartAt(Duration pos) {
    final cur = miniPlayer.value;
    if (cur == null) return;
    // Re‑emit with updated startAt so newly recreated mini player (or re‑init) seeks correctly.
    miniPlayer.value = MiniPlayerData(
      path: cur.path,
      title: cur.title,
      startAt: pos,
    );
  }

  /// Open mini player with an explicit resume position (sugar helper).
  void handoffToMini(String path, String title, Duration startAt) {
    openMiniPlayer(path, title, startAt: startAt);
  }

  /// Update the stored open tab URLs and immediately persist the change.
  /// This should be invoked by the browser whenever the list of tabs is
  /// modified (added, removed or navigated). By using this helper
  /// instead of directly assigning to [openTabs], consumers ensure that
  /// the state file is updated on disk and the notifier emits.
  void setOpenTabs(List<String> urls, {List<TabSessionState>? sessions}) {
    openTabs.value = List<String>.from(urls);
    if (sessions != null) {
      tabSessions.value = List<TabSessionState>.from(sessions);
    } else {
      tabSessions.value =
          urls
              .map(
                (url) => TabSessionState(
                  history: [url],
                  currentIndex: 0,
                  urlText: url,
                ),
              )
              .toList();
    }
    _saveState();
  }

  /// Signal that the browser should create a new blank tab. The UI layer
  /// listens to [pendingNewTab] and clears the notifier after handling the
  /// request, so each invocation here results in a single new tab.
  void requestNewTab() {
    pendingNewTab.value = Object();
  }

  // ---------------------------------------------------------------------------
  // Home screen management

  /// Add a new entry to the custom home page. The [url] should point to
  /// a valid web resource and [name] should be a short label. Both
  /// parameters are trimmed before use. After inserting the item the
  /// updated state is persisted to disk.
  String _normalizeHomeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) return trimmed;
    if (parsed.hasScheme && parsed.host.isNotEmpty) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) {
      final candidate = 'https:$trimmed';
      final uri = Uri.tryParse(candidate);
      return (uri != null && uri.host.isNotEmpty) ? candidate : trimmed;
    }
    final guess = Uri.tryParse('https://$trimmed');
    if (guess != null && guess.host.isNotEmpty) {
      return guess.toString();
    }
    return trimmed;
  }

  Future<Directory> _ensureHomeIconDirectory() async {
    if (_homeIconDirectory != null) {
      return _homeIconDirectory!;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'home_icons'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _homeIconDirectory = dir;
    return dir;
  }

  File _homeIconFileForHost(String host) {
    final normalized = host.toLowerCase();
    final hash = sha1.convert(utf8.encode(normalized)).toString();
    final dir = _homeIconDirectory;
    if (dir == null) {
      // Caller should ensure directory exists via _ensureHomeIconDirectory.
      throw StateError('Home icon directory not initialized');
    }
    return File(p.join(dir.path, '$hash.png'));
  }

  void _maybeDeleteOrphanedHomeIcon(String? path) {
    if (path == null || path.isEmpty) return;
    final stillUsed = homeItems.value.any((item) => item.iconPath == path);
    if (stillUsed) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  List<String> _faviconCandidatesForHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized.isEmpty) {
      return const <String>[];
    }
    return <String>[
      'https://$normalized/favicon.ico',
      'https://$normalized/apple-touch-icon.png',
      'https://$normalized/apple-touch-icon-precomposed.png',
      'https://$normalized/favicon.png',
      'https://www.google.com/s2/favicons?domain=$normalized&sz=128',
    ];
  }

  Future<void> _refreshHomeItemIcon(HomeItem item, {bool force = false}) async {
    Uri? uri;
    try {
      uri = Uri.tryParse(item.url);
    } catch (_) {
      uri = null;
    }
    final host = uri?.host ?? '';
    if (host.isEmpty) {
      if (item.iconPath != null) {
        item.iconPath = null;
        homeItems.value = List<HomeItem>.from(homeItems.value);
        notifyListeners();
        unawaited(_saveState());
      }
      return;
    }

    if (!force) {
      final current = item.iconPath;
      if (current != null && current.isNotEmpty) {
        final file = File(current);
        if (await file.exists()) {
          return;
        }
      }
    }

    final key = host.toLowerCase();
    if (_homeIconTasks.containsKey(key)) {
      await _homeIconTasks[key];
      return;
    }

    final task = () async {
      try {
        await _ensureHomeIconDirectory();
        final file = _homeIconFileForHost(host);
        final dio = _createDio();
        final candidates = _faviconCandidatesForHost(host);
        for (final url in candidates) {
          try {
            final resp = await dio.get<List<int>>(
              url,
              options: Options(
                responseType: ResponseType.bytes,
                followRedirects: true,
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
              ),
            );
            final data = resp.data;
            if (data == null || data.isEmpty) {
              continue;
            }
            await file.writeAsBytes(data, flush: true);
            if (item.iconPath != file.path) {
              item.iconPath = file.path;
              homeItems.value = List<HomeItem>.from(homeItems.value);
              notifyListeners();
              unawaited(_saveState());
            }
            return;
          } catch (_) {
            continue;
          }
        }
      } catch (_) {
        // ignore failures; fall back to text icon
      }
    }();

    _homeIconTasks[key] = task;
    try {
      await task;
    } finally {
      _homeIconTasks.remove(key);
    }
  }

  void _updateFaviconCacheEntry(String key, String? path) {
    final current = Map<String, String?>.from(faviconCache.value);
    if (path == null || path.isEmpty) {
      if (current.containsKey(key)) {
        current.remove(key);
        faviconCache.value = current;
      }
      return;
    }
    if (current[key] == path) {
      return;
    }
    current[key] = path;
    faviconCache.value = current;
  }

  Future<String?> ensureFaviconForUrl(String url) async {
    Uri? uri;
    try {
      uri = Uri.tryParse(url);
    } catch (_) {
      uri = null;
    }
    final host = uri?.host ?? '';
    if (host.isEmpty) {
      return null;
    }
    final key = host.toLowerCase();

    final cached = _faviconMemoryCache[key];
    if (cached != null) {
      if (cached.isEmpty) {
        return null;
      }
      final file = File(cached);
      if (await file.exists()) {
        return cached;
      }
      _faviconMemoryCache.remove(key);
      _updateFaviconCacheEntry(key, null);
    } else {
      try {
        await _ensureHomeIconDirectory();
        final file = _homeIconFileForHost(host);
        if (await file.exists()) {
          final path = file.path;
          _faviconMemoryCache[key] = path;
          _updateFaviconCacheEntry(key, path);
          return path;
        }
      } catch (_) {}
    }

    if (_faviconFetchTasks.containsKey(key)) {
      return await _faviconFetchTasks[key];
    }

    Future<String?> task() async {
      try {
        await _ensureHomeIconDirectory();
        final file = _homeIconFileForHost(host);
        final dio = _createDio();
        final candidates = _faviconCandidatesForHost(host);
        for (final candidate in candidates) {
          try {
            final resp = await dio.get<List<int>>(
              candidate,
              options: Options(
                responseType: ResponseType.bytes,
                followRedirects: true,
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
              ),
            );
            final data = resp.data;
            if (data == null || data.isEmpty) {
              continue;
            }
            await file.writeAsBytes(data, flush: true);
            final path = file.path;
            _faviconMemoryCache[key] = path;
            _updateFaviconCacheEntry(key, path);
            return path;
          } catch (_) {
            continue;
          }
        }
      } catch (_) {}
      _faviconMemoryCache[key] = '';
      return null;
    }

    final future = task();
    _faviconFetchTasks[key] = future;
    try {
      return await future;
    } finally {
      _faviconFetchTasks.remove(key);
    }
  }

  Future<void> refreshMissingHomeIcons() async {
    final items = homeItems.value;
    for (final item in items) {
      final path = item.iconPath;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        await _refreshHomeItemIcon(item);
      }
    }
  }

  void addHomeItem(String url, String name) {
    final u = _normalizeHomeUrl(url);
    final n = name.trim();
    if (u.isEmpty || n.isEmpty) return;
    if (hasReachedFreeHomeShortcutLimit) {
      return;
    }
    final item = HomeItem(url: u, name: n);
    final items = [...homeItems.value, item];
    homeItems.value = items;
    notifyListeners();
    setHomeTilesOrder([...homeTilesOrder.value, 'item:${item.id}']);
    // persist change asynchronously
    unawaited(_saveState());
    unawaited(_refreshHomeItemIcon(item));
  }

  /// Remove the home item at [index] if it exists. This will update
  /// listeners and persist the new state.
  void removeHomeItemAt(int index) {
    final items = [...homeItems.value];
    if (index < 0 || index >= items.length) return;
    final removed = items.removeAt(index);
    homeItems.value = items;
    notifyListeners();
    final updatedOrder =
        homeTilesOrder.value
            .where((id) => id != 'item:${removed.id}')
            .toList();
    setHomeTilesOrder(updatedOrder);
    unawaited(_saveState());
    _maybeDeleteOrphanedHomeIcon(removed.iconPath);
  }

  /// Update the item at [index] with new values. Pass null to leave a
  /// field unchanged. If [url] or [name] are empty strings the update
  /// will be ignored. After updating the item the state is persisted.
  void updateHomeItem(int index, {String? url, String? name}) {
    final items = [...homeItems.value];
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    final u = url?.trim();
    final n = name?.trim();
    var urlChanged = false;
    final oldIconPath = item.iconPath;
    if (u != null && u.isNotEmpty) {
      final normalized = _normalizeHomeUrl(u);
      if (normalized != item.url) {
        item.url = normalized;
        urlChanged = true;
      }
    }
    if (n != null && n.isNotEmpty) item.name = n;
    if (urlChanged) {
      item.iconPath = null;
      unawaited(_refreshHomeItemIcon(item, force: true));
    }
    homeItems.value = items;
    notifyListeners();
    unawaited(_saveState());
    if (urlChanged) {
      _maybeDeleteOrphanedHomeIcon(oldIconPath);
    }
  }

  /// Move an item from [oldIndex] to [newIndex] in the home list. If the
  /// indices are invalid or equal this method does nothing. Reordering
  /// automatically persists the new ordering and notifies listeners.
  void reorderHomeItems(int oldIndex, int newIndex) {
    final items = [...homeItems.value];
    if (oldIndex < 0 ||
        oldIndex >= items.length ||
        newIndex < 0 ||
        newIndex >= items.length)
      return;
    final item = items.removeAt(oldIndex);
    // When dragging to a lower index the removal shifts subsequent items
    // one position left; adjust the target index accordingly for insertion.
    if (newIndex > oldIndex) {
      newIndex--;
    }
    items.insert(newIndex, item);
    homeItems.value = items;
    notifyListeners();
    final merged = _applyItemOrderToTiles(homeTilesOrder.value, items);
    homeTilesOrder.value = merged;
    unawaited(_saveState());
  }

  /// Delete all files in the temporary cache directory. Does not remove
  /// downloaded media stored in the documents directory. Useful for cleaning
  /// up leftover thumbnails or temp files.
  Future<void> clearCache() async {
    final dir = await getTemporaryDirectory();
    try {
      final list = dir.list(recursive: true, followLinks: false);
      await for (final entity in list) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    await getCacheSize();
  }

  /// Format byte size with a consistent human-readable unit (2 decimals).
  String formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(2)} ${units[unit]}';
  }

  List<String> _normalizeHomeTilesOrder(
    List<String>? raw,
    List<HomeItem> items,
  ) {
    final seen = <String>{};
    final output = <String>[];
    final itemIds = {for (final item in items) item.id};
    if (raw != null) {
      for (final id in raw) {
        if (_defaultQuickTiles.contains(id) && seen.add(id)) {
          output.add(id);
          continue;
        }
        if (id.startsWith('item:')) {
          final itemId = id.substring('item:'.length);
          if (itemIds.contains(itemId) && seen.add(id)) {
            output.add(id);
          }
        }
      }
    }
    for (final id in _defaultQuickTiles) {
      if (seen.add(id)) {
        output.add(id);
      }
    }
    for (final item in items) {
      final id = 'item:${item.id}';
      if (seen.add(id)) {
        output.add(id);
      }
    }
    return output;
  }

  List<String> _applyItemOrderToTiles(
    List<String> order,
    List<HomeItem> items,
  ) {
    final itemIds = items.map((item) => 'item:${item.id}').toList();
    final updated = <String>[];
    var itemIndex = 0;
    for (final id in order) {
      if (_defaultQuickTiles.contains(id)) {
        updated.add(id);
        continue;
      }
      if (id.startsWith('item:')) {
        if (itemIndex < itemIds.length) {
          updated.add(itemIds[itemIndex]);
          itemIndex++;
        }
      }
    }
    for (final id in _defaultQuickTiles) {
      if (!updated.contains(id)) {
        updated.add(id);
      }
    }
    while (itemIndex < itemIds.length) {
      updated.add(itemIds[itemIndex]);
      itemIndex++;
    }
    return updated;
  }

  void _applyHomeItemsOrderFromTiles(List<String> order) {
    final byId = {for (final item in homeItems.value) item.id: item};
    final ordered = <HomeItem>[];
    for (final id in order) {
      if (!id.startsWith('item:')) continue;
      final itemId = id.substring('item:'.length);
      final item = byId.remove(itemId);
      if (item != null) {
        ordered.add(item);
      }
    }
    if (byId.isNotEmpty) {
      ordered.addAll(byId.values);
    }
    homeItems.value = ordered;
  }

  void setHomeTilesOrder(List<String> order) {
    final normalized = _normalizeHomeTilesOrder(order, homeItems.value);
    homeTilesOrder.value = normalized;
    _applyHomeItemsOrderFromTiles(normalized);
    notifyListeners();
    unawaited(_saveState());
  }

  Future<void> _purgeStaleFfmpegSessions() async {
    var mutated = false;

    if (_ffmpegSessions.isNotEmpty) {
      const activeStates = {
        SessionState.running,
        SessionState.created,
      };
      final entries = List<MapEntry<DownloadTask, int>>.from(
        _ffmpegSessions.entries,
      );
      for (final entry in entries) {
        final sessionId = entry.value;
        if (sessionId < 0) {
          // Placeholder while the native session id is being resolved; keep it.
          continue;
        }
        SessionState? state;
        try {
          final session = await FFmpegKitConfig.getSession(sessionId);
          state = await session?.getState();
        } catch (_) {
          // Unable to query the session (e.g. engine not ready yet). Treat as still active.
          continue;
        }
        if (state == null || activeStates.contains(state)) {
          continue;
        }

        final task = entry.key;
        _ffmpegSessions.remove(task);
        if (task.kind == 'yt-merge') {
          final key = _canonicalPath(task.savePath);
          final session = _ytMergeSessions[key];
          if (session != null) {
            session.merging = false;
            _persistYtSession(session);
          }
          task.extra?.remove('isConverting');
        } else if (task.kind == 'hls') {
          task.extra?.remove('hlsImageRunning');
          task.extra?.remove('isConverting');
        } else if (task.kind == 'dash') {
          task.extra?.remove('isConverting');
        }
        mutated = true;
      }
    }

    for (final task in downloads.value) {
      if (task.kind != 'hls') {
        continue;
      }
      final extra = task.extra;
      if (extra == null) {
        continue;
      }
      final bool flagRunning = extra['hlsImageRunning'] == true;
      final bool flagConverting = extra['isConverting'] == true;
      final bool hasOutput = _hlsActiveOutputs.containsKey(task);
      final bool hasSession = _ffmpegSessions.containsKey(task);
      if (flagRunning && !hasOutput && !hasSession) {
        extra.remove('hlsImageRunning');
        extra.remove('isConverting');
        mutated = true;
      } else if (flagConverting && !hasSession) {
        extra.remove('isConverting');
        mutated = true;
      }
    }

    if (mutated) {
      _notifyDownloadsUpdated();
      await _saveState();
    }
  }

  Future<void> _cleanupStaleProcessingOnLaunch() async {
    bool changed = false;
    for (final task in downloads.value) {
      final extra = task.extra;
      final isProcessing =
          task.state == 'processing' || extra?['isConverting'] == true;
      if (!isProcessing) continue;
      final exportPath = extra?['hlsExportPath'] as String?;
      if (exportPath != null && exportPath.isNotEmpty) {
        await cleanupTempExportPath(exportPath);
        extra?.remove('hlsExportPath');
      }
      extra?.remove('isConverting');
      task.state = 'error';
      task.paused = false;
      task.progressUnit = null;
      changed = true;
    }
    if (changed) {
      _notifyDownloadsUpdated();
      notifyListeners();
      await _saveState();
    }
  }

  bool _requiresForeground(DownloadTask task) {
    if (Platform.isIOS) {
      return false;
    }
    return task.kind == 'hls' || task.kind == 'dash' || task.kind == 'yt-direct';
  }

  Future<void> _markAwaitingForeground(DownloadTask task) async {
    (task.extra ??= {})['awaitingForeground'] = true;
    if (task.state != 'paused') {
      task.state = 'paused';
      task.paused = true;
      _notifyDownloadsUpdated();
      notifyListeners();
      await _saveState();
    }
  }

  Future<void> _pauseForegroundOnlyTasks() async {
    final tasks = List<DownloadTask>.from(downloads.value);
    for (final task in tasks) {
      if (!_requiresForeground(task)) continue;
      if (task.state != 'downloading') continue;
      (task.extra ??= {})['awaitingForeground'] = true;
      await pauseTask(task);
    }
  }

  Future<void> _resumeForegroundOnlyTasks() async {
    final tasks = List<DownloadTask>.from(downloads.value);
    for (final task in tasks) {
      final extra = task.extra;
      if (extra == null || extra['awaitingForeground'] != true) {
        continue;
      }
      extra.remove('awaitingForeground');
      if (_requiresForeground(task)) {
        await resumeTask(task);
      }
    }
    _checkPendingYtMerges();
  }

  Future<void> _resumeHlsMergesIfReady() async {
    if (!Platform.isIOS) return;
    final tasks = List<DownloadTask>.from(downloads.value);
    for (final task in tasks) {
      if (task.kind != 'hls') continue;
      if (task.extra?[_hlsBgReadyKey] == true) {
        await _runTaskHlsMergeFromLocal(task);
      }
    }
  }

  Future<void> _resumeDashMergesIfReady() async {
    if (!Platform.isIOS) return;
    final tasks = List<DownloadTask>.from(downloads.value);
    for (final task in tasks) {
      if (task.kind != 'dash') continue;
      if (task.extra?[_dashBgReadyKey] == true) {
        await _runTaskDashMergeFromLocal(task);
      }
    }
  }

  /// Resume downloads that were interrupted by an app restart. Tasks that were
  /// previously paused remain paused. Tasks that were still queued will be
  /// started and tasks that were mid-download will continue from where they
  /// left off when possible.
  Future<void> resumeIncompleteDownloads() async {
    try {
      await _bgDownloader.ready;
    } catch (_) {}
    await _purgeStaleFfmpegSessions();
    final tasks = List<DownloadTask>.from(downloads.value);
    for (final task in tasks) {
      if (task.state == 'paused' || task.paused) {
        task.paused = true;
        task.state = 'paused';
        continue;
      }
      if (task.state == 'error') {
        unawaited(_reconcileTaskIfCompletedFileExists(task));
        continue;
      }
      if (task.state == 'queued') {
        unawaited(_runTask(task));
      } else if (task.state == 'downloading') {
        task.paused = false;
        if (task.kind == 'file') {
          unawaited(_runTaskFile(task, resume: true));
        } else if (task.kind == 'dash') {
          unawaited(_runTaskDash(task));
        } else if (task.kind == 'yt-direct') {
          unawaited(_runTaskYoutubeDirect(task));
        } else if (task.kind == 'yt-merge') {
          unawaited(_runTaskYoutubeMerge(task));
        } else {
          unawaited(_runTaskHls(task));
        }
      }
    }
    if (_appInForeground) {
      unawaited(_resumeForegroundOnlyTasks());
    }
  }

  final ValueNotifier<bool> snifferEnabled = ValueNotifier(true);
  final ValueNotifier<bool> longPressDetectionEnabled = ValueNotifier(true);

  /// Candidates detected from long-pressing actively playing videos.
  final ValueNotifier<List<PlayingVideoCandidate>> playingVideos =
      ValueNotifier<List<PlayingVideoCandidate>>([]);

  /// Detected media hits from the browser. Updated by the WebView sniffer.
  final ValueNotifier<List<MediaHit>> hits = ValueNotifier([]);

  /// All download tasks tracked by the app. Persisted across restarts.
  final ValueNotifier<List<DownloadTask>> downloads = ValueNotifier([]);

  /// Custom folders used to organise download tasks on the media page.
  final ValueNotifier<List<MediaFolder>> mediaFolders =
      ValueNotifier<List<MediaFolder>>([]);

  /// List of favourited page URLs. Persisted across restarts.
  final ValueNotifier<List<String>> favorites = ValueNotifier([]);

  /// Whether downloaded files should automatically be saved to the device photo gallery.
  final ValueNotifier<bool> autoSave = ValueNotifier(true);
  final ValueNotifier<bool> downloadNotificationsEnabled = ValueNotifier(true);

  /// Browsing history entries. Each time a page finishes loading, a new entry
  /// will be appended here. The list is persisted across restarts.
  final ValueNotifier<List<HistoryEntry>> history = ValueNotifier([]);

  /// Whether pop‑up windows (new windows triggered via window.open or target=_blank)
  /// should be blocked. When true, new window requests will be suppressed and
  /// the URL will open in the same tab. When false, the new window will be
  /// allowed (which in WebView opens within the same WebView instance).
  final ValueNotifier<bool> blockPopup = ValueNotifier(false);

  /// Whether the built-in Adblocker (content blockers) is enabled for WebView.
  final ValueNotifier<bool> adBlockEnabled = ValueNotifier(false);

  /// Live cache size (bytes). Updated by [getCacheSize] and [clearCache].
  final ValueNotifier<int> cacheSizeBytes = ValueNotifier<int>(-1);

  /// Selected Adblocker rule profiles applied when the blocker is enabled.
  /// Defaults to the "plus" ruleset for broader coverage and can be customised
  /// by the user from the browser menu.
  final ValueNotifier<Set<String>> adBlockFilterSets =
      ValueNotifier<Set<String>>({'plus'});

  /// Data for the global mini player overlay. When non‑null, the root widget
  /// should display a floating mini player allowing background playback.
  final ValueNotifier<MiniPlayerData?> miniPlayer = ValueNotifier(null);

  /// Mini player dock position: 'top' | 'middle' | 'bottom'. The root view
  /// listens to this to place the mini player overlay for better ergonomics
  /// on tablets. Defaults to bottom.
  final ValueNotifier<String> miniDock = ValueNotifier<String>('bottom');

  /// Mini player free position in pixels relative to the screen (left, top).
  /// When set to non-zero, overrides [miniDock] and allows the user to place
  /// the mini player like iOS 的小白點。由 UI 寫入此值；app 重建時沿用。
  final ValueNotifier<Offset> miniOffset = ValueNotifier<Offset>(Offset.zero);

  /// A list of home screen shortcuts created by the user. These entries
  /// appear on the custom home page in the browser. Each item holds a URL
  /// and a user defined name. The order of items in this list is
  /// significant and can be changed by dragging items in the UI.
  final ValueNotifier<List<HomeItem>> homeItems = ValueNotifier<List<HomeItem>>(
    [],
  );

  /// Persisted list of currently open browser tab URLs. Each string is the
  /// URL loaded in an open tab. When the app is restarted the
  /// [BrowserPage] reads this list and recreates tabs for each entry.
  /// Keeping this state here allows the user’s open pages to be restored
  /// across app launches rather than always starting with a single blank tab.
  final ValueNotifier<List<String>> openTabs = ValueNotifier<List<String>>([]);

  /// Persisted per-tab sessions including navigation history so back/forward
  /// stacks survive application restarts.
  final ValueNotifier<List<TabSessionState>> tabSessions =
      ValueNotifier<List<TabSessionState>>([]);

  /// A transient notifier used to request the browser page to create a new
  /// blank tab. The value is set to a new object for each request so listeners
  /// can react even if a previous request is still pending.
  final ValueNotifier<Object?> pendingNewTab = ValueNotifier<Object?>(null);

  /// A transient notifier used to communicate a URL from the home page to the
  /// browser. When a value is set, the browser page should load the URL
  /// and then reset this notifier back to null. This allows decoupled
  /// navigation between pages in the root navigation.
  final ValueNotifier<String?> pendingOpenUrl = ValueNotifier<String?>(null);

  /// A transient notifier used to request the browser page to open the
  /// downloads sheet. A new object is assigned for each request.
  final ValueNotifier<Object?> pendingOpenDownloadsSheet =
      ValueNotifier<Object?>(null);

  /// A transient notifier used to request the browser page to open the
  /// favorites page (web favorites, not media).
  final ValueNotifier<Object?> pendingOpenFavoritesPage =
      ValueNotifier<Object?>(null);

  /// A transient notifier used to request the browser page to open the
  /// browsing history page.
  final ValueNotifier<Object?> pendingOpenHistoryPage =
      ValueNotifier<Object?>(null);

  /// A transient notifier used to request the browser page to open the
  /// tab manager.
  final ValueNotifier<Object?> pendingOpenTabManager =
      ValueNotifier<Object?>(null);

  static const List<String> _defaultQuickTiles = [
    'quick.settings',
    'quick.favorites',
    'quick.downloads',
    'quick.add_download',
    'quick.media',
    'quick.tabs',
    'quick.history',
    'quick.clear_cache',
  ];

  /// Persisted order of home tiles (quick actions + user shortcuts).
  final ValueNotifier<List<String>> homeTilesOrder =
      ValueNotifier<List<String>>(List<String>.from(_defaultQuickTiles));


  /// Active FFmpeg session ids for HLS downloads (hls kind).
  final Map<DownloadTask, int> _ffmpegSessions = {};

  /// Tasks currently bootstrapping an HLS conversion/download. Prevents
  /// lifecycle resume race conditions from spawning duplicate workers.
  final Set<DownloadTask> _hlsBootstrapTasks = <DownloadTask>{};

  /// Tracks the active output file path for HLS conversions. When a conversion
  /// is resumed we write to a temporary chunk; this map lets progress probes
  /// read the correct file instead of the final destination.
  final Map<DownloadTask, String> _hlsActiveOutputs = {};

  /// Directory containing cached favicons for home shortcuts.
  Directory? _homeIconDirectory;

  /// In-flight favicon download tasks keyed by host. Prevents duplicate
  /// network requests when multiple widgets request the same favicon.
  final Map<String, Future<void>> _homeIconTasks = {};

  /// Cached favicon paths accessible across the app (e.g. history list).
  final ValueNotifier<Map<String, String?>> faviconCache =
      ValueNotifier<Map<String, String?>>({});

  /// In-memory cache of resolved favicon file paths keyed by host.
  final Map<String, String?> _faviconMemoryCache = {};

  /// In-flight favicon fetch operations keyed by host to avoid duplicate downloads.
  final Map<String, Future<String?>> _faviconFetchTasks = {};

  /// Path to the JSON file used to persist app state (tasks, favourites, settings).
  late String _stateFilePath;

  void setSnifferEnabled(bool on) {
    final effective = isPremiumUnlocked ? on : false;
    if (snifferEnabled.value == effective) return;
    snifferEnabled.value = effective;
    notifyListeners();
  }

  void setLongPressDetectionEnabled(bool on) {
    if (longPressDetectionEnabled.value == on) {
      return;
    }
    longPressDetectionEnabled.value = on;
    if (!on && playingVideos.value.isNotEmpty) {
      playingVideos.value = [];
    }
    notifyListeners();
  }

  void upsertPlayingVideo(PlayingVideoCandidate candidate) {
    final list = [...playingVideos.value];
    final index = list.indexWhere((element) => element.id == candidate.id);
    if (index >= 0) {
      list[index] = candidate;
    } else {
      list.insert(0, candidate);
    }
    const maxEntries = 8;
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    playingVideos.value = list;
  }

  void clearPlayingVideos() {
    if (playingVideos.value.isEmpty) {
      return;
    }
    playingVideos.value = [];
  }

  void removePlayingVideo(String id) {
    if (id.isEmpty) {
      return;
    }
    final list = playingVideos.value;
    if (list.isEmpty) {
      return;
    }
    final next = list
        .where((candidate) => candidate.id != id)
        .toList(growable: false);
    if (next.length == list.length) {
      return;
    }
    playingVideos.value = List<PlayingVideoCandidate>.from(next);
  }

  /// Adds a media hit or merges if URL already exists.

  String _normalizeHitType(String url, String rawType, String contentType) {
    final lowerType = (rawType.isEmpty ? '' : rawType.toLowerCase());
    final lowerCt = contentType.toLowerCase();
    if (lowerCt.startsWith('image/')) return 'image';
    if (lowerCt.startsWith('audio/')) return 'audio';
    if (lowerCt.startsWith('video/')) return 'video';
    if (lowerType == 'image' || lowerType == 'audio' || lowerType == 'video') {
      return lowerType;
    }
    final inferred = _inferType(url);
    if (inferred != 'file') return inferred;
    return lowerType.isNotEmpty ? lowerType : 'video';
  }

  String _mergeHitType(String existing, String incoming) {
    if (existing == incoming) return existing;
    final priority = {'video': 1, 'audio': 2, 'image': 3};
    final currentScore = priority[existing] ?? 0;
    final incomingScore = priority[incoming] ?? 0;
    return incomingScore >= currentScore ? incoming : existing;
  }

  void addHit(MediaHit h, {bool storeInHits = true}) {
    final normalizedType = _normalizeHitType(h.url, h.type, h.contentType);
    final normalizedHit = h.copyWith(type: normalizedType);
    MediaHit effectiveHit = normalizedHit;
    if (storeInHits) {
      final list = [...hits.value];
      final idx = list.indexWhere((e) => e.url == normalizedHit.url);
      if (idx >= 0) {
        final cur = list[idx];
        final mergedType = _mergeHitType(cur.type, normalizedType);
        final mergedContentType =
            cur.contentType.isNotEmpty
                ? cur.contentType
                : normalizedHit.contentType;
        final mergedPoster =
            cur.poster.isNotEmpty ? cur.poster : normalizedHit.poster;
        final mergedDuration =
            cur.durationSeconds ?? normalizedHit.durationSeconds;
        effectiveHit = cur.copyWith(
          type: mergedType,
          contentType: mergedContentType,
          poster: mergedPoster,
          durationSeconds: mergedDuration,
        );
        list[idx] = effectiveHit;
      } else {
        list.add(normalizedHit);
        effectiveHit = normalizedHit;
      }
      hits.value = list;
    }

    if (longPressDetectionEnabled.value &&
        (effectiveHit.type == 'video' || effectiveHit.type == 'audio')) {
      final pageUrl = currentPageUrl.value ?? '';
      final mediaUrl = effectiveHit.url.trim();
      if (pageUrl.isNotEmpty && mediaUrl.isNotEmpty) {
        final idSource = '$pageUrl::$mediaUrl';
        final id = sha1.convert(utf8.encode(idSource)).toString();
        final poster = effectiveHit.poster.trim();
        String _deriveCandidateTitle() {
          final pageTitle = currentPageTitle.value?.trim();
          if (pageTitle != null && pageTitle.isNotEmpty) {
            return pageTitle;
          }
          try {
            final uri = Uri.parse(mediaUrl);
            final segments =
                uri.pathSegments.where((s) => s.isNotEmpty).toList();
            if (segments.isNotEmpty) {
              return segments.last;
            }
          } catch (_) {}
          return mediaUrl;
        }

        upsertPlayingVideo(
          PlayingVideoCandidate(
            id: id,
            url: mediaUrl,
            pageUrl: pageUrl,
            title: _deriveCandidateTitle(),
            durationSeconds: effectiveHit.durationSeconds,
            positionSeconds: null,
            videoWidth: null,
            videoHeight: null,
            snapshot: null,
            posterUrl: poster.isNotEmpty ? poster : null,
            detectedAt: DateTime.now(),
          ),
        );
      }
    }
  }

  /// Creates a unique file path in the persistent downloads directory with
  /// the given extension. Files stored here will survive app restarts and
  /// will show up in the iOS Files app. A subfolder is created on demand.
  String _sanitizeDownloadStem(String input) {
    var sanitized =
        input
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
            .replaceAll(RegExp(r'[\s\n\r]+'), ' ')
            .trim();
    sanitized = sanitized.replaceAll(RegExp(r'[\u0000-\u001F]'), '');
    if (sanitized.length > 120) {
      sanitized = sanitized.substring(0, 120).trim();
    }
    if (sanitized.isEmpty) {
      sanitized = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }
    return sanitized;
  }

  String? _preferredDownloadStem({required String url}) {
    final candidates = <String?>[
      ytTitle.value?.trim(),
      currentPageTitle.value?.trim(),
    ];
    for (final candidate in candidates) {
      if (candidate != null && candidate.isNotEmpty) {
        return _sanitizeDownloadStem(candidate);
      }
    }
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) {
        final last = segments.last;
        final dot = last.lastIndexOf('.');
        final stem = dot > 0 ? last.substring(0, dot) : last;
        if (stem.trim().isNotEmpty) {
          return _sanitizeDownloadStem(stem);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _tempFilePath(String ext, {String? suggestedName}) async {
    final docs = await getApplicationDocumentsDirectory();
    final downloadDir = Directory('${docs.path}/downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    final stem =
        (suggestedName != null && suggestedName.trim().isNotEmpty)
            ? _sanitizeDownloadStem(suggestedName)
            : 'download_${DateTime.now().millisecondsSinceEpoch}';
    var candidate = '$stem.$ext';
    var path = p.join(downloadDir.path, candidate);
    var index = 1;
    while (await File(path).exists()) {
      candidate = '$stem ($index).$ext';
      path = p.join(downloadDir.path, candidate);
      index += 1;
    }
    return _canonicalPath(path);
  }

  Future<String> _tempExportPath(String ext, {String? suggestedName}) async {
    final dir = await getTemporaryDirectory();
    final stem =
        (suggestedName != null && suggestedName.trim().isNotEmpty)
            ? _sanitizeDownloadStem(suggestedName)
            : 'export_${DateTime.now().millisecondsSinceEpoch}';
    var candidate = '$stem.$ext';
    var path = p.join(dir.path, candidate);
    var index = 1;
    while (await File(path).exists()) {
      candidate = '$stem ($index).$ext';
      path = p.join(dir.path, candidate);
      index += 1;
    }
    return _canonicalPath(path);
  }

  Future<void> cleanupTempExportPath(String path) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final canonical = _canonicalPath(path);
      if (!canonical.startsWith(tempDir.path)) {
        return;
      }
      await _deletePathIfExists(canonical);
    } catch (_) {}
  }

  /// Requests permission to save media to gallery. Throws if denied.
  Future<void> requestGalleryPerm() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) {
      throw Exception(
        LanguageService.instance.translate('media.error.photoPermissionDenied'),
      );
    }
  }

  /// Saves a file at [path] to the user's photo gallery.
  Future<void> saveFileToGallery(String path) async {
    await requestGalleryPerm();
    await ImageGallerySaver.saveFile(path, isReturnPathOfIOS: true);
  }

  bool _isNativeHlsOfflinePath(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('.movpkg')) {
      return true;
    }
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        return lower.endsWith('.movpkg');
      }
    } catch (_) {}
    return false;
  }

  Future<int?> _nativeDurationForPath(String path) async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _playerChannel.invokeMapMethod<String, dynamic>(
        'metadataForFile',
        {'path': path},
      );
      if (result == null) return null;
      final raw = result['durationMs'];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
    } catch (_) {}
    return null;
  }

  Future<Uint8List?> _nativePreviewForPath(
    String path, {
    required int positionMs,
    double maxWidth = 320,
  }) async {
    if (!Platform.isIOS) return null;
    try {
      return await _playerChannel.invokeMethod<Uint8List>(
        'previewFileAt',
        {
          'path': path,
          'positionMs': positionMs,
          'maxWidth': maxWidth,
        },
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _exportOfflineHlsToMp4(
    String sourcePath, {
    String? suggestedName,
  }) async {
    if (!Platform.isIOS) return sourcePath;
    final output = await _tempExportPath('mp4', suggestedName: suggestedName);
    try {
      final result = await _hlsNativeChannel.invokeMethod<String>(
        'exportOffline',
        {
          'sourcePath': sourcePath,
          'destinationPath': output,
        },
      );
      return result ?? output;
    } catch (_) {
      final task = _downloadTaskForKey(sourcePath);
      final hlsUrl =
          (task?.extra?['hlsSourceUrl'] as String?) ??
          (task?.url.toLowerCase().contains('.m3u8') == true ? task!.url : null);
      if (hlsUrl == null || hlsUrl.isEmpty) {
        rethrow;
      }
      final h = await _headersFor(hlsUrl);
      final ua = (h['User-Agent'] ?? '').replaceAll("'", "\'");
      final ref = (h['Referer'] ?? '').replaceAll("'", "\'");
      final ck = (h['Cookie'] ?? '').replaceAll("'", "\'");
      final headerLines = [
        if (ref.isNotEmpty) 'Referer: $ref',
        if (ck.isNotEmpty) 'Cookie: $ck',
      ].join('\\r\\n');
      final headerArg =
          headerLines.isNotEmpty ? "-headers '${headerLines}\\r\\n'" : '';
      final uaArg = ua.isNotEmpty ? "-user_agent '${ua}'" : '';
      final cmd =
          "-y $uaArg $headerArg -i '$hlsUrl' -map 0:v:0? -map 0:a:0? -c copy -movflags +faststart -bsf:a aac_adtstoasc '$output'";
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        return output;
      }
      throw Exception('ffmpeg export failed');
    }
  }

  Future<String> _exportOfflineHlsToMp4ToPath(
    String sourcePath,
    String outputPath, {
    String? suggestedName,
  }) async {
    if (!Platform.isIOS) return sourcePath;
    try {
      final result = await _hlsNativeChannel.invokeMethod<String>(
        'exportOffline',
        {
          'sourcePath': sourcePath,
          'destinationPath': outputPath,
        },
      );
      return result ?? outputPath;
    } catch (_) {
      final task = _downloadTaskForKey(sourcePath);
      final hlsUrl =
          (task?.extra?['hlsSourceUrl'] as String?) ??
          (task?.url.toLowerCase().contains('.m3u8') == true ? task!.url : null);
      if (hlsUrl == null || hlsUrl.isEmpty) {
        rethrow;
      }
      final h = await _headersFor(hlsUrl);
      final ua = (h['User-Agent'] ?? '').replaceAll("'", "\'");
      final ref = (h['Referer'] ?? '').replaceAll("'", "\'");
      final ck = (h['Cookie'] ?? '').replaceAll("'", "\'");
      final headerLines = [
        if (ref.isNotEmpty) 'Referer: $ref',
        if (ck.isNotEmpty) 'Cookie: $ck',
      ].join('\\r\\n');
      final headerArg =
          headerLines.isNotEmpty ? "-headers '${headerLines}\\r\\n'" : '';
      final uaArg = ua.isNotEmpty ? "-user_agent '${ua}'" : '';
      final cmd =
          "-y $uaArg $headerArg -i '$hlsUrl' -map 0:v:0? -map 0:a:0? -c copy -movflags +faststart -bsf:a aac_adtstoasc '$outputPath'";
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        return outputPath;
      }
      throw Exception('ffmpeg export failed');
    }
  }

  Future<void> _convertNativeHlsToMp4(DownloadTask task) async {
    if (!Platform.isIOS) return;
    final sourcePath = task.savePath;
    final sourceName = task.name?.trim();
    final suggestedName =
        (sourceName != null && sourceName.isNotEmpty)
            ? sourceName
            : p.basenameWithoutExtension(sourcePath);
    final outputPath = await _tempExportPath(
      'mp4',
      suggestedName: suggestedName,
    );
    int totalBytes = 0;
    try {
      final type = await FileSystemEntity.type(sourcePath);
      if (type == FileSystemEntityType.directory) {
        totalBytes = await _directorySize(Directory(sourcePath));
      } else if (type == FileSystemEntityType.file) {
        totalBytes = await File(sourcePath).length();
      }
    } catch (_) {}
    if (totalBytes <= 0) totalBytes = 1;
    (task.extra ??= {})['isConverting'] = true;
    task.extra?['hlsExportPath'] = outputPath;
    task.state = 'processing';
    task.progressUnit = 'bytes';
    task.total = totalBytes;
    task.received = 0;
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveState();
    Timer? poller;
    poller = Timer.periodic(const Duration(seconds: 1), (_) {
      try {
        final outFile = File(outputPath);
        if (outFile.existsSync()) {
          final size = outFile.lengthSync();
          task.received = size.clamp(0, totalBytes);
          _notifyDownloadsUpdated();
          notifyListeners();
        }
      } catch (_) {}
    });
    try {
      final resultPath = await _exportOfflineHlsToMp4ToPath(
        sourcePath,
        outputPath,
        suggestedName: suggestedName,
      );
      if (!_pathExistsSync(resultPath)) {
        throw Exception('mp4 export missing output');
      }
      final normalized = _canonicalPath(resultPath);
      task.savePath = normalized;
      task.extra?.remove(_hlsNativeOfflineKey);
      task.extra?.remove('isConverting');
      task.extra?.remove('hlsExportPath');
      try {
        final length = await File(normalized).length();
        task.total = length;
        task.received = length;
      } catch (_) {}
      task.state = 'done';
      task.paused = false;
      task.progressUnit = null;
      _normalizeTaskType(task);
      _notifyDownloadsUpdated();
      notifyListeners();
      await _generatePreview(task);
      if (autoSave.value) {
        unawaited(saveFileToGallery(task.savePath));
      }
      if (_canonicalPath(sourcePath) != normalized) {
        unawaited(_deletePathIfExists(sourcePath));
      }
      unawaited(_cleanupTaskResiduals(task));
      await _saveState();
    } catch (_) {
      task.extra?.remove('isConverting');
      task.extra?.remove('hlsExportPath');
      task.state = 'error';
      task.paused = false;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadFailed(task);
      await _saveState();
    } finally {
      poller?.cancel();
    }
  }

  Future<String> ensureEditableMediaPath(
    String sourcePath, {
    String? suggestedName,
  }) async {
    if (Platform.isIOS && _isNativeHlsOfflinePath(sourcePath)) {
      return _exportOfflineHlsToMp4(
        sourcePath,
        suggestedName: suggestedName,
      );
    }
    return sourcePath;
  }

  Future<List<String>> _resolveShareablePaths(
    List<String> paths, {
    List<String>? cleanupTargets,
  }) async {
    if (!Platform.isIOS) return paths;
    final resolved = <String>[];
    for (final path in paths) {
      if (_isNativeHlsOfflinePath(path)) {
        final suggested = p.basenameWithoutExtension(path);
        final exported = await _exportOfflineHlsToMp4(
          path,
          suggestedName: suggested,
        );
        resolved.add(exported);
        cleanupTargets?.add(exported);
      } else {
        resolved.add(path);
      }
    }
    return resolved;
  }

  /// Shares a file via share_plus. Falls back to copying files into a
  /// temporary share-safe location on iOS when the system refuses to open
  /// files from the app's Documents directory directly.
  Future<void> shareFile(String path) async {
    await sharePaths([path]);
  }

  /// Shares multiple files. When iOS refuses to load files from the Documents
  /// directory (observed on some devices when file names contain certain
  /// characters), this method copies them to the temporary directory with a
  /// sanitized ASCII name before invoking the share sheet.
  Future<void> sharePaths(List<String> paths, {Rect? shareOrigin}) async {
    if (paths.isEmpty) {
      throw Exception('No files to share');
    }
    final normalized = paths.map(_canonicalPath).toList();
    final exportCleanup = <String>[];
    final shareable = await _resolveShareablePaths(
      normalized,
      cleanupTargets: exportCleanup,
    );
    final primary = await _prepareShareFiles(shareable, copyToTemp: false);
    if (primary.isEmpty) {
      throw Exception('No files to share');
    }
    final origin = _resolveShareOrigin(shareOrigin);
    try {
      await Share.shareXFiles(primary, sharePositionOrigin: origin);
      return;
    } catch (error, stack) {
      debugPrint('[Share] Primary share failed: $error\n$stack');
      if (!Platform.isIOS) {
        rethrow;
      }
      final cleanup = <String>[];
      try {
        final fallback = await _prepareShareFiles(
          shareable,
          copyToTemp: true,
          cleanupTargets: cleanup,
        );
        if (fallback.isEmpty) {
          throw error;
        }
        await Share.shareXFiles(fallback, sharePositionOrigin: origin);
      } catch (fallbackErr, fallbackStack) {
        debugPrint(
          '[Share] Fallback share failed: $fallbackErr\n$fallbackStack',
        );
        rethrow;
      } finally {
        for (final tempPath in cleanup) {
          try {
            final tempFile = File(tempPath);
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          } catch (_) {}
        }
      }
    } finally {
      for (final tempPath in exportCleanup) {
        try {
          final tempFile = File(tempPath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    }
  }

  Rect? _resolveShareOrigin(Rect? requested) {
    if (!Platform.isIOS) {
      return requested;
    }
    if (requested != null) {
      if (requested.width > 0 && requested.height > 0) {
        return requested;
      }
    }
    try {
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      if (dispatcher.views.isEmpty) {
        return null;
      }
      final view = dispatcher.views.first;
      final size = view.physicalSize;
      final dpr = view.devicePixelRatio;
      if (dpr <= 0) {
        return null;
      }
      final width = size.width / dpr;
      final height = size.height / dpr;
      if (width <= 0 || height <= 0) {
        return null;
      }
      return Rect.fromLTWH(0, 0, width, height);
    } catch (_) {
      return null;
    }
  }

  String? _shareMimeTypeForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mov':
        return 'video/quicktime';
      case '.webm':
        return 'video/webm';
      case '.mkv':
        return 'video/x-matroska';
      case '.ts':
        return 'video/mp2t';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      case '.aac':
        return 'audio/aac';
      case '.wav':
        return 'audio/wav';
      case '.flac':
        return 'audio/flac';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.bmp':
        return 'image/bmp';
      case '.webp':
        return 'image/webp';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      case '.zip':
        return 'application/zip';
      default:
        return null;
    }
  }

  String _safeShareFileName(String original) {
    final micro = DateTime.now().microsecondsSinceEpoch;
    final rawStem = p.basenameWithoutExtension(original).trim();
    final sanitizedStem = rawStem.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final stem = sanitizedStem.isNotEmpty ? sanitizedStem : 'share_$micro';
    final rawExt = p.extension(original);
    final normalizedExt = rawExt.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final ext =
        normalizedExt.isNotEmpty ? '.${normalizedExt.toLowerCase()}' : '.bin';
    return '$stem$ext';
  }

  Future<File> _createTemporaryShareCopy(
    File source,
    String displayName,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = _safeShareFileName(displayName);
    final tempPath = p.join(
      tempDir.path,
      'share_${DateTime.now().microsecondsSinceEpoch}_$safeName',
    );
    return source.copy(tempPath);
  }

  Future<List<XFile>> _prepareShareFiles(
    List<String> paths, {
    required bool copyToTemp,
    List<String>? cleanupTargets,
  }) async {
    final List<XFile> files = [];
    for (final original in paths) {
      final canonical = _canonicalPath(original);
      try {
        final file = File(canonical);
        if (!await file.exists()) {
          debugPrint('[Share] Skipping missing file $canonical');
          continue;
        }
        final displayName = p.basename(canonical);
        final mimeType = _shareMimeTypeForPath(displayName);
        if (copyToTemp) {
          final copy = await _createTemporaryShareCopy(file, displayName);
          cleanupTargets?.add(copy.path);
          files.add(XFile(copy.path, name: displayName, mimeType: mimeType));
        } else {
          files.add(XFile(file.path, name: displayName, mimeType: mimeType));
        }
      } catch (err, stack) {
        debugPrint('[Share] Failed to prepare $original: $err\n$stack');
      }
    }
    return files;
  }

  /// Enqueue a new download task for the given URL. Infers the type
  /// (video/audio/image/file) based on the URL extension, determines
  /// whether the URL is an HLS playlist, allocates a persistent output
  /// path and starts the download. The task list is immediately updated
  /// and persisted. Robust: always adds a task even on errors.
  Future<DownloadTask> enqueueDownload(
    String url, {
    bool skipYoutubeHandling = false,
    String? suggestedName,
  }) async {
    final originalUrl = url;
    try {
      if (!skipYoutubeHandling && _isYouTubeUrl(url)) {
        try {
          final info = await _collectYtVideoInfo(url);
          if (info.hlsManifestUrl != null) {
            final hlsUrl = info.hlsManifestUrl!;
            final ytExtra = <String, dynamic>{
              'yt': {
                'sourceUrl': url,
                'videoId': info.videoId,
                'hlsManifestUrl': hlsUrl,
              },
            };
            return await _enqueueDirectTask(
              hlsUrl,
              suggestedName: info.title,
              explicitType: 'video',
              kindOverride: 'hls',
              extra: ytExtra,
            );
          }
          final defaultOption = _pickDefaultYtOption(info.options);
          if (defaultOption != null) {
            return await enqueueYoutubeOption(
              defaultOption,
              sourceUrl: url,
              titleOverride: info.title,
            );
          }
        } catch (e) {
          if (kDebugMode) print('YouTube options fetch error: $e');
        }
      }

      return await _enqueueDirectTask(url, suggestedName: suggestedName);
    } catch (e, st) {
      if (kDebugMode) {
        print('enqueueDownload fatal: $e');
        print(st);
      }
      final out = await _tempFilePath('bin');
      final task = DownloadTask(
        url: originalUrl,
        savePath: out,
        kind: 'file',
        type: _inferType(originalUrl),
        state: 'error',
        name: LanguageService.instance.translate(
          'download.error.enqueueFailed',
          params: {'error': '${e.runtimeType}'},
        ),
      );
      downloads.value = [...downloads.value, task];
      await _saveState();
      notifyListeners();
      return task;
    }
  }

  _DownloadPlan _resolveDownloadPlan({
    required String url,
    String? suggestedName,
    String? forcedExtension,
    String? explicitType,
    String? kindOverride,
  }) {
    final lower0 = url.toLowerCase();
    final bool isHls = lower0.contains('.m3u8');
    final bool isDash = lower0.contains('.mpd');
    final kind = kindOverride ?? (isHls ? 'hls' : (isDash ? 'dash' : 'file'));
    final innerUrl = _extractInnerUrl(url) ?? url;
    final type = explicitType ?? _inferType(innerUrl);

    var ext =
        forcedExtension ??
        ((isHls || isDash) ? 'mp4' : _extensionFromUrl(innerUrl));
    if (Platform.isIOS && kind == 'hls') {
      ext = forcedExtension ?? 'movpkg';
    }
    if (ext.isEmpty || ext == 'bin') {
      ext = forcedExtension ?? _defaultExtensionForType(type);
    }

    final stem =
        _preferredDownloadStem(url: innerUrl) ??
        _preferredDownloadStem(url: url);
    final suggested =
        suggestedName ?? stem ?? ytTitle.value ?? currentPageTitle.value;
    return _DownloadPlan(
      url: url,
      kind: kind,
      type: type,
      extension: ext,
      suggestedName: suggested,
    );
  }

  Future<DownloadTask> _enqueueDirectTask(
    String initialUrl, {
    String? suggestedName,
    String? forcedExtension,
    String? explicitType,
    String? kindOverride,
    Map<String, dynamic>? extra,
  }) async {
    var url = initialUrl;

    if (_isBlobUrl(url)) {
      final resolved = await _resolveRealMediaFromHits(url);
      if (resolved != null) {
        url = resolved;
      } else {
        final out = await _tempFilePath('bin');
        final task = DownloadTask(
          url: url,
          savePath: out,
          kind: kindOverride ?? 'file',
          type: 'video',
          state: 'error',
          name: LanguageService.instance.translate('download.error.playFirst'),
        );
        downloads.value = [...downloads.value, task];
        await _saveState();
        notifyListeners();
        return task;
      }
    }

    final plan = _resolveDownloadPlan(
      url: url,
      suggestedName: suggestedName,
      forcedExtension: forcedExtension,
      explicitType: explicitType,
      kindOverride: kindOverride,
    );
    final out = await _tempFilePath(
      plan.extension,
      suggestedName: plan.suggestedName,
    );

    final task = DownloadTask(
      url: plan.url,
      savePath: out,
      kind: plan.kind,
      type: plan.type,
      name: plan.suggestedName,
      extra: extra,
    );
    downloads.value = [...downloads.value, task];
    await _saveState();
    notifyListeners();
    unawaited(_trackDownloadAd(task));

    try {
      await FirebaseAnalytics.instance.logEvent(
        name: 'download_enqueue',
        parameters: {
          'kind': plan.kind,
          'type': plan.type,
          'host': _hostFromAny(url) ?? '',
        },
      );
    } catch (_) {}

    _runTask(task);
    return task;
  }

  Future<DownloadTask> enqueueYoutubeOption(
    YtStreamOption option, {
    String? sourceUrl,
    String? titleOverride,
  }) async {
    final mergedExtra = <String, dynamic>{};
    final ytMeta = <String, dynamic>{
      'sourceUrl': sourceUrl ?? currentPageUrl.value,
      'optionType': option.type.name,
      'qualityLabel': option.qualityLabel,
      'downloadUrl': option.downloadUrl,
      'videoId': option.videoId,
      if (option.width != null) 'width': option.width,
      if (option.height != null) 'height': option.height,
      if (option.videoCodec != null) 'videoCodec': option.videoCodec,
      if (option.audioCodec != null) 'audioCodec': option.audioCodec,
      if (option.videoBitrate != null) 'videoBitrate': option.videoBitrate,
      if (option.audioBitrate != null) 'audioBitrate': option.audioBitrate,
      if (option.totalBitrate != null) 'totalBitrate': option.totalBitrate,
      if (option.itag != null) 'itag': option.itag,
      if (option.audioItag != null) 'audioItag': option.audioItag,
      if (option.duration != null)
        'durationMs': option.duration!.inMilliseconds,
    };
    if (option.audioUrl != null) {
      ytMeta['audioUrl'] = option.audioUrl;
    }
    if (option.audioContainer != null) {
      ytMeta['audioContainer'] = option.audioContainer;
    }
    ytMeta['fileExtension'] = option.fileExtension;
    mergedExtra['yt'] = ytMeta;

    final suggested =
        option.suggestedFileName ??
        titleOverride ??
        ytTitle.value ??
        currentPageTitle.value;

    switch (option.type) {
      case YtOptionType.muxed:
        return _enqueueDirectTask(
          option.downloadUrl,
          suggestedName: suggested,
          forcedExtension: option.fileExtension,
          explicitType: 'video',
          kindOverride: 'yt-direct',
          extra: mergedExtra,
        );
      case YtOptionType.videoOnly:
        return _enqueueDirectTask(
          option.downloadUrl,
          suggestedName: suggested,
          forcedExtension: option.fileExtension,
          explicitType: 'video',
          kindOverride: 'yt-direct',
          extra: mergedExtra,
        );
      case YtOptionType.audioOnly:
        return _enqueueDirectTask(
          option.downloadUrl,
          suggestedName: suggested,
          forcedExtension: option.fileExtension,
          explicitType: 'audio',
          kindOverride: 'yt-direct',
          extra: mergedExtra,
        );
      case YtOptionType.videoAudio:
        return _enqueueYoutubeMergeTask(
          option,
          suggestedName: suggested,
          extra: mergedExtra,
        );
    }
  }

  Future<DownloadTask> enqueueYoutubeHlsManifest(
    String hlsUrl, {
    String? sourceUrl,
    String? titleOverride,
    String? videoId,
  }) async {
    final mergedExtra = <String, dynamic>{
      'yt': {
        'sourceUrl': sourceUrl ?? currentPageUrl.value,
        if (videoId != null) 'videoId': videoId,
        'hlsManifestUrl': hlsUrl,
        'optionType': 'hls',
      },
    };
    return _enqueueDirectTask(
      hlsUrl,
      suggestedName: titleOverride ?? ytTitle.value ?? currentPageTitle.value,
      explicitType: 'video',
      kindOverride: 'hls',
      extra: mergedExtra,
    );
  }

  Future<DownloadTask> _enqueueYoutubeMergeTask(
    YtStreamOption option, {
    String? suggestedName,
    Map<String, dynamic>? extra,
  }) async {
    final audioUrl = option.audioUrl;
    if (audioUrl == null) {
      throw ArgumentError('Missing audio stream for YouTube merge option');
    }
    final mergedExtra = extra ?? {};
    final ytMeta = Map<String, dynamic>.from(
      (mergedExtra['yt'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
    ytMeta['videoUrl'] = option.downloadUrl;
    ytMeta['audioUrl'] = audioUrl;
    ytMeta['audioContainer'] =
        option.audioContainer ?? ytMeta['audioContainer'] ?? 'm4a';
    ytMeta['fileExtension'] = option.fileExtension;
    mergedExtra['yt'] = ytMeta;

    return _enqueueDirectTask(
      option.downloadUrl,
      suggestedName: suggestedName,
      forcedExtension: option.fileExtension,
      explicitType: 'video',
      kindOverride: 'yt-merge',
      extra: mergedExtra,
    );
  }

  YtStreamOption? _pickDefaultYtOption(List<YtStreamOption> options) {
    return options.firstWhereOrNull((o) => o.type == YtOptionType.videoAudio) ??
        options.firstWhereOrNull((o) => o.type == YtOptionType.muxed) ??
        options.firstWhereOrNull((o) => o.type == YtOptionType.videoOnly) ??
        options.firstWhereOrNull((o) => o.type == YtOptionType.audioOnly);
  }

  /// Pause a running download. For 'file' kind, cancels the Dio request and keeps partial file.
  /// For 'hls' kind, cancels the FFmpeg session (true resume is not supported by FFmpeg;
  /// resuming will restart from the beginning).
  Future<void> pauseTask(DownloadTask t) async {
    if (t.state != 'downloading') return;
    try {
      if (t.kind == 'file') {
        final handle = await _backgroundHandleForTask(t);
        if (handle != null) {
          await _bgDownloader.pause(handle);
        } else {
          final bgId = _backgroundTaskIdFor(t);
          if (bgId != null) {
            await _bgDownloader.cancelTaskWithId(bgId);
            _detachBackgroundTask(bgId);
          }
        }
        t.paused = true;
        t.state = 'paused';
      } else if (t.kind == 'hls') {
        if (Platform.isIOS && t.extra?[_hlsNativeActiveKey] == true) {
          await _pauseNativeHls(t);
        } else {
          final id = _ffmpegSessions.remove(t);
          if (id != null) {
            await FFmpegKit.cancel(id);
          }
        }
        t.paused = true;
        t.state = 'paused';
      } else if (t.kind == 'dash') {
        final id = _ffmpegSessions.remove(t);
        if (id != null) {
          await FFmpegKit.cancel(id);
        }
        t.paused = true;
        t.state = 'paused';
      } else if (t.kind == 'yt-direct') {
        t.paused = true;
        t.state = 'paused';
      } else if (t.kind == 'yt-merge') {
        final id = _ffmpegSessions.remove(t);
        if (id != null) {
          await FFmpegKit.cancel(id);
        }
        final key = _canonicalPath(t.savePath);
        final session = _ytMergeSessions[key];
        if (session != null) {
          if (session.videoTaskId != null) {
            try {
              await _bgDownloader.cancelTaskWithId(session.videoTaskId!);
            } catch (_) {}
            _ytMergeTaskBindings.remove(session.videoTaskId!);
            session.videoTaskId = null;
            session.videoComplete = false;
          }
          if (session.audioTaskId != null) {
            try {
              await _bgDownloader.cancelTaskWithId(session.audioTaskId!);
            } catch (_) {}
            _ytMergeTaskBindings.remove(session.audioTaskId!);
            session.audioTaskId = null;
            session.audioComplete = false;
          }
          session.merging = false;
          _persistYtSession(session);
        }
        t.extra?.remove('isConverting');
        t.paused = true;
        t.state = 'paused';
      }
    } catch (_) {
      // ignore
    }
    notifyListeners();
    await _saveState();
  }

  /// Resume a paused download. For 'file' kind uses HTTP Range to append.
  /// For 'hls' kind restarts the remux from the start (real segment resume is not available here).
  Future<void> resumeTask(DownloadTask t) async {
    if (!(t.state == 'paused' || (t.paused))) return;
    t.paused = false;
    t.state = 'downloading';
    notifyListeners();
    // Resume via underlying runners.
    if (t.kind == 'file') {
      _runTaskFile(t, resume: true);
    } else if (t.kind == 'hls') {
      if (Platform.isIOS) {
        unawaited(_startNativeHlsDownload(t));
      } else {
        _runTaskHls(t);
      }
    } else if (t.kind == 'dash') {
      _runTaskDash(t);
    } else if (t.kind == 'yt-direct') {
      _runTaskYoutubeDirect(t);
    } else if (t.kind == 'yt-merge') {
      _runTaskYoutubeMerge(t);
    } else {
      _runTask(t);
    }
  }

  Future<void> retryTask(DownloadTask t) async {
    final state = t.state.toLowerCase();
    if (state == 'downloading' && !t.paused) {
      await pauseTask(t);
    }

    final bgId = _backgroundTaskIdFor(t);
    if (bgId != null) {
      try {
        await _bgDownloader.cancelTaskWithId(bgId);
      } catch (_) {}
      _detachBackgroundTask(bgId);
    }

    if (t.kind == 'hls') {
      if (Platform.isIOS && t.extra?[_hlsNativeActiveKey] == true) {
        await _cancelNativeHls(t);
      }
      await _clearHlsManifest(t);
      await _clearHlsImageResume(t);
      await _cleanupHlsWorkspace(t);
      _hlsActiveOutputs.remove(t);
      _lastHlsSize.remove(t);
      t.extra?.remove(_hlsBgReadyKey);
      t.extra?.remove(_hlsBgNotifiedKey);
      t.extra?.remove(_hlsFfmpegFallbackKey);
      t.extra?.remove(_hlsNativeActiveKey);
      t.extra?.remove(_hlsRefreshAttemptKey);
      t.extra?.remove(_hlsRefreshUrlKey);
      t.extra?.remove(_hlsProgressAtKey);
    } else if (t.kind == 'dash') {
      await _cleanupDashWorkspace(t);
      t.extra?.remove(_dashBgReadyKey);
      t.extra?.remove(_dashBgNotifiedKey);
      t.extra?.remove(_dashFfmpegFallbackKey);
    } else if (t.kind == 'yt-merge') {
      await _cleanupYtMergeWorkspace(t);
      final key = _canonicalPath(t.savePath);
      final session = _ytMergeSessions.remove(key);
      if (session != null) {
        if (session.videoTaskId != null) {
          _ytMergeTaskBindings.remove(session.videoTaskId!);
        }
        if (session.audioTaskId != null) {
          _ytMergeTaskBindings.remove(session.audioTaskId!);
        }
      }
      t.extra?.remove('ytBg');
      t.extra?.remove('isConverting');
    }

    if (t.kind == 'hls' || t.kind == 'dash' || t.kind == 'yt-merge') {
      final ffmpegId = _ffmpegSessions.remove(t);
      if (ffmpegId != null) {
        try {
          await FFmpegKit.cancel(ffmpegId);
        } catch (_) {}
      }
    }

    try {
      final file = File(t.savePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}

    t.state = 'queued';
    t.paused = false;
    t.received = 0;
    t.total = null;
    t.progressUnit = null;
    t.extra?.remove(_bgFailedNotifiedKey);
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveState();
    unawaited(_runTask(t));
  }

  /// Runs the download task. For HLS, uses FFmpeg to remux the m3u8 playlist
  /// into an MP4. For direct media files, uses Dio for streaming download.
  Future<void> _runTask(DownloadTask t) async {
    t.state = 'downloading';
    notifyListeners();
    if (_requiresForeground(t) && !_appInForeground) {
      await _markAwaitingForeground(t);
      return;
    }
    if (t.kind == 'hls') {
      await _runTaskHls(t);
    } else if (t.kind == 'dash') {
      await _runTaskDash(t);
    } else if (t.kind == 'yt-merge') {
      await _runTaskYoutubeMerge(t);
    } else if (t.kind == 'yt-direct') {
      await _runTaskYoutubeDirect(t);
    } else {
      await _runTaskFile(t, resume: false);
    }
  }

  Future<void> _runTaskYoutubeDirect(DownloadTask t) async {
    if (Platform.isIOS) {
      await _runTaskFile(t, resume: true);
      return;
    }
    if (!_appInForeground) {
      await _markAwaitingForeground(t);
      return;
    }
    final meta = t.extra?['yt'];
    int? itag;
    String? videoId;
    if (meta is Map) {
      final rawItag = meta['itag'] ?? meta['audioItag'];
      if (rawItag is int) {
        itag = rawItag;
      } else if (rawItag is num) {
        itag = rawItag.toInt();
      }
      final rawVideoId = meta['videoId'];
      if (rawVideoId is String && rawVideoId.isNotEmpty) {
        videoId = rawVideoId;
      }
    }
    if (itag == null || videoId == null) {
      await _runTaskFile(t, resume: false);
      return;
    }
    t.state = 'downloading';
    t.paused = false;
    t.progressUnit = null;
    t.extra?.remove('awaitingForeground');
    t.received = 0;
    _notifyDownloadsUpdated();
    notifyListeners();

    int lastNotified = t.received;
    bool seeded = false;
    try {
      final written = await downloadYoutubeStreamToFile(
        videoId: videoId,
        itag: itag,
        destinationPath: t.savePath,
        onTotalBytes: (total) {
          t.total = total;
          _notifyDownloadsUpdated();
          notifyListeners();
        },
        onBytes: (chunkBytes) {
          if (!seeded) {
            t.received = chunkBytes;
            seeded = true;
          } else {
            t.received += chunkBytes;
          }
          if (t.total != null && t.total! < t.received) {
            t.total = t.received;
          }
          if ((t.received - lastNotified) >= (256 * 1024)) {
            lastNotified = t.received;
            _notifyDownloadsUpdated();
            notifyListeners();
          }
        },
        shouldAbort:
            () => t.state == 'paused' || t.paused || !_appInForeground,
      );
      if (t.state == 'paused' || t.paused) {
        return;
      }
      t.received = written;
      if (t.total != null && t.total! < written) {
        t.total = written;
      }
      t.state = 'done';
      _normalizeTaskType(t);
      _notifyDownloadsUpdated();
      notifyListeners();
      await _generatePreview(t);
      _maybeNotifyDownloadComplete(t);
      if (autoSave.value) {
        try {
          await saveFileToGallery(t.savePath);
        } catch (_) {}
      }
      await _saveState();
    } on YoutubeStreamCancelled {
      t.state = 'paused';
      t.paused = true;
      _notifyDownloadsUpdated();
      notifyListeners();
      await _saveState();
    } catch (e) {
      if (t.state != 'paused') {
        t.state = 'error';
        t.paused = false;
        _notifyDownloadsUpdated();
        notifyListeners();
        await _saveState();
      }
      if (kDebugMode) {
        print('download error(yt-direct): $e');
      }
    }
  }

  Future<bool> _finalizeFfmpegOutput(DownloadTask t) async {
    try {
      final output = File(t.savePath);
      if (!await output.exists()) {
        return false;
      }
      final length = await output.length();
      if (length <= 0) {
        return false;
      }
      t.received = length;
      t.total = length;
      t.state = 'done';
      t.progressUnit = null;
      _markBackgroundCompletionVerified(t);
      _normalizeTaskType(t);
      _notifyDownloadsUpdated();
      notifyListeners();
      await _generatePreview(t);
      _maybeNotifyDownloadComplete(t);
      if (autoSave.value) {
        try {
          await saveFileToGallery(t.savePath);
        } catch (e) {
          if (kDebugMode) {
            print('Failed to save to gallery: $e');
          }
        }
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Finalize FFmpeg output failed: $e');
      }
      return false;
    }
  }

  Future<void> _runTaskYoutubeMerge(DownloadTask t) async {
    final session = await _prepareYtMergeSession(t);
    if (session == null) {
      t.state = 'error';
      _notifyDownloadsUpdated();
      notifyListeners();
      await _saveState();
      return;
    }

    t.state = 'downloading';
    t.paused = false;
    _notifyDownloadsUpdated();
    notifyListeners();

    try {
      await _ensureYtPartDownload(session, _YtMergePart.video);
      await _ensureYtPartDownload(session, _YtMergePart.audio);
      _updateYtAggregateProgress(session, forceNotify: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('_ensureYtPartDownload failed: $e');
      }
      t.state = 'error';
      _notifyDownloadsUpdated();
      notifyListeners();
      await _saveState();
      return;
    }

    if (session.partsComplete) {
      unawaited(_mergeYtSession(session));
    } else {
      _persistYtSession(session);
      unawaited(_saveState());
    }
  }

  Future<_YtMergeSession?> _prepareYtMergeSession(DownloadTask t) async {
    final key = _canonicalPath(t.savePath);
    final existing = _ytMergeSessions[key];
    if (existing != null) {
      return existing;
    }

    final meta = (t.extra?['yt'] as Map<String, dynamic>?) ?? const {};
    final videoUrl = (meta['videoUrl'] as String?) ?? t.url;
    final audioUrl = meta['audioUrl'] as String?;
    if (audioUrl == null || audioUrl.isEmpty || videoUrl.isEmpty) {
      return null;
    }

    int? parseItag(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    }

    final fileExtRaw = (meta['fileExtension'] as String?) ?? 'mp4';
    final audioExtRaw = (meta['audioContainer'] as String?) ?? 'm4a';
    final fileExt = fileExtRaw.isEmpty ? 'mp4' : fileExtRaw;
    final audioExt = audioExtRaw.isEmpty ? 'm4a' : audioExtRaw;

    final workspace = await _ensureYtMergeWorkspace(t);
    final videoPath = p.join(workspace.path, 'video.$fileExt');
    final audioPath = p.join(workspace.path, 'audio.$audioExt');
    Map<String, String> videoHeaders;
    try {
      videoHeaders = await _headersFor(
        (meta['sourceUrl'] as String?) ?? videoUrl,
      );
    } catch (_) {
      videoHeaders = const {};
    }
    Map<String, String> audioHeaders;
    try {
      audioHeaders = await _headersFor(audioUrl);
    } catch (_) {
      audioHeaders = const {};
    }

    final session = _YtMergeSession(
      task: t,
      key: key,
      workspacePath: workspace.path,
      videoPath: videoPath,
      audioPath: audioPath,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      videoHeaders: videoHeaders,
      audioHeaders: audioHeaders,
      videoId: meta['videoId'] as String?,
      videoItag: parseItag(meta['itag']),
      audioItag: parseItag(meta['audioItag']),
    );
    _restoreYtSessionStateFromExtra(session);
    _ytMergeSessions[key] = session;
    _persistYtSession(session);
    return session;
  }

  void _restoreYtSessionStateFromExtra(_YtMergeSession session) {
    final raw = session.task.extra?['ytBg'];
    if (raw is! Map) {
      return;
    }
    session.videoTaskId = raw['videoTaskId'] as String?;
    session.audioTaskId = raw['audioTaskId'] as String?;
    session.videoReceived = (raw['videoReceived'] as num?)?.toInt() ?? session.videoReceived;
    session.videoTotal = (raw['videoTotal'] as num?)?.toInt() ?? session.videoTotal;
    session.videoComplete = raw['videoComplete'] == true;
    session.audioReceived = (raw['audioReceived'] as num?)?.toInt() ?? session.audioReceived;
    session.audioTotal = (raw['audioTotal'] as num?)?.toInt() ?? session.audioTotal;
    session.audioComplete = raw['audioComplete'] == true;
    session.merging = raw['merging'] == true;
    session.lastNotifiedBytes =
        (raw['lastNotified'] as num?)?.toInt() ?? session.lastNotifiedBytes;

    if (session.videoTaskId != null) {
      _ytMergeTaskBindings[session.videoTaskId!] = _YtMergePartBinding(
        sessionKey: session.key,
        part: _YtMergePart.video,
      );
    }
    if (session.audioTaskId != null) {
      _ytMergeTaskBindings[session.audioTaskId!] = _YtMergePartBinding(
        sessionKey: session.key,
        part: _YtMergePart.audio,
      );
    }
  }

  void _persistYtSession(_YtMergeSession session) {
    final extra = session.task.extra ??= {};
    extra['ytBg'] = {
      'videoTaskId': session.videoTaskId,
      'audioTaskId': session.audioTaskId,
      'videoReceived': session.videoReceived,
      'videoTotal': session.videoTotal,
      'videoComplete': session.videoComplete,
      'audioReceived': session.audioReceived,
      'audioTotal': session.audioTotal,
      'audioComplete': session.audioComplete,
      'merging': session.merging,
      'lastNotified': session.lastNotifiedBytes,
    };
  }

  Future<void> _ensureYtPartDownload(
    _YtMergeSession session,
    _YtMergePart part,
  ) async {
    _clearBackgroundCompletionVerified(session.task);
    final path = part == _YtMergePart.video ? session.videoPath : session.audioPath;
    final file = File(path);
    try {
      await file.parent.create(recursive: true);
    } catch (_) {}

    if (session.merging) {
      return;
    }

    if (part == _YtMergePart.video && session.videoComplete) {
      if (await file.exists() && await file.length() > 0) {
        return;
      }
      session.videoComplete = false;
      session.videoReceived = 0;
      session.videoTotal = 0;
    } else if (part == _YtMergePart.audio && session.audioComplete) {
      if (await file.exists() && await file.length() > 0) {
        return;
      }
      session.audioComplete = false;
      session.audioReceived = 0;
      session.audioTotal = 0;
    }

    final existingId =
        part == _YtMergePart.video ? session.videoTaskId : session.audioTaskId;
    if (existingId != null) {
      _ytMergeTaskBindings[existingId] = _YtMergePartBinding(
        sessionKey: session.key,
        part: part,
      );
      return;
    }

    final existingLen =
        await file.exists() ? await file.length() : 0;
    if (existingLen > 0) {
      if (part == _YtMergePart.video) {
        session.videoReceived = existingLen;
        if (session.videoTotal == 0) session.videoTotal = existingLen;
        session.videoComplete = true;
      } else {
        session.audioReceived = existingLen;
        if (session.audioTotal == 0) session.audioTotal = existingLen;
        session.audioComplete = true;
      }
      _persistYtSession(session);
      return;
    } else if (existingLen == 0 && await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }

    final components = await _backgroundPathComponents(path);
    final headers =
        part == _YtMergePart.video ? session.videoHeaders : session.audioHeaders;
    final url = part == _YtMergePart.video ? session.videoUrl : session.audioUrl;
    final displayName =
        session.task.name?.trim().isNotEmpty == true
            ? session.task.name!.trim()
            : p.basename(session.task.savePath);
    final bgTask = bg.DownloadTask(
      url: url,
      filename: components.$3,
      directory: components.$2,
      baseDirectory: components.$1,
      headers: headers,
      group: _bgDownloadGroup,
      updates: bg.Updates.statusAndProgress,
      allowPause: true,
      displayName:
          part == _YtMergePart.video ? 'YouTube video stream' : 'YouTube audio stream',
      metaData: _YtBgMeta(
        parentKey: session.key,
        part: part,
        totalBytes: part == _YtMergePart.video ? session.videoTotal : session.audioTotal,
        name: displayName,
      ).encode(),
    );
    final enqueued = await _bgDownloader.enqueue(bgTask);
    if (!enqueued) {
      throw StateError('enqueue_failed');
    }
    _ytMergeTaskBindings[bgTask.taskId] = _YtMergePartBinding(
      sessionKey: session.key,
      part: part,
    );
    if (part == _YtMergePart.video) {
      session.videoTaskId = bgTask.taskId;
      session.videoComplete = false;
      session.videoReceived = 0;
      session.videoTotal = 0;
    } else {
      session.audioTaskId = bgTask.taskId;
      session.audioComplete = false;
      session.audioReceived = 0;
      session.audioTotal = 0;
    }
    _persistYtSession(session);
  }

  void _updateYtAggregateProgress(
    _YtMergeSession session, {
    bool forceNotify = false,
  }) {
    final task = session.task;
    final total = session.expectedTotalBytes;
    final received = session.downloadedBytes;
    if (total > 0) {
      task.total = total;
      task.received = math.min(total, received);
    } else {
      task.total = null;
      task.received = received;
    }
    task.state = 'downloading';
    task.paused = false;
    task.progressUnit = null;
    _notifyDownloadsUpdated();
    if (forceNotify ||
        received >= total ||
        (received - session.lastNotifiedBytes).abs() >= (256 * 1024)) {
      session.lastNotifiedBytes = received;
      notifyListeners();
    }
  }

  Future<void> _mergeYtSession(_YtMergeSession session) async {
    if (session.merging) return;
    if (!_appInForeground) {
      session.task.extra?.remove('awaitingForeground');
    }
    session.merging = true;
    _persistYtSession(session);

    final t = session.task;
    (t.extra ??= {})['isConverting'] = true;

    final videoFile = File(session.videoPath);
    final audioFile = File(session.audioPath);
    final hasVideo = await videoFile.exists() && await videoFile.length() > 0;
    final hasAudio = await audioFile.exists() && await audioFile.length() > 0;
    if (!hasVideo || !hasAudio) {
      t.state = 'error';
      _notifyDownloadsUpdated();
      notifyListeners();
      session.merging = false;
      _persistYtSession(session);
      await _saveState();
      return;
    }

    final existingVideo = await videoFile.length();
    final existingAudio = await audioFile.length();
    session.videoReceived = existingVideo;
    session.audioReceived = existingAudio;
    session.videoTotal = session.videoTotal > 0 ? session.videoTotal : existingVideo;
    session.audioTotal = session.audioTotal > 0 ? session.audioTotal : existingAudio;
    session.videoComplete = true;
    session.audioComplete = true;
    if (session.videoTaskId != null) {
      _ytMergeTaskBindings.remove(session.videoTaskId!);
      session.videoTaskId = null;
    }
    if (session.audioTaskId != null) {
      _ytMergeTaskBindings.remove(session.audioTaskId!);
      session.audioTaskId = null;
    }

    final aggregate = existingVideo + existingAudio;
    t.received = aggregate;
    final total = session.expectedTotalBytes;
    if (total > 0) {
      t.total = total;
    } else {
      t.total = aggregate;
    }
    _notifyDownloadsUpdated();
    notifyListeners();

    Future<void> cleanupTemps() async {
      try {
        await _cleanupYtMergeWorkspace(t);
      } catch (_) {}
    }

    try {
      final cmd =
          "-y -i '${session.videoPath}' -i '${session.audioPath}' -c copy -movflags +faststart '${t.savePath}'";
      _ffmpegSessions[t] = -1;
      final ffmpegSession = await FFmpegKit.executeAsync(
        cmd,
        (sessionResult) async {
          final rc = await sessionResult.getReturnCode();
          var completed = false;
          if (rc != null && rc.isValueSuccess()) {
            completed = await _finalizeFfmpegOutput(t);
          } else if (t.state != 'paused') {
            completed = await _finalizeFfmpegOutput(t);
          }
          if (!completed && t.state != 'paused') {
            t.state = 'error';
            _notifyDownloadsUpdated();
            notifyListeners();
            unawaited(_reconcileTaskIfCompletedFileExists(t));
          }
          session.merging = false;
          _ffmpegSessions.remove(t);
          t.extra?.remove('isConverting');
          if (completed) {
            t.extra?.remove('ytBg');
            _ytMergeSessions.remove(session.key);
            await _cleanupTaskResiduals(t);
          } else {
            _persistYtSession(session);
          }
          await cleanupTemps();
          await _saveState();
        },
        (log) {
          if (kDebugMode) {
            print('ffmpeg(yt-merge): ${log.getMessage()}');
          }
        },
        (_) {},
      );
      final id = await ffmpegSession.getSessionId();
      if (id != null) {
        _ffmpegSessions[t] = id;
      }
    } catch (e) {
      session.merging = false;
      _ffmpegSessions.remove(t);
      t.extra?.remove('isConverting');
      if (t.state != 'paused') {
        t.state = 'error';
        if (kDebugMode) {
          print('youtube merge error: $e');
        }
        _notifyDownloadsUpdated();
        notifyListeners();
        unawaited(_reconcileTaskIfCompletedFileExists(t));
      }
      _persistYtSession(session);
      await cleanupTemps();
      await _saveState();
    }
  }

  bool _handleYtBackgroundStatus(bg.TaskStatusUpdate update) {
    final taskId = update.task.taskId;
    var binding = _ytMergeTaskBindings[taskId];
    binding ??= () {
      final meta = _YtBgMeta.fromMetaData(update.task.metaData);
      if (meta == null) return null;
      final session = _ytMergeSessions[meta.parentKey];
      if (session == null) return null;
      final resolved = _YtMergePartBinding(sessionKey: meta.parentKey, part: meta.part);
      _ytMergeTaskBindings[taskId] = resolved;
      if (meta.part == _YtMergePart.video) {
        session.videoTaskId = taskId;
      } else {
        session.audioTaskId = taskId;
      }
      return resolved;
    }();
    if (binding == null) {
      return false;
    }
    final session = _ytMergeSessions[binding.sessionKey];
    if (session == null) {
      return false;
    }

    switch (binding.part) {
      case _YtMergePart.video:
        session.videoTaskId = taskId;
        break;
      case _YtMergePart.audio:
        session.audioTaskId = taskId;
        break;
    }

    final status = update.status;
    switch (status) {
      case bg.TaskStatus.running:
        session.task.state = 'downloading';
        session.task.paused = false;
        _updateYtAggregateProgress(session);
        break;
      case bg.TaskStatus.paused:
        session.task.state = 'paused';
        session.task.paused = true;
        _notifyDownloadsUpdated();
        notifyListeners();
        break;
      case bg.TaskStatus.canceled:
        session.task.state = 'paused';
        session.task.paused = true;
        _ytMergeTaskBindings.remove(taskId);
        if (binding.part == _YtMergePart.video) {
          session.videoTaskId = null;
        } else {
          session.audioTaskId = null;
        }
        _persistYtSession(session);
        _notifyDownloadsUpdated();
        notifyListeners();
        break;
      case bg.TaskStatus.failed:
      case bg.TaskStatus.notFound:
        _ytMergeTaskBindings.remove(taskId);
        if (binding.part == _YtMergePart.video) {
          session.videoTaskId = null;
        } else {
          session.audioTaskId = null;
        }
        if (_isBackgroundCompletionVerified(session.task)) {
          _persistYtSession(session);
          break;
        }
        session.task.state = 'error';
        session.task.paused = false;
        _persistYtSession(session);
        _notifyDownloadsUpdated();
        notifyListeners();
        unawaited(_reconcileTaskIfCompletedFileExists(session.task));
        break;
      case bg.TaskStatus.waitingToRetry:
      case bg.TaskStatus.enqueued:
        break;
      case bg.TaskStatus.complete:
        try {
          final file = File(
            binding.part == _YtMergePart.video
                ? session.videoPath
                : session.audioPath,
          );
          final length = file.lengthSync();
          if (binding.part == _YtMergePart.video) {
            session.videoReceived = length;
            session.videoTotal = length;
            session.videoComplete = true;
            session.videoTaskId = null;
          } else {
            session.audioReceived = length;
            session.audioTotal = length;
            session.audioComplete = true;
            session.audioTaskId = null;
          }
        } catch (_) {}
        _ytMergeTaskBindings.remove(taskId);
        _persistYtSession(session);
        _updateYtAggregateProgress(session, forceNotify: true);
        if (session.partsComplete) {
          unawaited(_mergeYtSession(session));
        }
        break;
    }
    _persistYtSession(session);
    if (status != bg.TaskStatus.complete &&
        status != bg.TaskStatus.failed &&
        status != bg.TaskStatus.notFound) {
      _updateYtAggregateProgress(session);
    }
    return true;
  }

  bool _handleYtBackgroundProgress(bg.TaskProgressUpdate update) {
    final taskId = update.task.taskId;
    var binding = _ytMergeTaskBindings[taskId];
    binding ??= () {
      final meta = _YtBgMeta.fromMetaData(update.task.metaData);
      if (meta == null) return null;
      final session = _ytMergeSessions[meta.parentKey];
      if (session == null) return null;
      final resolved = _YtMergePartBinding(sessionKey: meta.parentKey, part: meta.part);
      _ytMergeTaskBindings[taskId] = resolved;
      if (meta.part == _YtMergePart.video) {
        session.videoTaskId = taskId;
      } else {
        session.audioTaskId = taskId;
      }
      return resolved;
    }();
    if (binding == null) {
      return false;
    }
    final session = _ytMergeSessions[binding.sessionKey];
    if (session == null) {
      return false;
    }

    final expected = update.expectedFileSize;
    if (expected > 0 && update.progress >= 0) {
      final received = (update.progress * expected).round().clamp(0, expected);
      if (binding.part == _YtMergePart.video) {
        session.videoTotal = expected;
        session.videoReceived = received;
      } else {
        session.audioTotal = expected;
        session.audioReceived = received;
      }
      _persistYtSession(session);
      _updateYtAggregateProgress(session);
    }
    return true;
  }

  Future<bool> _applyYtBackgroundRecord(
    bg.TaskRecord record,
    _YtBgMeta meta,
  ) async {
    DownloadTask? parent;
    for (final candidate in downloads.value) {
      if (_canonicalPath(candidate.savePath) == meta.parentKey) {
        parent = candidate;
        break;
      }
    }
    if (parent == null) {
      return false;
    }
    if (_isBackgroundCompletionVerified(parent) || parent.state == 'done') {
      return false;
    }
    final session = await _prepareYtMergeSession(parent);
    if (session == null) {
      return false;
    }

    if (meta.part == _YtMergePart.video) {
      session.videoTaskId = record.taskId;
    } else {
      session.audioTaskId = record.taskId;
    }
    _ytMergeTaskBindings[record.taskId] = _YtMergePartBinding(
      sessionKey: session.key,
      part: meta.part,
    );

    final expected = record.expectedFileSize;
    if (expected > 0) {
      final recv = record.progress != null && record.progress! >= 0
          ? (record.progress! * expected).round().clamp(0, expected)
          : null;
      if (meta.part == _YtMergePart.video) {
        session.videoTotal = expected;
        if (recv != null) {
          session.videoReceived = recv;
        }
      } else {
        session.audioTotal = expected;
        if (recv != null) {
          session.audioReceived = recv;
        }
      }
    }

    switch (record.status) {
      case bg.TaskStatus.complete:
        try {
          final path =
              meta.part == _YtMergePart.video ? session.videoPath : session.audioPath;
          final file = File(path);
          final length = file.existsSync() ? file.lengthSync() : 0;
          if (meta.part == _YtMergePart.video) {
            session.videoReceived = length;
            session.videoTotal = length;
            session.videoComplete = true;
            session.videoTaskId = null;
          } else {
            session.audioReceived = length;
            session.audioTotal = length;
            session.audioComplete = true;
            session.audioTaskId = null;
          }
        } catch (_) {}
        break;
      case bg.TaskStatus.failed:
      case bg.TaskStatus.notFound:
        if (!_isBackgroundCompletionVerified(session.task)) {
          session.task.state = 'error';
          _notifyDownloadsUpdated();
          notifyListeners();
        }
        break;
      case bg.TaskStatus.canceled:
        session.task.state = 'paused';
        session.task.paused = true;
        if (meta.part == _YtMergePart.video) {
          session.videoTaskId = null;
        } else {
          session.audioTaskId = null;
        }
        break;
      default:
        break;
    }

    _persistYtSession(session);
    _updateYtAggregateProgress(session, forceNotify: true);
    if (session.partsComplete && record.status == bg.TaskStatus.complete) {
      unawaited(_mergeYtSession(session));
    }
    return true;
  }

  void _checkPendingYtMerges() {
    final sessions = List<_YtMergeSession>.from(_ytMergeSessions.values);
    for (final session in sessions) {
      if (session.partsComplete && !session.merging) {
        unawaited(_mergeYtSession(session));
      }
    }
  }

  Future<void> _runTaskDash(DownloadTask t, {bool forceFfmpeg = false}) async {
    if (!forceFfmpeg && Platform.isIOS) {
      final ready = t.extra?[_dashBgReadyKey] == true;
      if (ready) {
        if (_appInForeground) {
          await _runTaskDashMergeFromLocal(t);
        } else {
          await _markAwaitingForeground(t);
        }
        return;
      }
      final started = await _startDashBackgroundSegments(t);
      if (started) {
        return;
      }
      if (!_appInForeground) {
        await _markAwaitingForeground(t);
        return;
      }
    }
    if (!_appInForeground) {
      await _markAwaitingForeground(t);
      return;
    }
    t.extra?.remove('awaitingForeground');
    try {
      // Add UA/Referer/Cookie headers for ffmpeg DASH downloads.
      final h = await _headersFor(t.url);
      final ua = (h['User-Agent'] ?? '').replaceAll("'", "\'");
      final ref = (h['Referer'] ?? '').replaceAll("'", "\'");
      final ck = (h['Cookie'] ?? '').replaceAll("'", "\'");
      final headerLines = [
        if (ref.isNotEmpty) 'Referer: $ref',
        if (ck.isNotEmpty) 'Cookie: $ck',
      ].join('\\r\\n');
      final headerArg =
          headerLines.isNotEmpty ? "-headers '${headerLines}'" : '';
      final uaArg = ua.isNotEmpty ? "-user_agent '${ua}'" : '';
      final cmd =
          "-y -protocol_whitelist file,http,https,tcp,tls,crypto $uaArg $headerArg -i '${t.url}' -c copy -bsf:a aac_adtstoasc '${t.savePath}'";
      _ffmpegSessions[t] = -1;
      final session = await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          _ffmpegSessions.remove(t);
          if (rc != null && rc.isValueSuccess()) {
            t.state = 'done';
            _markBackgroundCompletionVerified(t);
            _normalizeTaskType(t);
            // propagate update to downloads list
            _notifyDownloadsUpdated();
            notifyListeners();
            await _generatePreview(t);
            _maybeNotifyDownloadComplete(t);
            if (autoSave.value) {
              try {
                await saveFileToGallery(t.savePath);
              } catch (e) {
                if (kDebugMode) print('Failed to save to gallery: $e');
              }
            }
          } else {
            if (t.state != 'paused') {
              t.state = 'error';
              _notifyDownloadsUpdated();
              notifyListeners();
              _maybeNotifyDownloadFailed(t);
            }
          }
          await _saveState();
          t.extra?.remove('isConverting');
        },
        (log) {
          if (kDebugMode) print('ffmpeg(dash): ${log.getMessage()}');
        },
        (stat) async {
          try {
            final f = File(t.savePath);
            if (await f.exists()) {
              final len = await f.length();
              if (len >= t.received + 64 * 1024) {
                t.received = len;
                // propagate update to downloads list
                _notifyDownloadsUpdated();
                notifyListeners();
              }
            }
          } catch (_) {}
        },
      );
      final id = await session.getSessionId();
      if (id != null) _ffmpegSessions[t] = id;
    } catch (e) {
      _ffmpegSessions.remove(t);
      if (t.state != 'paused') {
        t.state = 'error';
        notifyListeners();
        _maybeNotifyDownloadFailed(t);
        if (kDebugMode) print('download error(dash): $e');
        await _saveState();
      }
    }
  }

  /// 掃描 TS 檔案的二進位資料，尋找第一個有效的同步點 (0x47)。
  /// 驗證方式：檢查 offset + 188、offset + 376... 是否也為 0x47。
  /// 若連續至少 5 個封包符合，回傳 offset；否則回傳 -1。
  int _findTsSyncOffset(List<int> data, {int minValidPackets = 5}) {
    final int packetSize = 188;
    for (int offset = 0; offset < data.length; offset++) {
      if (data[offset] != 0x47) continue;

      bool valid = true;
      for (int i = 1; i < minValidPackets; i++) {
        final int pos = offset + i * packetSize;
        if (pos >= data.length || data[pos] != 0x47) {
          valid = false;
          break;
        }
      }

      if (valid) return offset;
    }
    return -1; // 沒找到
  }

  /// 掃描 TS 檔案的二進位資料，尋找第一個有效的同步點 (0x47)。
  /// 驗證方式：檢查 offset + 188、offset + 376... 是否也為 0x47。
  /// 若連續至少 5 個封包符合，回傳 offset；否則回傳 -1。
  Future<String?> _sanitizeHlsToLocal(
    String url, {
    DownloadTask? progressTask,
  }) async {
    final originalTotal = progressTask?.total;
    final originalReceived = progressTask?.received ?? 0;
    final originalProgressUnit = progressTask?.progressUnit;
    final originalName = progressTask?.name;
    final bool nameWasEmpty = (originalName == null || originalName.isEmpty);
    var resetName = false;
    try {
      final hdrs = await _headersFor(url);
      final dio = _createDio();
      final r = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: hdrs,
          followRedirects: true,
        ),
      );
      final txt = r.data ?? '';
      if (!txt.contains('#EXTM3U')) return null;

      final baseUri = Uri.parse(url);

      // Parse as media playlist (best effort)
      final parser = HlsPlaylistParser.create();
      final parsed = await parser.parseString(baseUri, txt);

      // Build list of candidate media segments (skip obvious image thumbnails)
      final rawSegs = (parsed is HlsMediaPlaylist) ? parsed.segments : const [];
      final mediaSegs = <Uri>[];
      for (final seg in rawSegs) {
        final su = seg.url?.toString();
        if (su == null || su.isEmpty) continue;
        final abs = baseUri.resolve(su);
        final low = abs.path.toLowerCase();
        if (low.endsWith('.jpg') ||
            low.endsWith('.jpeg') ||
            low.endsWith('.png') ||
            low.endsWith('.webp')) {
          continue; // skip trick-play thumbnails
        }
        mediaSegs.add(abs);
      }

      if (mediaSegs.isEmpty) {
        // Nothing usable to sanitize
        return null;
      }

      // Initialize progress feedback via task (use segment count as pseudo total)
      if (progressTask != null) {
        progressTask.progressUnit = 'segments';
        progressTask.total = mediaSegs.length;
        progressTask.received = 0;
        if (nameWasEmpty) {
          progressTask.name = LanguageService.instance.translate(
            'download.progress.sanitizingHls',
          );
          resetName = true;
        }
        _notifyDownloadsUpdated();
        notifyListeners();
      }

      // Prepare folder to hold cleaned segments and local m3u8. When a
      // progress task is provided reuse its workspace so paused sanitisation
      // can resume without re-downloading earlier segments.
      Directory workDir;
      if (progressTask != null) {
        workDir = await _ensureHlsWorkspace(progressTask);
      } else {
        final tmp = await getTemporaryDirectory();
        final stamp = DateTime.now().millisecondsSinceEpoch;
        workDir = Directory('${tmp.path}/hls_sanitize_$stamp');
        await workDir.create(recursive: true);
      }

      final durations = <double>[];
      if (parsed is HlsMediaPlaylist) {
        for (final seg in parsed.segments) {
          if (seg.durationUs == null) {
            durations.add(4.0);
          } else {
            durations.add(seg.durationUs! / 1000000.0);
          }
        }
      }
      if (durations.length < mediaSegs.length) {
        durations.addAll(
          List<double>.filled(mediaSegs.length - durations.length, 4.0),
        );
      }

      final completed = <int>{};
      if (progressTask != null) {
        for (int i = 0; i < mediaSegs.length; i++) {
          final existing = File(p.join(workDir.path, 'seg_$i.ts'));
          if (await existing.exists()) {
            try {
              final len = await existing.length();
              if (len > 0) {
                completed.add(i);
              } else {
                await existing.delete();
              }
            } catch (_) {}
          }
        }
        if (completed.isNotEmpty) {
          progressTask.received = completed.length;
          _notifyDownloadsUpdated();
          notifyListeners();
        }
      }

      final int parallelism = 4;
      int nextIndex = 0;
      int doneCount = completed.length;
      bool cancelled = false;

      Future<void> worker() async {
        while (true) {
          if (cancelled) return;
          if (progressTask != null &&
              (progressTask.state == 'paused' || progressTask.paused)) {
            cancelled = true;
            return;
          }
          if (nextIndex >= mediaSegs.length) {
            return;
          }
          final index = nextIndex++;
          if (completed.contains(index)) {
            continue;
          }
          final abs = mediaSegs[index].toString();
          final outPath = p.join(workDir.path, 'seg_$index.ts');
          final f = File(outPath);
          try {
            final resp = await dio.get<List<int>>(
              abs,
              options: Options(
                responseType: ResponseType.bytes,
                headers: hdrs,
                followRedirects: true,
              ),
            );
            List<int> data = resp.data ?? const [];
            int start = 0;
            for (int i = 0; i < data.length; i++) {
              final b = data[i];
              if (b == 0x47) {
                final j = i + 188;
                if (j < data.length) {
                  if (data[j] == 0x47) {
                    start = i;
                    break;
                  }
                } else {
                  start = i;
                  break;
                }
              }
            }
            if (start > 0) {
              data = data.sublist(start);
            }
            await f.writeAsBytes(data, flush: true);
          } catch (_) {
            // Skip failed segment; leave empty so the playlist stays aligned.
            try {
              await f.writeAsBytes(const <int>[], flush: true);
            } catch (_) {}
          }
          completed.add(index);
          doneCount += 1;
          if (progressTask != null) {
            progressTask.received = doneCount;
            _notifyDownloadsUpdated();
            if ((doneCount % 5) == 0) {
              notifyListeners();
            }
          }
        }
      }

      final workers = List<Future<void>>.generate(parallelism, (_) => worker());
      await Future.wait(workers);
      if (cancelled) {
        throw const _DownloadCancelled();
      }

      final sb = StringBuffer();
      sb.writeln('#EXTM3U');
      sb.writeln('#EXT-X-VERSION:3');
      if (parsed is HlsMediaPlaylist && parsed.targetDurationUs != null) {
        final sec = (parsed.targetDurationUs! / 1000000).ceil();
        sb.writeln('#EXT-X-TARGETDURATION:$sec');
      }
      if (parsed is HlsMediaPlaylist && parsed.mediaSequence != null) {
        sb.writeln('#EXT-X-MEDIA-SEQUENCE:${parsed.mediaSequence}');
      }
      for (int index = 0; index < mediaSegs.length; index++) {
        final durSec = durations[index];
        sb.writeln('#EXTINF:${durSec.toStringAsFixed(3)},');
        sb.writeln('seg_$index.ts');
      }
      sb.writeln('#EXT-X-ENDLIST');

      final localPl = p.join(workDir.path, 'local.m3u8');
      await File(localPl).writeAsString(sb.toString(), flush: true);
      if (progressTask != null) {
        if (progressTask.state == 'paused' || progressTask.paused) {
          throw const _DownloadCancelled();
        }
        _notifyDownloadsUpdated();
        notifyListeners();
      }
      return localPl;
    } on _DownloadCancelled {
      rethrow;
    } catch (e) {
      if (kDebugMode) print('_sanitizeHlsToLocal error: $e');
      return null;
    } finally {
      if (progressTask != null) {
        progressTask.progressUnit = originalProgressUnit;
        progressTask.total = originalTotal;
        progressTask.received = originalReceived;
        if (resetName) {
          progressTask.name = originalName;
        }
        _notifyDownloadsUpdated();
        notifyListeners();
      }
    }
  }

  String _hlsWorkspaceId(DownloadTask t) {
    final input = utf8.encode('${t.url}|${t.savePath}');
    return sha1.convert(input).toString();
  }

  Future<Directory> _ensureHlsWorkspace(DownloadTask t) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'hls_resume', _hlsWorkspaceId(t)));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _hlsBgStateFile(DownloadTask t) async {
    final dir = await _ensureHlsWorkspace(t);
    return File(p.join(dir.path, 'bg_state.json'));
  }

  Future<Directory> _hlsBgSegmentsDir(DownloadTask t) async {
    final dir = await _ensureHlsWorkspace(t);
    final segments = Directory(p.join(dir.path, 'segments'));
    if (!await segments.exists()) {
      await segments.create(recursive: true);
    }
    return segments;
  }

  Future<_HlsBgState?> _loadHlsBgState(DownloadTask t) async {
    try {
      final file = await _hlsBgStateFile(t);
      if (!await file.exists()) {
        return null;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return _HlsBgState.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveHlsBgState(DownloadTask t, _HlsBgState state) async {
    try {
      final file = await _hlsBgStateFile(t);
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    } catch (_) {}
  }

  String _hlsNativeIdFor(DownloadTask t) {
    final extra = t.extra ??= {};
    final existing = extra['hlsNativeId'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;
    final input = utf8.encode('${t.url}|${t.savePath}');
    final id = sha1.convert(input).toString();
    extra['hlsNativeId'] = id;
    return id;
  }

  DownloadTask? _taskForHlsNativeId(String id) {
    final cached = _hlsNativeTasksById[id];
    if (cached != null) return cached;
    for (final task in downloads.value) {
      final extra = task.extra;
      if (extra == null) continue;
      if (extra['hlsNativeId'] == id) {
        _hlsNativeTasksById[id] = task;
        return task;
      }
    }
    return null;
  }

  String _effectiveHlsUrl(DownloadTask t) {
    final extra = t.extra;
    final refreshed = extra?[_hlsRefreshUrlKey] as String?;
    if (refreshed != null && refreshed.isNotEmpty) return refreshed;
    return t.url;
  }

  Future<bool> _startNativeHlsDownload(DownloadTask t) async {
    if (!Platform.isIOS) return false;
    await _ensureHlsNativeEvents();
    await _ensureNativeHlsSavePath(t);
    final id = _hlsNativeIdFor(t);
    _hlsNativeTasksById[id] = t;
    final url = _effectiveHlsUrl(t);
    final headers = await _headersFor(url);
    debugPrint('[HLS native] start id=$id url=$url headers=${headers.length}');
    final rawName = t.name?.trim();
    final displayName =
        (rawName != null && rawName.isNotEmpty)
            ? rawName
            : p.basename(t.savePath);
    final notificationTitle = LanguageService.instance.translate(
      'download.notification.title',
    );
    final notificationBody = LanguageService.instance.translate(
      'download.notification.body',
      params: {'name': displayName},
    );
    final errorTitle = LanguageService.instance.translate(
      'download.notification.failed.title',
    );
    final errorBody = LanguageService.instance.translate(
      'download.notification.failed.body',
      params: {'name': displayName},
    );
    try {
      await _hlsNativeChannel.invokeMethod('start', {
        'id': id,
        'url': url,
        'destinationPath': t.savePath,
        'headers': headers,
        'notificationTitle': notificationTitle,
        'notificationBody': notificationBody,
        'notificationErrorTitle': errorTitle,
        'notificationErrorBody': errorBody,
      });
    } catch (err) {
      debugPrint('[HLS native] start failed id=$id error=$err');
      rethrow;
    }
    final extra = t.extra ??= {};
    extra[_hlsNativeActiveKey] = true;
    extra[_hlsNativeOfflineKey] = true;
    extra['hlsSourceUrl'] = url;
    extra['hlsHeaders'] = headers;
    extra.remove(_hlsFfmpegFallbackKey);
    t.state = 'downloading';
    t.paused = false;
    t.progressUnit = 'time-ms';
    _markHlsProgress(t);
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveState();
    return true;
  }

  Future<void> _ensureNativeHlsSavePath(DownloadTask t) async {
    if (!Platform.isIOS) return;
    if (!_isNativeHlsOfflinePath(t.savePath)) {
      final suggested =
          (t.name != null && t.name!.trim().isNotEmpty)
              ? t.name
              : p.basenameWithoutExtension(t.savePath);
      final newPath = await _tempFilePath('movpkg', suggestedName: suggested);
      t.savePath = newPath;
      t.extra?.remove('hlsNativeId');
    }
  }

  Future<void> _pauseNativeHls(DownloadTask t) async {
    if (!Platform.isIOS) return;
    final id = _hlsNativeIdFor(t);
    try {
      await _hlsNativeChannel.invokeMethod('pause', {'id': id});
    } catch (_) {}
  }

  Future<void> _cancelNativeHls(DownloadTask t) async {
    if (!Platform.isIOS) return;
    final id = _hlsNativeIdFor(t);
    try {
      await _hlsNativeChannel.invokeMethod('cancel', {'id': id});
    } catch (_) {}
  }

  Future<String?> _refreshHlsUrl(DownloadTask t) async {
    final extra = t.extra;
    final ytMeta = extra?['yt'];
    if (ytMeta is Map) {
      final sourceUrl = ytMeta['sourceUrl'] as String?;
      final videoId = ytMeta['videoId'] as String?;
      if (sourceUrl != null && sourceUrl.isNotEmpty) {
        try {
          final info = await _collectYtVideoInfo(sourceUrl);
          final hlsUrl = info.hlsManifestUrl;
          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            return hlsUrl;
          }
        } catch (_) {}
      }
      if (videoId != null && videoId.isNotEmpty) {
        final fallbackUrl = 'https://www.youtube.com/watch?v=$videoId';
        try {
          final info = await _collectYtVideoInfo(fallbackUrl);
          final hlsUrl = info.hlsManifestUrl;
          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            return hlsUrl;
          }
        } catch (_) {}
      }
    }

    final sourceUrl =
        (extra?['sourceUrl'] as String?) ?? currentPageUrl.value ?? t.url;
    try {
      final resolved = await _resolveRealMediaFromHits(sourceUrl);
      if (resolved != null && resolved.toLowerCase().contains('.m3u8')) {
        return resolved;
      }
    } catch (_) {}

    final currentUrl = _effectiveHlsUrl(t);
    if (currentUrl.toLowerCase().contains('.m3u8')) {
      try {
        final picked = await _pickBestHlsVariant(currentUrl);
        if (picked != null && picked.isNotEmpty) {
          return picked;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<bool> _attemptHlsRefreshAndRestart(
    DownloadTask t, {
    bool preferNative = true,
    bool forceFfmpeg = false,
  }) async {
    if (t.kind != 'hls') return false;
    final extra = t.extra ??= {};
    final attempts = (extra[_hlsRefreshAttemptKey] as num?)?.toInt() ?? 0;
    if (attempts >= 1) return false;
    extra[_hlsRefreshAttemptKey] = attempts + 1;

    String? refreshed;
    try {
      refreshed = await _refreshHlsUrl(t);
    } catch (_) {
      return false;
    }
    if (refreshed == null ||
        refreshed.isEmpty ||
        refreshed == _effectiveHlsUrl(t)) {
      return false;
    }

    final ytMeta = extra['yt'];
    if (ytMeta is Map<String, dynamic>) {
      ytMeta['hlsManifestUrl'] = refreshed;
    }
    extra[_hlsRefreshUrlKey] = refreshed;
    extra.remove(_hlsNativeActiveKey);
    t.state = 'downloading';
    t.paused = false;
    t.progressUnit = null;
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveState();

    if (!forceFfmpeg &&
        Platform.isIOS &&
        preferNative) {
      try {
        final started = await _startNativeHlsDownload(t);
        if (started) return true;
      } catch (_) {}
    }
    if (Platform.isIOS) {
      return false;
    }
    _hlsBootstrapTasks.remove(t);
    unawaited(
      _runTaskHls(
        t,
        forceFfmpeg: forceFfmpeg || extra[_hlsFfmpegFallbackKey] == true,
      ),
    );
    return true;
  }

  void _handleHlsNativeEvent(dynamic event) {
    if (event is! Map) return;
    final id = event['id'] as String?;
    if (id == null || id.isEmpty) return;
    final task = _taskForHlsNativeId(id);
    if (task == null) return;
    final type = event['event'] as String?;
    if (type == null) return;

    switch (type) {
      case 'debug':
        final message = event['message'] as String? ?? '';
        debugPrint('[HLS native][$id] $message');
        break;
      case 'progress':
        final receivedMs = (event['receivedMs'] as num?)?.toInt() ?? 0;
        final totalMs = (event['totalMs'] as num?)?.toInt() ?? 0;
        final fractionRaw = (event['fraction'] as num?)?.toDouble() ?? 0.0;
        if (totalMs > 0) {
          task.total = totalMs;
          task.received = receivedMs.clamp(0, totalMs);
          task.progressUnit = 'time-ms';
        } else {
          final totalBytes = (event['totalBytes'] as num?)?.toInt() ?? 0;
          final receivedBytes = (event['receivedBytes'] as num?)?.toInt() ?? 0;
          if (totalBytes > 0) {
            task.total = totalBytes;
            task.received = receivedBytes.clamp(0, totalBytes);
            task.progressUnit = 'bytes';
          } else if (fractionRaw > 0) {
            const scale = 1000;
            final clamped = fractionRaw.clamp(0.0, 1.0);
            task.total = scale;
            task.received = (clamped * scale).round();
            task.progressUnit = 'fraction';
          }
        }
        task.state = 'downloading';
        task.paused = false;
        _markHlsProgress(task);
        _notifyDownloadsUpdated();
        notifyListeners();
        break;
      case 'processing':
        (task.extra ??= {})['isConverting'] = true;
        task.state = 'processing';
        task.paused = false;
        _markHlsProgress(task);
        _notifyDownloadsUpdated();
        notifyListeners();
        break;
      case 'complete':
        final path = event['path'] as String?;
        final bytes = (event['bytes'] as num?)?.toInt() ?? 0;
        final bgNotified = event['bgNotified'] == true;
        final isNativeOffline =
            task.extra?[_hlsNativeOfflineKey] == true ||
            (path != null && _isNativeHlsOfflinePath(path));
        if (path != null && path.isNotEmpty) {
          task.savePath = path;
        }
        _hlsNativeTasksById.remove(id);
        task.received = bytes;
        task.total = bytes;
        task.state = isNativeOffline ? 'processing' : 'done';
        task.paused = false;
        task.progressUnit = null;
        if (isNativeOffline) {
          (task.extra ??= {})['isConverting'] = true;
        } else {
          task.extra?.remove('isConverting');
        }
        task.extra?.remove(_hlsNativeActiveKey);
        task.extra?.remove(_hlsFfmpegFallbackKey);
        task.extra?.remove(_hlsRefreshAttemptKey);
        task.extra?.remove(_hlsRefreshUrlKey);
        task.extra?.remove(_hlsProgressAtKey);
        if (bgNotified) {
          task.extra?[_hlsBgNotifiedKey] = true;
        }
        _normalizeTaskType(task);
        _notifyDownloadsUpdated();
        notifyListeners();
        if (isNativeOffline) {
          _maybeNotifyDownloadComplete(task);
          unawaited(_convertNativeHlsToMp4(task));
          return;
        }
        unawaited(_generatePreview(task));
        _maybeNotifyDownloadComplete(task);
        if (!isNativeOffline && autoSave.value) {
          unawaited(saveFileToGallery(task.savePath));
        }
        unawaited(_cleanupTaskResiduals(task));
        break;
      case 'cancelled':
        _hlsNativeTasksById.remove(id);
        task.state = 'paused';
        task.paused = true;
        _notifyDownloadsUpdated();
        notifyListeners();
        break;
      case 'error':
        _hlsNativeTasksById.remove(id);
        if (task.state == 'paused') {
          break;
        }
        final extra = task.extra ??= {};
        if (event['bgNotified'] == true) {
          extra[_bgFailedNotifiedKey] = true;
        }
        extra.remove(_hlsNativeActiveKey);
        _attemptHlsRefreshAndRestart(task).then((refreshed) {
          if (refreshed) return;
          task.state = 'error';
          task.paused = false;
          _notifyDownloadsUpdated();
          notifyListeners();
          _maybeNotifyDownloadFailed(task);
          unawaited(_saveState());
        });
        break;
    }
  }

  Future<bool> _isValidHlsSegmentFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length <= 0) return false;
      final ext = p.extension(filePath).toLowerCase();
      if (ext == '.ts') {
        if (length < 188) return false;
        final raf = await file.open();
        try {
          final readLen = math.min(length, 376);
          final bytes = await raf.read(readLen);
          if (bytes.isEmpty) return false;
          if (bytes[0] != 0x47) return false;
          if (bytes.length > 188 && bytes[188] != 0x47) return false;
        } finally {
          await raf.close();
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeHlsBgPlaylist(
    _HlsBgState state,
    Directory segmentsDir,
  ) async {
    final playlistFile = File(state.playlistPath);
    final lines = state.playlistLines;
    if (lines != null && lines.isNotEmpty) {
      await playlistFile.writeAsString(lines.join('\n'), flush: true);
      return;
    }
    final maxDur = state.segmentDurations.isEmpty
        ? 4.0
        : state.segmentDurations.reduce(math.max);
    final target = math.max(1, maxDur.ceil());
    final sb = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:$target')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
    for (var i = 0; i < state.segmentFiles.length; i++) {
      final dur = state.segmentDurations[i];
      final safeDur = dur > 0 ? dur : 4.0;
      sb.writeln('#EXTINF:${safeDur.toStringAsFixed(3)},');
      sb.writeln(state.segmentFiles[i]);
    }
    sb.writeln('#EXT-X-ENDLIST');
    await playlistFile.writeAsString(sb.toString(), flush: true);
  }

  Future<Directory> _ensureDashWorkspace(DownloadTask t) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'dash_bg', _hlsWorkspaceId(t)));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _dashBgStateFile(DownloadTask t) async {
    final dir = await _ensureDashWorkspace(t);
    return File(p.join(dir.path, 'bg_state.json'));
  }

  Future<Directory> _dashBgSegmentsDir(DownloadTask t) async {
    final dir = await _ensureDashWorkspace(t);
    final segments = Directory(p.join(dir.path, 'segments'));
    if (!await segments.exists()) {
      await segments.create(recursive: true);
    }
    return segments;
  }

  Future<_DashBgState?> _loadDashBgState(DownloadTask t) async {
    try {
      final file = await _dashBgStateFile(t);
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return _DashBgState.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDashBgState(DownloadTask t, _DashBgState state) async {
    try {
      final file = await _dashBgStateFile(t);
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    } catch (_) {}
  }

  double _parseIsoDurationSeconds(String raw) {
    final text = raw.trim().toUpperCase();
    if (!text.startsWith('P')) return 0;
    final regex = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    );
    final match = regex.firstMatch(text);
    if (match == null) return 0;
    final days = double.tryParse(match.group(1) ?? '') ?? 0;
    final hours = double.tryParse(match.group(2) ?? '') ?? 0;
    final minutes = double.tryParse(match.group(3) ?? '') ?? 0;
    final seconds = double.tryParse(match.group(4) ?? '') ?? 0;
    return days * 86400 + hours * 3600 + minutes * 60 + seconds;
  }

  String _dashReplaceTemplate(
    String template, {
    required int number,
    required String representationId,
    required int bandwidth,
  }) {
    var out = template;
    out = out.replaceAllMapped(
      RegExp(r'\$Number%0(\d+)d\$'),
      (m) {
        final width = int.tryParse(m.group(1) ?? '') ?? 0;
        return number.toString().padLeft(width, '0');
      },
    );
    out = out.replaceAll('\$Number\$', number.toString());
    out = out.replaceAll('\$RepresentationID\$', representationId);
    out = out.replaceAll('\$Bandwidth\$', bandwidth.toString());
    return out;
  }

  String _resolveDashUrl(String base, String relative) {
    try {
      final baseUri = Uri.parse(base);
      return baseUri.resolve(relative).toString();
    } catch (_) {
      return relative;
    }
  }

  String? _firstElementText(Iterable<xml.XmlElement> nodes) {
    for (final node in nodes) {
      final text = node.text.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  _DashTrackState? _parseDashTrack({
    required xml.XmlElement adaptation,
    required String baseUrl,
    required _DashTrackType track,
    required double totalDurationSeconds,
  }) {
    final reps = adaptation.findElements('Representation').toList();
    if (reps.isEmpty) {
      return null;
    }
    reps.sort((a, b) {
      final bwA = int.tryParse(a.getAttribute('bandwidth') ?? '') ?? 0;
      final bwB = int.tryParse(b.getAttribute('bandwidth') ?? '') ?? 0;
      return bwB.compareTo(bwA);
    });
    final rep = reps.first;
    final repId = rep.getAttribute('id') ?? '${track.name}_rep';
    final bw = int.tryParse(rep.getAttribute('bandwidth') ?? '') ?? 0;

    final repBase = _firstElementText(rep.findElements('BaseURL'));
    final adaptBase = _firstElementText(adaptation.findElements('BaseURL'));
    var resolvedBase = baseUrl;
    if (adaptBase != null) {
      resolvedBase = _resolveDashUrl(resolvedBase, adaptBase);
    }
    if (repBase != null) {
      resolvedBase = _resolveDashUrl(resolvedBase, repBase);
    }

    xml.XmlElement? template =
        rep.findElements('SegmentTemplate').firstWhereOrNull((_) => true);
    template ??=
        adaptation
            .findElements('SegmentTemplate')
            .firstWhereOrNull((_) => true);
    if (template == null) {
      return null;
    }
    final media = template.getAttribute('media') ?? '';
    final init = template.getAttribute('initialization') ?? '';
    final timescale = int.tryParse(template.getAttribute('timescale') ?? '') ?? 1;
    final duration = int.tryParse(template.getAttribute('duration') ?? '') ?? 0;
    final startNumber =
        int.tryParse(template.getAttribute('startNumber') ?? '') ?? 1;
    if (media.isEmpty || init.isEmpty) {
      return null;
    }

    final initUrl = _resolveDashUrl(
      resolvedBase,
      _dashReplaceTemplate(
        init,
        number: startNumber,
        representationId: repId,
        bandwidth: bw,
      ),
    );
    final initExt = p.extension(Uri.parse(initUrl).path);
    final initFile =
        '${track.name}_init${initExt.isNotEmpty ? initExt : '.mp4'}';

    final timeline = template.findElements('SegmentTimeline').firstWhereOrNull((_) => true);
    final segmentUrls = <String>[];
    final segmentFiles = <String>[];
    final segmentDurations = <double>[];
    var number = startNumber;
    if (timeline != null) {
      final segments = timeline.findElements('S');
      for (final s in segments) {
        final d = int.tryParse(s.getAttribute('d') ?? '') ?? 0;
        final r = int.tryParse(s.getAttribute('r') ?? '') ?? 0;
        final repsCount = r >= 0 ? r + 1 : 1;
        for (var i = 0; i < repsCount; i++) {
          final url = _resolveDashUrl(
            resolvedBase,
            _dashReplaceTemplate(
              media,
              number: number,
              representationId: repId,
              bandwidth: bw,
            ),
          );
          final ext = p.extension(Uri.parse(url).path);
          final fileName =
              '${track.name}_${number.toString().padLeft(6, '0')}${ext.isNotEmpty ? ext : '.m4s'}';
          segmentUrls.add(url);
          segmentFiles.add(fileName);
          segmentDurations.add(d > 0 ? d / timescale : 0.0);
          number += 1;
        }
      }
    } else if (duration > 0) {
      final segmentDuration = duration / timescale;
      if (segmentDuration > 0 && totalDurationSeconds > 0) {
        final count =
            math.max(1, (totalDurationSeconds / segmentDuration).ceil());
        for (var i = 0; i < count; i++) {
          final url = _resolveDashUrl(
            resolvedBase,
            _dashReplaceTemplate(
              media,
              number: number,
              representationId: repId,
              bandwidth: bw,
            ),
          );
          final ext = p.extension(Uri.parse(url).path);
          final fileName =
              '${track.name}_${number.toString().padLeft(6, '0')}${ext.isNotEmpty ? ext : '.m4s'}';
          segmentUrls.add(url);
          segmentFiles.add(fileName);
          segmentDurations.add(segmentDuration);
          number += 1;
        }
      }
    }

    if (segmentUrls.isEmpty) {
      return null;
    }
    return _DashTrackState(
      initUrl: initUrl,
      initFile: initFile,
      initComplete: false,
      segmentUrls: segmentUrls,
      segmentFiles: segmentFiles,
      segmentDurations: segmentDurations,
      completed: <int>{},
    );
  }

  Future<_DashBgState?> _prepareDashBgState(DownloadTask t) async {
    final headers = await _headersFor(t.url);
    final dio = _createDio();
    final resp = await dio.get<String>(
      t.url,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        followRedirects: true,
      ),
    );
    final content = resp.data ?? '';
    final doc = xml.XmlDocument.parse(content);
    final mpd = doc.rootElement;
    final mpdBase = _firstElementText(mpd.findElements('BaseURL')) ?? t.url;
    final period = mpd.findElements('Period').firstWhereOrNull((_) => true);
    if (period == null) {
      return null;
    }
    final periodBase = _firstElementText(period.findElements('BaseURL'));
    var resolvedBase = mpdBase;
    if (periodBase != null) {
      resolvedBase = _resolveDashUrl(resolvedBase, periodBase);
    }
    final mpdDuration =
        _parseIsoDurationSeconds(mpd.getAttribute('mediaPresentationDuration') ?? '');
    final periodDuration =
        _parseIsoDurationSeconds(period.getAttribute('duration') ?? '');
    final totalDurationSeconds =
        periodDuration > 0 ? periodDuration : mpdDuration;

    _DashTrackState? video;
    _DashTrackState? audio;
    final adaptations = period.findElements('AdaptationSet').toList();
    for (final adaptation in adaptations) {
      final mime = (adaptation.getAttribute('mimeType') ?? '').toLowerCase();
      final contentType =
          (adaptation.getAttribute('contentType') ?? '').toLowerCase();
      final isVideo =
          mime.startsWith('video') || contentType == 'video';
      final isAudio =
          mime.startsWith('audio') || contentType == 'audio';
      if (!isVideo && !isAudio) {
        continue;
      }
      if (isVideo && video != null) {
        continue;
      }
      if (isAudio && audio != null) {
        continue;
      }
      final trackType = isVideo ? _DashTrackType.video : _DashTrackType.audio;
      final track = _parseDashTrack(
        adaptation: adaptation,
        baseUrl: resolvedBase,
        track: trackType,
        totalDurationSeconds: totalDurationSeconds,
      );
      if (trackType == _DashTrackType.video) {
        video = track ?? video;
      } else {
        audio = track ?? audio;
      }
    }

    if (video == null && audio == null) {
      return null;
    }
    final workspace = await _ensureDashWorkspace(t);
    final state = _DashBgState(
      mpdUrl: t.url,
      video: video,
      audio: audio,
      workspacePath: workspace.path,
    );
    await _saveDashBgState(t, state);
    return state;
  }

  Future<Directory> _dashTrackDir(DownloadTask t, _DashTrackType track) async {
    final base = await _dashBgSegmentsDir(t);
    final dir = Directory(p.join(base.path, track.name));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<bool> _startDashBackgroundSegments(DownloadTask t) async {
    var state = await _loadDashBgState(t);
    if (state == null) {
      state = await _prepareDashBgState(t);
    }
    if (state == null) {
      return false;
    }
    var currentState = state;
    final sessionId = t.timestamp.millisecondsSinceEpoch;

    Future<_DashTrackState> scanTrack(
      _DashTrackType trackType,
      _DashTrackState track,
    ) async {
      final trackDir = await _dashTrackDir(t, trackType);
      final initPath = p.join(trackDir.path, track.initFile);
      bool initComplete = track.initComplete;
      try {
        final initFile = File(initPath);
        if (await initFile.exists()) {
          final len = await initFile.length();
          if (len > 0) {
            initComplete = true;
          }
        }
      } catch (_) {}
      final completed = <int>{...track.completed};
      for (var i = 0; i < track.segmentFiles.length; i++) {
        final filePath = p.join(trackDir.path, track.segmentFiles[i]);
        try {
          final file = File(filePath);
          if (await file.exists()) {
            final len = await file.length();
            if (len > 0) {
              completed.add(i);
            }
          }
        } catch (_) {}
      }
      return _DashTrackState(
        initUrl: track.initUrl,
        initFile: track.initFile,
        initComplete: initComplete,
        segmentUrls: track.segmentUrls,
        segmentFiles: track.segmentFiles,
        segmentDurations: track.segmentDurations,
        completed: completed,
      );
    }

    if (currentState.video != null) {
      final updatedVideo = await scanTrack(
        _DashTrackType.video,
        currentState.video!,
      );
      currentState = _DashBgState(
        mpdUrl: currentState.mpdUrl,
        video: updatedVideo,
        audio: currentState.audio,
        workspacePath: currentState.workspacePath,
      );
    }
    if (currentState.audio != null) {
      final updatedAudio = await scanTrack(
        _DashTrackType.audio,
        currentState.audio!,
      );
      currentState = _DashBgState(
        mpdUrl: currentState.mpdUrl,
        video: currentState.video,
        audio: updatedAudio,
        workspacePath: currentState.workspacePath,
      );
    }

    final hasVideo = currentState.video != null;
    final hasAudio = currentState.audio != null;
    final videoTotalSegments = currentState.video?.segmentUrls.length ?? 0;
    final audioTotalSegments = currentState.audio?.segmentUrls.length ?? 0;
    final videoCompletedSegments = currentState.video?.completed.length ?? 0;
    final audioCompletedSegments = currentState.audio?.completed.length ?? 0;
    final videoInitComplete = currentState.video?.initComplete ?? false;
    final audioInitComplete = currentState.audio?.initComplete ?? false;

    await _saveDashBgState(t, currentState);

    final headers = await _headersFor(currentState.mpdUrl);

    Future<void> enqueueTrack(
      _DashTrackType trackType,
      _DashTrackState track,
    ) async {
      final trackDir = await _dashTrackDir(t, trackType);
      final initPath = p.join(trackDir.path, track.initFile);
      final initComponents = await _backgroundPathComponents(initPath);
      final initTask = bg.DownloadTask(
        url: track.initUrl,
        filename: initComponents.$3,
        directory: initComponents.$2,
        baseDirectory: initComponents.$1,
        headers: headers,
        group: _bgDownloadGroup,
        updates: bg.Updates.status,
        allowPause: false,
        metaData: _DashBgMeta(
          parentKey: _canonicalPath(t.savePath),
          track: trackType,
          index: 0,
          isInit: true,
          videoTotalSegments: videoTotalSegments,
          audioTotalSegments: audioTotalSegments,
          videoCompletedSegments: videoCompletedSegments,
          audioCompletedSegments: audioCompletedSegments,
          videoInitComplete: videoInitComplete,
          audioInitComplete: audioInitComplete,
          hasVideo: hasVideo,
          hasAudio: hasAudio,
          session: sessionId,
        ).encode(),
      );
      if (!track.initComplete) {
        final initEnqueued = await _bgDownloader.enqueue(initTask);
        if (initEnqueued) {
          _dashSegmentBindings[initTask.taskId] = _DashSegmentBinding(
            parentKey: _canonicalPath(t.savePath),
            track: trackType,
            index: 0,
            isInit: true,
          );
        }
      }

      for (var i = 0; i < track.segmentUrls.length; i++) {
        if (track.completed.contains(i)) continue;
        final filePath = p.join(trackDir.path, track.segmentFiles[i]);
        final components = await _backgroundPathComponents(filePath);
        final task = bg.DownloadTask(
          url: track.segmentUrls[i],
          filename: components.$3,
          directory: components.$2,
          baseDirectory: components.$1,
          headers: headers,
          group: _bgDownloadGroup,
          updates: bg.Updates.status,
          allowPause: false,
          metaData: _DashBgMeta(
            parentKey: _canonicalPath(t.savePath),
            track: trackType,
            index: i,
            isInit: false,
            videoTotalSegments: videoTotalSegments,
            audioTotalSegments: audioTotalSegments,
            videoCompletedSegments: videoCompletedSegments,
            audioCompletedSegments: audioCompletedSegments,
            videoInitComplete: videoInitComplete,
            audioInitComplete: audioInitComplete,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            session: sessionId,
          ).encode(),
        );
        final enqueued = await _bgDownloader.enqueue(task);
        if (enqueued) {
          _dashSegmentBindings[task.taskId] = _DashSegmentBinding(
            parentKey: _canonicalPath(t.savePath),
            track: trackType,
            index: i,
            isInit: false,
          );
        }
      }
    }

    if (currentState.video != null) {
      await enqueueTrack(_DashTrackType.video, currentState.video!);
    }
    if (currentState.audio != null) {
      await enqueueTrack(_DashTrackType.audio, currentState.audio!);
    }

    final total = currentState.totalSegments;
    final completed = currentState.completedSegments();
    t.total = total;
    t.received = completed;
    t.progressUnit = 'segments';
    t.state = 'downloading';
    t.paused = false;
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveDashBgState(t, currentState);

    if (completed >= total && total > 0) {
      (t.extra ??= {})[_dashBgReadyKey] = true;
      t.state = 'paused';
      t.paused = true;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadComplete(t);
      t.extra?[_dashBgNotifiedKey] = true;
      await _saveState();
      if (_appInForeground) {
        unawaited(_runTaskDashMergeFromLocal(t));
      }
      return true;
    }
    return true;
  }

  Future<void> _runTaskDashMergeFromLocal(DownloadTask t) async {
    final state = await _loadDashBgState(t);
    if (state == null) return;
    final total = state.totalSegments;
    if (total <= 0 || state.completedSegments() < total) {
      return;
    }
    t.extra?.remove('awaitingForeground');
    t.state = 'downloading';
    t.paused = false;
    t.progressUnit = null;
    _notifyDownloadsUpdated();
    notifyListeners();

    Future<String?> buildConcatList(
      _DashTrackType trackType,
      _DashTrackState track,
    ) async {
      final trackDir = await _dashTrackDir(t, trackType);
      final listFile = File(p.join(trackDir.path, 'list.txt'));
      final sb = StringBuffer();
      sb.writeln("file '${track.initFile}'");
      for (final file in track.segmentFiles) {
        sb.writeln("file '$file'");
      }
      await listFile.writeAsString(sb.toString(), flush: true);
      return listFile.path;
    }

    String? videoList;
    String? audioList;
    if (state.video != null) {
      videoList = await buildConcatList(_DashTrackType.video, state.video!);
    }
    if (state.audio != null) {
      audioList = await buildConcatList(_DashTrackType.audio, state.audio!);
    }

    final cmd = () {
      if (videoList != null && audioList != null) {
        return "-y -protocol_whitelist file,crypto -allowed_extensions ALL -f concat -safe 0 -i '$videoList' -f concat -safe 0 -i '$audioList' -c copy '${t.savePath}'";
      }
      if (videoList != null) {
        return "-y -protocol_whitelist file,crypto -allowed_extensions ALL -f concat -safe 0 -i '$videoList' -c copy '${t.savePath}'";
      }
      return "-y -protocol_whitelist file,crypto -allowed_extensions ALL -f concat -safe 0 -i '$audioList' -c copy '${t.savePath}'";
    }();

    _ffmpegSessions[t] = -1;
    try {
      final session = await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          _ffmpegSessions.remove(t);
          if (rc != null && rc.isValueSuccess()) {
            t.state = 'done';
            _markBackgroundCompletionVerified(t);
            t.progressUnit = null;
            t.extra?.remove(_dashBgReadyKey);
            _normalizeTaskType(t);
            _notifyDownloadsUpdated();
            notifyListeners();
            await _generatePreview(t);
            if (t.extra?[_dashBgNotifiedKey] != true) {
              _maybeNotifyDownloadComplete(t);
            }
            if (autoSave.value) {
              try {
                await saveFileToGallery(t.savePath);
              } catch (_) {}
            }
            try {
              await _cleanupDashWorkspace(t);
            } catch (_) {}
            await _cleanupTaskResiduals(t);
          } else {
            if (t.state != 'paused') {
              final extra = t.extra ??= {};
              final triedFallback = extra[_dashFfmpegFallbackKey] == true;
              if (!triedFallback) {
                extra[_dashFfmpegFallbackKey] = true;
                extra.remove(_dashBgReadyKey);
                extra.remove(_dashBgNotifiedKey);
                t.state = 'downloading';
                t.paused = false;
                t.progressUnit = null;
                _notifyDownloadsUpdated();
                notifyListeners();
                unawaited(_runTaskDash(t, forceFfmpeg: true));
                await _saveState();
                return;
              }
              t.state = 'error';
              _notifyDownloadsUpdated();
              notifyListeners();
              _maybeNotifyDownloadFailed(t);
            }
          }
          await _saveState();
        },
        (log) {},
        (stat) async {
          if (t.state != 'downloading') return;
          try {
            if ((t.progressUnit == 'time-ms') && (t.total ?? 0) > 0) {
              final raw = stat.getTime();
              if (raw != null) {
                final num rawNum = raw;
                double candidate = rawNum.toDouble();
                if (!candidate.isFinite) {
                  candidate = 0;
                }
                final int total = t.total!;
                if (candidate > total * 4 &&
                    (candidate / 1000).round() <= total) {
                  candidate /= 1000;
                } else if (candidate > total * 4 &&
                    (candidate / 1000).round() > total &&
                    (candidate / 1000000).round() <= total) {
                  candidate /= 1000000;
                }
                final int ms = math.max(0, candidate.round());
                final int updated = math.min(total, ms);
                if (updated > t.received) {
                  final prev = t.received;
                  t.received = updated;
                  _notifyDownloadsUpdated();
                  if (updated - prev >= 1000) {
                    notifyListeners();
                  }
                }
              }
            }
          } catch (_) {}
        },
      );
      final id = await session.getSessionId();
      if (id != null) _ffmpegSessions[t] = id;
    } catch (_) {
      _ffmpegSessions.remove(t);
      if (t.state != 'paused') {
        final extra = t.extra ??= {};
        final triedFallback = extra[_dashFfmpegFallbackKey] == true;
        if (!triedFallback) {
          extra[_dashFfmpegFallbackKey] = true;
          extra.remove(_dashBgReadyKey);
          extra.remove(_dashBgNotifiedKey);
          t.state = 'downloading';
          t.paused = false;
          t.progressUnit = null;
          _notifyDownloadsUpdated();
          notifyListeners();
          unawaited(_runTaskDash(t, forceFfmpeg: true));
          await _saveState();
          return;
        }
        t.state = 'error';
        _notifyDownloadsUpdated();
        notifyListeners();
        _maybeNotifyDownloadFailed(t);
        await _saveState();
      }
    }
  }

  Future<_HlsBgState?> _prepareHlsBgState(DownloadTask t) async {
    final playlistUrl = await _ensurePlayableHls(_effectiveHlsUrl(t));
    final headers = await _headersFor(playlistUrl);
    final dio = _createDio();
    final resp = await dio.get<String>(
      playlistUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        followRedirects: true,
      ),
    );
    final content = resp.data ?? '';
    final rawLines = content.split('\n');
    bool hasKey = false;
    bool hasMap = false;
    bool hasByteRange = false;
    for (final raw in rawLines) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-KEY')) {
        hasKey = true;
      } else if (line.startsWith('#EXT-X-MAP')) {
        hasMap = true;
      } else if (line.startsWith('#EXT-X-BYTERANGE')) {
        hasByteRange = true;
      }
    }
    if (hasKey || hasMap || hasByteRange) {
      return null;
    }
    final baseUri = Uri.parse(playlistUrl);
    final parser = HlsPlaylistParser.create();
    final parsed = await parser.parseString(baseUri, content);
    if (parsed is! HlsMediaPlaylist) {
      return null;
    }
    final segments = parsed.segments;
    if (segments.isEmpty) {
      return null;
    }
    final segmentsDir = await _hlsBgSegmentsDir(t);
    final segmentUrls = <String>[];
    final segmentFiles = <String>[];
    final segmentDurations = <double>[];
    bool hasImageSegment = false;
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final Object? segRaw = seg.url;
      if (segRaw == null) {
        continue;
      }
      final Uri? parsedUri = segRaw is Uri
          ? segRaw
          : (segRaw is String ? Uri.tryParse(segRaw) : null);
      if (parsedUri == null) {
        continue;
      }
      final Uri resolved =
          parsedUri.hasScheme ? parsedUri : baseUri.resolveUri(parsedUri);
      final segUrl = resolved.toString();
      if (segUrl.isEmpty) {
        continue;
      }
      final uri = resolved;
      final ext = p.extension(uri.path);
      final safeExt = ext.isNotEmpty ? ext : '.ts';
      final lowerExt = safeExt.toLowerCase();
      if (lowerExt == '.jpg' ||
          lowerExt == '.jpeg' ||
          lowerExt == '.png' ||
          lowerExt == '.webp') {
        hasImageSegment = true;
      }
      final fileName = 'seg_${i.toString().padLeft(6, '0')}$safeExt';
      segmentUrls.add(segUrl);
      segmentFiles.add(fileName);
      final durUs = seg.durationUs ?? 0;
      segmentDurations.add(durUs > 0 ? (durUs / 1000000.0) : 0.0);
    }
    if (hasImageSegment) {
      return null;
    }
    if (segmentFiles.isEmpty) {
      return null;
    }
    final playlistPath = p.join(segmentsDir.path, 'local.m3u8');
    final rewrittenLines = <String>[];
    var segIndex = 0;
    for (final raw in rawLines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        rewrittenLines.add(raw);
        continue;
      }
      if (segIndex < segmentFiles.length) {
        rewrittenLines.add(segmentFiles[segIndex]);
      } else {
        rewrittenLines.add(raw);
      }
      segIndex++;
    }
    final state = _HlsBgState(
      playlistUrl: playlistUrl,
      segmentUrls: segmentUrls,
      segmentFiles: segmentFiles,
      segmentDurations: segmentDurations,
      completed: <int>{},
      playlistPath: playlistPath,
      playlistLines: rewrittenLines,
    );
    await _writeHlsBgPlaylist(state, segmentsDir);
    await _saveHlsBgState(t, state);
    return state;
  }

  Future<bool> _startHlsBackgroundSegments(DownloadTask t) async {
    var state = await _loadHlsBgState(t);
    state ??= await _prepareHlsBgState(t);
    if (state == null) {
      return false;
    }
    final sessionId = t.timestamp.millisecondsSinceEpoch;

    final segmentsDir = await _hlsBgSegmentsDir(t);
    await _writeHlsBgPlaylist(state, segmentsDir);

    final total = state.total;
    if (total <= 0) {
      return false;
    }

    for (var i = 0; i < state.segmentFiles.length; i++) {
      final filePath = p.join(segmentsDir.path, state.segmentFiles[i]);
      try {
        final valid = await _isValidHlsSegmentFile(filePath);
        if (valid) {
          state.completed.add(i);
        } else {
          state.completed.remove(i);
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (_) {}
    }

    t.total = total;
    t.received = state.completed.length;
    t.progressUnit = 'segments';
    t.state = 'downloading';
    t.paused = false;
    _markHlsProgress(t);
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveHlsBgState(t, state);

    if (state.completed.length >= state.total) {
      (t.extra ??= {})[_hlsBgReadyKey] = true;
      t.state = 'paused';
      t.paused = true;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadComplete(t);
      t.extra?[_hlsBgNotifiedKey] = true;
      await _saveState();
      if (_appInForeground) {
        unawaited(_runTaskHlsMergeFromLocal(t));
      }
      return true;
    }

    final headers = await _headersFor(state.playlistUrl);
    final completedCount = state.completed.length;
    for (var i = 0; i < state.segmentUrls.length; i++) {
      if (state.completed.contains(i)) continue;
      final segUrl = state.segmentUrls[i];
      final filePath = p.join(segmentsDir.path, state.segmentFiles[i]);
      final components = await _backgroundPathComponents(filePath);
      final bgTask = bg.DownloadTask(
        url: segUrl,
        filename: components.$3,
        directory: components.$2,
        baseDirectory: components.$1,
        headers: headers,
        group: _bgDownloadGroup,
        updates: bg.Updates.status,
        allowPause: false,
        metaData: _HlsBgMeta(
          parentKey: _canonicalPath(t.savePath),
          index: i,
          total: total,
          completed: completedCount,
          session: sessionId,
        ).encode(),
      );
      final enqueued = await _bgDownloader.enqueue(bgTask);
      if (enqueued) {
        _hlsSegmentBindings[bgTask.taskId] = _HlsSegmentBinding(
          parentKey: _canonicalPath(t.savePath),
          index: i,
        );
      }
    }
    return true;
  }

  Future<void> _enqueueHlsSegmentDownload(
    DownloadTask task,
    _HlsBgState state,
    int index, {
    required Map<String, String> headers,
  }) async {
    if (index < 0 || index >= state.segmentUrls.length) return;
    final parentKey = _canonicalPath(task.savePath);
    if (_hlsSegmentBindings.values.any(
      (b) => b.parentKey == parentKey && b.index == index,
    )) {
      return;
    }
    final sessionId = task.timestamp.millisecondsSinceEpoch;
    final segmentsDir = await _hlsBgSegmentsDir(task);
    final filePath = p.join(segmentsDir.path, state.segmentFiles[index]);
    final components = await _backgroundPathComponents(filePath);
    final bgTask = bg.DownloadTask(
      url: state.segmentUrls[index],
      filename: components.$3,
      directory: components.$2,
      baseDirectory: components.$1,
      headers: headers,
      group: _bgDownloadGroup,
      updates: bg.Updates.status,
      allowPause: false,
      metaData: _HlsBgMeta(
        parentKey: parentKey,
        index: index,
        total: state.total,
        completed: state.completed.length,
        session: sessionId,
      ).encode(),
    );
    final enqueued = await _bgDownloader.enqueue(bgTask);
    if (enqueued) {
      _hlsSegmentBindings[bgTask.taskId] = _HlsSegmentBinding(
        parentKey: parentKey,
        index: index,
      );
    }
  }

  Future<void> _runTaskHlsMergeFromLocal(DownloadTask t) async {
    final state = await _loadHlsBgState(t);
    if (state == null || state.completed.length != state.total) {
      return;
    }
    final playlistFile = File(state.playlistPath);
    if (!await playlistFile.exists()) {
      final segmentsDir = await _hlsBgSegmentsDir(t);
      await _writeHlsBgPlaylist(state, segmentsDir);
    }
    t.extra?.remove('awaitingForeground');
    t.state = 'downloading';
    t.paused = false;
    _markHlsProgress(t);
    final totalMs =
        state.segmentDurations.fold<double>(0, (sum, v) => sum + v) * 1000.0;
    if (totalMs > 0) {
      t.total = totalMs.round();
      t.received = 0;
      t.progressUnit = 'time-ms';
    } else {
      t.progressUnit = null;
    }
    _notifyDownloadsUpdated();
    notifyListeners();
    final cmd =
        "-y -protocol_whitelist file,crypto -i '${state.playlistPath}' -c copy -movflags +faststart -bsf:a aac_adtstoasc '${t.savePath}'";
    _ffmpegSessions[t] = -1;
    try {
      final session = await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          _ffmpegSessions.remove(t);
          if (rc != null && rc.isValueSuccess()) {
            t.state = 'done';
            _markBackgroundCompletionVerified(t);
            t.progressUnit = null;
            t.extra?.remove(_hlsBgReadyKey);
            t.extra?.remove('isConverting');
            _normalizeTaskType(t);
            _notifyDownloadsUpdated();
            notifyListeners();
            await _generatePreview(t);
            if (t.extra?[_hlsBgNotifiedKey] != true) {
              _maybeNotifyDownloadComplete(t);
            }
            if (autoSave.value) {
              try {
                await saveFileToGallery(t.savePath);
              } catch (_) {}
            }
            await _cleanupTaskResiduals(t);
          } else {
            if (t.state != 'paused') {
              final extra = t.extra ??= {};
              final triedFallback = extra[_hlsFfmpegFallbackKey] == true;
              if (!triedFallback) {
                extra[_hlsFfmpegFallbackKey] = true;
                extra.remove(_hlsBgReadyKey);
                extra.remove(_hlsBgNotifiedKey);
                t.state = 'downloading';
                t.paused = false;
                t.progressUnit = null;
                _notifyDownloadsUpdated();
                notifyListeners();
                unawaited(_runTaskHls(t, forceFfmpeg: true));
                await _saveState();
                return;
              }
              t.state = 'error';
              _notifyDownloadsUpdated();
              notifyListeners();
              _maybeNotifyDownloadFailed(t);
            }
          }
          await _saveState();
        },
        (log) {},
        (stat) async {
          if (t.state != 'downloading') return;
          try {
            final raw = stat.getTime();
            if (raw != null && (t.total ?? 0) > 0) {
              final num rawNum = raw;
              double candidate = rawNum.toDouble();
              if (!candidate.isFinite) {
                candidate = 0;
              }
              final int total = t.total!;
              if (candidate > total * 4 &&
                  (candidate / 1000).round() <= total) {
                candidate /= 1000;
              } else if (candidate > total * 4 &&
                  (candidate / 1000).round() > total &&
                  (candidate / 1000000).round() <= total) {
                candidate /= 1000000;
              }
              final int ms = math.max(0, candidate.round());
              final int updated = math.min(total, ms);
                if (updated > t.received) {
                  final prev = t.received;
                  t.received = updated;
                  _markHlsProgress(t);
                  _notifyDownloadsUpdated();
                  if (updated - prev >= 1000) {
                    notifyListeners();
                }
              }
            }
          } catch (_) {}
        },
      );
      final id = await session.getSessionId();
      if (id != null) _ffmpegSessions[t] = id;
    } catch (e) {
      _ffmpegSessions.remove(t);
      if (t.state != 'paused') {
        final extra = t.extra ??= {};
        final triedFallback = extra[_hlsFfmpegFallbackKey] == true;
        if (!triedFallback) {
          extra[_hlsFfmpegFallbackKey] = true;
          extra.remove(_hlsBgReadyKey);
          extra.remove(_hlsBgNotifiedKey);
          t.state = 'downloading';
          t.paused = false;
          t.progressUnit = null;
          _notifyDownloadsUpdated();
          notifyListeners();
          unawaited(_runTaskHls(t, forceFfmpeg: true));
          await _saveState();
          return;
        }
        t.state = 'error';
        _notifyDownloadsUpdated();
        notifyListeners();
        _maybeNotifyDownloadFailed(t);
        await _saveState();
      }
    }
  }

  String _ytMergeWorkspaceId(DownloadTask t) {
    final key = utf8.encode(
      '${t.url}|${t.savePath}|${t.timestamp.millisecondsSinceEpoch}',
    );
    return sha1.convert(key).toString();
  }

  Future<Directory> _ensureYtMergeWorkspace(DownloadTask t) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      p.join(docs.path, 'yt_merge', _ytMergeWorkspaceId(t)),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _cleanupYtMergeWorkspace(DownloadTask t) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(
        p.join(docs.path, 'yt_merge', _ytMergeWorkspaceId(t)),
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  File _hlsManifestFile(Directory dir) =>
      File(p.join(dir.path, 'manifest.json'));
  File _hlsImageManifestFile(Directory dir) =>
      File(p.join(dir.path, 'image_resume.json'));

  Directory _hlsImageFramesDir(Directory dir) =>
      Directory(p.join(dir.path, 'image_frames'));

  Future<_HlsResumeManifest> _loadHlsManifest(DownloadTask t) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final file = _hlsManifestFile(dir);
      if (!await file.exists()) {
        return _HlsResumeManifest();
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return _HlsResumeManifest();
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return _HlsResumeManifest.fromJson(data);
      }
      return _HlsResumeManifest();
    } catch (_) {
      return _HlsResumeManifest();
    }
  }

  Future<_HlsImageResumeData?> _loadHlsImageResume(DownloadTask t) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final file = _hlsImageManifestFile(dir);
      if (!await file.exists()) {
        return null;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return null;
      }
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return _HlsImageResumeData.fromJson(data);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveHlsImageResume(
    DownloadTask t,
    _HlsImageResumeData data,
  ) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final file = _hlsImageManifestFile(dir);
      await file.writeAsString(jsonEncode(data.toJson()), flush: true);
    } catch (_) {}
  }

  Future<void> _clearHlsImageResume(DownloadTask t) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final file = _hlsImageManifestFile(dir);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _saveHlsManifest(
    DownloadTask t,
    _HlsResumeManifest manifest,
  ) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final file = _hlsManifestFile(dir);
      await file.writeAsString(jsonEncode(manifest.toJson()), flush: true);
    } catch (_) {}
  }

  Future<void> _clearHlsManifest(DownloadTask t) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final file = _hlsManifestFile(dir);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _cleanupHlsWorkspace(DownloadTask t) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _cleanupDashWorkspace(DownloadTask t) async {
    try {
      final dir = await _ensureDashWorkspace(t);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  void _cleanupSegmentBindingsForTask(DownloadTask t) {
    final key = _canonicalPath(t.savePath);
    _hlsSegmentBindings.removeWhere((_, b) => b.parentKey == key);
    _dashSegmentBindings.removeWhere((_, b) => b.parentKey == key);
  }

  Future<void> _cleanupTaskResiduals(DownloadTask t) async {
    _cleanupSegmentBindingsForTask(t);
    final bgId = _backgroundTaskIdFor(t);
    if (bgId != null) {
      _detachBackgroundTask(bgId);
    }
    final extra = t.extra;
    if (extra != null) {
      extra.remove('awaitingForeground');
      extra.remove('isConverting');
      extra.remove('hlsImageRunning');
      extra.remove(_hlsBgReadyKey);
      extra.remove(_hlsBgNotifiedKey);
      extra.remove(_hlsFfmpegFallbackKey);
      extra.remove(_hlsNativeActiveKey);
      extra.remove(_hlsRefreshAttemptKey);
      extra.remove(_hlsRefreshUrlKey);
      extra.remove(_hlsProgressAtKey);
      extra.remove(_dashFfmpegFallbackKey);
      extra.remove(_dashBgReadyKey);
      extra.remove(_dashBgNotifiedKey);
      extra.remove(_bgFailedNotifiedKey);
    }
    if (t.kind == 'hls') {
      await _clearHlsManifest(t);
      await _clearHlsImageResume(t);
      await _cleanupHlsWorkspace(t);
      _hlsActiveOutputs.remove(t);
      _lastHlsSize.remove(t);
    } else if (t.kind == 'dash') {
      await _cleanupDashWorkspace(t);
    } else if (t.kind == 'yt-merge') {
      await _cleanupYtMergeWorkspace(t);
      final key = _canonicalPath(t.savePath);
      final session = _ytMergeSessions.remove(key);
      if (session != null) {
        if (session.videoTaskId != null) {
          _ytMergeTaskBindings.remove(session.videoTaskId!);
        }
        if (session.audioTaskId != null) {
          _ytMergeTaskBindings.remove(session.audioTaskId!);
        }
      }
      extra?.remove('ytBg');
    }
  }

  int _sumHlsDurationsMs(String playlistText) {
    int totalMs = 0;
    for (final rawLine in playlistText.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('#EXTINF')) continue;
      final remainder = line.split(':').skip(1).join(':');
      final value = remainder.split(',').first.trim();
      final seconds = double.tryParse(value);
      if (seconds != null && seconds > 0) {
        totalMs += (seconds * 1000).round();
      }
    }
    return totalMs;
  }

  Future<int> _estimateHlsDurationMs({
    required String playlistUrl,
    required String playlistText,
    required Map<String, String> headers,
    Dio? client,
    Set<String>? visited,
  }) async {
    final direct = _sumHlsDurationsMs(playlistText);
    if (direct > 0) {
      return direct;
    }

    final lower = playlistText.toLowerCase();
    if (!lower.contains('#ext-x-stream-inf')) {
      return 0;
    }

    visited ??= <String>{};
    if (!visited.add(playlistUrl)) {
      return 0;
    }

    try {
      final parser = HlsPlaylistParser.create();
      final parsed = await parser.parseString(
        Uri.parse(playlistUrl),
        playlistText,
      );
      if (parsed is! HlsMasterPlaylist) {
        return 0;
      }

      final variants = List.of(parsed.variants);
      if (variants.isEmpty) {
        return 0;
      }
      variants.sort(
        (a, b) => (b.format?.bitrate ?? 0).compareTo(a.format?.bitrate ?? 0),
      );

      final dio = client ?? _createDio();
      for (final variant in variants) {
        final variantUrl = variant.url.toString();
        if (variantUrl.isEmpty || visited.contains(variantUrl)) {
          continue;
        }
        try {
          final resp = await dio.get<String>(
            variantUrl,
            options: Options(
              responseType: ResponseType.plain,
              headers: headers,
              followRedirects: true,
            ),
          );
          final text = resp.data ?? '';
          final nested = await _estimateHlsDurationMs(
            playlistUrl: variantUrl,
            playlistText: text,
            headers: headers,
            client: dio,
            visited: visited,
          );
          if (nested > 0) {
            return nested;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return 0;
  }

  Future<bool> _finalizeHlsParts(
    DownloadTask t,
    _HlsResumeManifest manifest,
    String currentPartName,
  ) async {
    try {
      final dir = await _ensureHlsWorkspace(t);
      final seen = <String>{};
      final ordered = <String>[];
      for (final name in [...manifest.parts, currentPartName]) {
        if (name.isEmpty || seen.contains(name)) continue;
        final file = File(p.join(dir.path, name));
        if (await file.exists()) {
          seen.add(name);
          ordered.add(name);
        }
      }
      if (ordered.isEmpty) {
        return false;
      }
      if (ordered.length == 1) {
        final single = File(p.join(dir.path, ordered.first));
        final dest = File(t.savePath);
        try {
          if (await dest.exists()) {
            await dest.delete();
          }
        } catch (_) {}
        await single.rename(dest.path);
        await _clearHlsManifest(t);
        await _cleanupHlsWorkspace(t);
        return true;
      }
      final listFile = File(p.join(dir.path, 'concat.txt'));
      final sb = StringBuffer();
      for (final name in ordered) {
        final path = p.join(dir.path, name);
        sb.writeln("file '${path.replaceAll("'", "\\'")}'");
      }
      await listFile.writeAsString(sb.toString(), flush: true);
      final cmd =
          "-y -f concat -safe 0 -i '${listFile.path}' -c copy -movflags +faststart -bsf:a aac_adtstoasc '${t.savePath}'";
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (rc != null && rc.isValueSuccess()) {
        for (final name in ordered) {
          try {
            final f = File(p.join(dir.path, name));
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {}
        }
        try {
          if (await listFile.exists()) await listFile.delete();
        } catch (_) {}
        await _clearHlsManifest(t);
        await _cleanupHlsWorkspace(t);
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _runTaskHls(DownloadTask t, {bool forceFfmpeg = false}) async {
    final hlsUrl = _effectiveHlsUrl(t);
    if (Platform.isIOS) {
      try {
        final started = await _startNativeHlsDownload(t);
        if (started) return;
      } catch (_) {}
      final refreshed = await _attemptHlsRefreshAndRestart(t);
      if (refreshed) return;
      t.state = 'error';
      t.paused = false;
      _notifyDownloadsUpdated();
      notifyListeners();
      _maybeNotifyDownloadFailed(t);
      return;
    }
    if (!_appInForeground) {
      await _markAwaitingForeground(t);
      return;
    }
    t.extra?.remove('awaitingForeground');
    // If an FFmpeg session is already attached to this task, let it finish.
    if (_ffmpegSessions.containsKey(t)) {
      return;
    }
    if (!_hlsBootstrapTasks.add(t)) {
      return;
    }
    try {
      // Detect suspicious .jpeg segments and pre-sanitize if needed
      String inputUrl = hlsUrl;
      try {
        final hdrsProbe = await _headersFor(hlsUrl);
        final dioProbe = _createDio();
        final probe = await dioProbe.get<String>(
          hlsUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: hdrsProbe,
            followRedirects: true,
          ),
        );
        final probeTxt = probe.data ?? '';
        // Pre-calc total duration for progress: sum EXTINF durations if present
        try {
          final totalMs = await _estimateHlsDurationMs(
            playlistUrl: hlsUrl,
            playlistText: probeTxt,
            headers: hdrsProbe,
            client: dioProbe,
          );
          if (totalMs > 0) {
            t.total = totalMs;
            t.received = 0;
            t.progressUnit = 'time-ms';
            _notifyDownloadsUpdated();
            notifyListeners();
          }
        } catch (_) {}
        // Determine if this playlist contains jpeg/png/webp image segments and no TS segments.
        bool jpegish = false;
        bool hasTs = false;
        for (final rawLine in probeTxt.split('\n')) {
          final l = rawLine.trim().toLowerCase();
          if (l.isEmpty || l.startsWith('#')) continue;
          if (l.endsWith('.jpg') ||
              l.endsWith('.jpeg') ||
              l.endsWith('.png') ||
              l.endsWith('.webp')) {
            jpegish = true;
          }
          if (l.endsWith('.ts') || l.endsWith('.m4s') || l.endsWith('.mp4')) {
            hasTs = true;
          }
        }
        // If the playlist contains only image segments (no TS/m4s) then process via image sequence
        if (jpegish && !hasTs) {
          // run dedicated image sequence processing and return early
          try {
            await _runTaskHlsImages(t, playlistText: probeTxt);
          } on _DownloadCancelled {
            return;
          }
          return;
        }
        // If the playlist contains image segments but also TS segments, sanitize to remove images
        if (jpegish) {
          try {
            // Provide task so sanitizer can report progress to the UI
            final local = await _sanitizeHlsToLocal(t.url, progressTask: t);
            if (local != null) {
              inputUrl = local; // use local cleaned playlist
            }
          } on _DownloadCancelled {
            return;
          }
        }
      } catch (_) {}
      // Add UA/Referer/Cookie headers for ffmpeg HLS downloads.
      final h = await _headersFor(hlsUrl);
      final ua = (h['User-Agent'] ?? '').replaceAll("'", "\'");
      final ref = (h['Referer'] ?? '').replaceAll("'", "\'");
      final ck = (h['Cookie'] ?? '').replaceAll("'", "\'");
      final headerLines = [
        if (ref.isNotEmpty) 'Referer: $ref',
        if (ck.isNotEmpty) 'Cookie: $ck',
      ].join('\\r\\n');
      final headerArg =
          headerLines.isNotEmpty ? "-headers '${headerLines}\\r\\n'" : '';
      final uaArg = ua.isNotEmpty ? "-user_agent '${ua}'" : '';
      final manifest = await _loadHlsManifest(t);
      int resumeMs = manifest.completedMs;
      if (t.total != null && t.total! > 0) {
        resumeMs = resumeMs.clamp(0, t.total!) as int;
      } else {
        resumeMs = math.max(0, resumeMs);
      }
      if (resumeMs > 0) {
        t.progressUnit ??= 'time-ms';
        if (resumeMs > t.received) {
          t.received = resumeMs;
          _notifyDownloadsUpdated();
        }
      }
      final workspace = await _ensureHlsWorkspace(t);
      final partIndex = manifest.parts.length;
      final partName = 'part_${partIndex.toString().padLeft(2, '0')}';
      final outputPath = p.join(workspace.path, '$partName.mp4');
      try {
        final existing = File(outputPath);
        if (await existing.exists()) {
          await existing.delete();
        }
      } catch (_) {}
      _hlsActiveOutputs[t] = outputPath;
      _markHlsProgress(t);
      Future<void> recordPartial() async {
        final file = File(outputPath);
        if (!await file.exists()) {
          return;
        }
        if (!manifest.parts.contains('$partName.mp4')) {
          manifest.parts.add('$partName.mp4');
        }
        int progressMs = t.received;
        if (progressMs <= manifest.completedMs) {
          try {
            final probeSession = await FFprobeKit.getMediaInformation(
              outputPath,
            );
            final info = probeSession.getMediaInformation();
            final durationStr = info?.getDuration();
            final seconds = double.tryParse(durationStr ?? '');
            if (seconds != null && seconds.isFinite && seconds > 0) {
              progressMs = (seconds * 1000).round();
            }
          } catch (_) {}
        }
        if (progressMs > t.received) {
          t.received = progressMs;
          _notifyDownloadsUpdated();
        }
        manifest.completedMs = math.max(manifest.completedMs, progressMs);
        await _saveHlsManifest(t, manifest);
      }

      final seekPrefix =
          resumeMs > 0 ? "-ss ${(resumeMs / 1000.0).toStringAsFixed(3)} " : '';
      final cmd =
          "-y -loglevel info -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -http_persistent 1 "
          "-protocol_whitelist file,http,https,tcp,tls,crypto "
          "-allowed_extensions ALL "
          "-rw_timeout 15000000 -timeout 15000000 -analyzeduration 0 -probesize 500000 "
          "$seekPrefix$uaArg $headerArg -i '${inputUrl}' -map 0:v:0? -map 0:a:0? -c copy -movflags +faststart -bsf:a aac_adtstoasc '${outputPath}'";
      _ffmpegSessions[t] = -1;
      final session = await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          _hlsActiveOutputs.remove(t);
          _ffmpegSessions.remove(t);
          if (rc != null && rc.isValueSuccess()) {
            if (!manifest.parts.contains('$partName.mp4')) {
              manifest.parts.add('$partName.mp4');
            }
            manifest.completedMs =
                t.total ?? math.max(manifest.completedMs, resumeMs);
            await _saveHlsManifest(t, manifest);
            final assembled = await _finalizeHlsParts(
              t,
              manifest,
              '$partName.mp4',
            );
            if (!assembled) {
              t.state = 'error';
              _notifyDownloadsUpdated();
              notifyListeners();
              await _saveState();
              t.extra?.remove('isConverting');
              return;
            }
            t.state = 'done';
            _markBackgroundCompletionVerified(t);
            try {
              final output = File(t.savePath);
              if (await output.exists()) {
                final size = await output.length();
                if (size > 0) {
                  t.total = size;
                  t.received = size;
                }
              }
            } catch (_) {}
            t.extra?.remove('isConverting');
            t.extra?.remove(_hlsRefreshAttemptKey);
            t.extra?.remove(_hlsRefreshUrlKey);
            t.extra?.remove(_hlsProgressAtKey);
            t.progressUnit = null;
            _lastHlsSize.remove(t);
            _normalizeTaskType(t);

            _notifyDownloadsUpdated();
            notifyListeners();
            await _generatePreview(t);
            _maybeNotifyDownloadComplete(t);
            try {
              final analyticsPath = () {
                final base = p.basename(t.savePath);
                return base.length <= 100 ? base : base.substring(0, 100);
              }();
              await FirebaseAnalytics.instance.logEvent(
                name: 'download_complete',
                parameters: {
                  'kind': 'hls',
                  'type': t.type,
                  'path': analyticsPath,
                },
              );
            } catch (_) {}
            if (autoSave.value) {
              try {
                await saveFileToGallery(t.savePath);
              } catch (e) {
                if (kDebugMode) print('Failed to save to gallery: $e');
              }
            }
          } else {
            if (t.state == 'paused') {
              await recordPartial();
              t.extra?.remove('isConverting');
            } else {
              final forceRefreshFfmpeg =
                  !Platform.isIOS ||
                  forceFfmpeg ||
                  t.extra?[_hlsFfmpegFallbackKey] == true;
              final refreshed = await _attemptHlsRefreshAndRestart(
                t,
                preferNative: !forceRefreshFfmpeg,
                forceFfmpeg: forceRefreshFfmpeg,
              );
              if (refreshed) {
                return;
              }
              t.state = 'error';
              _notifyDownloadsUpdated();
              notifyListeners();
              _maybeNotifyDownloadFailed(t);
              unawaited(_reconcileTaskIfCompletedFileExists(t));
              try {
                await FirebaseAnalytics.instance.logEvent(
                  name: 'download_error',
                  parameters: {'kind': 'hls'},
                );
              } catch (_) {}

      if (!hlsUrl.startsWith('file:') &&
                  !hlsUrl.startsWith('/') &&
                  !hlsUrl.contains('/hls_sanitize_')) {
                try {
                  final local = await _sanitizeHlsToLocal(
                    hlsUrl,
                    progressTask: t,
                  );
                  if (local != null) {
                    await _clearHlsManifest(t);
                    await _cleanupHlsWorkspace(t);
                    final h2 = await _headersFor(hlsUrl);
                    final ua2 = (h2['User-Agent'] ?? '').replaceAll("'", "\'");
                    final ref2 = (h2['Referer'] ?? '').replaceAll("'", "\'");
                    final ck2 = (h2['Cookie'] ?? '').replaceAll("'", "\'");
                    final headerLines2 = [
                      if (ref2.isNotEmpty) 'Referer: $ref2',
                      if (ck2.isNotEmpty) 'Cookie: $ck2',
                    ].join('\\r\\n');
                    final headerArg2 =
                        headerLines2.isNotEmpty
                            ? "-headers '${headerLines2}\\r\\n'"
                            : '';
                    final uaArg2 = ua2.isNotEmpty ? "-user_agent '${ua2}'" : '';
                    final cmd2 =
                        "-y -loglevel info -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -http_persistent 1 "
                        "-protocol_whitelist file,http,https,tcp,tls,crypto "
                        "-allowed_extensions ALL "
                        "-rw_timeout 15000000 -timeout 15000000 -analyzeduration 0 -probesize 500000 "
                        "$uaArg2 $headerArg2 -i '${local}' -map 0:v:0? -map 0:a:0? -c copy -movflags +faststart -bsf:a aac_adtstoasc '${t.savePath}'";
                    final s2 = await FFmpegKit.execute(cmd2);
                    final rc2 = await s2.getReturnCode();
                    if (rc2 != null && rc2.isValueSuccess()) {
                      t.state = 'done';
                      _markBackgroundCompletionVerified(t);
                      try {
                        final output = File(t.savePath);
                        if (await output.exists()) {
                          final size = await output.length();
                          if (size > 0) {
                            t.total = size;
                            t.received = size;
                          }
                        }
                      } catch (_) {}
                      t.extra?.remove('isConverting');
                      t.extra?.remove(_hlsRefreshAttemptKey);
                      t.extra?.remove(_hlsRefreshUrlKey);
                      t.extra?.remove(_hlsProgressAtKey);
                      t.progressUnit = null;
                      _lastHlsSize.remove(t);
                      _normalizeTaskType(t);
                      _notifyDownloadsUpdated();
                      notifyListeners();
                      await _generatePreview(t);
                      _maybeNotifyDownloadComplete(t);
                      if (autoSave.value) {
                        try {
                          await saveFileToGallery(t.savePath);
                        } catch (_) {}
                      }
                      await _saveState();
                      return;
                    }
                  }
                } on _DownloadCancelled {
                  return;
                } catch (_) {}
              }
            }
          }
          await _saveState();
        },
        (log) {},
        (stat) async {
          if (t.state != 'downloading') {
            return;
          }
          final activePath = _hlsActiveOutputs[t] ?? t.savePath;
          bool emittedProgress = false;
          try {
            if ((t.progressUnit == 'time-ms') && (t.total ?? 0) > 0) {
              final raw = stat.getTime();
              if (raw != null) {
                final num rawNum = raw;
                double candidate = rawNum.toDouble();
                if (!candidate.isFinite) {
                  candidate = 0;
                }
                final int total = t.total!;
                if (candidate > total * 4 &&
                    (candidate / 1000).round() <= total) {
                  candidate /= 1000;
                } else if (candidate > total * 4 &&
                    (candidate / 1000).round() > total &&
                    (candidate / 1000000).round() <= total) {
                  candidate /= 1000000;
                }
                final int ms = math.max(0, candidate.round());
                final int updated = math.min(total, math.max(0, resumeMs + ms));
                if (updated > t.received) {
                  final int previous = t.received;
                  t.received = updated;
                  _markHlsProgress(t);
                  _notifyDownloadsUpdated();
                  emittedProgress = true;
                  if (updated - previous >= 1000) {
                    notifyListeners();
                  }
                }
              }
            }
          } catch (_) {}

          try {
            final f = File(activePath);
            if (await f.exists()) {
              final len = await f.length();
              final last = _lastHlsSize[t] ?? 0;

              if (len >= last + (16 * 1024)) {
                _lastHlsSize[t] = len;
                _markHlsProgress(t);
                if (!emittedProgress) {
                  _notifyDownloadsUpdated();
                }
                notifyListeners();
              }
            }
          } catch (_) {}
        },
      );
      final id = await session.getSessionId();
      if (id != null) _ffmpegSessions[t] = id;
    } on _DownloadCancelled {
      _hlsActiveOutputs.remove(t);
      _ffmpegSessions.remove(t);
      return;
    } catch (e) {
      _hlsActiveOutputs.remove(t);
      _ffmpegSessions.remove(t);
      if (t.state == 'paused') {
        return;
      }

      final alreadyDone = t.state == 'done';
      bool finalized = false;
      try {
        final file = File(t.savePath);
        if (await file.exists()) {
          final len = await file.length();
          if (len > 0) {
            t.received = len;
            t.total = len;
            if (!alreadyDone) {
              t.state = 'done';
              _markBackgroundCompletionVerified(t);
              _normalizeTaskType(t);
              _notifyDownloadsUpdated();
              notifyListeners();
              await _generatePreview(t);
              _maybeNotifyDownloadComplete(t);
            }
            finalized = true;
          }
        }
      } catch (_) {}

      t.extra?.remove('isConverting');

      if (!finalized && !alreadyDone) {
        final forceRefreshFfmpeg =
            !Platform.isIOS ||
            forceFfmpeg ||
            t.extra?[_hlsFfmpegFallbackKey] == true;
        final refreshed = await _attemptHlsRefreshAndRestart(
          t,
          preferNative: !forceRefreshFfmpeg,
          forceFfmpeg: forceRefreshFfmpeg,
        );
        if (refreshed) {
          return;
        }
        t.state = 'error';
        _notifyDownloadsUpdated();
        notifyListeners();
        _maybeNotifyDownloadFailed(t);
        unawaited(_reconcileTaskIfCompletedFileExists(t));
      }

      await _saveState();
    } finally {
      _hlsBootstrapTasks.remove(t);
    }
  }

  /// Handles HLS playlists comprised solely of image segments (e.g. JPEG trick‑play).
  /// Downloads each image segment, updates progress (segment count based), then
  /// concatenates the images into a single MP4 using FFmpeg. If a #EXTINF
  /// duration precedes an image segment in the playlist, that duration is
  /// respected; otherwise a default of 4 seconds per image is used. During
  /// download, [t.total] and [t.received] track the total number of images and
  /// the count downloaded so far to drive progress display. Note: the
  /// resulting file size cannot be predicted ahead of time; the UI still
  /// displays progress by percentage based on segment count.
  Future<void> _runTaskHlsImages(
    DownloadTask t, {
    required String playlistText,
  }) async {
    final extra = t.extra ??= {};
    if (extra['hlsImageRunning'] == true) {
      return;
    }
    extra['hlsImageRunning'] = true;
    try {
      try {
        // Parse playlist lines for image URIs and durations.
        final lines = playlistText.split('\n');
        final base = Uri.parse(t.url);
        final imageUris = <Uri>[];
        final durations = <double>[];
      double? pendingDuration;
      for (final raw in lines) {
        final l = raw.trim();
        if (l.isEmpty) continue;
        if (l.startsWith('#EXTINF')) {
          // parse duration before comma
          final part = l.split(':').skip(1).join(':');
          final durStr = part.split(',').first;
          final dur = double.tryParse(durStr.trim());
          if (dur != null) pendingDuration = dur;
          continue;
        }
        if (l.startsWith('#')) {
          continue;
        }
        final lower = l.toLowerCase();
        if (lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp')) {
          imageUris.add(base.resolve(l));
          durations.add(pendingDuration ?? 4.0);
          pendingDuration = null;
        }
      }
      if (imageUris.isEmpty) {
        // fallback: mark error if nothing to process
        t.state = 'error';
        _notifyDownloadsUpdated();
        notifyListeners();
        _maybeNotifyDownloadFailed(t);
        await _saveState();
        return;
      }
      final playlistHash = sha1.convert(utf8.encode(playlistText)).toString();
      final workspace = await _ensureHlsWorkspace(t);
      final framesDir = _hlsImageFramesDir(workspace);
      if (!await framesDir.exists()) {
        await framesDir.create(recursive: true);
      }
      String frameExt = '.jpeg';
      for (final uri in imageUris) {
        final ext = p.extension(uri.path).toLowerCase();
        if (ext.isNotEmpty) {
          frameExt = ext;
          break;
        }
      }

      var resumeData = await _loadHlsImageResume(t);
      if (resumeData == null ||
          resumeData.playlistHash != playlistHash ||
          resumeData.frameCount != imageUris.length) {
        try {
          if (await framesDir.exists()) {
            await framesDir.delete(recursive: true);
          }
        } catch (_) {}
        await framesDir.create(recursive: true);
        resumeData = _HlsImageResumeData(
          playlistHash: playlistHash,
          frameExt: frameExt,
          frameCount: imageUris.length,
        );
      } else {
        if (resumeData.frameExt.isNotEmpty) {
          frameExt = resumeData.frameExt;
        } else {
          resumeData.frameExt = frameExt;
        }
        resumeData.frameCount = imageUris.length;
      }

      final validatedCompleted = <int>{};
      for (final index in resumeData.completed) {
        if (index < 0 || index >= imageUris.length) {
          continue;
        }
        final frameName = 'frame_${index.toString().padLeft(6, '0')}$frameExt';
        final file = File(p.join(framesDir.path, frameName));
        try {
          if (await file.exists()) {
            final len = await file.length();
            if (len > 0) {
              validatedCompleted.add(index);
            }
          }
        } catch (_) {}
      }
      if (validatedCompleted.length != resumeData.completed.length) {
        resumeData.completed
          ..clear()
          ..addAll(validatedCompleted);
      }
      resumeData.frameExt = frameExt;
      resumeData.frameCount = imageUris.length;
      await _saveHlsImageResume(t, resumeData);

      final frameNames = <String>[];
      final int totalFrames = imageUris.length;
      final int completedFrames = resumeData.completed.length;
      final bool needsDownloadStage = completedFrames < totalFrames;
      t.state = 'downloading';
      if (needsDownloadStage) {
        t.total = totalFrames;
        t.received = completedFrames;
        t.progressUnit = null;
        _notifyDownloadsUpdated();
        notifyListeners();
        final dio = _createDio();
        final headers = await _headersFor(t.url);
        var downloadedCount = completedFrames;
        for (int i = 0; i < totalFrames; i++) {
          if (t.state == 'paused' || t.paused) {
            throw const _DownloadCancelled();
          }
          final uri = imageUris[i];
          final frameName = 'frame_${i.toString().padLeft(6, '0')}$frameExt';
          final framePath = p.join(framesDir.path, frameName);
          frameNames.add(frameName);
          if (resumeData.completed.contains(i)) {
            continue;
          }
          try {
            final resp = await dio.get<List<int>>(
              uri.toString(),
              options: Options(
                responseType: ResponseType.bytes,
                headers: headers,
                followRedirects: true,
              ),
            );
            final bytes = resp.data ?? const <int>[];
            final file = File(framePath);
            await file.writeAsBytes(bytes, flush: true);
          } catch (e) {
            // still create empty file to maintain sequence
            final file = File(framePath);
            await file.writeAsBytes(const <int>[], flush: true);
          }
          resumeData.completed.add(i);
          downloadedCount += 1;
          // update progress by segment count
          t.received = downloadedCount;
          // propagate to listeners (downloads list and others)
          _notifyDownloadsUpdated();
          notifyListeners();
          await _saveHlsImageResume(t, resumeData);
        }
      } else {
        for (int i = 0; i < totalFrames; i++) {
          final frameName = 'frame_${i.toString().padLeft(6, '0')}$frameExt';
          frameNames.add(frameName);
        }
      }
      await _saveHlsImageResume(t, resumeData);
      // Reset progress to reflect the conversion stage using media duration as the unit.
      final baseDuration = durations.isNotEmpty ? durations.first : 4.0;
      final double totalDurationSeconds =
          durations.isEmpty
              ? baseDuration * frameNames.length
              : durations.fold<double>(
                0.0,
                (sum, value) => sum + (value > 0 ? value : baseDuration),
              );
      final int computedTotalMs =
          totalDurationSeconds.isFinite
              ? (totalDurationSeconds * 1000).round()
              : 0;
      final int conversionTotalMs =
          computedTotalMs > 0
              ? computedTotalMs
              : math.max(frameNames.length, 1) * 1000;
      t.progressUnit = 'time-ms';
      t.total = conversionTotalMs;
      t.received = 0;
      (t.extra ??= {})['isConverting'] = true;
      _lastHlsSize[t] = 0;
      _notifyDownloadsUpdated();
      notifyListeners();
      // Determine whether all durations are effectively identical so we can
      // leverage the lightweight image2 demuxer with a constant framerate.
      final uniformDuration = durations.every(
        (d) => (d - baseDuration).abs() < 0.001 && d > 0,
      );
      final framePattern = p.join(framesDir.path, 'frame_%06d$frameExt');
      final WidgetsBinding binding = WidgetsBinding.instance;
      final AppLifecycleState? lifecycle = binding.lifecycleState;
      final bool useHardwareEncoder =
          Platform.isIOS && lifecycle != AppLifecycleState.detached;
      const evenScaleFilter = 'scale=trunc(iw/2)*2:trunc(ih/2)*2';
      const encoderFilterHw = 'nv12';
      const encoderFilterSw = 'yuv420p';
      const encoderHw = 'h264_videotoolbox';
      const encoderSw = 'libx264';
      String? concatListPath;
      if (!(uniformDuration && baseDuration > 0)) {
        // Build concat list file for FFmpeg so we can keep per-image durations
        final listFile = File(p.join(framesDir.path, 'list.txt'));
        final sb = StringBuffer();
        for (int i = 0; i < frameNames.length; i++) {
          final name = frameNames[i];
          final dur = durations[i];
          sb.writeln("file '$name'");
          sb.writeln('duration ${dur}');
        }
        // Append last file without duration to satisfy concat demuxer
        final lastName = frameNames.last;
        sb.writeln("file '$lastName'");
        await listFile.writeAsString(sb.toString(), flush: true);
        concatListPath = listFile.path;
      }

      String _buildCommand(String encoderArgs) {
        if (uniformDuration && baseDuration > 0) {
          final fps = 1.0 / baseDuration;
          final fpsStr = fps.toStringAsFixed(6);
          return "-y -framerate $fpsStr -i '$framePattern' $encoderArgs '${t.savePath}'";
        }
        return "-y -f concat -safe 0 -i '${concatListPath!}' $encoderArgs '${t.savePath}'";
      }

      Future<bool> _runEncoder(String encoderArgs) async {
        if (t.state == 'paused' || t.paused) {
          throw const _DownloadCancelled();
        }
        final completer = Completer<bool>();
        try {
          _ffmpegSessions[t] = -1;
          final session = await FFmpegKit.executeAsync(
            _buildCommand(encoderArgs),
            (session) async {
              final rc = await session.getReturnCode();
              if (!completer.isCompleted) {
                completer.complete(rc != null && rc.isValueSuccess());
              }
            },
            (log) {
              if (kDebugMode) {
                print('ffmpeg(image-hls): ${log.getMessage()}');
              }
            },
            (stat) async {
              if (t.state != 'downloading') {
                return;
              }

              bool emittedProgress = false;
              try {
                if ((t.progressUnit == 'time-ms') && (t.total ?? 0) > 0) {
                  final raw = stat.getTime();
                  if (raw != null) {
                    final num rawNum = raw;
                    double candidate = rawNum.toDouble();
                    if (!candidate.isFinite) {
                      candidate = 0;
                    }
                    final int total = t.total!;
                    if (candidate > total * 4 &&
                        (candidate / 1000).round() <= total) {
                      candidate /= 1000;
                    } else if (candidate > total * 4 &&
                        (candidate / 1000).round() > total &&
                        (candidate / 1000000).round() <= total) {
                      candidate /= 1000000;
                    }
                    final int ms = math.max(0, candidate.round());
                    final int updated = math.min(total, ms);
                    if (updated > t.received) {
                      final int previous = t.received;
                      t.received = updated;
                      _notifyDownloadsUpdated();
                      emittedProgress = true;
                      if (updated - previous >= 1000) {
                        notifyListeners();
                      }
                    }
                  }
                }
              } catch (_) {}

              try {
                final output = File(t.savePath);
                if (await output.exists()) {
                  final len = await output.length();
                  final last = _lastHlsSize[t] ?? 0;
                  if (len > last) {
                    _lastHlsSize[t] = len;
                    if (!emittedProgress) {
                      _notifyDownloadsUpdated();
                    }
                    if (len - last >= 256 * 1024) {
                      notifyListeners();
                    }
                  }
                }
              } catch (_) {}
            },
          );
          final id = await session.getSessionId();
          if (id != null) {
            _ffmpegSessions[t] = id;
          }
          final ok = await completer.future;
          _ffmpegSessions.remove(t);
          return ok;
        } on PlatformException catch (e) {
          _ffmpegSessions.remove(t);
          if (kDebugMode) {
            print('ffmpeg(image-hls) failed to start: $e');
          }
          return false;
        } catch (e) {
          _ffmpegSessions.remove(t);
          if (kDebugMode) {
            print('ffmpeg(image-hls) error: $e');
          }
          return false;
        }
      }

      bool success = false;
      if (useHardwareEncoder) {
        final hwArgs =
            '-vf $evenScaleFilter,format=$encoderFilterHw -c:v $encoderHw '
            '-b:v 6000k -pix_fmt $encoderFilterSw';
        success = await _runEncoder(hwArgs);
        if (!success) {
          // Hardware encoding may fail on some devices; retry with software encoder.
          final swArgs =
              '-vf $evenScaleFilter,format=$encoderFilterSw -c:v $encoderSw';
          success = await _runEncoder(swArgs);
        }
      } else {
        final swArgs =
            '-vf $evenScaleFilter,format=$encoderFilterSw -c:v $encoderSw';
        success = await _runEncoder(swArgs);
      }

      if (success) {
        t.state = 'done';
        _markBackgroundCompletionVerified(t);
        int? finalSize;
        try {
          final output = File(t.savePath);
          if (await output.exists()) {
            finalSize = await output.length();
          }
        } catch (_) {}
        if (finalSize != null && finalSize > 0) {
          t.total = finalSize;
          t.received = finalSize;
        } else {
          t.received = t.total ?? t.received;
        }
        t.progressUnit = null;
        _normalizeTaskType(t);
        await _clearHlsImageResume(t);
        await _cleanupHlsWorkspace(t);
        _notifyDownloadsUpdated();
        notifyListeners();
        await _generatePreview(t);
        _maybeNotifyDownloadComplete(t);
        if (autoSave.value) {
          try {
            await saveFileToGallery(t.savePath);
          } catch (e) {}
        }
      } else {
        t.state = 'error';
        t.progressUnit = null;
        _lastHlsSize.remove(t);
        _notifyDownloadsUpdated();
        notifyListeners();
      }
      await _saveState();
      } on _DownloadCancelled {
        _ffmpegSessions.remove(t);
        return;
      } catch (e) {
        if (kDebugMode) print('runTaskHlsImages error: $e');
        if (t.state != 'paused') {
          t.state = 'error';
          _notifyDownloadsUpdated();
          notifyListeners();
          await _saveState();
        }
      }
    } finally {
      extra.remove('hlsImageRunning');
    }
  }

  /// Helper to notify listeners of changes to the downloads list by reassigning
  /// the value to a new list. This triggers any ValueListenableBuilders
  /// watching [downloads] to rebuild, even when individual tasks mutate.
  void _scheduleLiveActivityUpdate() {
    if (!Platform.isIOS) {
      return;
    }
    if (!_appInForeground) {
      final now = DateTime.now();
      final last = _lastLiveActivityPushAt;
      if (last != null &&
          now.difference(last) < const Duration(seconds: 3)) {
        return;
      }
      _lastLiveActivityPushAt = now;
      unawaited(_pushLiveActivityUpdate());
      return;
    }
    _liveActivityDebounce?.cancel();
    _liveActivityDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_pushLiveActivityUpdate()),
    );
  }

  Map<String, Object?>? _buildLiveActivityPayload() {
    if (!Platform.isIOS) {
      return null;
    }
    final active =
        downloads.value
            .where((t) => t.state == 'downloading' || t.state == 'queued')
            .toList();
    if (active.isEmpty) {
      return null;
    }
    final bool isBackground = !_appInForeground;
    final bool hasYtMerge =
        active.any((t) => t.kind.toLowerCase() == 'yt-merge');
    if (active.length == 1) {
      final task = active.first;
      final title = LanguageService.instance.translate(
        'download.live.title.single',
      );
      final total = task.total ?? 0;
      double? progress;
      if (total > 0 && !(isBackground && task.kind == 'yt-merge')) {
        final ratio = task.received / total;
        progress = ratio.clamp(0.0, 1.0);
      }
      String? subtitle;
      if (isBackground && task.kind == 'yt-merge') {
        subtitle = LanguageService.instance.translate(
          'download.live.subtitle.background',
        );
      }
      return {
        'mode': 'single',
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        'progress': progress,
        'activeCount': 1,
        'totalCount': 1,
      };
    }

    final title = LanguageService.instance.translate(
      'download.live.title.group',
    );
    final subtitle = LanguageService.instance.translate(
      'download.live.subtitle.group',
      params: {'count': active.length.toString()},
    );
    var sumTotal = 0;
    var sumReceived = 0;
    var hasUnknown = false;
    for (final task in active) {
      final total = task.total ?? 0;
      if (total > 0) {
        sumTotal += total;
        sumReceived += math.min(task.received, total);
      } else {
        hasUnknown = true;
      }
    }
    double? progress;
    if (sumTotal > 0 && !hasUnknown && !(isBackground && hasYtMerge)) {
      final ratio = sumReceived / sumTotal;
      progress = ratio.clamp(0.0, 1.0);
    }
    return {
      'mode': 'group',
      'title': title,
      'subtitle':
          (isBackground && hasYtMerge)
              ? LanguageService.instance.translate(
                'download.live.subtitle.background',
              )
              : subtitle,
      'progress': progress,
      'activeCount': active.length,
      'totalCount': active.length,
    };
  }

  Future<void> _pushLiveActivityUpdate() async {
    if (!Platform.isIOS) {
      return;
    }
    final payload = _buildLiveActivityPayload();
    if (payload == null) {
      if (_lastLiveActivityPayload != null) {
        _lastLiveActivityPayload = null;
        await LiveActivityService.instance.end();
      }
      return;
    }
    final isSame = const DeepCollectionEquality().equals(
      _lastLiveActivityPayload,
      payload,
    );
    if (isSame) {
      return;
    }
    _lastLiveActivityPushAt = DateTime.now();
    _lastLiveActivityPayload = payload;
    await LiveActivityService.instance.startOrUpdate(payload);
  }

  void _notifyDownloadsUpdated() {
    // assign a shallow copy to force ValueNotifier to notify
    downloads.value = List<DownloadTask>.from(downloads.value);
    _scheduleLiveActivityUpdate();
  }

  void refreshDownloadsView() {
    _notifyDownloadsUpdated();
  }

  Dio _createDio({Duration? timeout}) {
    final dio = Dio();
    final Duration effectiveTimeout = timeout ?? const Duration(seconds: 30);
    dio.options
      ..connectTimeout = effectiveTimeout
      ..receiveTimeout = effectiveTimeout
      ..sendTimeout = effectiveTimeout;
    if (!kIsWeb) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.connectionTimeout = effectiveTimeout;
          client.maxConnectionsPerHost = 8;
          return client;
        },
      );
    }
    return dio;
  }

  /// Returns the active temporary output file for an ongoing HLS conversion
  /// if one is available. When null, the task is either not active or is
  /// writing directly to its final destination path.
  String? activeHlsOutputFor(DownloadTask t) => _hlsActiveOutputs[t];

  Future<void> _runTaskFile(DownloadTask t, {required bool resume}) async {
    try {
      if (resume) {
        final hadBgId = _backgroundTaskIdFor(t) != null;
        final resumed = await _tryResumeBackgroundDownload(t);
        if (resumed == null && hadBgId) {
          // Background downloader metadata not yet available; retry after
          // the next sync instead of enqueuing a duplicate task.
          return;
        }
        if (resumed == true) {
          return;
        }
      }
      await _startBackgroundDownload(t);
    } catch (_) {
      if (t.state != 'paused') {
        t.state = 'error';
        t.paused = false;
        _notifyDownloadsUpdated();
        notifyListeners();
        await _saveState();
      }
    }
  }

  Future<bool?> _tryResumeBackgroundDownload(DownloadTask task) async {
    final existingId = _backgroundTaskIdFor(task);
    if (existingId == null) {
      return false;
    }
    try {
      await _bgDownloader.ready;
    } catch (_) {}
    final handle = await _backgroundHandleForTask(task);
    if (handle == null) {
      return null;
    }
    _bgTasksById[handle.taskId] = task;

    bg.TaskStatus? status;
    try {
      final record = await _bgDownloader.database.recordForId(handle.taskId);
      if (record != null) {
        status = record.status;
        _applyBackgroundRecord(task, record);
      }
    } catch (_) {}

    switch (status) {
      case bg.TaskStatus.enqueued:
      case bg.TaskStatus.waitingToRetry:
      case bg.TaskStatus.running:
        return true;
      case bg.TaskStatus.complete:
        if (handle is bg.DownloadTask) {
          unawaited(_onBackgroundTaskComplete(handle, task));
        } else {
          _detachBackgroundTask(handle.taskId);
        }
        return true;
      case bg.TaskStatus.paused:
        final ok = await _bgDownloader.resume(handle);
        if (!ok) {
          _detachBackgroundTask(handle.taskId);
        }
        return ok;
      case bg.TaskStatus.canceled:
        task.state = 'paused';
        task.paused = true;
        _notifyDownloadsUpdated();
        notifyListeners();
        _detachBackgroundTask(handle.taskId);
        return true;
      case bg.TaskStatus.failed:
      case bg.TaskStatus.notFound:
        _detachBackgroundTask(handle.taskId);
        return false;
      case null:
        // If we cannot determine status, assume the native task is still active
        // to avoid spawning a duplicate download. The periodic sync will update
        // progress once the downloader reports again.
        return true;
    }
  }

  Future<void> _startBackgroundDownload(DownloadTask task) async {
    final file = File(task.savePath);
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final headers = await _headersFor(task.url);
    final split = await _backgroundPathComponents(task.savePath);
    final displayName =
        task.name?.trim().isNotEmpty == true
            ? task.name!.trim()
            : p.basename(task.savePath);
    final bgTask = bg.DownloadTask(
      url: task.url,
      filename: split.$3,
      directory: split.$2,
      baseDirectory: split.$1,
      headers: headers,
      group: _bgDownloadGroup,
      updates: bg.Updates.statusAndProgress,
      allowPause: true,
      displayName: displayName,
      metaData: task.savePath,
    );
    _maybeConfigureBackgroundNotification(task, bgTask);
    _registerBackgroundTaskHandle(task, bgTask);
    final enqueued = await _bgDownloader.enqueue(bgTask);
    if (!enqueued) {
      _detachBackgroundTask(bgTask.taskId);
      throw Exception('enqueue_failed');
    }
    task.state = 'queued';
    task.paused = false;
    task.received = 0;
    task.total = null;
    _notifyDownloadsUpdated();
    notifyListeners();
    await _saveState();
  }

  Future<(bg.BaseDirectory, String, String)> _backgroundPathComponents(
    String absolutePath,
  ) async {
    final normalizedPath = p.normalize(absolutePath);
    final dirPath = p.dirname(normalizedPath);
    final fileName = p.basename(normalizedPath);

    try {
      final docs = await getApplicationDocumentsDirectory();
      final docsPath = p.normalize(docs.path);
      if (p.isWithin(docsPath, dirPath) || dirPath == docsPath) {
        final relative = p.relative(dirPath, from: docsPath);
        final directory = relative == '.' ? '' : relative;
        return (bg.BaseDirectory.applicationDocuments, directory, fileName);
      }
    } catch (_) {}

    try {
      final support = await getApplicationSupportDirectory();
      final supportPath = p.normalize(support.path);
      if (p.isWithin(supportPath, dirPath) || dirPath == supportPath) {
        final relative = p.relative(dirPath, from: supportPath);
        final directory = relative == '.' ? '' : relative;
        return (bg.BaseDirectory.applicationSupport, directory, fileName);
      }
    } catch (_) {}

    try {
      final temp = await getTemporaryDirectory();
      final tempPath = p.normalize(temp.path);
      if (p.isWithin(tempPath, dirPath) || dirPath == tempPath) {
        final relative = p.relative(dirPath, from: tempPath);
        final directory = relative == '.' ? '' : relative;
        return (bg.BaseDirectory.temporary, directory, fileName);
      }
    } catch (_) {}

    final directory = dirPath.startsWith('/') ? dirPath.substring(1) : dirPath;
    return (bg.BaseDirectory.root, directory, fileName);
  }
}

/// Simple wrapper for iOS 系統子母畫面（PiP）。
/// 需在 iOS 原生端實作 MethodChannel 'app.pip' 的方法：
/// - isAvailable -> bool
/// - enter -> bool（啟動成功）
/// - exit -> void
/// 若未實作，這些方法會回傳 false 並不影響 App。
class SystemPip {
  static const MethodChannel _ch = MethodChannel('app.pip');
  static String? _lastUrl;
  static final StreamController<int?> _stopEventsController =
      StreamController<int?>.broadcast();
  static bool _handlerBound = false;

  static void _ensureHandlerBound() {
    if (_handlerBound) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onPiPStopped') {
        int? position;
        final args = call.arguments;
        if (args is Map) {
          final value = args['positionMs'];
          if (value is int) {
            position = value;
          }
        } else if (args is int) {
          position = args;
        }
        _stopEventsController.add(position);
        return null;
      }
      return null;
    });
    _handlerBound = true;
  }

  static Stream<int?> get stopEvents {
    _ensureHandlerBound();
    return _stopEventsController.stream;
  }

  /// 只準備原生播放器（不啟動 PiP）
  static Future<bool> prepare({required String url, int? positionMs}) async {
    _ensureHandlerBound();
    try {
      final params = <String, dynamic>{
        'url': url,
        if (positionMs != null) 'positionMs': positionMs,
      };
      final ok = await _ch.invokeMethod('prepare', params);
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 預先建立原生 PiP 播放資源，但不觸發進入 PiP。
  static Future<bool> prime({
    required String url,
    int? positionMs,
    bool? isPlaying,
  }) async {
    _ensureHandlerBound();
    try {
      final params = <String, dynamic>{
        'url': url,
        if (positionMs != null) 'positionMs': positionMs,
        if (isPlaying != null) 'isPlaying': isPlaying,
      };
      final ok = await _ch.invokeMethod('prime', params);
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> updateHostViewFrame(Rect rect) async {
    _ensureHandlerBound();
    try {
      await _ch.invokeMethod('updateHostViewFrame', {
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
      });
    } catch (_) {}
  }

  static Future<bool> isAvailable() async {
    _ensureHandlerBound();
    try {
      final ok = await _ch.invokeMethod('isAvailable');
      // Avoid recursion: just log the value, do not call isAvailable() again.
      print('[PiP] isAvailable -> $ok');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> enter({
    String? url,
    int? positionMs,
    bool? isPlaying,
  }) async {
    _ensureHandlerBound();
    try {
      // If a new URL is provided and differs from the last PiP source, force-exit first.
      if (url != null && _lastUrl != null && _lastUrl != url) {
        try {
          await _ch.invokeMethod('exit');
        } catch (_) {}
        // Small delay to let iOS detach the previous player from PiP.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      final params = <String, dynamic>{
        if (url != null) 'url': url,
        if (positionMs != null) 'positionMs': positionMs,
        if (isPlaying != null) 'isPlaying': isPlaying,
      };

      final ok = await _ch.invokeMethod('enter', params);
      if (ok == true && url != null) {
        _lastUrl = url;
      }
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> exit() async {
    _ensureHandlerBound();
    try {
      final pos = await _ch.invokeMethod('exit');
      if (pos is int) {
        return pos;
      }
    } catch (_) {}
    _lastUrl = null;
    return null;
  }
}

/// Result of attempting to unlock hidden media via biometric authentication.
class LockerResult {
  final bool success;
  final bool requiresPermission;

  const LockerResult({required this.success, this.requiresPermission = false});

  static const LockerResult successResult = LockerResult(success: true);
  static const LockerResult permissionRequired = LockerResult(
    success: false,
    requiresPermission: true,
  );
}

/// Helper class that encapsulates local authentication (e.g. Face ID, Touch ID).
class Locker {
  static final _auth = LocalAuthentication();

  static Future<LockerResult> unlock({String? reason}) async {
    final unlockReason =
        reason ??
        LanguageService.instance.translate('locker.reason.privateMedia');
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        return LockerResult.successResult;
      }
    } catch (_) {
      // If the platform cannot report support, still attempt authentication.
    }
    try {
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) {
        // When biometric permissions are missing (e.g. Face ID disabled for the
        // app) iOS reports that biometrics cannot be checked. Treat this the
        // same as a missing permission so the UI can prompt the user to grant
        // access in Settings.
        return LockerResult.permissionRequired;
      }
    } catch (_) {
      // If the platform throws here, assume we need to guide the user to grant
      // permission before retrying.
      return LockerResult.permissionRequired;
    }
    try {
      final didAuthenticate = await _auth.authenticate(
        localizedReason: unlockReason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      return LockerResult(success: didAuthenticate);
    } on PlatformException catch (e) {
      final code = (e.code).toLowerCase();
      final permissionCodes = {
        auth_error.notAvailable.toLowerCase(),
        auth_error.notEnrolled.toLowerCase(),
        auth_error.passcodeNotSet.toLowerCase(),
        auth_error.lockedOut.toLowerCase(),
        auth_error.permanentlyLockedOut.toLowerCase(),
      };
      if (permissionCodes.contains(code)) {
        return LockerResult.permissionRequired;
      }
      return const LockerResult(success: false);
    } catch (_) {
      return const LockerResult(success: false);
    }
  }
}

/// Public trigger for UI to rescan downloads folder on demand.
/// Public trigger for UI to rescan downloads folder on demand.
Future<void> rescanDownloadsFolder() => AppRepo.I.importExistingFiles();
