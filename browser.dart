import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'soure.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
// Import the media page to allow launching the built‑in video player when
// playing remote videos from the browser. This also brings in the
// VideoPlayerPage class used in the play callbacks.
import 'media.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';

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

class _BrowserPageState extends State<BrowserPage> {
  // Global key used to control the Scaffold (e.g. open the end drawer) from
  // contexts where Scaffold.of(context) does not resolve correctly, such as
  // bottom sheets. This allows the side drawer to slide in from the right
  // when the menu button is pressed in the downloads sheet.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // Global key for the tab count button (for anchored popup menu)
  final GlobalKey _tabButtonKey = GlobalKey();

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

  // ---- UA Preference ----
  String? _uaMode; // 'iphone' | 'ipad' | 'android'
  String? _userAgent; // resolved UA string used by WebView
  bool _uaInitialized = false;

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

  Future<void> _openMiniPlayer(String url) async {
    // 關掉舊的
    await _closeMiniPlayer();
    _miniUrl = url;

    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
      _miniCtrl = ctrl;
      await ctrl.initialize();
      await ctrl.play();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('無法開啟迷你播放器')));
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
                            const SnackBar(content: Text('已加入下載')),
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
                  final tab = _TabData();
                  tab.urlCtrl.addListener(() {
                    if (mounted) setState(() {});
                  });
                  _tabs.add(tab);
                  _currentTabIndex = _tabs.length - 1;
                });
                _updateOpenTabs();
              },
              onSelect: (int index) {
                setState(() {
                  _currentTabIndex = index;
                });
              },
              onClose: (int index) {
                setState(() {
                  final removed = _tabs.removeAt(index);
                  removed.urlCtrl.dispose();
                  removed.progress.dispose();
                  if (_currentTabIndex >= _tabs.length) {
                    _currentTabIndex = _tabs.length - 1;
                  } else if (_currentTabIndex > index) {
                    _currentTabIndex -= 1;
                  }
                });
                _updateOpenTabs();
              },
            ),
      ),
    );
  }

  // Removed the obsolete _showHome flag. Home navigation happens via RootNav.

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

  /// Prompt the user to add the current page to the home screen. Prefills
  /// the dialog with the current title (or derived file name) and URL.
  void _showAddToHomeDialog() {
    // Use the active tab's title and current URL as defaults. Fall back to
    // deriving a file name from the URL when no title exists.
    String? tabTitle;
    String? tabUrl;
    if (_tabs.isNotEmpty) {
      final tab = _tabs[_currentTabIndex];
      tabTitle = tab.pageTitle;
      tabUrl = tab.currentUrl;
    }
    final defaultName =
        (tabTitle != null && tabTitle.trim().isNotEmpty)
            ? tabTitle.trim()
            : (tabUrl != null ? _prettyFileName(tabUrl) : '');
    final nameCtrl = TextEditingController(text: defaultName);
    final urlCtrlLocal = TextEditingController(text: tabUrl ?? '');
    showDialog(
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
    // Restore any previously open tabs from the repository. If none
    // exist, start with a single blank tab. Each tab’s URL controller
    // will update the UI when its text changes.
    final savedTabs = repo.openTabs.value;
    if (savedTabs.isNotEmpty) {
      for (final url in savedTabs) {
        final tab = _TabData(initialUrl: url);
        tab.urlCtrl.addListener(() {
          if (mounted) setState(() {});
        });
        _tabs.add(tab);
      }
      _currentTabIndex = 0;
    } else {
      _tabs.add(_TabData());
      _tabs[0].urlCtrl.addListener(() {
        if (mounted) setState(() {});
      });
    }
    // Save the restored tabs back into the repo in case they were just
    // created from saved state. This ensures that any default blank tab
    // also gets persisted.
    _updateOpenTabs();

    // When a pending URL is set via the home page, load it automatically in
    // the current browser tab.
    repo.pendingOpenUrl.addListener(() {
      final pending = repo.pendingOpenUrl.value;
      if (pending != null && pending.isNotEmpty) {
        if (_tabs.isNotEmpty) {
          final tab = _tabs[_currentTabIndex];
          tab.urlCtrl.text = pending;
        }
        _go(pending);
        // Clear the notifier so the URL isn't loaded repeatedly.
        repo.pendingOpenUrl.value = null;
      }
    });
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
      // Provide a right‑hand drawer that slides in to show favourites, history
      // and settings such as the pop‑up blocker. When the menu icon is
      // pressed, this drawer will open. Clicking outside closes it.
      endDrawer: Drawer(child: SafeArea(child: _buildEndDrawer(context))),
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
                    textInputAction: TextInputAction.go,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: '輸入網址或關鍵字以搜尋',
                      suffixIcon:
                          (_tabs.isNotEmpty &&
                                  _tabs[_currentTabIndex]
                                      .urlCtrl
                                      .text
                                      .isNotEmpty &&
                                  _urlFocus.hasFocus)
                              ? IconButton(
                                tooltip: '清除網址',
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  if (_tabs.isNotEmpty) {
                                    _tabs[_currentTabIndex].urlCtrl.clear();
                                  }
                                  // Remove focus so the keyboard hides.
                                  _urlFocus.unfocus();
                                  setState(() {});
                                },
                              )
                              : null,
                    ),
                    onSubmitted: (v) => _go(v),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '重新整理',
                  onPressed: () {
                    if (_tabs.isNotEmpty) {
                      _tabs[_currentTabIndex].controller?.reload();
                    }
                  },
                ),
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
                  InAppWebView(
                    key: _tabs[tabIndex].webviewKey,
                    initialSettings: InAppWebViewSettings(
                      userAgent: _userAgent,
                      allowsInlineMediaPlayback: true,
                      mediaPlaybackRequiresUserGesture: false,
                      useOnLoadResource: true,
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
                          final url = map['url'] ?? '';
                          final type = map['type'] ?? 'video';
                          final contentType = map['contentType'] ?? '';
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
                    },
                    onLoadStart: (c, u) async {
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
                    onUpdateVisitedHistory: (c, url, androidIsReload) async {
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
                      // 注入嗅探腳本並同步開關
                      await c.evaluateJavascript(source: Sniffer.jsHook);
                      await c.evaluateJavascript(
                        source: Sniffer.jsSetEnabled(repo.snifferEnabled.value),
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
                      if (repo.blockPopup.value && uri != null) {
                        // If pop‑ups are blocked, load the URL in the same WebView and
                        // prevent a new window from being created.
                        ctl.loadUrl(urlRequest: URLRequest(url: uri));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('彈出視窗已被阻擋')),
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
                            type: ct.startsWith('audio/') ? 'audio' : 'video',
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
                    onLongPressHitTestResult: (c, res) async {
                      String? link = res.extra;
                      String type = 'video';
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
                              type = (first['type'] ?? 'video') as String;
                            }
                          }
                        } catch (_) {}
                      }
                      if (link == null || link.isEmpty) return;
                      if (!mounted) return;
                      showModalBottomSheet(
                        context: context,
                        builder:
                            (_) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    title: Text(
                                      link!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(type),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton.icon(
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text('播放'),
                                        onPressed: () {
                                          Navigator.pop(context);
                                          // 使用內建播放器播放（支援 iOS 子母畫面 PiP）。
                                          _playMedia(link!);
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      FilledButton.icon(
                                        icon: const Icon(Icons.download),
                                        label: const Text('下載'),
                                        onPressed: () {
                                          Navigator.pop(context);
                                          _confirmDownload(link!);
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
                    },
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
      final tab = _TabData();
      tab.urlCtrl.addListener(() {
        if (mounted) setState(() {});
      });
      _tabs.add(tab);
      _currentTabIndex = 0;
    });
    _updateOpenTabs();
  }

  /// Toolbar with back/forward/refresh and a button to load the current URL into the address bar.
  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: LayoutBuilder(
        builder: (context, box) {
          final shortest = MediaQuery.of(context).size.shortestSide;
          final bool tablet = shortest >= 600;
          return Row(
            mainAxisAlignment:
                tablet
                    ? MainAxisAlignment.spaceEvenly
                    : MainAxisAlignment.start,
            children: [
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
              // Sniffer enable/disable toggle
              ValueListenableBuilder<bool>(
                valueListenable: repo.snifferEnabled,
                builder: (context, on, _) {
                  return IconButton(
                    icon: Icon(on ? Icons.visibility : Icons.visibility_off),
                    color: on ? Colors.green : null,
                    tooltip: on ? '嗅探：開啟' : '嗅探：關閉',
                    onPressed: () async {
                      final next = !on;
                      repo.setSnifferEnabled(next);
                      // apply to current page
                      if (_tabs.isNotEmpty) {
                        final tab = _tabs[_currentTabIndex];
                        if (tab.controller != null) {
                          await tab.controller!.evaluateJavascript(
                            source: Sniffer.jsSetEnabled(next),
                          );
                        }
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(next ? '已開啟嗅探' : '已關閉嗅探')),
                        );
                      }
                    },
                  );
                },
              ),
              // Detected resources icon with badge
              ValueListenableBuilder<List<MediaHit>>(
                valueListenable: repo.hits,
                builder: (context, list, _) {
                  final int detected = list.length;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: '偵測到的資源',
                        onPressed: _openDetectedSheet,
                      ),
                      if (detected > 0)
                        Positioned(
                          right: 0,
                          top: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$detected',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              // Favourite current page button (filled if current page is favourited)
              ValueListenableBuilder<List<String>>(
                valueListenable: repo.favorites,
                builder: (context, favs, _) {
                  String? curUrl;
                  if (_tabs.isNotEmpty) {
                    curUrl = _tabs[_currentTabIndex].currentUrl;
                  }
                  final isFav = curUrl != null && favs.contains(curUrl);
                  return IconButton(
                    icon: Icon(isFav ? Icons.favorite : Icons.favorite_border),
                    color: isFav ? Colors.redAccent : null,
                    tooltip: isFav ? '取消收藏' : '收藏',
                    onPressed: () {
                      final url =
                          (_tabs.isNotEmpty)
                              ? _tabs[_currentTabIndex].currentUrl
                              : null;
                      if (url != null) {
                        repo.toggleFavoriteUrl(url);
                        setState(() {});
                      }
                    },
                  );
                },
              ),
              // Downloads list with badge; shows how many download tasks exist.
              ValueListenableBuilder<List<DownloadTask>>(
                valueListenable: repo.downloads,
                builder: (context, list, _) {
                  final count = list.length;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.file_download),
                        tooltip: '下載清單',
                        onPressed: _openDownloadsSheet,
                      ),
                      if (count > 0)
                        Positioned(
                          right: 0,
                          top: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              // Add current page to home screen
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '加入主頁',
                onPressed: _showAddToHomeDialog,
              ),
              // Navigate to the home screen via callback
              Padding(
                padding: const EdgeInsets.only(right: 4.0), // adjust spacing
                child: IconButton(
                  icon: const Icon(Icons.home),
                  tooltip: '主頁',
                  onPressed: () {
                    if (widget.onGoHome != null) {
                      widget.onGoHome!();
                    }
                  },
                ),
              ),
              // Custom tab count button
              GestureDetector(
                onTap: _openTabManager,
                onLongPress: () async {
                  final overlay =
                      Overlay.of(context).context.findRenderObject()
                          as RenderBox;
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
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已清除全部分頁')));
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
            ],
          );
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

    if (_tabs.isNotEmpty) {
      final tab = _tabs[_currentTabIndex];
      tab.urlCtrl.text = dest;
      tab.currentUrl = dest;
      await tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(dest)));
      _updateOpenTabs();
    }
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已更新收藏狀態')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入佇列，完成後會存入相簿')));
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

  /// Builds the side drawer that slides in from the right. The drawer
  /// contains sections for favourites, browsing history and the pop‑up
  /// blocking toggle. Tapping a favourite or history item loads it in
  /// the current WebView and closes the drawer. Each section has an
  /// optional clear button to remove all entries.
  Widget _buildEndDrawer(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Favourites section
        ValueListenableBuilder<List<String>>(
          valueListenable: repo.favorites,
          builder: (context, favs, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExpansionTile(
                  leading: const Icon(Icons.favorite),
                  title: Text('我的收藏（${favs.length}）'),
                  childrenPadding: const EdgeInsets.only(
                    left: 16,
                    right: 8,
                    bottom: 8,
                  ),
                  children: [
                    if (favs.isEmpty)
                      const ListTile(
                        dense: true,
                        title: Text('尚無收藏', style: TextStyle(fontSize: 14)),
                      )
                    else ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          icon: const Icon(Icons.delete_sweep),
                          tooltip: '清除全部',
                          onPressed: () {
                            repo.clearFavorites();
                          },
                        ),
                      ),
                      const Divider(height: 1),
                      ...favs.map((url) {
                        final display = _prettyFileName(url);
                        return ListTile(
                          dense: true,
                          title: Text(
                            display,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            tooltip: '移除收藏',
                            onPressed: () {
                              repo.removeFavoriteUrl(url);
                            },
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            if (_tabs.isNotEmpty) {
                              final tab = _tabs[_currentTabIndex];
                              tab.controller?.loadUrl(
                                urlRequest: URLRequest(url: WebUri(url)),
                              );
                            }
                          },
                        );
                      }),
                    ],
                  ],
                ),
                const Divider(height: 1),
              ],
            );
          },
        ),
        // History section header
        ValueListenableBuilder<List<HistoryEntry>>(
          valueListenable: repo.history,
          builder: (context, hist, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text('瀏覽記錄（${hist.length}）'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hist.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.delete_sweep),
                          tooltip: '清除全部',
                          onPressed: () {
                            repo.clearHistory();
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        tooltip: '查看更多',
                        onPressed: () {
                          // Close the drawer and show the full history page. The
                          // callback passed to HistoryPage will simply load the
                          // URL; the HistoryPage itself will handle popping.
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder:
                                  (_) => HistoryPage(
                                    onOpen: (String url) {
                                      if (_tabs.isNotEmpty) {
                                        final tab = _tabs[_currentTabIndex];
                                        tab.controller?.loadUrl(
                                          urlRequest: URLRequest(
                                            url: WebUri(url),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  // Allow tapping anywhere on the tile to open the history page
                  onTap: () {
                    // Same as tapping the chevron: close drawer then open history page.
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
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
                  },
                ),
                const Divider(height: 1),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        // Pop‑up blocking toggle
        ValueListenableBuilder<bool>(
          valueListenable: repo.blockPopup,
          builder: (context, block, _) {
            return SwitchListTile(
              secondary: const Icon(Icons.block),
              title: const Text('阻擋彈出視窗'),
              value: block,
              onChanged: (v) {
                repo.setBlockPopup(v);
              },
            );
          },
        ),
      ],
    );
  }

  /// Shows a bottom sheet listing all detected media resources with download buttons.
  void _openDetectedSheet() {
    showModalBottomSheet(
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
                            const SnackBar(content: Text('已清除所有資源')),
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
                                      const SnackBar(content: Text('已複製連結')),
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
              final tasks = [...list]
                ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
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
                                  content: Text('已清除任務，已完成的媒體已保留'),
                                ),
                              );
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.menu),
                          tooltip: '選單',
                          onPressed: () {
                            Navigator.pop(context);
                            _scaffoldKey.currentState?.openEndDrawer();
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

    // Determine the leading icon or thumbnail. Use a saved thumbnail if
    // available; otherwise fall back to an icon based on media type.
    Widget leading;
    if (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync()) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(t.thumbnailPath!),
          width: 44,
          height: 44,
          fit: BoxFit.cover,
        ),
      );
    } else if (t.type == 'video') {
      leading = const Icon(Icons.ondemand_video);
    } else if (t.type == 'audio') {
      leading = const Icon(Icons.audiotrack);
    } else if (t.type == 'image') {
      leading = const Icon(Icons.image);
    } else {
      leading = const Icon(Icons.insert_drive_file);
    }

    // Build the subtitle lines dynamically. Use a list to collect lines and
    // later spread them into the Column.
    final List<Widget> subtitleWidgets = [];
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
        if (f.existsSync()) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
      } catch (_) {}
    }
    // During conversion of an HLS task, show the current output file size to
    // provide some sense of progress. Since FFmpeg does not expose a
    // percentage, we rely on the file growing over time.
    if (isConverting) {
      try {
        final f = File(t.savePath);
        if (f.existsSync()) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
        } else {
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
      } else if (t.state == 'done' || t.state == 'error') {
        try {
          final f = File(t.savePath);
          if (f.existsSync()) {
            subtitleWidgets.add(
              Text(
                '大小: ${_fmtSize(f.lengthSync())}',
                style: const TextStyle(fontSize: 12),
              ),
            );
          }
        } catch (_) {}
      }
    } else if (isHls && t.state == 'done') {
      // HLS tasks that have completed conversion: show final size.
      try {
        final f = File(t.savePath);
        if (f.existsSync()) {
          subtitleWidgets.add(
            Text(
              '大小: ${_fmtSize(f.lengthSync())}',
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
      } catch (_) {}
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
    } else if (t.type == 'video' || t.type == 'audio') {
      subtitleWidgets.add(
        const Text('時長: 解析中…', style: TextStyle(fontSize: 12)),
      );
    }

    // 對於 HLS 轉換中，使用小型 ticker 讓大小文字即時刷新
    final needsTicker = isConverting;

    Widget buildTile() {
      // Build and return the ListTile. Action buttons for pause/resume/delete
      // remain unchanged. Progress indicators adapt based on the computed
      // progressPercent.
      return ListTile(
        isThreeLine: true,
        dense: false,
        minVerticalPadding: 8,
        leading: leading,
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
              widget.onAdd();
              setState(() {
                _localTabs.add(_TabInfo(title: '新分頁'));
              });
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
                        setState(() {
                          _localTabs.add(_TabInfo(title: '新分頁'));
                        });
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
