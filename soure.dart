import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:collection/collection.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:share_plus/share_plus.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
        contentType.startsWith('video/') ||
        contentType.startsWith('audio/') ||
        contentType.startsWith('image/');
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

/// Represents a download task for either a direct media file or HLS playlist.
class DownloadTask {
  final String url;
  final String savePath;
  final String kind; // 'hls' | 'file'
  int received = 0;
  int? total;
  String state = 'queued'; // queued/downloading/done/error
  DownloadTask({required this.url, required this.savePath, required this.kind});
}

/// Application repository managing detected media hits, download tasks, and favorites.
/// It also handles downloading/ converting HLS media to MP4/MOV and saving
/// downloaded files into the photo gallery.
class AppRepo extends ChangeNotifier {
  static final AppRepo I = AppRepo._();
  AppRepo._();

  final ValueNotifier<bool> snifferEnabled = ValueNotifier(true);

  final ValueNotifier<List<MediaHit>> hits = ValueNotifier([]);
  final ValueNotifier<List<DownloadTask>> downloads = ValueNotifier([]);
  final ValueNotifier<List<String>> favorites = ValueNotifier([]); // 收藏 URL

  void setSnifferEnabled(bool on) {
    if (snifferEnabled.value == on) return;
    snifferEnabled.value = on;
    notifyListeners();
  }

  /// Adds a media hit or merges if URL already exists.
  void addHit(MediaHit h) {
    final list = [...hits.value];
    final idx = list.indexWhere((e) => e.url == h.url);
    if (idx >= 0) {
      final cur = list[idx];
      list[idx] = cur.copyWith(
        type: cur.type.isEmpty ? h.type : cur.type,
        contentType: cur.contentType.isEmpty ? h.contentType : cur.contentType,
        poster: cur.poster.isEmpty ? h.poster : cur.poster,
        durationSeconds: cur.durationSeconds ?? h.durationSeconds,
      );
      hits.value = list;
    } else {
      hits.value = [...list, h];
    }
  }

  /// Creates a temporary file path with the given extension.
  Future<String> _tempFilePath(String ext) async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  /// Requests permission to save media to gallery. Throws if denied.
  Future<void> requestGalleryPerm() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) {
      throw Exception('相簿權限被拒絕');
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

  /// Enqueues a new download task for the given URL. Detects whether
  /// the URL is HLS (.m3u8) or a direct media file, chooses the appropriate
  /// handling, and begins processing in the background.
  Future<DownloadTask> enqueueDownload(String url) async {
    final isHls = url.contains('.m3u8');
    final ext =
        isHls ? 'mp4' : (url.split('?').first.split('.').lastOrNull ?? 'bin');
    final out = await _tempFilePath(ext);
    final task = DownloadTask(
      url: url,
      savePath: out,
      kind: isHls ? 'hls' : 'file',
    );
    downloads.value = [...downloads.value, task];
    _runTask(task);
    return task;
  }

  /// Runs the download task. For HLS, uses FFmpeg to remux the m3u8 playlist
  /// into an MP4. For direct media files, uses Dio for streaming download.
  Future<void> _runTask(DownloadTask t) async {
    try {
      t.state = 'downloading';
      notifyListeners();
      if (t.kind == 'hls') {
        final cmd =
            "-i '${t.url}' -c copy -bsf:a aac_adtstoasc '${t.savePath}'";
        final sess = await FFmpegKit.executeAsync(cmd, (s) {}, (log) {
          if (kDebugMode) print('ffmpeg: ${log.getMessage()}');
        }, (st) {});
        await sess.getState();
      } else {
        final dio = Dio();
        await dio.download(
          t.url,
          t.savePath,
          options: Options(responseType: ResponseType.bytes),
          onReceiveProgress: (rcv, total) {
            t.received = rcv;
            t.total = total;
            notifyListeners();
          },
        );
      }
      t.state = 'done';
      notifyListeners();
      await saveFileToGallery(t.savePath);
    } catch (e) {
      t.state = 'error';
      notifyListeners();
      if (kDebugMode) print('download error: $e');
    }
  }
}

/// Helper class that encapsulates local authentication (e.g. Face ID, Touch ID).
class Locker {
  static final _auth = LocalAuthentication();
  static Future<bool> unlock({String reason = '解鎖以查看私人影片'}) async {
    try {
      final can = await _auth.canCheckBiometrics;
      if (!can) return true; // 沒有生物辨識時不擋（可改為必須輸入 PIN）
      return _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
