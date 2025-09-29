import 'dart:async';
import 'dart:io';
import 'dart:ui'
    show Offset, Rect; // for mini player free-positioning & PiP sync
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:dio/dio.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:share_plus/share_plus.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_localizations.dart';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_hls_parser/flutter_hls_parser.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'notification_service.dart';
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
  static String jsSetEnabled(bool on) =>
      "window._SNF_ON = " + (on ? "true" : "false") + ";";

  /// JavaScript code injected into webpages to intercept media/image requests.
  /// It hooks into fetch, XMLHttpRequest, and media tags (video/audio/img) to
  /// capture URLs of resources, reporting them back to Flutter via the
  /// 'sniffer' handler. It also grabs duration from <video>/<audio> when ready
  /// and filters OUT everything that is not image/video/audio.
  static const jsHook = r"""
  (function(){
    // On/off toggle flag (Flutter can set window._SNF_ON later)
    if (typeof window._SNF_ON === 'undefined') window._SNF_ON = true;

    const send = (p) => {
      if (!window._SNF_ON) return;
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
            send({url, type, contentType: ct, duration: null});
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
                send({url, type, contentType: ct, duration: null});
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
          send({url: u, type: type, contentType: '', duration: d, poster: (el.poster || '')});
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
class HomeItem {
  /// The destination URL that will be loaded when this item is tapped.
  String url;

  /// A user defined title shown under the favicon. If empty, the host part
  /// of [url] will be used as a fallback in the UI.
  String name;

  /// Local path to the cached favicon for this shortcut. May be null if the
  /// icon has not been downloaded yet or failed to download.
  String? iconPath;

  HomeItem({required this.url, required this.name, this.iconPath});

  factory HomeItem.fromJson(Map<String, dynamic> json) {
    return HomeItem(
      url: json['url'] as String? ?? '',
      name: json['name'] as String? ?? '',
      iconPath: json['iconPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
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

  /// Tracks the last emitted file size for HLS conversion progress. Used to
  /// throttle UI updates during FFmpeg processing so that the UI remains
  /// responsive without flooding with notifications. The key is the task and
  /// the value is the last reported file size in bytes.
  final Map<DownloadTask, int> _lastHlsSize = {};

  /// Initialise the repository. Must be called before using [AppRepo.I].
  /// It loads previously persisted state from disk and prepares directories.
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    // Place the state file in the app documents directory. This directory
    // persists across restarts and appears in the Files app on iOS.
    _stateFilePath = '${dir.path}/app_state.json';
    await _loadState();
    await importExistingFiles();
  }

  /// Returns the persistent downloads directory inside the app's Documents.
  Future<Directory> _downloadsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns a persistent directory for storing generated media thumbnails.
  ///
  /// Thumbnails used to live inside the temporary cache directory which iOS
  /// may purge at any time. When that happened the app would lose previews for
  /// older downloads after a restart. Keeping them inside Documents ensures
  /// they survive restarts and are not deleted unexpectedly.
  Future<Directory> _thumbnailsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, '.thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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
      if (!File(task.savePath).existsSync()) continue;

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
      }
      final existing = current.map((t) => _canonicalPath(t.savePath)).toSet();

      // Track tasks whose files are currently missing so we can re-bind them
      // if the underlying file was renamed outside the app (e.g. via Files).
      final List<DownloadTask> missing = [];
      final Map<int, List<DownloadTask>> missingBySize = {};
      for (final task in current) {
        final exists = File(task.savePath).existsSync();
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
        if (e is! File) continue;
        final path = e.path;
        // Skip hidden/system files to avoid importing metadata artefacts.
        if (p.basename(path).startsWith('.')) continue;
        final norm = _canonicalPath(path);
        // Filter by common media extensions
        final lower = path.toLowerCase();
        final isMedia =
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

        final stat = await (e as File).stat();
        final fileSize = stat.size;

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

      // Deduplicate by normalised path while keeping richest metadata.
      final Map<String, DownloadTask> byPath = {};
      int score(DownloadTask t) {
        var s = 0;
        if (File(t.savePath).existsSync()) s += 3;
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

        'resume': _resumePositionsMs,

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
      final dio = Dio();
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
      final dio = Dio();
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
      final dio = Dio();
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

      final cmd =
          "-y -loglevel error -ss ${capturePoint.toStringAsFixed(2)} -i '${t.savePath}' "
          "-frames:v 1 -vf \"scale=320:-1:flags=lanczos\" -q:v 3 '$thumbPath'";
      final session = await FFmpegKit.execute(cmd);
      ReturnCode? rc;
      try {
        rc = await session.getReturnCode();
      } on PlatformException catch (err, stack) {
        if (kDebugMode) {
          debugPrint(
            'FFmpegKit session result unavailable: $err\n${stack.toString()}',
          );
        }
      }
      final thumbFile = File(thumbPath);
      final thumbExists = thumbFile.existsSync();
      if ((rc == null || rc.isValueSuccess()) && thumbExists) {
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
      // ignore: unawaited_futures
      _saveState();
    } catch (_) {}
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
    _saveState();
  }

  /// Remove tasks from the list and delete their associated files. Also
  /// deletes thumbnails. Updates persistent state.
  Future<void> removeTasks(
    List<DownloadTask> tasks, {
    bool deleteFiles = true,
  }) async {
    final current = [...downloads.value];
    for (final t in tasks) {
      final cancelToken = _dioTokens.remove(t);
      if (cancelToken != null && !cancelToken.isCancelled) {
        try {
          cancelToken.cancel('task removed');
        } catch (_) {}
      }
      final ffmpegSessionId = _ffmpegSessions.remove(t);
      if (ffmpegSessionId != null) {
        try {
          await FFmpegKit.cancel(ffmpegSessionId);
        } catch (_) {}
      }
      _hlsActiveOutputs.remove(t);
      _lastHlsSize.remove(t);
      current.remove(t);
      if (deleteFiles) {
        try {
          final f = File(t.savePath);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
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
      if (t.kind == 'yt-merge') {
        await _cleanupYtMergeWorkspace(t);
      } else if (t.kind == 'hls') {
        await _cleanupHlsWorkspace(t);
      }
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

  Future<bool> retainOnlyCompletedDownloads() async {
    final current = [...downloads.value];
    final kept =
        current
            .where((t) => (t.state).toString().toLowerCase() == 'done')
            .toList();
    if (kept.length == current.length) {
      return false;
    }
    downloads.value = kept;
    notifyListeners();
    await _saveState();
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
        final dio = Dio();
        final candidates = <String>[
          'https://$host/favicon.ico',
          'https://$host/apple-touch-icon.png',
          'https://$host/apple-touch-icon-precomposed.png',
          'https://$host/favicon.png',
          'https://www.google.com/s2/favicons?domain=$host&sz=128',
        ];
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
  }

  /// Resume downloads that were interrupted by an app restart. Tasks that were
  /// previously paused remain paused. Tasks that were still queued will be
  /// started and tasks that were mid-download will continue from where they
  /// left off when possible.
  Future<void> resumeIncompleteDownloads() async {
    final tasks = List<DownloadTask>.from(downloads.value);
    for (final task in tasks) {
      if (task.state == 'paused' || task.paused) {
        task.paused = true;
        task.state = 'paused';
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
        } else if (task.kind == 'yt-merge') {
          unawaited(_runTaskYoutubeMerge(task));
        } else {
          unawaited(_runTaskHls(task));
        }
      }
    }
  }

  final ValueNotifier<bool> snifferEnabled = ValueNotifier(true);

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

  /// Active HTTP cancel tokens for Dio downloads (file kind).
  final Map<DownloadTask, CancelToken> _dioTokens = {};

  /// Active FFmpeg session ids for HLS downloads (hls kind).
  final Map<DownloadTask, int> _ffmpegSessions = {};

  /// Tracks the active output file path for HLS conversions. When a conversion
  /// is resumed we write to a temporary chunk; this map lets progress probes
  /// read the correct file instead of the final destination.
  final Map<DownloadTask, String> _hlsActiveOutputs = {};

  /// Directory containing cached favicons for home shortcuts.
  Directory? _homeIconDirectory;

  /// In-flight favicon download tasks keyed by host. Prevents duplicate
  /// network requests when multiple widgets request the same favicon.
  final Map<String, Future<void>> _homeIconTasks = {};

  /// Path to the JSON file used to persist app state (tasks, favourites, settings).
  late String _stateFilePath;

  void setSnifferEnabled(bool on) {
    final effective = isPremiumUnlocked ? on : false;
    if (snifferEnabled.value == effective) return;
    snifferEnabled.value = effective;
    notifyListeners();
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

  void addHit(MediaHit h) {
    final normalizedType = _normalizeHitType(h.url, h.type, h.contentType);
    final normalizedHit = h.copyWith(type: normalizedType);
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
      list[idx] = cur.copyWith(
        type: mergedType,
        contentType: mergedContentType,
        poster: mergedPoster,
        durationSeconds: mergedDuration,
      );
    } else {
      list.add(normalizedHit);
    }
    hits.value = list;
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

  /// Shares a file via share_plus.
  Future<void> shareFile(String path) async {
    await Share.shareXFiles([XFile(path)]);
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

    final lower0 = url.toLowerCase();
    final bool isHls = lower0.contains('.m3u8');
    final bool isDash = lower0.contains('.mpd');
    var kind = kindOverride ?? (isHls ? 'hls' : (isDash ? 'dash' : 'file'));
    final innerUrl = _extractInnerUrl(url) ?? url;
    var type = explicitType ?? _inferType(innerUrl);

    var ext =
        forcedExtension ??
        ((isHls || isDash) ? 'mp4' : _extensionFromUrl(innerUrl));
    if (ext.isEmpty || ext == 'bin') {
      ext = forcedExtension ?? _defaultExtensionForType(type);
    }

    final stem =
        _preferredDownloadStem(url: innerUrl) ??
        _preferredDownloadStem(url: url);
    final suggested =
        suggestedName ?? stem ?? ytTitle.value ?? currentPageTitle.value;
    final out = await _tempFilePath(ext, suggestedName: suggested);

    final task = DownloadTask(
      url: url,
      savePath: out,
      kind: kind,
      type: type,
      name: suggested,
      extra: extra,
    );
    downloads.value = [...downloads.value, task];
    await _saveState();
    notifyListeners();

    try {
      await FirebaseAnalytics.instance.logEvent(
        name: 'download_enqueue',
        parameters: {
          'kind': kind,
          'type': type,
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
          extra: mergedExtra,
        );
      case YtOptionType.videoOnly:
        return _enqueueDirectTask(
          option.downloadUrl,
          suggestedName: suggested,
          forcedExtension: option.fileExtension,
          explicitType: 'video',
          extra: mergedExtra,
        );
      case YtOptionType.audioOnly:
        return _enqueueDirectTask(
          option.downloadUrl,
          suggestedName: suggested,
          forcedExtension: option.fileExtension,
          explicitType: 'audio',
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
    return options.firstWhereOrNull((o) => o.type == YtOptionType.muxed) ??
        options.firstWhereOrNull((o) => o.type == YtOptionType.videoAudio) ??
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
        final token = _dioTokens.remove(t);
        if (token != null && !token.isCancelled) token.cancel('user pause');
        t.paused = true;
        t.state = 'paused';
      } else if (t.kind == 'hls') {
        final id = _ffmpegSessions.remove(t);
        if (id != null) {
          await FFmpegKit.cancel(id);
        }
        t.paused = true;
        t.state = 'paused';
      } else if (t.kind == 'yt-merge') {
        final token = _dioTokens.remove(t);
        if (token != null && !token.isCancelled) token.cancel('user pause');
        final id = _ffmpegSessions.remove(t);
        if (id != null) {
          await FFmpegKit.cancel(id);
        }
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
      _runTaskHls(t);
    } else if (t.kind == 'dash') {
      _runTaskDash(t);
    } else if (t.kind == 'yt-merge') {
      _runTaskYoutubeMerge(t);
    } else {
      _runTask(t);
    }
  }

  /// Runs the download task. For HLS, uses FFmpeg to remux the m3u8 playlist
  /// into an MP4. For direct media files, uses Dio for streaming download.
  Future<void> _runTask(DownloadTask t) async {
    t.state = 'downloading';
    notifyListeners();
    if (t.kind == 'hls') {
      await _runTaskHls(t);
    } else if (t.kind == 'dash') {
      await _runTaskDash(t);
    } else if (t.kind == 'yt-merge') {
      await _runTaskYoutubeMerge(t);
    } else {
      await _runTaskFile(t, resume: false);
    }
  }

  Future<void> _runTaskYoutubeMerge(DownloadTask t) async {
    final meta = (t.extra?['yt'] as Map<String, dynamic>?) ?? const {};
    final videoUrl = (meta['videoUrl'] as String?) ?? t.url;
    final audioUrl = meta['audioUrl'] as String?;
    if (audioUrl == null || videoUrl.isEmpty) {
      t.state = 'error';
      notifyListeners();
      await _saveState();
      return;
    }

    int? parseItag(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    }

    final videoId = meta['videoId'] as String?;
    final videoItag = parseItag(meta['itag']);
    final audioItag = parseItag(meta['audioItag']);

    final sourceUrl = meta['sourceUrl'] as String?;
    final fileExtRaw = (meta['fileExtension'] as String?) ?? 'mp4';
    final audioExtRaw = (meta['audioContainer'] as String?) ?? 'm4a';
    final fileExt = fileExtRaw.isEmpty ? 'mp4' : fileExtRaw;
    final audioExt = audioExtRaw.isEmpty ? 'm4a' : audioExtRaw;

    final dio = Dio();
    final token = CancelToken();
    _dioTokens[t] = token;

    final workspace = await _ensureYtMergeWorkspace(t);
    final videoTemp = p.join(workspace.path, 'video.$fileExt');
    final audioTemp = p.join(workspace.path, 'audio.$audioExt');

    Future<int> existingLength(String path) async {
      try {
        final file = File(path);
        if (await file.exists()) {
          return await file.length();
        }
      } catch (_) {}
      return 0;
    }

    int aggregate =
        await existingLength(videoTemp) + await existingLength(audioTemp);
    if (aggregate > 0) {
      t.received = aggregate;
      _notifyDownloadsUpdated();
    }
    int totalExpected = 0;

    Future<void> cleanupTemps({required bool keepPartial}) async {
      if (keepPartial) {
        return;
      }
      await _cleanupYtMergeWorkspace(t);
    }

    void handleChunk(int chunkLength) {
      aggregate += chunkLength;
      t.received = aggregate;
      _notifyDownloadsUpdated();
      if (aggregate % (128 * 1024) == 0) {
        notifyListeners();
      }
    }

    Future<int?> probeLength(
      String targetUrl,
      Map<String, String> headers,
    ) async {
      try {
        final resp = await dio.head(
          targetUrl,
          options: Options(
            headers: headers,
            followRedirects: true,
            validateStatus: (_) => true,
          ),
        );
        final cl = resp.headers.value(HttpHeaders.contentLengthHeader);
        final parsed = int.tryParse(cl ?? '');
        if (parsed != null && parsed > 0) {
          return parsed;
        }
      } catch (_) {}
      return null;
    }

    Future<int> downloadPart(
      String targetUrl,
      String outputPath,
      Map<String, String> headers,
    ) async {
      final file = File(outputPath);

      await file.create(recursive: true);
      int start = 0;
      try {
        if (await file.exists()) {
          start = await file.length();
        }
      } catch (_) {
        start = 0;
      }

      final hdrs = Map<String, String>.from(headers);
      if (start > 0) {
        hdrs[HttpHeaders.rangeHeader] = 'bytes=$start-';
      }

      final resp = await dio.get<ResponseBody>(
        targetUrl,
        options: Options(
          headers: hdrs,
          responseType: ResponseType.stream,
          followRedirects: true,
          validateStatus:
              (status) => status != null && status >= 200 && status < 400,
        ),
        cancelToken: token,
      );

      final status = resp.statusCode ?? HttpStatus.ok;
      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        return await file.length();
      }

      if (start > 0 && status == HttpStatus.ok) {
        aggregate -= start;
        if (aggregate < 0) aggregate = 0;
        t.received = aggregate;
        _notifyDownloadsUpdated();
        await file.writeAsBytes(const [], flush: true);
        start = 0;
      }

      final sink = file.openWrite(mode: FileMode.append);
      try {
        await for (final chunk in resp.data!.stream) {
          if (chunk.isEmpty) continue;
          if (token.isCancelled) break;
          sink.add(chunk);
          handleChunk(chunk.length);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      return await file.exists() ? await file.length() : 0;
    }

    try {
      final videoHeaders = await _headersFor(videoUrl);
      final audioHeaders = await _headersFor(audioUrl);
      if (sourceUrl != null && sourceUrl.isNotEmpty) {
        videoHeaders['Referer'] = sourceUrl;
        audioHeaders['Referer'] = sourceUrl;
      }

      final videoLen = await probeLength(videoUrl, videoHeaders);
      final audioLen = await probeLength(audioUrl, audioHeaders);
      if (videoLen != null) totalExpected += videoLen;
      if (audioLen != null) totalExpected += audioLen;
      if (totalExpected > 0) {
        t.total = totalExpected;
        _notifyDownloadsUpdated();
        notifyListeners();
      } else {
        t.total = null;
      }

      await downloadPart(videoUrl, videoTemp, videoHeaders);
      if (token.isCancelled) {
        t.paused = true;
        t.state = 'paused';

        await _saveState();
        return;
      }
      final videoBytesNow = await existingLength(videoTemp);
      final preAudioBytes = await existingLength(audioTemp);
      final diskTotalBeforeAudio = videoBytesNow + preAudioBytes;
      if (diskTotalBeforeAudio > aggregate) {
        aggregate = diskTotalBeforeAudio;
        t.received = aggregate;
        _notifyDownloadsUpdated();
      }
      Future<void> ensureLocalStream({
        required String path,
        required String kind,
        required int? itag,
        required Future<int> Function() fallback,
      }) async {
        final file = File(path);
        final exists = await file.exists();
        final hasSize = exists ? await file.length() > 0 : false;
        if (hasSize) {
          return;
        }
        if (token.isCancelled) {
          throw const YoutubeStreamCancelled();
        }
        if (itag == null || videoId == null) {
          throw StateError('Missing YouTube metadata to recover $kind track');
        }
        final produced = await fallback();
        if (produced <= 0 || !await file.exists()) {
          throw StateError('Failed to fetch YouTube $kind stream');
        }
      }

      Future<int> downloadVideoFallback() async {
        final existing = await existingLength(videoTemp);
        var skipResume = existing > 0;
        return await downloadYoutubeStreamToFile(
          videoId: videoId!,
          itag: videoItag!,
          destinationPath: videoTemp,
          onBytes: (bytes) {
            if (skipResume) {
              skipResume = false;
              if (bytes == existing) {
                return;
              }
              aggregate -= existing;
              if (aggregate < 0) aggregate = 0;
              t.received = aggregate;
              _notifyDownloadsUpdated();
            }
            handleChunk(bytes);
          },
          shouldAbort: () => token.isCancelled,
        );
      }

      Future<int> downloadAudioFallback() async {
        final existing = await existingLength(audioTemp);
        var skipResume = existing > 0;
        return await downloadYoutubeStreamToFile(
          videoId: videoId!,
          itag: audioItag!,
          destinationPath: audioTemp,
          onBytes: (bytes) {
            if (skipResume) {
              skipResume = false;
              if (bytes == existing) {
                return;
              }
              aggregate -= existing;
              if (aggregate < 0) aggregate = 0;
              t.received = aggregate;
              _notifyDownloadsUpdated();
            }
            handleChunk(bytes);
          },
          shouldAbort: () => token.isCancelled,
        );
      }

      if (videoId != null && videoItag != null) {
        try {
          await ensureLocalStream(
            path: videoTemp,
            kind: 'video',
            itag: videoItag,
            fallback: downloadVideoFallback,
          );
        } on YoutubeStreamCancelled {
          t.paused = true;
          t.state = 'paused';

          await _saveState();
          return;
        }
      }

      await downloadPart(audioUrl, audioTemp, audioHeaders);
      if (token.isCancelled) {
        t.paused = true;
        t.state = 'paused';

        await _saveState();
        return;
      }
      final audioBytesNow = await existingLength(audioTemp);
      final diskTotal = await existingLength(videoTemp) + audioBytesNow;
      if (diskTotal > aggregate) {
        aggregate = diskTotal;
        t.received = aggregate;
        _notifyDownloadsUpdated();
      }
      if (videoId != null && audioItag != null) {
        try {
          await ensureLocalStream(
            path: audioTemp,
            kind: 'audio',
            itag: audioItag,
            fallback: downloadAudioFallback,
          );
        } on YoutubeStreamCancelled {
          t.paused = true;
          t.state = 'paused';

          await _saveState();
          return;
        }
      }

      _dioTokens.remove(t);

      final cmd =
          "-y -i '${videoTemp}' -i '${audioTemp}' -c copy -movflags +faststart '${t.savePath}'";
      final session = await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          if (rc != null && rc.isValueSuccess()) {
            try {
              final outFile = File(t.savePath);
              if (await outFile.exists()) {
                final len = await outFile.length();
                t.received = len;
                t.total = len;
              }
            } catch (_) {}
            t.state = 'done';
            _normalizeTaskType(t);
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
          } else if (t.state != 'paused') {
            t.state = 'error';
            _notifyDownloadsUpdated();
            notifyListeners();
          }
          _ffmpegSessions.remove(t);
          await cleanupTemps(keepPartial: t.state == 'paused');
          await _saveState();
        },
        (log) {
          if (kDebugMode) {
            print('ffmpeg(yt-merge): ${log.getMessage()}');
          }
        },
        (_) {},
      );
      final id = await session.getSessionId();
      if (id != null) _ffmpegSessions[t] = id;
    } on DioException catch (e) {
      if (!CancelToken.isCancel(e) && t.state != 'paused') {
        t.state = 'error';
        if (kDebugMode) print('youtube merge download error: $e');
        _notifyDownloadsUpdated();
        notifyListeners();
      } else {
        t.paused = true;
        t.state = 'paused';
      }
      await cleanupTemps(keepPartial: t.state == 'paused');
      await _saveState();
    } catch (e) {
      if (t.state != 'paused') {
        t.state = 'error';
        if (kDebugMode) print('youtube merge error: $e');
        _notifyDownloadsUpdated();
        notifyListeners();
      }
      await cleanupTemps(keepPartial: t.state == 'paused');
      await _saveState();
    } finally {
      _dioTokens.remove(t);
    }
  }

  Future<void> _runTaskDash(DownloadTask t) async {
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
      final session = await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          if (rc != null && rc.isValueSuccess()) {
            t.state = 'done';
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
            }
          }
          await _saveState();
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
      if (t.state != 'paused') {
        t.state = 'error';
        notifyListeners();
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
      final dio = Dio();
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

      int resumedSegments = 0;
      if (progressTask != null) {
        for (int i = 0; i < mediaSegs.length; i++) {
          final existing = File(p.join(workDir.path, 'seg_$i.ts'));
          if (await existing.exists()) {
            try {
              final len = await existing.length();
              if (len > 0) {
                resumedSegments++;
                continue;
              }
            } catch (_) {}
          }
          break;
        }
        if (resumedSegments > 0) {
          progressTask.received = resumedSegments;
          _notifyDownloadsUpdated();
        }
      }

      // Build local m3u8 content
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

      int index = 0;
      for (final absUri in mediaSegs) {
        final abs = absUri.toString();
        if (progressTask != null &&
            (progressTask.state == 'paused' || progressTask.paused)) {
          throw const _DownloadCancelled();
        }
        final outPath = p.join(workDir.path, 'seg_$index.ts');
        final f = File(outPath);
        bool hasExisting = false;
        if (await f.exists()) {
          try {
            final len = await f.length();
            if (len > 0) {
              hasExisting = true;
            } else {
              await f.delete();
            }
          } catch (_) {}
        }

        if (!hasExisting) {
          // Fetch segment bytes with headers
          final resp = await dio.get<List<int>>(
            abs,
            options: Options(
              responseType: ResponseType.bytes,
              headers: hdrs,
              followRedirects: true,
            ),
          );
          List<int> data = resp.data ?? const [];

          // Strip leading junk until MPEG-TS sync (0x47 appearing on 188-byte cadence).
          int start = 0;
          for (int i = 0; i < data.length; i++) {
            final b = data[i];
            if (b == 0x47) {
              // Heuristic: also check next 188 bytes if possible
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
        }

        // Write EXTINF with duration (fallback 4.0 if null)
        double durSec = 4.0;
        if (parsed is HlsMediaPlaylist &&
            index < parsed.segments.length &&
            parsed.segments[index].durationUs != null) {
          durSec = parsed.segments[index].durationUs! / 1000000.0;
        }
        sb.writeln('#EXTINF:${durSec.toStringAsFixed(3)},');
        sb.writeln(p.basename(outPath));

        // progress update by segment count (lightweight and reliable)
        if (progressTask != null) {
          if (progressTask.state == 'paused' || progressTask.paused) {
            throw const _DownloadCancelled();
          }
          progressTask.received = index + 1;
          // propagate update to downloads list for UI progress
          _notifyDownloadsUpdated();
          if ((index % 5) == 0) {
            notifyListeners();
          }
        }
        index++;
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

      final dio = client ?? Dio();
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

  Future<void> _runTaskHls(DownloadTask t) async {
    try {
      // Detect suspicious .jpeg segments and pre-sanitize if needed
      String inputUrl = t.url;
      try {
        final hdrsProbe = await _headersFor(t.url);
        final dioProbe = Dio();
        final probe = await dioProbe.get<String>(
          t.url,
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
            playlistUrl: t.url,
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
      final h = await _headersFor(t.url);
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
              return;
            }
            t.state = 'done';
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
            t.progressUnit = null;
            _lastHlsSize.remove(t);
            _normalizeTaskType(t);

            _notifyDownloadsUpdated();
            notifyListeners();
            await _generatePreview(t);
            _maybeNotifyDownloadComplete(t);
            try {
              await FirebaseAnalytics.instance.logEvent(
                name: 'download_complete',
                parameters: {'kind': 'hls', 'type': t.type, 'path': t.savePath},
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
            } else {
              t.state = 'error';
              _notifyDownloadsUpdated();
              notifyListeners();
              try {
                await FirebaseAnalytics.instance.logEvent(
                  name: 'download_error',
                  parameters: {'kind': 'hls'},
                );
              } catch (_) {}

              if (!t.url.startsWith('file:') &&
                  !t.url.startsWith('/') &&
                  !t.url.contains('/hls_sanitize_')) {
                try {
                  final local = await _sanitizeHlsToLocal(
                    t.url,
                    progressTask: t,
                  );
                  if (local != null) {
                    await _clearHlsManifest(t);
                    await _cleanupHlsWorkspace(t);
                    final h2 = await _headersFor(t.url);
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
          try {
            final f = File(activePath);
            if (await f.exists()) {
              final len = await f.length();
              final last = _lastHlsSize[t] ?? 0;

              if (len >= last + (16 * 1024)) {
                _lastHlsSize[t] = len;
                _notifyDownloadsUpdated();
                notifyListeners();
              }
            }
          } catch (_) {}
          try {
            final ms = stat.getTime();
            if (ms != null &&
                (t.progressUnit == 'time-ms') &&
                (t.total ?? 0) > 0) {
              final newMs = (resumeMs + ms).clamp(0, t.total!);
              if (newMs > t.received) {
                t.received = newMs;
                _notifyDownloadsUpdated();
              }
            }
          } catch (_) {}
        },
      );
      final id = await session.getSessionId();
      if (id != null) _ffmpegSessions[t] = id;
    } on _DownloadCancelled {
      return;
    } catch (e) {
      if (t.state != 'paused') {
        t.state = 'error';
        _notifyDownloadsUpdated();
        notifyListeners();

        await _saveState();
      }
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

      t.total = imageUris.length;
      t.received = resumeData.completed.length;
      t.progressUnit = null;
      t.state = 'downloading';
      _notifyDownloadsUpdated();
      notifyListeners();
      final dio = Dio();
      final headers = await _headersFor(t.url);
      final frameNames = <String>[];
      var downloadedCount = resumeData.completed.length;
      for (int i = 0; i < imageUris.length; i++) {
        if (t.state == 'paused' || t.paused) {
          throw const _DownloadCancelled();
        }
        final uri = imageUris[i];
        final frameName = 'frame_${i.toString().padLeft(6, '0')}$frameExt';
        final framePath = p.join(framesDir.path, frameName);
        if (resumeData.completed.contains(i)) {
          frameNames.add(frameName);
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
        frameNames.add(frameName);
        resumeData.completed.add(i);
        downloadedCount += 1;
        // update progress by segment count
        t.received = downloadedCount;
        // propagate to listeners (downloads list and others)
        _notifyDownloadsUpdated();
        notifyListeners();
        await _saveHlsImageResume(t, resumeData);
      }
      await _saveHlsImageResume(t, resumeData);
      t.received = t.total ?? downloadedCount;
      t.progressUnit = 'hls-converting';
      _lastHlsSize[t] = 0;
      _notifyDownloadsUpdated();
      notifyListeners();
      // Determine whether all durations are effectively identical so we can
      // leverage the lightweight image2 demuxer with a constant framerate.
      final baseDuration = durations.isNotEmpty ? durations.first : 4.0;
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
              try {
                final output = File(t.savePath);
                if (await output.exists()) {
                  final len = await output.length();
                  final last = _lastHlsSize[t] ?? 0;
                  if (len > last) {
                    _lastHlsSize[t] = len;
                    t.received = len;
                    _notifyDownloadsUpdated();
                    if (len - last >= 256 * 1024) {
                      notifyListeners();
                    }
                  }
                }
              } catch (_) {}
            },
          );
          final id = await session.getSessionId();
          if (id != null) _ffmpegSessions[t] = id;
          final ok = await completer.future;
          _ffmpegSessions.remove(t);
          return ok;
        } on PlatformException catch (e) {
          if (kDebugMode) {
            print('ffmpeg(image-hls) failed to start: $e');
          }
          return false;
        } catch (e) {
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
  }

  /// Helper to notify listeners of changes to the downloads list by reassigning
  /// the value to a new list. This triggers any ValueListenableBuilders
  /// watching [downloads] to rebuild, even when individual tasks mutate.
  void _notifyDownloadsUpdated() {
    // assign a shallow copy to force ValueNotifier to notify
    downloads.value = List<DownloadTask>.from(downloads.value);
  }

  /// Returns the active temporary output file for an ongoing HLS conversion
  /// if one is available. When null, the task is either not active or is
  /// writing directly to its final destination path.
  String? activeHlsOutputFor(DownloadTask t) => _hlsActiveOutputs[t];

  Future<void> _runTaskFile(DownloadTask t, {required bool resume}) async {
    try {
      var file = File(t.savePath);
      int start = 0;
      if (resume && await file.exists()) {
        try {
          start = await file.length();
        } catch (_) {
          start = 0;
        }
      } else {
        // ensure file exists
        if (!await file.exists()) {
          await file.create(recursive: true);
        } else if (!resume) {
          await file.writeAsBytes(const [], flush: true); // truncate
        }
      }
      final token = CancelToken();
      _dioTokens[t] = token;
      final dio = Dio();
      // Inject UA/Referer/Cookie headers for direct file download
      final baseHeaders = await _headersFor(t.url);
      final hdrs = Map<String, String>.from(baseHeaders);
      // 若未知總長，先以 HEAD 或 Range:0-0 試探取得總長，供 UI 顯示百分比
      if (t.total == null || t.total == 0) {
        try {
          final head = await dio.head(
            t.url,
            options: Options(
              headers: hdrs,
              followRedirects: true,
              validateStatus: (_) => true,
            ),
          );
          final cl = head.headers.value(HttpHeaders.contentLengthHeader);
          final n = int.tryParse(cl ?? '');
          if (n != null && n > 0) {
            t.total = n;
            _notifyDownloadsUpdated();
            notifyListeners();
          } else {
            // 部分站點不回 Content-Length；改用 Range 試探從 Content-Range 取總長
            final hdrs2 = Map<String, String>.from(hdrs);
            hdrs2[HttpHeaders.rangeHeader] = 'bytes=0-0';
            final probe = await dio.get<ResponseBody>(
              t.url,
              options: Options(
                headers: hdrs2,
                responseType: ResponseType.stream,
                followRedirects: true,
                validateStatus: (_) => true,
              ),
            );
            final cr = probe.headers.value(HttpHeaders.contentRangeHeader);
            if (cr != null && cr.contains('/')) {
              final totalStr = cr.split('/').last.trim();
              final tot = int.tryParse(totalStr);
              if (tot != null && tot > 0) {
                t.total = tot;
                _notifyDownloadsUpdated();
                notifyListeners();
              }
            }
          }
        } catch (_) {}
      }
      if (start > 0) hdrs[HttpHeaders.rangeHeader] = 'bytes=$start-';
      final opts = Options(
        responseType: ResponseType.stream,
        headers: hdrs,
        followRedirects: true,
      );
      final resp = await dio.get<ResponseBody>(
        t.url,
        options: opts,
        cancelToken: token,
      );
      final headers = resp.headers;
      final contentType = headers.value(HttpHeaders.contentTypeHeader);
      final contentDisposition = headers.value('content-disposition');
      final beforeType = t.type;
      var newType = beforeType;
      final filename = _filenameFromContentDisposition(contentDisposition);
      final filenameExt = _extensionFromFilename(filename);
      final headerType =
          filenameExt != null ? _typeFromExtension(filenameExt) : null;
      if (headerType != null && headerType != 'file') {
        newType = headerType;
      }
      if (contentType != null) {
        final lowerCt = contentType.toLowerCase();
        if (lowerCt.startsWith('audio/')) {
          newType = 'audio';
        } else if (lowerCt.startsWith('image/')) {
          newType = 'image';
        } else if (lowerCt.startsWith('video/') &&
            (newType == beforeType ||
                (newType != 'audio' && newType != 'image'))) {
          newType = 'video';
        }
      }
      if (newType != beforeType) {
        t.type = newType;
        _normalizeTaskType(t);
        _notifyDownloadsUpdated();
        notifyListeners();
      }
      if (filename != null && filename.isNotEmpty) {
        final shouldUpdateName = (t.name == null || t.name!.isEmpty);
        if (shouldUpdateName) {
          t.name = filename;
          _notifyDownloadsUpdated();
          notifyListeners();
        }
      }
      final suggestedExt =
          filenameExt ??
          _extensionFromContentType(contentType) ??
          _defaultExtensionForType(t.type);
      final currentExt = p.extension(t.savePath).replaceFirst('.', '');
      if ((currentExt.isEmpty || currentExt == 'bin') &&
          suggestedExt.isNotEmpty &&
          suggestedExt != 'bin') {
        try {
          final newPath = p.setExtension(t.savePath, '.$suggestedExt');
          await file.rename(newPath);
          final canonical = _canonicalPath(newPath);
          t.savePath = canonical;
          file = File(canonical);
          start = resume && await file.exists() ? await file.length() : start;
          _normalizeTaskType(t);
          _notifyDownloadsUpdated();
          notifyListeners();
        } catch (_) {}
      }
      final sink = file.openWrite(mode: FileMode.append);
      int receivedSince = 0;
      final totalHeader = resp.headers.value(HttpHeaders.contentLengthHeader);
      if (totalHeader != null) {
        // If server returns remaining length when ranged, total = start + remaining.
        final remaining = int.tryParse(totalHeader) ?? 0;
        t.total = remaining > 0 ? start + remaining : t.total;
      }
      await for (final chunk in resp.data!.stream) {
        receivedSince += chunk.length;
        t.received = start + receivedSince;
        sink.add(chunk);
        // propagate progress updates to downloads list
        _notifyDownloadsUpdated();
        // still throttle UI updates for performance; notify global listeners occasionally
        if (t.received % (128 * 1024) == 0) {
          notifyListeners();
        }
        if (token.isCancelled) {
          break;
        }
      }
      await sink.flush();
      await sink.close();
      final detectedExt =
          _extensionFromContentType(contentType) ??
          _detectExtensionFromFile(file.path);
      final currentExtAfter = p.extension(file.path).replaceFirst('.', '');
      if (detectedExt != null &&
          detectedExt.isNotEmpty &&
          detectedExt != 'bin' &&
          currentExtAfter != detectedExt) {
        try {
          final newPath = p.setExtension(file.path, '.$detectedExt');
          await file.rename(newPath);
          final canonical = _canonicalPath(newPath);
          t.savePath = canonical;
          file = File(canonical);
          _normalizeTaskType(t);
          _notifyDownloadsUpdated();
          notifyListeners();
        } catch (_) {}
      }
      _dioTokens.remove(t);
      if (token.isCancelled) {
        // paused by user; keep state as paused
        return;
      }
      t.state = 'done';
      _normalizeTaskType(t);
      // final update of downloads list and global listeners
      _notifyDownloadsUpdated();
      notifyListeners();
      await _generatePreview(t);
      _maybeNotifyDownloadComplete(t);
      try {
        await FirebaseAnalytics.instance.logEvent(
          name: 'download_complete',
          parameters: {
            'kind': 'file',
            'type': t.type,
            'bytes': await File(t.savePath).length(),
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
      await _saveState();
    } catch (e) {
      if (t.state != 'paused') {
        t.state = 'error';
        _notifyDownloadsUpdated();
        notifyListeners();
        if (kDebugMode) print('download error(file): $e');
        await _saveState();
        try {
          await FirebaseAnalytics.instance.logEvent(
            name: 'download_error',
            parameters: {'kind': 'file'},
          );
        } catch (_) {}
        // NOTE: For Flutter Web builds, consider falling back to the `download` package:
        //   final bytes = await http.readBytes(Uri.parse(t.url));
        //   web_download.download(bytes, '${p.basename(t.savePath)}');
        // Mobile (iOS/Android) cannot use `download` for filesystem writes.
      }
    }
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
