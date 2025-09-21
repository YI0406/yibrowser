import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'soure.dart';
import 'iap.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
// Import the media page to allow launching the built‑in video player when
// playing remote videos from the browser. This also brings in the
// VideoPlayerPage class used in the play callbacks.
import 'media.dart';
import 'video_player_page.dart';
import 'image_preview_page.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';

// --- Top-level helper for measuring instantaneous rates (bytes per second)
class _RateSnapshot {
  final int bytes;
  final DateTime ts;
  const _RateSnapshot(this.bytes, this.ts);
}

// Represents one browser tab's state (URL text controller, progress, title, etc.)
class _TabData {
  final Key webviewKey;
  final TextEditingController urlCtrl;
  final ValueNotifier<double> progress;
  String? pageTitle;
  String? currentUrl;
  InAppWebViewController? controller;

  /// When true the first page load should not be recorded in history.
  bool skipInitialHistory = true;
  _TabData({String initialUrl = 'about:blank'})
    : webviewKey = UniqueKey(),
      urlCtrl = TextEditingController(
        text:
            initialUrl.toLowerCase().startsWith('about:blank')
                ? ''
                : initialUrl,
      ),
      progress = ValueNotifier<double>(0.0);
}

class _BlockedExternalNavigation {
  final String rawUrl;
  final String? scheme;

  const _BlockedExternalNavigation({required this.rawUrl, this.scheme});
}

/// BrowserPage encapsulates a WebView with URL entry, navigation, and a bar
/// showing detected media resources. It hooks into resource loading
/// callbacks and JavaScript injection to sniff media URLs (audio/video).
class BrowserPage extends StatefulWidget {
  /// Optional callback invoked when the user presses the home button in the toolbar.
  final VoidCallback? onGoHome;
  const BrowserPage({super.key, this.onGoHome});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

enum _ToolbarMenuAction {
  toggleSniffer,
  openResources,
  openDownloads,
  openFavorites,
  openHistory,
  toggleBlockPopup,
  blockExternalApp,
  addHome,
  goHome,
}

enum _LinkContextMenuAction {
  copyLink,
  downloadLink,
  openInNewTab,
  addFavorite,
  addHome,
}

class _BrowserPageState extends State<BrowserPage> {
  // Global key used to control the Scaffold (e.g. open the end drawer) from
  // contexts where Scaffold.of(context) does not resolve correctly, such as
  // bottom sheets. This allows the side drawer to slide in from the right
  // when the menu button is pressed in the downloads sheet.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // Global key for the tab count button (for anchored popup menu)
  final GlobalKey _tabButtonKey = GlobalKey();
  // Global key for the toolbar menu button so we can reopen the menu at the
  // same location after toggling quick actions.
  final GlobalKey _menuButtonKey = GlobalKey();

  // List of open tabs. At least one tab is always present.
  final List<_TabData> _tabs = [];
  // Index of the currently active tab.
  int _currentTabIndex = 0;
  // --- Mini player state ---
  OverlayEntry? _miniEntry;
  VideoPlayerController? _miniCtrl;
  bool _miniVisible = false;
  Offset _miniPos = const Offset(20, 80); // 初始位置（相對螢幕左上）
  String? _miniUrl;
  // Focus node for the URL input. Used to determine whether to show the
  // clear button only when the field has focus and contains text.
  final FocusNode _urlFocus = FocusNode();
  // --- Paste button state ---
  bool _showPaste = false;
  String? _clipboardCache;

  // ---- UA Preference ----
  String? _uaMode; // 'iphone' | 'ipad' | 'android'
  String? _userAgent; // resolved UA string used by WebView
  bool _uaInitialized = false;

  bool _blockExternalApp = false; // 阻擋由網頁開啟第三方 App
  String? _lastBlockedExternalUrl;
  DateTime? _lastBlockedExternalAt;
  static const Set<String> _kWebSchemes = {
    'http',
    'https',
    'about',
    'data',
    'blob',
    'file',
  };
  static const List<String> _kExternalAppFlagKeys = [
    'shouldPerformAppLink',
    'iosShouldPerformAppLink',
    'iosShouldOpenExternalApp',
    'shouldOpenExternalApp',
    'shouldOpenApp',
    'shouldOpenAppLink',
    'androidShouldOpenExternalApp',
    'androidShouldLeaveApplication',
    'iosShouldOpenApp',
    'iosWKNavigationActionShouldPerformAppLink',
    'iosWKNavigationActionShouldOpenApp',
    'shouldPerformAppLinkForCurrentRequest',
    'shouldAllowExternalApp',
    'shouldOpenExternalAppUrl',
    'shouldAllowOpenInExternalApp',
    'shouldOpenInExternalApp',
    'openExternalApp',
    'opensExternalApp',
    'openWithSystemBrowser',
  ];

  static const double _edgeSwipeWidth = 32.0;
  static const double _edgeSwipeDistanceThreshold = 48.0;
  static const double _edgeSwipeVelocityThreshold = 700.0;
  bool _iosLinkMenuBridgeReady = false;
  String? _lastIosLinkMenuUrl;
  DateTime? _lastIosLinkMenuTime;

  static const String _kIosLinkContextMenuJS = r'''
(() => {
  if (window.__flutterIosLinkMenuInstalled) {
    return;
  }
  window.__flutterIosLinkMenuInstalled = true;

  const LONG_PRESS_DELAY = 450;
  let activeAnchor = null;
  let longPressTimer = null;

  const ensureStyle = () => {
    if (document.getElementById('flutter-ios-link-menu-style')) {
      return;
    }
    const style = document.createElement('style');
    style.id = 'flutter-ios-link-menu-style';
    style.textContent = 'a, a * { -webkit-touch-callout: none !important; }';
    document.documentElement.appendChild(style);
  };

  const resolveHref = (anchor) => {
    if (!anchor) {
      return null;
    }
    let href = anchor.getAttribute('href') || '';
    if (!href && anchor.href) {
      href = anchor.href;
    }
    if (!href) {
      return null;
    }
    try {
      return new URL(href, window.location.href).href;
    } catch (err) {
      return href;
    }
  };

  const clearPending = () => {
    if (longPressTimer !== null) {
      clearTimeout(longPressTimer);
      longPressTimer = null;
    }
    activeAnchor = null;
  };

  document.addEventListener(
    'touchstart',
    (event) => {
      if (!event || (event.touches && event.touches.length > 1)) {
        clearPending();
        return;
      }
      ensureStyle();
      const anchor =
        event.target && event.target.closest
          ? event.target.closest('a[href]')
          : null;
      if (!anchor) {
        clearPending();
        return;
      }
      if (longPressTimer !== null) {
        clearTimeout(longPressTimer);
      }
      activeAnchor = anchor;
      longPressTimer = setTimeout(() => {
        const resolved = resolveHref(activeAnchor);
        clearPending();
        if (
          resolved &&
          window.flutter_inappwebview &&
          window.flutter_inappwebview.callHandler
        ) {
          window.flutter_inappwebview.callHandler('linkLongPress', resolved);
        }
      }, LONG_PRESS_DELAY);
    },
    { passive: true }
  );

  document.addEventListener(
    'touchmove',
    (event) => {
      if (!activeAnchor) {
        return;
      }
      if (!event || !event.target || !event.target.closest) {
        clearPending();
        return;
      }
      const anchor = event.target.closest('a[href]');
      if (!anchor || anchor !== activeAnchor) {
        clearPending();
      }
    },
    { passive: true }
  );

  document.addEventListener('touchend', clearPending, { passive: true });
  document.addEventListener('touchcancel', clearPending, { passive: true });

  document.addEventListener(
    'contextmenu',
    (event) => {
      const anchor =
        event && event.target && event.target.closest
          ? event.target.closest('a[href]')
          : null;
      if (anchor) {
        event.preventDefault();
      }
    },
    { capture: true }
  );
})();
''';
  String _uaForMode(String mode) {
    switch (mode) {
      case 'ipad':
        return 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      case 'android':
        return 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
      case 'windows':
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
      case 'iphone':
      default:
        return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
  }

  bool _hasRenderableFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      return file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  Widget _buildThumb(DownloadTask t) {
    final resolvedType = AppRepo.I.resolvedTaskType(t);
    final isDone = t.state.toLowerCase() == 'done';
    if (resolvedType == 'image') {
      if (isDone && _hasRenderableFile(t.savePath)) {
        final file = File(t.savePath);
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.image),
          ),
        );
      }
      return Container(
        color: Colors.grey.shade300,
        alignment: Alignment.center,
        child: const Icon(Icons.image, color: Colors.black54),
      );
    }

    if (resolvedType == 'audio') {
      return Container(
        color: Colors.deepPurple.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.audiotrack, color: Colors.white),
      );
    }

    final thumbPath = t.thumbnailPath;
    if (thumbPath != null && File(thumbPath).existsSync()) {
      return Image.file(
        File(thumbPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.movie),
      );
    }

    // 如果影片檔還存在，但縮圖沒有 → 背景再抓一次縮圖
    final f = File(t.savePath);
    if (isDone && f.existsSync() && resolvedType == 'video') {
      _regenThumbAsync(t); // 非同步抽圖
    }

    // 預設顯示一個灰色方塊或 icon
    return Container(
      color: Colors.grey.shade800,
      child: const Icon(Icons.movie, color: Colors.white),
    );
  }

  Future<void> _regenThumbAsync(DownloadTask t) async {
    if (AppRepo.I.resolvedTaskType(t) != 'video') {
      return;
    }
    if (t.state.toLowerCase() != 'done') {
      return;
    }
    try {
      final outDir = path.join(
        (await getApplicationDocumentsDirectory()).path,
        'thumbnails',
      );
      await Directory(outDir).create(recursive: true);
      final outPath = path.join(
        outDir,
        '${path.basenameWithoutExtension(t.savePath)}.jpg',
      );

      // ffmpeg 抽取 1 秒處的畫面，縮成寬 320
      final cmd =
          "-i '${t.savePath}' -ss 00:00:01.000 -vframes 1 -vf scale=320:-1 '$outPath'";
      await FFmpegKit.execute(cmd);

      if (File(outPath).existsSync()) {
        setState(() {
          t.thumbnailPath = outPath;
        });
        AppRepo.I.updateDownload(t);
      }
    } catch (e) {
      debugPrint('縮圖生成失敗: $e');
    }
  }

  Future<void> _openMiniPlayer(String url) async {
    // 關掉舊的
    await _closeMiniPlayer();
    _miniUrl = url;

    try {
      final bgOptions =
          Platform.isIOS
              ? VideoPlayerOptions(allowBackgroundPlayback: true)
              : null;
      final ctrl = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: bgOptions,
      );
      _miniCtrl = ctrl;
      await ctrl.initialize();
      await ctrl.play();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 1),
            content: Text('無法開啟迷你播放器'),
          ),
        );
      }
      return;
    }

    _miniEntry = OverlayEntry(
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSB) {
            final size = MediaQuery.of(context).size;
            final dx = _miniPos.dx.clamp(0.0, size.width - 220.0);
            final dy = _miniPos.dy.clamp(0.0, size.height - 140.0);
            return Positioned(
              left: dx,
              top: dy,
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setSB(
                      () =>
                          _miniPos = Offset(
                            _miniPos.dx + d.delta.dx,
                            _miniPos.dy + d.delta.dy,
                          ),
                    );
                  },
                  child: Container(
                    width: 220,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 標題列 + 關閉鈕
                        Row(
                          children: [
                            const Icon(Icons.smart_display, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _prettyFileName(url),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            InkWell(
                              onTap: () async => await _closeMiniPlayer(),
                              child: const Padding(
                                padding: EdgeInsets.all(4.0),
                                child: Icon(Icons.close, size: 16),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // 迷你預覽（可拿掉，只留控制列也行）
                        if (_miniCtrl != null && _miniCtrl!.value.isInitialized)
                          AspectRatio(
                            aspectRatio: _miniCtrl!.value.aspectRatio,
                            child: VideoPlayer(_miniCtrl!),
                          ),
                        const SizedBox(height: 6),
                        // 控制列：後退15、播放/暫停、快轉15
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.replay_10),
                              tooltip: '後退 15 秒',
                              onPressed: () async {
                                final v = _miniCtrl;
                                if (v == null) return;
                                final cur = await v.position ?? Duration.zero;
                                final targetMs = (cur.inMilliseconds - 15000)
                                    .clamp(0, 1 << 31);
                                await v.seekTo(
                                  Duration(milliseconds: targetMs),
                                );
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                (_miniCtrl?.value.isPlaying ?? false)
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                              tooltip: '播放/暫停',
                              onPressed: () async {
                                final v = _miniCtrl;
                                if (v == null) return;
                                if (v.value.isPlaying) {
                                  await v.pause();
                                } else {
                                  await v.play();
                                }
                                setSB(() {}); // 更新按鈕圖示
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.forward_10),
                              tooltip: '快轉 15 秒',
                              onPressed: () async {
                                final v = _miniCtrl;
                                if (v == null) return;
                                final dur = v.value.duration;
                                final cur = await v.position ?? Duration.zero;
                                var ms = cur.inMilliseconds + 15000;
                                if (dur != null) {
                                  ms = ms.clamp(0, dur.inMilliseconds);
                                }
                                await v.seekTo(Duration(milliseconds: ms));
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    Overlay.of(context).insert(_miniEntry!);
    setState(() => _miniVisible = true);
  }

  Future<void> _closeMiniPlayer() async {
    _miniEntry?.remove();
    _miniEntry = null;
    try {
      await _miniCtrl?.pause();
    } catch (_) {}
    await _miniCtrl?.dispose();
    _miniCtrl = null;
    if (mounted) setState(() => _miniVisible = false);
  }

  Future<void> _loadUaFromPrefs(BuildContext context) async {
    final sp = await SharedPreferences.getInstance();
    String? mode = sp.getString('ua_mode');
    if (mode == null) {
      // Decide a sensible default based on device type
      if (Platform.isIOS) {
        final shortest = MediaQuery.of(context).size.shortestSide;
        mode = shortest >= 600 ? 'ipad' : 'iphone';
      } else if (Platform.isAndroid) {
        mode = 'android';
      } else {
        mode = 'iphone';
      }
      await sp.setString('ua_mode', mode);
    }
    final ua = _uaForMode(mode);
    if (mounted) {
      setState(() {
        _uaMode = mode;
        _userAgent = ua;
        _uaInitialized = true;
      });
    }
    // Try to apply to existing controllers
    await _applyUserAgentToControllers();
  }

  Future<void> _applyUserAgentToControllers() async {
    if (_userAgent == null) return;
    for (final t in _tabs) {
      final c = t.controller;
      if (c != null) {
        try {
          await c.setSettings(
            settings: InAppWebViewSettings(userAgent: _userAgent),
          );
          await c.reload();
        } catch (_) {}
      }
    }
  }

  // --- YouTube Download Options Listener ---
  bool _ytMenuOpen = false;

  void _onYtOptionsChanged() {
    final opts = repo.ytOptions.value;
    if (opts == null || _ytMenuOpen) return;
    _ytMenuOpen = true;
    final title = repo.ytTitle.value ?? '選擇下載品質';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_circle_fill),
                title: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('已擷取到可下載串流，選擇一個品質/種類即可開始下載'),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: opts.length,
                  itemBuilder: (_, i) {
                    final o = opts[i];
                    return ListTile(
                      dense: false,
                      leading: Icon(
                        o.kind == 'audio'
                            ? Icons.audiotrack
                            : Icons.ondemand_video,
                      ),
                      title: Text(
                        o.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${o.kind.toUpperCase()} · ${o.container.toUpperCase()}${o.bitrate != null ? ' · ${(o.bitrate! / 1000).round()}kbps' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.download),
                      onTap: () async {
                        Navigator.pop(context);
                        await AppRepo.I.enqueueDownload(o.url);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              duration: Duration(seconds: 1),
                              content: Text('已加入下載'),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _ytMenuOpen = false;
      // 重置，不要重複彈出
      repo.ytOptions.value = null;
      repo.ytTitle.value = null;
    });
  }

  void _onUaChanged() {
    final mode = uaNotifier.value;
    if (mode == null) return;
    final ua = _uaForMode(mode);
    setState(() {
      _uaMode = mode;
      _userAgent = ua;
    });
    _applyUserAgentToControllers(); // 對所有現有 WebView setSettings + reload
  }
  // ---- end of UA Preference ----

  String _fmtDur(double s) {
    final d = s.floor();
    final h = d ~/ 3600;
    final m = (d % 3600) ~/ 60;
    final sec = d % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(sec)}';
  }

  /// Format bytes into a human friendly string.
  /// Examples: 532 -> 532 B, 1_234 -> 1.21 KB, 5_678_901 -> 5.42 MB
  String _fmtSize(int? bytes) {
    final b = bytes ?? 0;
    if (b < 1024) return '$b B';
    final kb = b / 1024.0;
    if (kb < 1024) return '${kb.toStringAsFixed(2)} KB';
    final mb = kb / 1024.0;
    if (mb < 1024) return '${mb.toStringAsFixed(2)} MB';
    final gb = mb / 1024.0;
    return '${gb.toStringAsFixed(2)} GB';
  }

  /// Whether this task is a segmented/HLS style job where size doesn't update in real time.
  bool _isSegmentedTask(DownloadTask t) {
    final k = (t.kind).toString().toLowerCase();
    final ty = (t.type).toString().toLowerCase();
    return k.contains('hls') ||
        k.contains('m3u8') ||
        k.contains('segment') ||
        ty.contains('hls') ||
        ty.contains('m3u8');
  }

  /// Whether this entry should be counted as a real "download task"
  /// (used by the badge and sheet). Excludes local/imported/library items.
  bool _isDownloadTaskEntry(DownloadTask t) {
    final s = (t.state).toString().toLowerCase();
    final isLocalUrl =
        t.url.startsWith('file://') ||
        t.url.startsWith('/') ||
        t.url.startsWith('asset://');
    final fromLibrary =
        (t.kind == 'library' || t.kind == 'local' || t.kind == 'import');
    final isTaskState =
        s == 'downloading' ||
        s == 'paused' ||
        s == 'queued' ||
        s == 'error' ||
        s == 'done' ||
        s == 'canceled' ||
        s == 'cancelled';
    return !isLocalUrl && !fromLibrary && isTaskState;
  }

  /// Produce a compact progress text for a download entry.
  /// For HLS/segmented tasks we hide size until finished as requested.
  String _currentReceived(DownloadTask t) {
    // Hide size while still processing segmented downloads
    if (_isSegmentedTask(t) && (t.state.toLowerCase() != 'done')) {
      return '處理中…';
    }
    if (t.total != null && t.total! > 0) {
      return '${_fmtSize(t.received)} / ${_fmtSize(t.total)}';
    }
    return _fmtSize(t.received);
  }

  String _prettyFileName(String url) {
    try {
      final u = Uri.parse(url);
      String name = '';
      final segs = u.pathSegments.where((e) => e.isNotEmpty).toList();
      if (segs.isNotEmpty) {
        name = segs.last;
        // If it is an m3u8, prefer parent folder name + .m3u8
        if (name.toLowerCase().endsWith('.m3u8') && segs.length >= 2) {
          name = '${segs[segs.length - 2]}.m3u8';
        }
      }
      if (name.isEmpty) name = u.host;
      name = Uri.decodeComponent(name);
      name = name.split('?').first.split('#').first;
      // Use the active tab's title as a smarter fallback when name looks generic.
      final generic =
          name.isEmpty ||
          name == '/' ||
          name.toLowerCase() == 'index.m3u8' ||
          name.toLowerCase().startsWith('index.');
      if (generic) {
        String? tabTitle;
        if (_tabs.isNotEmpty && _currentTabIndex < _tabs.length) {
          tabTitle = _tabs[_currentTabIndex].pageTitle;
        }
        if (tabTitle != null && tabTitle.trim().isNotEmpty) {
          name = tabTitle.trim();
        }
      }
      if (name.isEmpty) return url;
      if (name.length > 60) {
        name = '${name.substring(0, 57)}…';
      }
      return name;
    } catch (_) {
      return url;
    }
  }

  // All tab‑specific controllers live on the individual [_TabData] instances.
  final repo = AppRepo.I;
  final Map<String, String> _thumbCache = {};

  /// Persist the list of open tabs into the AppRepo. This helper
  /// should be called whenever the tabs list changes (added, removed or
  /// navigated) so that the browser state can be restored on the next
  /// application launch. Each tab contributes its current URL (or
  /// pending URL if the page has not yet loaded).
  void _updateOpenTabs() {
    final urls = _tabs.map((t) => t.urlCtrl.text.trim()).toList();
    repo.setOpenTabs(urls);
  }

  bool _looksLikeLikelyUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('/') ||
        trimmed.startsWith('./') ||
        trimmed.startsWith('../')) {
      return true;
    }
    if (trimmed.startsWith('//')) {
      return true;
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('file://') ||
        lower.startsWith('about:') ||
        lower.startsWith('data:') ||
        lower.startsWith('blob:') ||
        lower.startsWith('ftp://')) {
      return true;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    if (uri.hasScheme && uri.scheme.length > 1) return true;
    if (uri.host.isNotEmpty) return true;
    return false;
  }

  Future<String?> _resolveHitTestUrl(
    InAppWebViewController controller,
    String link,
  ) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return null;
    final script =
        '(() => { try { return new URL(${jsonEncode(trimmed)}, window.location.href).href; } catch (e) { return ${jsonEncode(trimmed)}; } })();';
    try {
      final result = await controller.evaluateJavascript(source: script);
      if (result is String && result.isNotEmpty) {
        return result;
      }
    } catch (_) {}
    return trimmed;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 1), content: Text(message)),
    );
  }

  Future<void> _checkClipboardForPasteButton() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      final hasText = text != null && text.isNotEmpty;
      // 若剪貼簿內容與欄位相同，也不顯示貼上
      final current =
          (_tabs.isNotEmpty ? _tabs[_currentTabIndex].urlCtrl.text.trim() : '');
      final shouldShow = _urlFocus.hasFocus && hasText && text != current;
      if (mounted && (_showPaste != shouldShow || _clipboardCache != text)) {
        setState(() {
          _showPaste = shouldShow;
          _clipboardCache = text;
        });
      }
    } catch (_) {
      if (mounted && _showPaste) {
        setState(() => _showPaste = false);
      }
    }
  }

  Future<void> _injectIosLinkContextMenuBridge(
    InAppWebViewController controller,
  ) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await controller.evaluateJavascript(source: _kIosLinkContextMenuJS);
      _iosLinkMenuBridgeReady = true;
    } catch (_) {
      _iosLinkMenuBridgeReady = false;
    }
  }

  Future<void> _handleLinkContextMenu(String url) async {
    final action = await _showLinkContextMenu(url);
    if (action == null) return;
    switch (action) {
      case _LinkContextMenuAction.copyLink:
        await Clipboard.setData(ClipboardData(text: url));
        _showSnackBar('已複製連結');
        break;
      case _LinkContextMenuAction.downloadLink:
        await _confirmDownload(url);
        break;
      case _LinkContextMenuAction.openInNewTab:
        await _openLinkInNewTab(url);
        _showSnackBar('已在新分頁開啟');
        break;
      case _LinkContextMenuAction.addFavorite:
        _addUrlToFavorites(url);
        break;
      case _LinkContextMenuAction.addHome:
        await _showAddToHomeDialog(initialUrl: url);
        break;
    }
  }

  Future<_LinkContextMenuAction?> _showLinkContextMenu(String url) {
    return showGeneralDialog<_LinkContextMenuAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'link-menu',
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, secondaryAnimation) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        Widget buildItem(
          IconData icon,
          String label,
          _LinkContextMenuAction action,
        ) {
          return ListTile(
            leading: Icon(icon, color: colorScheme.primary),
            title: Text(label),
            dense: true,
            visualDensity: VisualDensity.compact,
            onTap: () => Navigator.of(context).pop(action),
          );
        }

        return SafeArea(
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.18),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Material(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Text(
                            url,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface.withOpacity(0.75),
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Divider(height: 1),
                        buildItem(
                          Icons.copy,
                          '複製連結',
                          _LinkContextMenuAction.copyLink,
                        ),
                        const Divider(height: 1),
                        buildItem(
                          Icons.download,
                          '下載連結網址',
                          _LinkContextMenuAction.downloadLink,
                        ),
                        const Divider(height: 1),
                        buildItem(
                          Icons.open_in_new,
                          '在新分頁開啟',
                          _LinkContextMenuAction.openInNewTab,
                        ),
                        const Divider(height: 1),
                        buildItem(
                          Icons.bookmark_add,
                          '收藏網址',
                          _LinkContextMenuAction.addFavorite,
                        ),
                        const Divider(height: 1),
                        buildItem(
                          Icons.home,
                          '加入主頁',
                          _LinkContextMenuAction.addHome,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.15, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openLinkInNewTab(String url) async {
    final target = url.trim();
    if (target.isEmpty) return;
    final tab = _createTab(initialUrl: target);
    tab.currentUrl = target;
    setState(() {
      _tabs.add(tab);
      _currentTabIndex = _tabs.length - 1;
    });
    _updateOpenTabs();
    await _persistCurrentTabIndex();
  }

  void _addUrlToFavorites(String url) {
    final target = url.trim();
    if (target.isEmpty) return;
    if (repo.favorites.value.contains(target)) {
      _showSnackBar('網址已在收藏');
      return;
    }
    repo.addFavoriteUrl(target);
    _showSnackBar('已加入收藏');
  }

  Future<void> _persistCurrentTabIndex() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('current_tab_index', _currentTabIndex);
    } catch (_) {}
  }

  /// Build the horizontal scrollable tab bar used below the toolbar. Each
  /// tab displays its page title or URL and includes a close button when
  /// more than one tab is present. A plus button at the end allows users
  /// to open a new blank tab. The active tab is highlighted using a
  /// secondary container colour. Scrolling horizontally reveals all tabs
  /// when there are too many to fit on screen.
  Widget _buildTabBar() {
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < _tabs.length; i++)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      (i == _currentTabIndex)
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () {
                        setState(() {
                          _currentTabIndex = i;
                        });
                        _persistCurrentTabIndex();
                      },
                      child: Text(
                        _tabs[i].pageTitle?.isNotEmpty == true
                            ? _tabs[i].pageTitle!
                            : (_tabs[i].currentUrl ?? '新分頁'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (_tabs.length > 1)
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            final removed = _tabs.removeAt(i);
                            removed.urlCtrl.dispose();
                            removed.progress.dispose();
                            if (_currentTabIndex >= _tabs.length) {
                              _currentTabIndex = _tabs.length - 1;
                            } else if (_currentTabIndex > i) {
                              _currentTabIndex -= 1;
                            }
                          });
                          // Update persisted open tabs after removal
                          _updateOpenTabs();
                        },
                        child: const Icon(Icons.close, size: 14),
                      ),
                  ],
                ),
              ),
            GestureDetector(
              onTap: () {
                // Open the tab manager page instead of directly adding a tab. This
                // page displays all open tabs and allows the user to add,
                // select or close tabs. It is similar to Chrome's tab switcher.
                _openTabManager();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                // Show number of tabs instead of a plus icon.
                child: Text(
                  '${_tabs.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Launch the app’s built‑in media player for the given URL. The page
  /// title is derived from the URL to provide a reasonable default name.
  /// 直接啟動內建全螢幕播放器；如需背景瀏覽請使用 iOS 子母畫面（PiP）。
  void _playMedia(String url) {
    final title = _prettyFileName(url);
    // 直接啟動內建全螢幕播放器；如需背景瀏覽請使用 iOS 子母畫面（PiP）。
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(path: url, title: title),
      ),
    );
  }

  Future<String> _buildSearchUrl(String query) async {
    final sp = await SharedPreferences.getInstance();
    final engine = sp.getString('search_engine') ?? 'google';
    final q = Uri.encodeComponent(query);
    switch (engine) {
      case 'bing':
        return 'https://www.bing.com/search?q=$q';
      case 'yahoo':
        return 'https://search.yahoo.com/search?p=$q';
      case 'duckduckgo':
        return 'https://duckduckgo.com/?q=$q';
      case 'baidu':
        return 'https://www.baidu.com/s?wd=$q';
      case 'google':
      default:
        return 'https://www.google.com/search?q=$q';
    }
  }

  /// Navigate to the tab management view. This view displays all open tabs
  /// in a grid and allows adding, selecting and closing tabs. When the
  /// manager is closed the browser state is updated accordingly.
  Future<void> _openTabManager() async {
    // 逐一蒐集每個分頁的資訊
    final infos = <_TabInfo>[];
    for (final t in _tabs) {
      final name = () {
        if (t.pageTitle != null && t.pageTitle!.trim().isNotEmpty) {
          return t.pageTitle!.trim();
        }
        final u = t.currentUrl?.trim();
        if (u != null &&
            u.isNotEmpty &&
            !u.toLowerCase().startsWith('about:blank')) {
          return u;
        }
        return '新分頁';
      }();

      Uint8List? shot;
      try {
        if (t.controller != null) {
          shot = await t.controller!.takeScreenshot();
        }
      } catch (_) {}

      infos.add(_TabInfo(title: name, thumbnail: shot));
    }

    // 推分頁管理頁（保留你原本 onAdd/onSelect/onClose）
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _TabManagerPage(
              tabs: List<_TabInfo>.from(infos),
              onAdd: () {
                setState(() {
                  _tabs.add(_createTab());
                  _currentTabIndex = _tabs.length - 1;
                });
                _updateOpenTabs();
                _persistCurrentTabIndex();
              },
              onSelect: (int index) {
                setState(() {
                  _currentTabIndex = index;
                });
                _persistCurrentTabIndex();
              },
              onClose: (int index) {
                setState(() {
                  final removed = _tabs.removeAt(index);
                  removed.urlCtrl.dispose();
                  removed.progress.dispose();
                  if (_tabs.isEmpty) {
                    _tabs.add(_createTab());
                    _currentTabIndex = 0;
                  } else if (_currentTabIndex >= _tabs.length) {
                    _currentTabIndex = _tabs.length - 1;
                  } else if (_currentTabIndex > index) {
                    _currentTabIndex -= 1;
                  }
                });
                _updateOpenTabs();
                _persistCurrentTabIndex();
              },
            ),
      ),
    );
  }

  // Removed the obsolete _showHome flag. Home navigation happens via RootNav.

  _TabData _createTab({String initialUrl = 'about:blank'}) {
    final tab = _TabData(initialUrl: initialUrl);
    tab.urlCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    return tab;
  }

  void _onPendingNewTab() {
    final token = repo.pendingNewTab.value;
    if (token == null) {
      return;
    }
    // Clear the request before creating the new tab to avoid re-entrant
    // handling when the notifier updates.
    repo.pendingNewTab.value = null;
    final tab = _createTab();
    if (mounted) {
      setState(() {
        _tabs.add(tab);
        _currentTabIndex = _tabs.length - 1;
      });
    } else {
      _tabs.add(tab);
      _currentTabIndex = _tabs.length - 1;
    }
    _updateOpenTabs();
    _persistCurrentTabIndex();
  }

  void _ensureActiveTab() {
    if (_tabs.isEmpty) {
      final tab = _createTab();
      if (mounted) {
        setState(() {
          _tabs.add(tab);
          _currentTabIndex = 0;
        });
      } else {
        _tabs.add(tab);
        _currentTabIndex = 0;
      }
      _updateOpenTabs();
      _persistCurrentTabIndex();
    } else if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      final newIndex = _tabs.isEmpty ? 0 : (_tabs.length - 1);
      if (mounted) {
        setState(() {
          _currentTabIndex = newIndex;
        });
      } else {
        _currentTabIndex = newIndex;
      }
      _persistCurrentTabIndex();
    }
  }

  /// Builds the custom home page widget. Displays a list of user saved
  /// shortcuts. Items can be reordered by dragging, tapped to open
  /// their corresponding URL, or long pressed to edit/delete. When no
  /// items are present a helpful message is shown.
  Widget _buildHomePage() {
    return ValueListenableBuilder<List<HomeItem>>(
      valueListenable: repo.homeItems,
      builder: (context, items, _) {
        if (items.isEmpty) {
          return const Center(
            child: Text(
              '尚未添加任何捷徑\n使用 + 按鈕新增網址到主頁',
              textAlign: TextAlign.center,
            ),
          );
        }
        return ReorderableListView(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          onReorder: (oldIndex, newIndex) {
            repo.reorderHomeItems(oldIndex, newIndex);
          },
          children: [
            for (int i = 0; i < items.length; i++) _buildHomeItem(i, items[i]),
          ],
        );
      },
    );
  }

  /// Build a single shortcut tile for the home page. Includes the site's
  /// favicon (derived from the domain), the user defined name, and the
  /// URL as a subtitle. Tapping opens the URL in the browser. Long
  /// pressing opens a menu to edit or delete the entry.
  Widget _buildHomeItem(int index, HomeItem item) {
    final uri = Uri.tryParse(item.url);
    final host = uri?.host ?? '';
    final faviconUrl =
        host.isNotEmpty
            ? 'https://www.google.com/s2/favicons?domain=$host&sz=64'
            : null;
    return ListTile(
      key: ValueKey('home_$index'),
      leading:
          faviconUrl != null
              ? Image.network(
                faviconUrl,
                width: 32,
                height: 32,
                errorBuilder: (_, __, ___) => const Icon(Icons.public),
              )
              : const Icon(Icons.public),
      title: Text(item.name.isNotEmpty ? item.name : host),
      subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        // Navigate to the URL on the current tab.
        _ensureActiveTab();
        if (_tabs.isNotEmpty) {
          final tab = _tabs[_currentTabIndex];
          tab.urlCtrl.text = item.url;
          _go(item.url);
        }
      },
      onLongPress: () => _showHomeItemMenu(index),
    );
  }

  /// Present a bottom sheet for a specific home item allowing the user to
  /// edit or delete the entry. Editing pops up a dialog prefilled with
  /// the current name and URL. Deleting removes the entry immediately.
  void _showHomeItemMenu(int index) {
    final items = repo.homeItems.value;
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    showModalBottomSheet(
      context: context,
      builder:
          (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(item.name.isNotEmpty ? item.name : item.url),
                  subtitle: Text(item.url),
                ),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('編輯'),
                  onTap: () {
                    Navigator.pop(context);
                    _editHomeItem(index);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('刪除'),
                  onTap: () {
                    Navigator.pop(context);
                    repo.removeHomeItemAt(index);
                  },
                ),
              ],
            ),
          ),
    );
  }

  /// Show a dialog allowing the user to edit an existing home entry. The
  /// current values are prefilled. On confirmation the entry is updated.
  void _editHomeItem(int index) {
    final items = repo.homeItems.value;
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    final nameCtrl = TextEditingController(text: item.name);
    final urlCtrlLocal = TextEditingController(text: item.url);
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('編輯捷徑'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名稱'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrlLocal,
                decoration: const InputDecoration(labelText: '網址'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final newName = nameCtrl.text.trim();
                final newUrl = urlCtrlLocal.text.trim();
                if (newName.isNotEmpty && newUrl.isNotEmpty) {
                  repo.updateHomeItem(index, url: newUrl, name: newName);
                }
                Navigator.pop(context);
              },
              child: const Text('確定'),
            ),
          ],
        );
      },
    );
  }

  /// Prompt the user to add a page to the home screen. When [initialUrl]
  /// or [initialName] are provided they are used to prefill the dialog,
  /// otherwise the current tab's information is used.
  Future<void> _showAddToHomeDialog({
    String? initialUrl,
    String? initialName,
  }) async {
    if (AppRepo.I.hasReachedFreeHomeShortcutLimit) {
      await PurchaseService().showPurchasePrompt(
        context,
        featureName: '新增更多主頁捷徑',
      );
      return;
    }
    String? tabTitle =
        (initialName != null && initialName.trim().isNotEmpty)
            ? initialName.trim()
            : null;
    String? tabUrl =
        (initialUrl != null && initialUrl.trim().isNotEmpty)
            ? initialUrl.trim()
            : null;
    if ((tabTitle == null || tabTitle.isEmpty) ||
        (tabUrl == null || tabUrl.isEmpty)) {
      if (_tabs.isNotEmpty) {
        final tab = _tabs[_currentTabIndex];
        tabTitle = tabTitle ?? tab.pageTitle;
        tabUrl = tabUrl ?? tab.currentUrl;
      }
    }
    final defaultUrl = tabUrl ?? '';
    final defaultName =
        (tabTitle != null && tabTitle.trim().isNotEmpty)
            ? tabTitle.trim()
            : (defaultUrl.isNotEmpty ? _prettyFileName(defaultUrl) : '');
    final nameCtrl = TextEditingController(text: defaultName);
    final urlCtrlLocal = TextEditingController(text: defaultUrl);
    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('新增捷徑到主頁'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名稱'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrlLocal,
                decoration: const InputDecoration(labelText: '網址'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final url = urlCtrlLocal.text.trim();
                if (name.isNotEmpty && url.isNotEmpty) {
                  repo.addHomeItem(url, name);
                  setState(() {});
                }
                Navigator.pop(context);
              },
              child: const Text('新增'),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    uaNotifier.addListener(_onUaChanged);
    repo.ytOptions.addListener(_onYtOptionsChanged);
    // Listen to focus changes to handle paste button
    _urlFocus.addListener(() {
      if (_urlFocus.hasFocus) {
        _checkClipboardForPasteButton();
      } else {
        if (mounted && _showPaste) setState(() => _showPaste = false);
      }
    });
    // Restore any previously open tabs from the repository. If none
    // exist, start with a single blank tab. Each tab’s URL controller
    // will update the UI when its text changes.
    final savedTabs = repo.openTabs.value;
    if (savedTabs.isNotEmpty) {
      for (final url in savedTabs) {
        _tabs.add(_createTab(initialUrl: url));
      }
      _currentTabIndex = 0;
    } else {
      _tabs.add(_createTab());
    }
    // Save the restored tabs back into the repo in case they were just
    // created from saved state. This ensures that any default blank tab
    // also gets persisted.
    _updateOpenTabs();
    // Restore last active tab index (default 0), clamp to valid range.
    () async {
      final sp = await SharedPreferences.getInstance();
      int idx = sp.getInt('current_tab_index') ?? 0;
      if (_tabs.isNotEmpty) {
        if (idx < 0) idx = 0;
        if (idx >= _tabs.length) idx = _tabs.length - 1;
        if (mounted) {
          setState(() {
            _currentTabIndex = idx;
          });
        } else {
          _currentTabIndex = idx;
        }
      }
    }();
    // When a pending URL is set via the home page, load it automatically in
    // the current browser tab.
    repo.pendingOpenUrl.addListener(() {
      final pending = repo.pendingOpenUrl.value;
      if (pending != null && pending.isNotEmpty) {
        _ensureActiveTab();
        if (_tabs.isNotEmpty) {
          final tab = _tabs[_currentTabIndex];
          tab.urlCtrl.text = pending;
        }
        _go(pending);
        // Clear the notifier so the URL isn't loaded repeatedly.
        repo.pendingOpenUrl.value = null;
      }
    });

    // Load saved snifferEnabled preference, default to false if not set.
    () async {
      final sp = await SharedPreferences.getInstance();
      if (!sp.containsKey('sniffer_enabled')) {
        repo.setSnifferEnabled(false);
        await sp.setBool('sniffer_enabled', false);
      } else {
        final saved = sp.getBool('sniffer_enabled') ?? false;
        repo.setSnifferEnabled(saved);
      }
    }();
    // Load saved blockExternalApp preference, default to false if not set.
    () async {
      final sp = await SharedPreferences.getInstance();
      _blockExternalApp = sp.getBool('block_external_app') ?? false;
      if (mounted) setState(() {});
    }();
  }

  void _toggleBlockExternalAppSetting() async {
    final next = !_blockExternalApp;
    _blockExternalApp = next;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('block_external_app', next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(next ? '已開啟「阻擋外部 App」' : '已關閉「阻擋外部 App」'),
      ),
    );
    setState(() {});
  }

  _TabData? _tabForController(InAppWebViewController controller) {
    for (final tab in _tabs) {
      if (tab.controller == controller) {
        return tab;
      }
    }
    return null;
  }

  String _describeExternalAppTarget(_BlockedExternalNavigation blocked) {
    if (blocked.scheme != null && blocked.scheme!.isNotEmpty) {
      return blocked.scheme!;
    }
    final parsed = Uri.tryParse(blocked.rawUrl);
    final fallbackScheme = parsed?.scheme;
    if (fallbackScheme != null && fallbackScheme.isNotEmpty) {
      return fallbackScheme;
    }
    return blocked.rawUrl.isEmpty ? '未知' : blocked.rawUrl;
  }

  void _showExternalAppBlockedSnackBar(_BlockedExternalNavigation blocked) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastBlockedExternalUrl == blocked.rawUrl &&
        _lastBlockedExternalAt != null &&
        now.difference(_lastBlockedExternalAt!).inMilliseconds < 500) {
      return;
    }
    _lastBlockedExternalUrl = blocked.rawUrl;
    _lastBlockedExternalAt = now;

    final messenger = ScaffoldMessenger.of(context);
    final label = _describeExternalAppTarget(blocked);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        content: Row(
          children: [
            Icon(
              Icons.close,
              size: 18,
              color: Theme.of(context).colorScheme.onInverseSurface,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('已阻止網頁打開第三方 App($label)')),
          ],
        ),
        action: SnackBarAction(
          label: '打開',
          onPressed: () {
            messenger.hideCurrentSnackBar();
            unawaited(_launchExternalApp(blocked.rawUrl));
          },
        ),
      ),
    );
  }

  Future<void> _launchExternalApp(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _showExternalAppLaunchError();
      return;
    }
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _showExternalAppLaunchError();
      }
    } catch (_) {
      _showExternalAppLaunchError();
    }
  }

  void _showExternalAppLaunchError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 1),
        content: Text('無法開啟外部 App'),
      ),
    );
  }

  void _handleBlockedExternalNavigation(
    _BlockedExternalNavigation blocked, {
    InAppWebViewController? controller,
  }) {
    if (controller != null) {
      try {
        unawaited(controller.stopLoading());
      } catch (_) {}
      final tab = _tabForController(controller);
      if (tab != null) {
        final current = tab.currentUrl;
        if (current != null && current.isNotEmpty) {
          tab.urlCtrl.text = current;
        } else if (tab.urlCtrl.text.isNotEmpty) {
          tab.urlCtrl.clear();
        }
      }
    }
    _showExternalAppBlockedSnackBar(blocked);
  }

  bool _flagTruthy(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'y';
    }
    return false;
  }

  bool _mapContainsExternalAppHint(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return false;
    }
    for (final key in _kExternalAppFlagKeys) {
      final dynamic flag = map[key];
      if (_flagTruthy(flag)) {
        return true;
      }
    }
    return false;
  }

  bool _navigationActionRequestsExternalApp(NavigationAction action) {
    bool shouldBlock = false;
    try {
      final dynamic dynAction = action;
      final dynamic shouldPerformAppLink = dynAction.shouldPerformAppLink;
      if (_flagTruthy(shouldPerformAppLink)) {
        shouldBlock = true;
      }
      final dynamic iosShouldPerformAppLink = dynAction.iosShouldPerformAppLink;
      if (_flagTruthy(iosShouldPerformAppLink)) {
        shouldBlock = true;
      }
      final dynamic androidShouldOpenExternalApp =
          dynAction.androidShouldOpenExternalApp;
      if (_flagTruthy(androidShouldOpenExternalApp)) {
        shouldBlock = true;
      }
      final dynamic androidShouldLeaveApplication =
          dynAction.androidShouldLeaveApplication;
      if (_flagTruthy(androidShouldLeaveApplication)) {
        shouldBlock = true;
      }
      final dynamic iosShouldOpenExternalApp =
          dynAction.iosShouldOpenExternalApp;
      if (_flagTruthy(iosShouldOpenExternalApp)) {
        shouldBlock = true;
      }
      final dynamic iosShouldOpenApp = dynAction.iosShouldOpenApp;
      if (_flagTruthy(iosShouldOpenApp)) {
        shouldBlock = true;
      }
      final dynamic shouldOpenAppLink = dynAction.shouldOpenAppLink;
      if (_flagTruthy(shouldOpenAppLink)) {
        shouldBlock = true;
      }
      final dynamic shouldOpenExternalApp = dynAction.shouldOpenExternalApp;
      if (_flagTruthy(shouldOpenExternalApp)) {
        shouldBlock = true;
      }
    } catch (_) {}

    if (!shouldBlock) {
      try {
        final dynamic rawMap = action.toMap();
        if (rawMap is Map) {
          if (_mapContainsExternalAppHint(rawMap)) {
            shouldBlock = true;
          }
          if (!shouldBlock) {
            final dynamic requestMap = rawMap['request'];
            if (requestMap is Map && _mapContainsExternalAppHint(requestMap)) {
              shouldBlock = true;
            }
            if (!shouldBlock) {
              final dynamic optionsMap = rawMap['options'];
              if (optionsMap is Map &&
                  _mapContainsExternalAppHint(optionsMap)) {
                shouldBlock = true;
              }
            }
          }
        }
      } catch (_) {}
    }
    return shouldBlock;
  }

  bool _createWindowRequestRequestsExternalApp(
    // `CreateWindowRequest` was renamed in flutter_inappwebview v6, so accept
    // a dynamic value to stay compatible with multiple versions of the plugin.
    dynamic createWindowRequest,
  ) {
    if (createWindowRequest == null) {
      return false;
    }
    try {
      final dynamic rawMap = createWindowRequest.toMap();
      if (rawMap is Map) {
        if (_mapContainsExternalAppHint(rawMap)) {
          return true;
        }
        final dynamic requestMap = rawMap['request'];
        if (requestMap is Map && _mapContainsExternalAppHint(requestMap)) {
          return true;
        }
        final dynamic optionsMap =
            rawMap['options'] ?? rawMap['windowFeatures'];
        if (optionsMap is Map && _mapContainsExternalAppHint(optionsMap)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  _BlockedExternalNavigation? _shouldPreventExternalNavigation(
    WebUri? uri, {
    NavigationAction? action,
    URLRequest? request,
    // Accept dynamic for compatibility with renamed CreateWindowRequest class.
    dynamic createWindowRequest,
  }) {
    if (!_blockExternalApp) return null;

    String? scheme = uri?.scheme;
    String? rawUrl = uri?.toString();
    WebUri? resolvedUri = uri;
    bool shouldBlock = false;

    void ingestUrlRequest(URLRequest? req) {
      if (req == null) {
        return;
      }
      try {
        if (rawUrl == null || rawUrl!.isEmpty) {
          rawUrl = req.url?.toString();
        }
        if ((scheme == null || scheme!.isEmpty) && req.url != null) {
          scheme = req.url!.scheme;
          resolvedUri ??= req.url;
        }
        if (rawUrl == null || rawUrl!.isEmpty) {
          try {
            final mapped = req.toMap();
            final dynamic urlValue = mapped['url'];
            if (urlValue is String && urlValue.isNotEmpty) {
              rawUrl = urlValue;
            }
            final dynamic schemeValue = mapped['scheme'];
            if (schemeValue is String && schemeValue.isNotEmpty) {
              scheme ??= schemeValue;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    if (action != null) {
      try {
        ingestUrlRequest(action.request);
      } catch (_) {}
    }
    ingestUrlRequest(request);
    if (createWindowRequest != null) {
      ingestUrlRequest(createWindowRequest.request);
    }
    if ((rawUrl == null || rawUrl!.isEmpty) && action != null) {
      try {
        final dynamic rawMap = action.toMap();
        if (rawMap is Map) {
          final dynamic requestMap = rawMap['request'];
          if (requestMap is Map) {
            final dynamic mappedUrl = requestMap['url'];
            if (mappedUrl is String && mappedUrl.isNotEmpty) {
              rawUrl = mappedUrl;
            }
            final dynamic mappedScheme = requestMap['scheme'];
            if (mappedScheme is String && mappedScheme.isNotEmpty) {
              scheme ??= mappedScheme;
            }
          }
        }
      } catch (_) {}
    }
    if ((rawUrl == null || rawUrl!.isEmpty) && createWindowRequest != null) {
      try {
        final dynamic rawMap = createWindowRequest.toMap();
        if (rawMap is Map) {
          final dynamic requestMap = rawMap['request'];
          if (requestMap is Map) {
            final dynamic mappedUrl = requestMap['url'];
            if (mappedUrl is String && mappedUrl.isNotEmpty) {
              rawUrl = mappedUrl;
            }
            final dynamic mappedScheme = requestMap['scheme'];
            if (mappedScheme is String && mappedScheme.isNotEmpty) {
              scheme ??= mappedScheme;
            }
          }
        }
      } catch (_) {}
    }
    if ((scheme == null || scheme!.isEmpty) && rawUrl != null) {
      try {
        final parsed = WebUri(rawUrl!);
        scheme = parsed.scheme;
        resolvedUri ??= parsed;
      } catch (_) {
        try {
          scheme = Uri.tryParse(rawUrl!)?.scheme;
        } catch (_) {}
      }
    }

    final normalizedScheme = (scheme ?? '').toLowerCase();
    final normalizedRaw = (rawUrl ?? '').toLowerCase();

    if (normalizedScheme.isNotEmpty &&
        !_kWebSchemes.contains(normalizedScheme)) {
      shouldBlock = true;
    }

    if (!shouldBlock && normalizedScheme.isEmpty && normalizedRaw.isNotEmpty) {
      const suspiciousPrefixes = [
        'intent:',
        'intent://',
        'line://',
        'line:',
        'whatsapp://',
        'whatsapp:',
        'tg://',
        'twitter://',
        'fb://',
        'instagram://',
        'weixin://',
        'weibo://',
        'alipay://',
        'alipays://',
        'taobao://',
        'pinduoduo://',
        'mqq://',
        'mailto:',
        'tel:',
        'sms:',
      ];
      for (final prefix in suspiciousPrefixes) {
        if (normalizedRaw.startsWith(prefix)) {
          shouldBlock = true;
          break;
        }
      }
    }

    if (!shouldBlock && action != null) {
      if (_navigationActionRequestsExternalApp(action)) {
        shouldBlock = true;
      }
    }
    if (!shouldBlock && createWindowRequest != null) {
      if (_createWindowRequestRequestsExternalApp(createWindowRequest)) {
        shouldBlock = true;
      }
    }

    if (!shouldBlock) {
      return null;
    }

    final effectiveRaw =
        (rawUrl != null && rawUrl!.isNotEmpty)
            ? rawUrl
            : (resolvedUri?.toString() ?? '');
    final effectiveScheme =
        (scheme != null && scheme!.isNotEmpty)
            ? scheme
            : Uri.tryParse(effectiveRaw!)?.scheme;

    return _BlockedExternalNavigation(
      rawUrl: effectiveRaw ?? '',
      scheme: effectiveScheme,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_uaInitialized) {
      _loadUaFromPrefs(context);
    }
  }

  @override
  void dispose() {
    // Dispose each tab's controllers and progress notifiers. Also dispose
    // the focus node when the page is destroyed to free resources.
    for (final tab in _tabs) {
      tab.urlCtrl.dispose();
      tab.progress.dispose();
      _closeMiniPlayer();
    }
    uaNotifier.removeListener(_onUaChanged);
    repo.ytOptions.removeListener(_onYtOptionsChanged);
    _urlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    focusNode: _urlFocus,
                    // Bind the text controller to the current tab's URL controller.
                    controller:
                        (_tabs.isNotEmpty
                            ? _tabs[_currentTabIndex].urlCtrl
                            : TextEditingController()),
                    onTap: () {
                      final ctrl =
                          (_tabs.isNotEmpty
                              ? _tabs[_currentTabIndex].urlCtrl
                              : null);
                      if (ctrl != null) {
                        ctrl.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: ctrl.text.length,
                        );
                      }
                      _checkClipboardForPasteButton();
                    },
                    onChanged: (_) {
                      if (_urlFocus.hasFocus) _checkClipboardForPasteButton();
                    },
                    textInputAction: TextInputAction.go,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: '輸入網址或關鍵字以搜尋',
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_showPaste)
                            IconButton(
                              tooltip: '貼上',
                              icon: const Icon(Icons.content_paste),
                              onPressed: () async {
                                try {
                                  final data = await Clipboard.getData(
                                    Clipboard.kTextPlain,
                                  );
                                  final clip = data?.text ?? '';
                                  if (_tabs.isNotEmpty) {
                                    final c = _tabs[_currentTabIndex].urlCtrl;
                                    c.text = clip;
                                    c.selection = TextSelection.collapsed(
                                      offset: c.text.length,
                                    );
                                  }
                                  setState(() => _showPaste = false);
                                } catch (_) {}
                              },
                            ),
                          if (_tabs.isNotEmpty &&
                              _tabs[_currentTabIndex].urlCtrl.text.isNotEmpty &&
                              _urlFocus.hasFocus)
                            IconButton(
                              tooltip: '清除網址',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                if (_tabs.isNotEmpty) {
                                  _tabs[_currentTabIndex].urlCtrl.clear();
                                }
                                _urlFocus.unfocus();
                                setState(() {});
                              },
                            ),
                        ],
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 0,
                        minHeight: 0,
                      ),
                    ),
                    onSubmitted: (v) => _go(v),
                  ),
                ),
                ValueListenableBuilder<List<String>>(
                  valueListenable: repo.favorites,
                  builder: (context, favs, _) {
                    String? curUrl;
                    if (_tabs.isNotEmpty) {
                      curUrl = _tabs[_currentTabIndex].currentUrl;
                    }
                    final isFav = curUrl != null && favs.contains(curUrl);
                    final currentUrl = curUrl;
                    return IconButton(
                      icon: Icon(
                        isFav ? Icons.favorite : Icons.favorite_border,
                      ),
                      color: isFav ? Colors.redAccent : null,
                      tooltip: isFav ? '取消收藏' : '收藏',
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          currentUrl == null
                              ? null
                              : () {
                                repo.toggleFavoriteUrl(currentUrl);
                                setState(() {});
                              },
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '重新整理',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    if (_tabs.isNotEmpty) {
                      _tabs[_currentTabIndex].controller?.reload();
                    }
                  },
                ),
                const SizedBox(width: 4),
                _buildToolbarMenuButton(),
              ],
            ),
            // Loading progress bar for the current tab
            ValueListenableBuilder<double>(
              valueListenable:
                  (_tabs.isNotEmpty
                      ? _tabs[_currentTabIndex].progress
                      : ValueNotifier<double>(0.0)),
              builder: (context, p, _) {
                if (p <= 0.0 || p >= 1.0) {
                  return const SizedBox(height: 0);
                }
                return LinearProgressIndicator(value: p, minHeight: 2);
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _toolbar(),
          Expanded(
            child: IndexedStack(
              index: _currentTabIndex,
              children: [
                for (int tabIndex = 0; tabIndex < _tabs.length; tabIndex++)
                  Stack(
                    children: [
                      InAppWebView(
                        key: _tabs[tabIndex].webviewKey,
                        contextMenu: ContextMenu(
                          // ignore: deprecated_member_use
                          options: ContextMenuOptions(
                            hideDefaultSystemContextMenuItems: true,
                          ),
                        ),
                        initialSettings: InAppWebViewSettings(
                          userAgent: _userAgent,
                          allowsInlineMediaPlayback: true,
                          mediaPlaybackRequiresUserGesture: false,
                          useOnLoadResource: true,
                          useShouldOverrideUrlLoading: true,
                          javaScriptEnabled: true,
                          allowsBackForwardNavigationGestures: true,
                        ),
                        initialUrlRequest: URLRequest(
                          url: WebUri(
                            (() {
                              final s = _tabs[tabIndex].urlCtrl.text.trim();
                              return s.isEmpty ? 'about:blank' : s;
                            })(),
                          ),
                        ),
                        onWebViewCreated: (c) {
                          final tab = _tabs[tabIndex];
                          tab.controller = c;
                          // Register the JavaScript handler that receives sniffed media info.
                          c.addJavaScriptHandler(
                            handlerName: 'sniffer',
                            callback: (args) {
                              if (!repo.snifferEnabled.value) {
                                return {'ok': false, 'ignored': true};
                              }
                              final map = Map<String, dynamic>.from(args.first);
                              final url = (map['url'] ?? '').toString();
                              final type = (map['type'] ?? 'video').toString();
                              final contentType =
                                  (map['contentType'] ?? '').toString();
                              final poster = map['poster'] as String? ?? '';
                              double? dur;
                              final d = map['duration'];
                              if (d is num) {
                                dur = d.toDouble();
                              }
                              repo.addHit(
                                MediaHit(
                                  url: url,
                                  type: type,
                                  contentType: contentType,
                                  poster: poster,
                                  durationSeconds: dur,
                                ),
                              );
                              return {'ok': true};
                            },
                          );
                          if (Platform.isIOS) {
                            c.addJavaScriptHandler(
                              handlerName: 'linkLongPress',
                              callback: (args) async {
                                if (args.isEmpty) {
                                  return {'handled': false};
                                }
                                final dynamic raw = args.first;
                                if (raw is! String) {
                                  return {'handled': false};
                                }
                                final resolved = await _resolveHitTestUrl(
                                  c,
                                  raw,
                                );
                                final normalized = resolved?.trim();
                                if (normalized == null || normalized.isEmpty) {
                                  return {'handled': false};
                                }
                                _lastIosLinkMenuUrl = normalized;
                                _lastIosLinkMenuTime = DateTime.now();
                                await _handleLinkContextMenu(normalized);
                                return {'handled': true};
                              },
                            );
                          }
                        },
                        onLoadStart: (c, u) async {
                          // 雙保險：硬攔非 Web scheme（極少數情況仍可能觸發）
                          final blocked = _shouldPreventExternalNavigation(u);
                          if (blocked != null) {
                            _handleBlockedExternalNavigation(
                              blocked,
                              controller: c,
                            );
                            return;
                          }
                          _iosLinkMenuBridgeReady = false;
                          await _injectIosLinkContextMenuBridge(c);
                          if (u != null) {
                            final tab = _tabs[tabIndex];
                            final s = u.toString();
                            final isBlank = s.trim().toLowerCase().startsWith(
                              'about:blank',
                            );
                            tab.urlCtrl.text = isBlank ? '' : s;
                            tab.currentUrl = isBlank ? null : s;
                            if (!isBlank) AppRepo.I.currentPageUrl.value = s;
                            if (mounted) setState(() {});
                          }
                        },
                        onUpdateVisitedHistory: (
                          c,
                          url,
                          androidIsReload,
                        ) async {
                          if (url != null) {
                            final tab = _tabs[tabIndex];
                            final s = url.toString();
                            final isBlank = s.trim().toLowerCase().startsWith(
                              'about:blank',
                            );
                            tab.urlCtrl.text = isBlank ? '' : s;
                            tab.currentUrl = isBlank ? null : s;
                            if (!isBlank) AppRepo.I.currentPageUrl.value = s;
                            if (mounted) setState(() {});
                          }
                        },
                        onLoadStop: (c, u) async {
                          await _injectIosLinkContextMenuBridge(c);
                          // 注入嗅探腳本並同步開關
                          await c.evaluateJavascript(source: Sniffer.jsHook);
                          await c.evaluateJavascript(
                            source: Sniffer.jsSetEnabled(
                              repo.snifferEnabled.value,
                            ),
                          );

                          final curUrl = await c.getUrl();
                          final title = await c.getTitle();
                          if (curUrl != null) {
                            final tab = _tabs[tabIndex];
                            final s = curUrl.toString();
                            final isBlank = s.trim().toLowerCase().startsWith(
                              'about:blank',
                            );

                            tab.urlCtrl.text = isBlank ? '' : s;
                            tab.currentUrl = isBlank ? null : s;
                            if (!isBlank) AppRepo.I.currentPageUrl.value = s;
                            tab.pageTitle = title;

                            // about:blank 不寫入歷史；復原的第一筆載入也跳過
                            if (!isBlank) {
                              if (!tab.skipInitialHistory) {
                                repo.addHistory(s, title ?? '');
                              } else {
                                tab.skipInitialHistory = false;
                              }
                            } else {
                              tab.skipInitialHistory = false;
                            }
                            if (mounted) setState(() {});
                          }
                        },
                        onTitleChanged: (c, title) {
                          final tab = _tabs[tabIndex];
                          tab.pageTitle = title;
                          if (mounted) setState(() {});
                        },
                        onProgressChanged: (c, progress) {
                          final tab = _tabs[tabIndex];
                          tab.progress.value = progress / 100.0;
                        },
                        onCreateWindow: (ctl, createWindowRequest) async {
                          final req = createWindowRequest.request;
                          final uri = req?.url;
                          final blocked = _shouldPreventExternalNavigation(
                            uri,
                            request: req,
                            createWindowRequest: createWindowRequest,
                          );
                          if (blocked != null) {
                            _handleBlockedExternalNavigation(
                              blocked,
                              controller: ctl,
                            );
                            // 消化這次開窗要求（不交給系統），避免跳去外部 App
                            return true;
                          }
                          if (uri != null && repo.blockPopup.value) {
                            ctl.loadUrl(urlRequest: URLRequest(url: uri));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                duration: Duration(seconds: 1),
                                content: Text('彈出視窗已被阻擋'),
                              ),
                            );
                            return true;
                          }
                          return false;
                        },
                        onLoadResource: (c, r) async {
                          if (!repo.snifferEnabled.value) {
                            return;
                          }
                          final url = r.url.toString();
                          final ct = '';
                          if (Sniffer.looksLikeMedia(url, contentType: ct)) {
                            repo.addHit(
                              MediaHit(
                                url: url,
                                type:
                                    ct.startsWith('audio/') ? 'audio' : 'video',
                                contentType: ct,
                              ),
                            );
                          }
                        },
                        shouldInterceptRequest: (c, r) async {
                          if (!repo.snifferEnabled.value) {
                            return null;
                          }
                          final url = r.url.toString();
                          final ct = r.headers?['content-type'] ?? '';
                          if (Sniffer.looksLikeMedia(url, contentType: ct)) {
                            repo.addHit(
                              MediaHit(
                                url: url,
                                type:
                                    ct.toString().startsWith('audio/')
                                        ? 'audio'
                                        : 'video',
                                contentType: ct,
                              ),
                            );
                          }
                          return null;
                        },
                        shouldOverrideUrlLoading: (
                          controller,
                          navigationAction,
                        ) async {
                          final blocked = _shouldPreventExternalNavigation(
                            navigationAction.request.url,
                            action: navigationAction,
                          );
                          if (blocked != null) {
                            _handleBlockedExternalNavigation(
                              blocked,
                              controller: controller,
                            );
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                        onLongPressHitTestResult: (c, res) async {
                          final extra = res.extra?.toString();
                          InAppWebViewHitTestResultType? hitType;
                          String typeString = '';
                          try {
                            hitType = res.type;
                            typeString = hitType.toString();
                          } catch (_) {}
                          final bool isImageHit =
                              hitType ==
                                  InAppWebViewHitTestResultType.IMAGE_TYPE ||
                              hitType ==
                                  InAppWebViewHitTestResultType
                                      .SRC_IMAGE_ANCHOR_TYPE ||
                              typeString.contains('IMAGE');
                          final bool isAnchorHit =
                              hitType ==
                                  InAppWebViewHitTestResultType
                                      .SRC_ANCHOR_TYPE ||
                              hitType ==
                                  InAppWebViewHitTestResultType
                                      .SRC_IMAGE_ANCHOR_TYPE ||
                              typeString.contains('ANCHOR');

                          final candidate = extra?.trim();
                          final hasCandidateLink =
                              candidate != null && candidate.isNotEmpty;
                          if (hasCandidateLink &&
                              (isAnchorHit ||
                                  (!isImageHit &&
                                      _looksLikeLikelyUrl(candidate)))) {
                            if (_iosLinkMenuBridgeReady &&
                                Platform.isIOS &&
                                isAnchorHit) {
                              return;
                            }
                            if (Platform.isIOS &&
                                _lastIosLinkMenuUrl != null &&
                                _lastIosLinkMenuTime != null) {
                              final difference = DateTime.now().difference(
                                _lastIosLinkMenuTime!,
                              );
                              if (difference < const Duration(seconds: 1) &&
                                  _lastIosLinkMenuUrl == candidate) {
                                return;
                              }
                            }
                            final resolved = await _resolveHitTestUrl(
                              c,
                              candidate!,
                            );
                            if (resolved != null) {
                              final normalizedResolved = resolved.trim();
                              if (normalizedResolved.isNotEmpty) {
                                if (Platform.isIOS) {
                                  _lastIosLinkMenuUrl = normalizedResolved;
                                  _lastIosLinkMenuTime = DateTime.now();
                                }
                                await _handleLinkContextMenu(
                                  normalizedResolved,
                                );
                                return;
                              }
                            }
                          }

                          String? link = extra;
                          String type = isImageHit ? 'image' : 'video';
                          if (link == null || link.isEmpty) {
                            try {
                              final raw = await c.evaluateJavascript(
                                source: Sniffer.jsQueryActiveMedia,
                              );
                              if (raw is String && raw.startsWith('[')) {
                                final List<dynamic> decoded = jsonDecode(raw);
                                if (decoded.isNotEmpty) {
                                  final Map<String, dynamic> first =
                                      Map<String, dynamic>.from(
                                        decoded.first as Map,
                                      );
                                  link = (first['url'] ?? '') as String;

                                  final rawType =
                                      (first['type'] ?? '') as String;
                                  final lowerUrl = link!.toLowerCase();
                                  if (rawType.startsWith('image/') ||
                                      lowerUrl.endsWith('.png') ||
                                      lowerUrl.endsWith('.jpg') ||
                                      lowerUrl.endsWith('.jpeg') ||
                                      lowerUrl.endsWith('.gif') ||
                                      lowerUrl.endsWith('.webp')) {
                                    type = 'image';
                                  } else if (rawType.startsWith('audio/') ||
                                      lowerUrl.endsWith('.mp3') ||
                                      lowerUrl.endsWith('.wav') ||
                                      lowerUrl.endsWith('.ogg') ||
                                      lowerUrl.endsWith('.m4a')) {
                                    type = 'audio';
                                  } else if (rawType.startsWith('video/') ||
                                      lowerUrl.endsWith('.mp4') ||
                                      lowerUrl.endsWith('.mkv') ||
                                      lowerUrl.endsWith('.mov') ||
                                      lowerUrl.endsWith('.webm')) {
                                    type = 'video';
                                  } else {
                                    type =
                                        rawType.isNotEmpty
                                            ? rawType
                                            : 'unknown';
                                  }
                                }
                              }
                            } catch (_) {}
                          }
                          if (link == null || link.isEmpty) return;

                          final resolvedLink = link!;
                          final lowerUrl = resolvedLink.toLowerCase();
                          if (lowerUrl.endsWith('.png') ||
                              lowerUrl.endsWith('.jpg') ||
                              lowerUrl.endsWith('.jpeg') ||
                              lowerUrl.endsWith('.gif') ||
                              lowerUrl.endsWith('.webp') ||
                              lowerUrl.endsWith('.bmp') ||
                              lowerUrl.endsWith('.svg')) {
                            type = 'image';
                          } else if (lowerUrl.endsWith('.mp3') ||
                              lowerUrl.endsWith('.wav') ||
                              lowerUrl.endsWith('.ogg') ||
                              lowerUrl.endsWith('.m4a') ||
                              lowerUrl.endsWith('.aac') ||
                              lowerUrl.endsWith('.flac')) {
                            type = 'audio';
                          } else if (lowerUrl.endsWith('.mp4') ||
                              lowerUrl.endsWith('.mkv') ||
                              lowerUrl.endsWith('.mov') ||
                              lowerUrl.endsWith('.webm') ||
                              lowerUrl.endsWith('.m4v') ||
                              lowerUrl.endsWith('.ts')) {
                            type = 'video';
                          }

                          if (!mounted) return;
                          showDialog(
                            context: context,
                            builder: (_) {
                              return AlertDialog(
                                title: const Text('偵測到媒體'),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText(
                                      resolvedLink,
                                      maxLines: 4,
                                      onTap: () {},
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Chip(
                                          label: Text(type),
                                          visualDensity: VisualDensity.compact,
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: '複製連結',
                                          icon: const Icon(Icons.copy),
                                          onPressed: () async {
                                            await Clipboard.setData(
                                              ClipboardData(text: resolvedLink),
                                            );
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  duration: Duration(
                                                    seconds: 1,
                                                  ),
                                                  content: Text('已複製連結'),
                                                ),
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('取消'),
                                  ),
                                  if (type != 'image')
                                    TextButton.icon(
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('播放'),
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _playMedia(resolvedLink);
                                      },
                                    ),
                                  FilledButton.icon(
                                    icon: const Icon(Icons.download),
                                    label: const Text('下載'),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _confirmDownload(resolvedLink);
                                    },
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                      Positioned.fill(
                        child: Row(
                          children: [
                            _buildEdgeSwipeArea(
                              isLeft: true,
                              tabIndex: tabIndex,
                            ),
                            const Expanded(
                              child: IgnorePointer(child: SizedBox.expand()),
                            ),
                            _buildEdgeSwipeArea(
                              isLeft: false,
                              tabIndex: tabIndex,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 清空所有分頁（保留一個空白分頁）
  void _clearAllTabs() {
    for (final t in _tabs) {
      t.urlCtrl.dispose();
      t.progress.dispose();
    }
    setState(() {
      _tabs.clear();
      _tabs.add(_createTab());
      _currentTabIndex = 0;
      _persistCurrentTabIndex();
    });
    _updateOpenTabs();
  }

  /// Renders an icon with a numeric badge (if count > 0).
  Widget _iconWithBadge({
    required Widget icon,
    required int count,
    EdgeInsetsGeometry iconPadding = const EdgeInsets.all(8.0),
  }) {
    if (count <= 0) return Padding(padding: iconPadding, child: icon);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: iconPadding, child: icon),
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              borderRadius: BorderRadius.circular(10),
            ),
            constraints: const BoxConstraints(minWidth: 18),
            child: Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  /// Toolbar with back/forward/refresh and a button to load the current URL into the address bar.
  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: LayoutBuilder(
        builder: (context, box) {
          final shortest = MediaQuery.of(context).size.shortestSide;
          final bool tablet = shortest >= 600;
          Widget pad(Widget child) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: child,
          );

          final navItems = <Widget>[
            pad(
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
                onPressed: () {
                  if (_tabs.isNotEmpty) {
                    final tab = _tabs[_currentTabIndex];
                    tab.controller?.goBack();
                  }
                },
              ),
            ),
            pad(
              IconButton(
                icon: const Icon(Icons.arrow_forward),
                tooltip: '前進',
                onPressed: () {
                  if (_tabs.isNotEmpty) {
                    final tab = _tabs[_currentTabIndex];
                    tab.controller?.goForward();
                  }
                },
              ),
            ),
          ];

          // Right side controls (all aligned right): Sniffer, Resources, Downloads
          final rightSideButtons = <Widget>[
            // Sniffer toggle (eye icon)
            pad(
              ValueListenableBuilder<bool>(
                valueListenable: AppRepo.I.premiumUnlocked,
                builder: (context, premium, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: repo.snifferEnabled,
                    builder: (context, on, __) {
                      final active = premium && on;
                      return IconButton(
                        tooltip: premium ? '嗅探' : '嗅探（需高級版）',
                        onPressed: () async {
                          if (!premium) {
                            await PurchaseService().showPurchasePrompt(
                              context,
                              featureName: '嗅探功能',
                            );
                            return;
                          }
                          await _toggleSniffer();
                        },
                        icon: Icon(
                          active ? Icons.visibility : Icons.visibility_off,
                        ),
                        color: active ? Colors.green : null,
                        visualDensity: VisualDensity.compact,
                      );
                    },
                  );
                },
              ),
            ),
            // Resources (detected hits) with live badge
            pad(
              ValueListenableBuilder<bool>(
                valueListenable: AppRepo.I.premiumUnlocked,
                builder: (context, premium, _) {
                  return ValueListenableBuilder<List<MediaHit>>(
                    valueListenable: repo.hits,
                    builder: (context, hits, __) {
                      final detected = hits.length;
                      return IconButton(
                        tooltip:
                            premium
                                ? (detected > 0 ? '資源（$detected）' : '資源')
                                : '資源（需高級版）',
                        onPressed: () async {
                          if (!premium) {
                            await PurchaseService().showPurchasePrompt(
                              context,
                              featureName: '嗅探資源',
                            );
                            return;
                          }
                          await _openDetectedSheet();
                        },
                        visualDensity: VisualDensity.compact,
                        icon: _iconWithBadge(
                          icon: const Icon(Icons.search),
                          count: detected,
                          iconPadding: const EdgeInsets.all(8.0),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            // Downloads with live badge (only count real download tasks)
            pad(
              ValueListenableBuilder<List<DownloadTask>>(
                valueListenable: repo.downloads,
                builder: (context, list, _) {
                  final downloadCount = list.where(_isDownloadTaskEntry).length;
                  return IconButton(
                    tooltip:
                        downloadCount > 0 ? '下載清單（$downloadCount）' : '下載清單',
                    onPressed: _openDownloadsSheet,
                    visualDensity: VisualDensity.compact,
                    icon: _iconWithBadge(
                      icon: const Icon(Icons.file_download),
                      count: downloadCount,
                      iconPadding: const EdgeInsets.all(8.0),
                    ),
                  );
                },
              ),
            ),
          ];

          final tabButton = pad(
            GestureDetector(
              onTap: _openTabManager,
              onLongPress: () async {
                final overlay =
                    Overlay.of(context).context.findRenderObject() as RenderBox;
                final box =
                    _tabButtonKey.currentContext?.findRenderObject()
                        as RenderBox?;
                if (box == null) return;
                final position = RelativeRect.fromRect(
                  Rect.fromPoints(
                    box.localToGlobal(Offset.zero, ancestor: overlay),
                    box.localToGlobal(
                      box.size.bottomRight(Offset.zero),
                      ancestor: overlay,
                    ),
                  ),
                  Offset.zero & overlay.size,
                );
                final action = await showMenu<String>(
                  context: context,
                  position: position,
                  items: const [
                    PopupMenuItem<String>(
                      value: 'clear',
                      child: ListTile(
                        leading: Icon(Icons.delete_sweep),
                        title: Text('清除全部分頁'),
                      ),
                    ),
                  ],
                );
                if (action == 'clear') {
                  _clearAllTabs();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        duration: Duration(seconds: 1),
                        content: Text('已清除全部分頁'),
                      ),
                    );
                  }
                }
              },
              child: Container(
                key: _tabButtonKey,
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.8),
                    width: 1.2,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${_tabs.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          );

          if (tablet) {
            return Row(
              children: [
                ...navItems,
                const Spacer(),
                ...rightSideButtons,
                tabButton,
              ],
            );
          }

          return Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.start,
                  children: navItems,
                ),
              ),
              ...rightSideButtons,
              tabButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildToolbarMenuButton() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        repo.snifferEnabled,
        repo.hits,
        repo.downloads,
        repo.favorites,
        repo.history,
        repo.blockPopup,
      ]),
      builder: (context, _) {
        return IconButton(
          key: _menuButtonKey,
          tooltip: '功能選單',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: _showToolbarMenu,
          icon: Icon(
            Icons.more_horiz,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        );
      },
    );
  }

  Future<void> _showToolbarMenu() async {
    final keyContext = _menuButtonKey.currentContext;
    if (keyContext == null) return;
    final renderObject = keyContext.findRenderObject();
    if (renderObject is! RenderBox) return;
    final overlay = Overlay.of(context);
    if (overlay == null) return;
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) return;

    final repo = AppRepo.I;
    final detected = repo.hits.value.length;
    final downloadCount = repo.downloads.value.length;
    final favoriteCount = repo.favorites.value.length;
    final historyCount = repo.history.value.length;
    final blockPopupOn = repo.blockPopup.value;
    final snifferOn = repo.snifferEnabled.value;

    PopupMenuItem<_ToolbarMenuAction> buildItem(
      _ToolbarMenuAction action,
      IconData icon,
      String label, {
      Color? iconColor,
    }) {
      return PopupMenuItem<_ToolbarMenuAction>(
        value: action,
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final topLeft = renderObject.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final bottomRight = renderObject.localToGlobal(
      renderObject.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlayBox.size,
    ).shift(const Offset(0, 8));

    final entries = <PopupMenuEntry<_ToolbarMenuAction>>[
      buildItem(
        _ToolbarMenuAction.toggleSniffer,
        snifferOn ? Icons.toggle_on : Icons.toggle_off,
        '嗅探',
        iconColor: snifferOn ? Colors.green : null,
      ),
      buildItem(
        _ToolbarMenuAction.openResources,
        Icons.search,
        detected > 0 ? '資源（$detected）' : '資源',
      ),
      buildItem(
        _ToolbarMenuAction.openDownloads,
        Icons.file_download,
        downloadCount > 0 ? '下載清單（$downloadCount）' : '下載清單',
      ),
      const PopupMenuDivider(),
      buildItem(
        _ToolbarMenuAction.openFavorites,
        Icons.favorite,
        favoriteCount > 0 ? '我的收藏（$favoriteCount）' : '我的收藏',
        iconColor: favoriteCount > 0 ? Colors.redAccent : null,
      ),
      buildItem(
        _ToolbarMenuAction.openHistory,
        Icons.history,
        historyCount > 0 ? '瀏覽記錄（$historyCount）' : '瀏覽記錄',
        iconColor: historyCount > 0 ? colorScheme.primary : null,
      ),
      buildItem(
        _ToolbarMenuAction.toggleBlockPopup,
        blockPopupOn ? Icons.toggle_on : Icons.toggle_off,
        '阻擋彈出視窗',
        iconColor: blockPopupOn ? Colors.redAccent : null,
      ),
      buildItem(
        _ToolbarMenuAction.blockExternalApp,
        _blockExternalApp ? Icons.toggle_on : Icons.toggle_off,
        '阻擋外部App',
        iconColor:
            _blockExternalApp ? Theme.of(context).colorScheme.primary : null,
      ),
      const PopupMenuDivider(),
      buildItem(_ToolbarMenuAction.addHome, Icons.add, '加入主頁'),
      buildItem(_ToolbarMenuAction.goHome, Icons.home, '主頁'),
    ];

    final selected = await showMenu<_ToolbarMenuAction>(
      context: context,
      position: position,
      items: entries,
    );
    if (!mounted || selected == null) {
      return;
    }

    final keepOpen =
        selected == _ToolbarMenuAction.toggleSniffer ||
        selected == _ToolbarMenuAction.toggleBlockPopup ||
        selected == _ToolbarMenuAction.blockExternalApp;

    switch (selected) {
      case _ToolbarMenuAction.toggleSniffer:
        await _toggleSniffer();
        break;
      case _ToolbarMenuAction.openResources:
        await _openDetectedSheet();
        break;
      case _ToolbarMenuAction.openDownloads:
        _openDownloadsSheet();
        break;
      case _ToolbarMenuAction.openFavorites:
        await _openFavoritesPage();
        break;
      case _ToolbarMenuAction.openHistory:
        await _openHistoryPage();
        break;
      case _ToolbarMenuAction.toggleBlockPopup:
        _toggleBlockPopupSetting();
        break;
      case _ToolbarMenuAction.blockExternalApp:
        _toggleBlockExternalAppSetting();
        break;
      case _ToolbarMenuAction.addHome:
        await _showAddToHomeDialog();
        break;
      case _ToolbarMenuAction.goHome:
        if (widget.onGoHome != null) {
          widget.onGoHome!();
        }
        break;
    }

    if (keepOpen && mounted) {
      await Future.delayed(const Duration(milliseconds: 120));
      if (mounted) {
        _showToolbarMenu();
      }
    }
  }

  Widget _buildEdgeSwipeArea({required bool isLeft, required int tabIndex}) {
    double drag = 0;
    return SizedBox(
      width: _edgeSwipeWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          drag = 0;
        },
        onHorizontalDragUpdate: (details) {
          final delta = details.delta.dx;
          if (isLeft) {
            drag += delta;
            if (drag < 0) drag = 0;
          } else {
            drag -= delta;
            if (drag < 0) drag = 0;
          }
        },
        onHorizontalDragCancel: () {
          drag = 0;
        },
        onHorizontalDragEnd: (details) {
          final controller =
              tabIndex < _tabs.length ? _tabs[tabIndex].controller : null;
          if (controller == null) {
            drag = 0;
            return;
          }
          final velocity = details.primaryVelocity ?? 0.0;
          final directionalVelocity = isLeft ? velocity : -velocity;
          final exceededDistance = drag > _edgeSwipeDistanceThreshold;
          final exceededVelocity =
              directionalVelocity > _edgeSwipeVelocityThreshold;
          if (exceededDistance || exceededVelocity) {
            if (isLeft) {
              controller.canGoBack().then((can) {
                if (can) controller.goBack();
              });
            } else {
              controller.canGoForward().then((can) {
                if (can) controller.goForward();
              });
            }
          }
          drag = 0;
        },
      ),
    );
  }

  /// Navigates to a new URL entered by the user.
  Future<void> _go(String v) async {
    final text = v.trim();
    if (text.isEmpty) return;

    // 若像網址就直連；否則依設定的搜尋引擎產生查詢 URL
    final isUrl = text.startsWith('http') || text.contains('.');
    final dest =
        isUrl
            ? (text.startsWith('http') ? text : 'https://$text')
            : await _buildSearchUrl(text);

    _ensureActiveTab();
    if (_tabs.isEmpty) return;
    final tab = _tabs[_currentTabIndex];
    tab.urlCtrl.text = dest;
    tab.currentUrl = dest;
    await tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(dest)));
    _updateOpenTabs();
  }

  /// Adds the current page URL to favorites.
  Future<void> _addCurrentToFav() async {
    if (_tabs.isEmpty) return;
    final tab = _tabs[_currentTabIndex];
    final u = await tab.controller?.getUrl();
    final url = u?.toString();
    if (url == null) return;
    repo.toggleFavoriteUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(seconds: 1), content: Text('已更新收藏狀態')),
    );
  }

  Future<void> _toggleSniffer() async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: '嗅探功能',
    );
    if (!ok) {
      return;
    }
    final next = !repo.snifferEnabled.value;
    repo.setSnifferEnabled(next);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('sniffer_enabled', next);
    if (_tabs.isNotEmpty) {
      final tab = _tabs[_currentTabIndex];
      final controller = tab.controller;
      if (controller != null) {
        await controller.evaluateJavascript(source: Sniffer.jsSetEnabled(next));
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(next ? '已開啟嗅探' : '已關閉嗅探'),
      ),
    );
  }

  Future<void> _openFavoritesPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => FavoritesPage(
              onOpen: (String url) {
                if (_tabs.isEmpty) return;
                final tab = _tabs[_currentTabIndex];
                tab.controller?.loadUrl(
                  urlRequest: URLRequest(url: WebUri(url)),
                );
              },
              prettyName: _prettyFileName,
            ),
      ),
    );
  }

  Future<void> _openHistoryPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => HistoryPage(
              onOpen: (String url) {
                if (_tabs.isNotEmpty) {
                  final tab = _tabs[_currentTabIndex];
                  tab.controller?.loadUrl(
                    urlRequest: URLRequest(url: WebUri(url)),
                  );
                }
              },
            ),
      ),
    );
  }

  void _toggleBlockPopupSetting() {
    final next = !repo.blockPopup.value;
    repo.setBlockPopup(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(next ? '已開啟阻擋彈出視窗' : '已關閉阻擋彈出視窗'),
      ),
    );
  }

  /// Prompts the user to confirm downloading the given URL. If confirmed, enqueues the download.
  Future<void> _confirmDownload(String url) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('下載媒體'),
            content: Text(url, maxLines: 3, overflow: TextOverflow.ellipsis),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('下載'),
              ),
            ],
          ),
    );
    if (ok == true) {
      await AppRepo.I.enqueueDownload(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          content: Text('已加入佇列，完成後會存入相簿'),
        ),
      );
    }
  }

  Future<String?> _ensureVideoThumb(String url) async {
    if (_thumbCache.containsKey(url)) return _thumbCache[url];
    try {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/thumb_${url.hashCode}.jpg';
      // 從 1 秒抽一張影格；m3u8 有時也能成功
      final cmd = "-y -ss 1 -i \"$url\" -frames:v 1 -q:v 3 \"$out\"";
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (rc != null && rc.isValueSuccess() && File(out).existsSync()) {
        _thumbCache[url] = out;
        return out;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _previewHit(MediaHit h) async {
    Widget content;
    if (h.type == 'image') {
      content = InteractiveViewer(
        child: Image.network(
          h.url,
          fit: BoxFit.contain,
          errorBuilder:
              (_, __, ___) => const SizedBox(
                height: 160,
                child: Center(child: Icon(Icons.broken_image)),
              ),
        ),
      );
    } else if (h.type == 'video') {
      final thumb = await _ensureVideoThumb(h.url);
      content =
          thumb != null
              ? Image.file(File(thumb), fit: BoxFit.contain)
              : const SizedBox(
                height: 160,
                child: Center(child: Icon(Icons.ondemand_video, size: 48)),
              );
    } else {
      content = const SizedBox(
        height: 120,
        child: Center(child: Icon(Icons.audiotrack, size: 48)),
      );
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    h.url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Flexible(child: Center(child: content)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放'),
                      onPressed: () {
                        Navigator.pop(context);
                        // 使用內建播放器播放（支援 iOS 子母畫面 PiP）。
                        _playMedia(h.url);
                      },
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text('下載'),
                      onPressed: () {
                        Navigator.pop(context);
                        _confirmDownload(h.url);
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
  }

  /// Shows a bottom sheet listing all detected media resources with download buttons.
  Future<void> _openDetectedSheet() async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: '嗅探資源',
    );
    if (!ok) {
      return;
    }
    await showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: ValueListenableBuilder(
            valueListenable: repo.hits,
            builder: (_, list, __) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('尚未偵測到媒體資源'),
                );
              }
              return Column(
                children: [
                  ListTile(
                    title: Text('偵測到的資源（${list.length}）'),
                    trailing: TextButton.icon(
                      icon: const Icon(Icons.delete_sweep),
                      label: const Text('清除全部'),
                      onPressed: () {
                        repo.hits.value = [];
                        Navigator.pop(context);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              duration: Duration(seconds: 1),
                              content: Text('已清除所有資源'),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final h = list[i];
                        return ListTile(
                          leading: SizedBox(
                            width: 56,
                            height: 56,
                            child: () {
                              if (h.type == 'image') {
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    h.url,
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (_, __, ___) => const Icon(Icons.image),
                                  ),
                                );
                              } else if (h.type == 'video') {
                                return FutureBuilder<String?>(
                                  future: _ensureVideoThumb(h.url),
                                  builder: (_, snap) {
                                    Widget base;
                                    if (snap.connectionState ==
                                        ConnectionState.waiting) {
                                      base = Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black12,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      );
                                    } else if (snap.hasData &&
                                        snap.data != null) {
                                      base = ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.file(
                                          File(snap.data!),
                                          fit: BoxFit.cover,
                                        ),
                                      );
                                    } else {
                                      base = Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black12,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.ondemand_video),
                                      );
                                    }
                                    // overlay duration if available
                                    return Stack(
                                      children: [
                                        Positioned.fill(child: base),
                                        if (h.durationSeconds != null)
                                          Positioned(
                                            right: 4,
                                            bottom: 4,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(
                                                  0.6,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                _fmtDur(h.durationSeconds!),
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (h.durationSeconds == null &&
                                            snap.connectionState ==
                                                ConnectionState.waiting)
                                          Positioned(
                                            right: 4,
                                            bottom: 4,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(
                                                  0.4,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                '解析中…',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                );
                              } else {
                                return Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: Colors.black12,
                                  ),
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.audiotrack),
                                );
                              }
                            }(),
                          ),
                          title: Text(
                            _prettyFileName(h.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (h.type == 'image'
                                              ? Colors.blueGrey
                                              : (h.type == 'audio'
                                                  ? Colors.teal
                                                  : Colors.deepPurple))
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      h.type.isNotEmpty
                                          ? h.type
                                          : (h.contentType.isNotEmpty
                                              ? h.contentType.split('/').first
                                              : ''),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  if (h.contentType.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        h.contentType,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                h.url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              if (h.type != 'image')
                                Text(
                                  h.durationSeconds != null
                                      ? '時長: ${_fmtDur(h.durationSeconds!)}'
                                      : '時長: 解析中…',
                                  style: const TextStyle(fontSize: 12),
                                ),
                            ],
                          ),
                          onLongPress: () async {
                            await _previewHit(h);
                          },
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.link),
                                tooltip: '複製連結',
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: h.url),
                                  );
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        duration: Duration(seconds: 1),
                                        content: Text('已複製連結'),
                                      ),
                                    );
                                  }
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.download),
                                tooltip: '下載',
                                onPressed: () {
                                  Navigator.pop(context);
                                  _confirmDownload(h.url);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// --- Download speed helpers ---

  /// key => snapshot (key can be url or savePath+phase)
  final Map<String, _RateSnapshot> _rateSnaps = {};

  String _fmtSpeed(num bps) {
    // bytes per second to human friendly string without specifying colors
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s', 'TB/s'];
    double v = bps.toDouble();
    int i = 0;
    while (v >= 1024.0 && i < units.length - 1) {
      v /= 1024.0;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : (v >= 10 ? 1 : 2))} ${units[i]}';
  }

  _RateSnapshot _snapNow(int bytes) => _RateSnapshot(bytes, DateTime.now());

  /// Computes speed in B/s based on previous snapshot.
  /// Returns null if not enough data yet.
  double? _computeSpeed(String key, int bytesNow) {
    final prev = _rateSnaps[key];
    _rateSnaps[key] = _snapNow(bytesNow);
    if (prev == null) return null;
    final dt = DateTime.now().difference(prev.ts).inMilliseconds / 1000.0;
    if (dt <= 0) return null;
    final db = bytesNow - prev.bytes;
    if (db <= 0) return null;
    return db / dt;
  }

  /// --- end helpers ---

  /// Shows a bottom sheet listing all current download tasks. Each entry
  /// displays its name (or URL), status, timestamp, and progress. This
  /// provides quick visibility into ongoing and completed downloads without
  /// navigating away from the browser tab.
  void _openDownloadsSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: AnimatedBuilder(
            animation: AppRepo.I,
            builder: (_, __) {
              final list = repo.downloads.value;

              // 只顯示「下載任務」：與工具列徽章一致
              final tasks =
                  list.where(_isDownloadTaskEntry).toList()
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
              // 檢查並補齊缺失縮圖（重啟後快取丟失時自動重建）
              for (final t in tasks) {
                if (AppRepo.I.resolvedTaskType(t) != 'video') continue;
                final p = t.thumbnailPath;
                if (p == null || p.isEmpty || !File(p).existsSync()) {
                  _regenThumbAsync(t); // 背景抽圖，完成會 setState + 持久化
                }
              }

              if (tasks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('尚無下載任務'),
                );
              }
              return Column(
                children: [
                  ListTile(
                    title: Text('下載清單（${tasks.length}）'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_sweep),
                          tooltip: '清除任務（不刪除已完成媒體）',
                          onPressed: () async {
                            // 只清除任務（進行中/失敗/已取消），保留已完成的下載（已移入媒體）
                            final kept =
                                repo.downloads.value.where((t) {
                                  final s = (t.state).toString().toLowerCase();
                                  return s == 'done';
                                }).toList();
                            repo.downloads.value = kept;
                            Navigator.pop(context);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  duration: Duration(seconds: 1),
                                  content: Text('已清除任務，已完成的媒體已保留'),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: tasks.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final t = tasks[i];
                        return _buildDownloadTile(t);
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// Build a ListTile for a given download task. This encapsulates all the logic
  /// for displaying progress, size, segment counts and conversion status for
  /// both HLS (m3u8) and direct file downloads. It ensures that the UI
  /// reflects real-time updates via [_currentReceived] and by observing
  /// AppRepo notifications.
  Widget _buildDownloadTile(DownloadTask t) {
    // Determine if this task is an HLS playlist. HLS tasks use the segment
    // count to track progress rather than bytes until conversion begins.
    final bool isHls = t.kind == 'hls';
    // A HLS task is considered converting when all segments have been
    // downloaded but the state is still downloading. During this phase the
    // output file grows in size but total segment count does not change.
    final bool isConverting =
        isHls &&
        t.state == 'downloading' &&
        (t.total != null && t.received >= t.total!);
    // HLS tasks actively downloading segments have received fewer segments
    // than the total and are still marked as downloading.
    final bool isDownloadingSegments =
        isHls &&
        t.state == 'downloading' &&
        (t.total != null && t.received < t.total!);
    final resolvedType = AppRepo.I.resolvedTaskType(t);

    // --- Speed calculation setup ---

    String speedKeyPhase = 'dl';
    int? speedBytesNow;

    // Compute progress percentage. For HLS segment downloads, this is the
    // fraction of segments downloaded. For file downloads, it is the
    // fraction of bytes downloaded. When progress cannot be determined, it
    // remains null and the UI will show an indeterminate progress bar.
    double? progressPercent;
    if (isDownloadingSegments) {
      final int totalSegs = t.total ?? 0;
      if (totalSegs > 0) {
        progressPercent = t.received / totalSegs;
      }
    } else if (isHls &&
        t.progressUnit == 'time-ms' &&
        t.total != null &&
        t.total! > 0) {
      progressPercent = t.received / (t.total!.toDouble());
    } else if (!isHls &&
        t.state == 'downloading' &&
        t.total != null &&
        t.total! > 0) {
      progressPercent = t.received / (t.total!.toDouble());
    }

    // Decide which byte counter to use for speed:
    // - 非 HLS：使用 t.received（bytes）
    // - HLS 轉檔階段：使用輸出檔案大小
    // - HLS 片段下載階段：無法可靠取得 bytes，暫不顯示
    if (!isHls && t.state == 'downloading') {
      speedBytesNow = t.received;
      speedKeyPhase = 'dl';
    } else if (isConverting) {
      try {
        final f = File(t.savePath);
        if (f.existsSync()) {
          speedBytesNow = f.lengthSync();
          speedKeyPhase = 'conv';
        }
      } catch (_) {}
    }

    // Build the subtitle lines dynamically. Use a list to collect lines and
    // later spread them into the Column.
    final List<Widget> subtitleWidgets = [];
    bool _addedSize = false;
    // First line: the URL (truncated)
    subtitleWidgets.add(
      Text(
        t.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
    // Second line: status (show '轉換中' during conversion)
    final String statusText = isConverting ? '轉換中' : t.state;
    subtitleWidgets.add(
      Text('狀態: $statusText', style: const TextStyle(fontSize: 12)),
    );
    // For non-HLS tasks, display the timestamp when the download was added. HLS
    // tasks omit this to reduce clutter.
    if (!isHls) {
      subtitleWidgets.add(
        Text(
          '時間: ${t.timestamp.toLocal().toString().split('.').first}',
          style: const TextStyle(fontSize: 12),
        ),
      );
    }
    // If downloading HLS segments, show the segment count and progress.
    if (isDownloadingSegments) {
      subtitleWidgets.add(
        Text(
          '片段: ${t.received}/${t.total}',
          style: const TextStyle(fontSize: 12),
        ),
      );
      final int totalSegs = t.total ?? 0;
      if (totalSegs > 0) {
        final double pct = t.received / totalSegs * 100.0;
        subtitleWidgets.add(
          Text(
            '進度: ${t.received}/${t.total} (${pct.toStringAsFixed(1)}%)',
            style: const TextStyle(fontSize: 12),
          ),
        );
      }
      // 以「片段/秒」顯示近似速度（HLS 片段階段無可靠 byte 計數）
      final segKey = '${t.savePath}|seg';
      final segRate = _computeSpeed(
        segKey,
        t.received,
      ); // delta segments per second
      if (segRate != null) {
        subtitleWidgets.add(
          Text(
            '速度: ${segRate.toStringAsFixed(2)} 片段/秒',
            style: const TextStyle(fontSize: 12),
          ),
        );
      } else {
        _rateSnaps[segKey] = _snapNow(t.received);
        subtitleWidgets.add(
          const Text('速度: 測量中…', style: TextStyle(fontSize: 12)),
        );
      }
    } else if (isHls &&
        t.progressUnit == 'time-ms' &&
        t.total != null &&
        t.total! > 0) {
      final cur = Duration(milliseconds: t.received);
      final tot = Duration(milliseconds: t.total!);
      subtitleWidgets.add(
        Text(
          '進度: ${_fmtDur(cur.inSeconds.toDouble())}/${_fmtDur(tot.inSeconds.toDouble())} (${((progressPercent ?? 0) * 100).toStringAsFixed(1)}%)',
          style: const TextStyle(fontSize: 12),
        ),
      );
      // 顯示目前檔案大小（可選）
      try {
        final f = File(t.savePath);
        if (f.existsSync() && !_addedSize) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
          _addedSize = true;
        }
      } catch (_) {}
    }
    // During conversion of an HLS task, show the current output file size to
    // provide some sense of progress. Since FFmpeg does not expose a
    // percentage, we rely on the file growing over time.
    if (isConverting) {
      try {
        final f = File(t.savePath);
        if (f.existsSync() && !_addedSize) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
          _addedSize = true;
        } else if (!f.existsSync()) {
          subtitleWidgets.add(
            const Text('大小: 轉換中…', style: TextStyle(fontSize: 12)),
          );
        }
      } catch (_) {
        subtitleWidgets.add(
          const Text('大小: 轉換中…', style: TextStyle(fontSize: 12)),
        );
      }
    }
    // For non-HLS downloads: show the downloaded size while downloading and the
    // final size when finished or errored.
    if (!isHls) {
      if (t.state == 'downloading') {
        final hasTotal = t.total != null && t.total! > 0;
        final sizeStr =
            hasTotal
                ? '大小: ${_fmtSize(t.received)} / ${_fmtSize(t.total!)}'
                : '大小: ${_fmtSize(t.received)}';
        subtitleWidgets.add(
          Text(sizeStr, style: const TextStyle(fontSize: 12)),
        );
        if (progressPercent != null) {
          subtitleWidgets.add(
            Text(
              '進度: ${(progressPercent * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
        // 顯示直接下載檔案的即時速度（非 HLS）
        final keyDirect = '${t.savePath}|bytes';
        final spDirect = _computeSpeed(keyDirect, t.received);
        if (spDirect != null) {
          subtitleWidgets.add(
            Text(
              '速度: ${_fmtSpeed(spDirect)}',
              style: const TextStyle(fontSize: 12),
            ),
          );
        } else {
          _rateSnaps[keyDirect] = _snapNow(t.received);
          subtitleWidgets.add(
            const Text('速度: 測量中…', style: TextStyle(fontSize: 12)),
          );
        }
      } else if (t.state == 'done' || t.state == 'error') {
        try {
          final f = File(t.savePath);
          if (f.existsSync() && !_addedSize) {
            subtitleWidgets.add(
              Text(
                '大小: ${_fmtSize(f.lengthSync())}',
                style: const TextStyle(fontSize: 12),
              ),
            );
            _addedSize = true;
          }
        } catch (_) {}
      }
    } else if (isHls && t.state == 'done') {
      // HLS tasks that have completed conversion: show final size.
      try {
        final f = File(t.savePath);
        if (f.existsSync() && !_addedSize) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
          _addedSize = true;
        }
      } catch (_) {}
    }

    // 任何 downloading 狀態下的通用「目前檔案大小」顯示（若前面尚未加入大小）
    if (t.state == 'downloading' && !_addedSize) {
      try {
        final f = File(t.savePath);
        if (f.existsSync()) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
          _addedSize = true;
        }
      } catch (_) {}
    }
    // 顯示即時下載/轉換速度
    if (speedBytesNow != null) {
      final key = '${t.savePath}|$speedKeyPhase';
      final sp = _computeSpeed(key, speedBytesNow!);
      if (sp != null) {
        subtitleWidgets.add(
          Text('速度: ${_fmtSpeed(sp)}', style: const TextStyle(fontSize: 12)),
        );
      } else {
        // 首次建立快照時先不顯示數值（避免顯示 0）
        _rateSnaps[key] = _snapNow(speedBytesNow!);
        subtitleWidgets.add(
          const Text('速度: 測量中…', style: TextStyle(fontSize: 12)),
        );
      }
    }

    // Append duration information when available. If unavailable and the
    // media is audio/video, show a placeholder.
    if (t.duration != null) {
      subtitleWidgets.add(
        Text(
          '時長: ${_fmtDur(t.duration!.inSeconds.toDouble())}',
          style: const TextStyle(fontSize: 12),
        ),
      );
    } else if (resolvedType == 'video' || resolvedType == 'audio') {
      subtitleWidgets.add(
        const Text('時長: 解析中…', style: TextStyle(fontSize: 12)),
      );
    }

    // 對於 HLS 轉換中或下載中，使用小型 ticker 讓速度/大小文字即時刷新
    final needsTicker = isConverting || t.state == 'downloading';
    // Periodic rebuild to refresh speed/progress while active.
    Widget _wrapWithTicker(Widget child) {
      if (!needsTicker) return child;
      return StreamBuilder<int>(
        stream: Stream.periodic(const Duration(milliseconds: 800), (i) => i),
        builder: (_, __) => child,
      );
    }

    Widget buildTile() {
      // Build and return the ListTile. Action buttons for pause/resume/delete
      // remain unchanged. Progress indicators adapt based on the computed
      // progressPercent.
      return ListTile(
        isThreeLine: true,
        dense: false,
        minVerticalPadding: 8,
        leading: SizedBox(width: 64, height: 64, child: _buildThumb(t)),
        title: Text(
          t.name ?? path.basename(t.savePath),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...subtitleWidgets,
            if (t.state == 'downloading')
              (progressPercent == null)
                  ? const LinearProgressIndicator()
                  : LinearProgressIndicator(value: progressPercent),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.state == 'downloading' && !t.paused)
              IconButton(
                icon: const Icon(Icons.pause),
                tooltip: '暫停',
                onPressed: () {
                  AppRepo.I.pauseTask(t);
                },
              ),
            if (t.state == 'paused' || t.paused)
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: '繼續',
                onPressed: () {
                  AppRepo.I.resumeTask(t);
                },
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '刪除',
              onPressed: () async {
                await AppRepo.I.removeTasks([t]);
              },
            ),
          ],
        ),
        onTap: () async {
          if ((t.state).toString().toLowerCase() != 'done') return;
          String? filePath = t.savePath.isNotEmpty ? t.savePath : null;
          if (filePath != null && !File(filePath).existsSync()) {
            filePath = null;
          }
          if (resolvedType == 'video' || resolvedType == 'audio') {
            final target = filePath ?? t.url;
            _playMedia(target);
            return;
          }
          if (resolvedType == 'image') {
            if (filePath != null) {
              final ok = await PurchaseService().ensurePremium(
                context: context,
                featureName: '匯出',
              );
              if (!ok) return;
              final imagePath = filePath;
              if (!mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder:
                      (_) => ImagePreviewPage(
                        filePath: imagePath,
                        title: t.name ?? path.basename(imagePath),
                      ),
                ),
              );
            } else if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  duration: Duration(seconds: 1),
                  content: Text('檔案已不存在'),
                ),
              );
            }
            return;
          }
          if (filePath != null) {
            try {
              await Share.shareXFiles([XFile(filePath)]);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 1),
                    content: Text('匯出失敗: $e'),
                  ),
                );
              }
            }
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                duration: Duration(seconds: 1),
                content: Text('檔案已不存在'),
              ),
            );
          }
        },
      );
    }

    if (!needsTicker) return buildTile();
    return StreamBuilder<DateTime>(
      stream: Stream.periodic(
        const Duration(milliseconds: 700),
        (_) => DateTime.now(),
      ),
      builder: (_, __) => buildTile(),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({
    super.key,
    required this.onOpen,
    required this.prettyName,
  });

  final void Function(String url) onOpen;
  final String Function(String url) prettyName;

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder<List<String>>(
      valueListenable: repo.favorites,
      builder: (context, favs, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text('我的收藏（${favs.length}）'),
            actions: [
              if (favs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: '清除全部',
                  onPressed: () => repo.clearFavorites(),
                ),
            ],
          ),
          body: SafeArea(
            child:
                favs.isEmpty
                    ? const Center(child: Text('尚無收藏'))
                    : ListView.separated(
                      itemCount: favs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final url = favs[index];
                        final display = prettyName(url);
                        return ListTile(
                          leading: const Icon(Icons.bookmark_outline),
                          title: Text(
                            display,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            tooltip: '移除收藏',
                            onPressed: () => repo.removeFavoriteUrl(url),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            onOpen(url);
                          },
                        );
                      },
                    ),
          ),
        );
      },
    );
  }
}

/// A dedicated page that shows the browsing history in a scrollable list. Each
/// entry displays its title (or URL if no title), timestamp and URL. Tapping
/// an entry will invoke [onOpen] to load the URL in the caller's context.
/// A delete icon is shown to remove individual entries and a trash icon in
/// the app bar clears the entire history.
class HistoryPage extends StatelessWidget {
  final void Function(String url) onOpen;
  const HistoryPage({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Scaffold(
      appBar: AppBar(
        title: const Text('瀏覽紀錄'),
        actions: [
          ValueListenableBuilder<List<HistoryEntry>>(
            valueListenable: repo.history,
            builder: (context, hist, _) {
              if (hist.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: '清除全部',
                onPressed: () {
                  repo.clearHistory();
                },
              );
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<List<HistoryEntry>>(
        valueListenable: repo.history,
        builder: (context, hist, _) {
          if (hist.isEmpty) {
            return const Center(child: Text('尚無瀏覽記錄'));
          }
          // Show most recent first.
          final items = [...hist]
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final e = items[i];
              final title = e.title.isNotEmpty ? e.title : e.url;
              return ListTile(
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.timestamp.toLocal().toString().split('.').first,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      e.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  tooltip: '刪除',
                  onPressed: () {
                    repo.removeHistoryEntry(e);
                  },
                ),
                onTap: () {
                  // Close the history page before navigating. Do not pop
                  // twice; the drawer was already dismissed when the history
                  // page was presented.
                  Navigator.of(context).pop();
                  onOpen(e.url);
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// Simple data class describing a tab for the tab manager. Only contains a
/// title to display. The actual URL is managed by [BrowserPage].
class _TabInfo {
  final String title;
  final Uint8List? thumbnail; // 新增：縮圖
  _TabInfo({required this.title, this.thumbnail});
}

/// A page that displays all open browser tabs in a grid. Users can tap a
/// tab to switch to it, close tabs via the close icon, or create a new
/// blank tab. When done, the page is popped and the browser returns to
/// the previous view. This page does not directly modify the browser
/// tabs; instead it invokes the callbacks provided by [BrowserPage] to
/// update the tab list and current index.
class _TabManagerPage extends StatefulWidget {
  final List<_TabInfo> tabs;
  final VoidCallback onAdd;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;
  const _TabManagerPage({
    super.key,
    required this.tabs,
    required this.onAdd,
    required this.onSelect,
    required this.onClose,
  });

  @override
  State<_TabManagerPage> createState() => _TabManagerPageState();
}

class _TabManagerPageState extends State<_TabManagerPage> {
  late List<_TabInfo> _localTabs;
  bool _selectMode = false; // 是否進入選擇模式
  final Set<int> _selected = {}; // 已選索引集合
  @override
  void initState() {
    super.initState();
    _localTabs = List<_TabInfo>.from(widget.tabs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('分頁（${_localTabs.length}）'),
        actions: [
          // 切換選擇模式
          IconButton(
            tooltip: _selectMode ? '退出選擇' : '選擇分頁',
            icon: Icon(_selectMode ? Icons.close : Icons.checklist),
            onPressed: () {
              setState(() {
                _selectMode = !_selectMode;
                _selected.clear();
              });
            },
          ),
          if (_selectMode) ...[
            // 全選/取消全選
            IconButton(
              tooltip:
                  _selected.length == _localTabs.length && _localTabs.isNotEmpty
                      ? '取消全選'
                      : '全選',
              icon: const Icon(Icons.select_all),
              onPressed: () {
                setState(() {
                  if (_selected.length == _localTabs.length &&
                      _localTabs.isNotEmpty) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(List<int>.generate(_localTabs.length, (i) => i));
                  }
                });
              },
            ),
            // 刪除已選
            IconButton(
              tooltip: _selected.isEmpty ? '刪除' : '刪除（${_selected.length}）',
              icon: const Icon(Icons.delete_sweep),
              onPressed:
                  _selected.isEmpty
                      ? null
                      : () {
                        final toRemove =
                            _selected.toList()
                              ..sort((a, b) => b.compareTo(a)); // 由大到小避免位移
                        setState(() {
                          for (final idx in toRemove) {
                            if (idx >= 0 && idx < _localTabs.length) {
                              _localTabs.removeAt(idx);
                              widget.onClose(idx);
                            }
                          }
                          _selected.clear();
                        });
                      },
            ),
          ],
          // 右上的新增分頁（保留）
          IconButton(
            tooltip: '新增分頁',
            iconSize: 30,
            icon: const Icon(Icons.add_box_outlined),
            onPressed: () {
              // Create a real tab in the BrowserPage first
              widget.onAdd();
              // Determine new index (= current local list length before append)
              final int newIndex = _localTabs.length;
              setState(() {
                _localTabs.add(_TabInfo(title: '新分頁'));
              });
              // Switch to the newly created tab and close this manager
              widget.onSelect(newIndex);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _localTabs.isEmpty
              ? Center(
                child: ElevatedButton(
                  onPressed: () {
                    widget.onAdd();
                    Navigator.of(context).pop();
                  },
                  child: const Text('新增分頁'),
                ),
              )
              : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.8,
                ),
                itemCount: _localTabs.length + 1,
                itemBuilder: (context, index) {
                  if (index == _localTabs.length) {
                    return GestureDetector(
                      onTap: () {
                        widget.onAdd();
                        final int newIndex = _localTabs.length;
                        setState(() {
                          _localTabs.add(_TabInfo(title: '新分頁'));
                        });
                        widget.onSelect(newIndex);
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.add, size: 32),
                              SizedBox(height: 8),
                              Text('新增分頁'),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  final tab = _localTabs[index];
                  return GestureDetector(
                    onTap: () {
                      if (_selectMode) {
                        setState(() {
                          if (_selected.contains(index)) {
                            _selected.remove(index);
                          } else {
                            _selected.add(index);
                          }
                        });
                      } else {
                        widget.onSelect(index);
                        Navigator.of(context).pop();
                      }
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Preview image (if any)
                            if (tab.thumbnail != null)
                              Image.memory(tab.thumbnail!, fit: BoxFit.cover)
                            else
                              Container(
                                color:
                                    Theme.of(
                                      context,
                                    ).colorScheme.surfaceVariant,
                              ),
                            // Title overlay at bottom
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 8,
                              child: Text(
                                tab.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(blurRadius: 3, color: Colors.black),
                                  ],
                                ),
                              ),
                            ),
                            // Close button at top‑right
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 10,
                                    minHeight: 10,
                                  ),
                                  icon: const Icon(
                                    Icons.close,
                                    size: 20,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _localTabs.removeAt(index);
                                    });
                                    widget.onClose(index);
                                  },
                                ),
                              ),
                            ),
                            if (_selectMode)
                              Positioned(
                                top: 6,
                                left: 6,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black45,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Checkbox(
                                    value: _selected.contains(index),
                                    onChanged: (v) {
                                      setState(() {
                                        if (v == true) {
                                          _selected.add(index);
                                        } else {
                                          _selected.remove(index);
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          if (_selectMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Theme.of(context).colorScheme.surface,
                  child: Row(
                    children: [
                      Text('已選：${_selected.length}'),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (_selected.length == _localTabs.length &&
                                _localTabs.isNotEmpty) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(
                                  List<int>.generate(
                                    _localTabs.length,
                                    (i) => i,
                                  ),
                                );
                            }
                          });
                        },
                        child: Text(
                          _selected.length == _localTabs.length &&
                                  _localTabs.isNotEmpty
                              ? '取消全選'
                              : '全選',
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.delete),
                        label: const Text('刪除'),
                        onPressed:
                            _selected.isEmpty
                                ? null
                                : () {
                                  final toRemove =
                                      _selected.toList()
                                        ..sort((a, b) => b.compareTo(a));
                                  setState(() {
                                    for (final idx in toRemove) {
                                      if (idx >= 0 && idx < _localTabs.length) {
                                        _localTabs.removeAt(idx);
                                        widget.onClose(idx);
                                      }
                                    }
                                    _selected.clear();
                                  });
                                },
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
