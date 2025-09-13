import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'soure.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// BrowserPage encapsulates a WebView with URL entry, navigation, and a bar
/// showing detected media resources. It hooks into resource loading
/// callbacks and JavaScript injection to sniff media URLs (audio/video).
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  InAppWebViewController? controller;
  final urlCtrl = TextEditingController(text: 'https://google.com');
  final repo = AppRepo.I;
  final Map<String, String> _thumbCache = {};

  @override
  void initState() {
    super.initState();
    urlCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: TextField(
                controller: urlCtrl,
                textInputAction: TextInputAction.go,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: '輸入網址後按前往',
                  suffixIcon:
                      urlCtrl.text.isNotEmpty
                          ? IconButton(
                            tooltip: '清除網址',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              urlCtrl.clear();
                              FocusScope.of(context).requestFocus(FocusNode());
                            },
                          )
                          : null,
                ),
                onSubmitted: (v) => _go(v),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder(
              valueListenable: repo.snifferEnabled,
              builder: (_, on, __) {
                final enabled = on as bool;
                return IconButton(
                  icon: Icon(enabled ? Icons.visibility : Icons.visibility_off),
                  color: enabled ? Colors.green : null,
                  tooltip: enabled ? '嗅探：開啟' : '嗅探：關閉',
                  onPressed: () async {
                    final next = !enabled;
                    repo.setSnifferEnabled(next);
                    // apply to current page
                    if (controller != null) {
                      await controller!.evaluateJavascript(
                        source: Sniffer.jsSetEnabled(next),
                      );
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
          ],
        ),
        actions: [
          // The magnifying glass now opens the list of detected resources instead of navigating.
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '偵測到的資源',
            onPressed: _openDetectedSheet,
          ),
          // Favorite current page button
          IconButton(
            icon: const Icon(Icons.favorite_border),
            onPressed: _addCurrentToFav,
          ),
          // Downloads list with badge; shows how many download tasks exist.
          ValueListenableBuilder(
            valueListenable: repo.downloads,
            builder: (_, list, __) {
              final count = (list as List).length;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: const Icon(Icons.file_download),
                    onPressed: _openDownloadsSheet,
                    tooltip: '下載清單',
                  ),
                  if (count > 0)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(
                            fontSize: 11,
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
        ],
      ),
      body: Column(
        children: [
          _toolbar(),
          Expanded(
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
                useOnLoadResource: true,
                javaScriptEnabled: true,
                allowsBackForwardNavigationGestures: true,
              ),
              initialUrlRequest: URLRequest(url: WebUri(urlCtrl.text)),
              onWebViewCreated: (c) {
                controller = c;
                // Register the JavaScript handler that receives sniffed media info.
                c.addJavaScriptHandler(
                  handlerName: 'sniffer',
                  callback: (args) {
                    // Respect the global sniffer toggle; ignore JS events when off.
                    if (!repo.snifferEnabled.value) {
                      return {'ok': false, 'ignored': true};
                    }
                    final map = Map<String, dynamic>.from(args.first);
                    repo.addHit(
                      MediaHit(
                        url: map['url'] ?? '',
                        type: map['type'] ?? 'video',
                        contentType: map['contentType'] ?? '',
                      ),
                    );
                    return {'ok': true};
                  },
                );
              },
              onLoadStart: (c, u) async {
                if (u != null) {
                  urlCtrl.text = u.toString();
                }
              },
              onUpdateVisitedHistory: (c, url, androidIsReload) async {
                if (url != null) {
                  urlCtrl.text = url.toString();
                }
              },
              onLoadStop: (c, u) async {
                // Inject the sniffing JS after page load, then sync the enabled flag.
                await c.evaluateJavascript(source: Sniffer.jsHook);
                await c.evaluateJavascript(
                  source: Sniffer.jsSetEnabled(repo.snifferEnabled.value),
                );
              },
              onLoadResource: (c, r) async {
                if (!repo.snifferEnabled.value) {
                  return;
                }
                // Use resource loads to detect media.
                final url = r.url.toString();
                final ct =
                    ''; // LoadedResource has no content-type field across platforms; rely on URL sniffing here
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
                // Android only: intercept HTTP requests to detect media.
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
                // Allow long-press quick actions even when the global sniffer is OFF.
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
                        // 這裡簡單拿第一個；要更精準可再加條件（例如 duration 有值 / 目前有在播放等）
                        final Map<String, dynamic> first =
                            Map<String, dynamic>.from(decoded.first as Map);
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
                                    controller?.loadUrl(
                                      urlRequest: URLRequest(
                                        url: WebUri(link!),
                                      ),
                                    );
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
          ),
        ],
      ),
    );
  }

  /// Toolbar with back/forward/refresh and a button to load the current URL into the address bar.
  Widget _toolbar() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => controller?.goBack(),
        ),
        IconButton(
          icon: const Icon(Icons.arrow_forward),
          onPressed: () => controller?.goForward(),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => controller?.reload(),
        ),
        const Spacer(),
        // Removed the open_in_browser button as it was unused.
      ],
    );
  }

  /// Navigates to a new URL entered by the user.
  Future<void> _go(String v) async {
    final text = v.trim();
    if (text.isEmpty) return;
    // If the text looks like a URL (contains a dot or starts with http/https), navigate directly;
    // otherwise perform a Google search. Prefix bare domains with https.
    final isUrl = text.startsWith('http') || text.contains('.');
    final dest = isUrl
        ? (text.startsWith('http') ? text : 'https://$text')
        : 'https://www.google.com/search?q=${Uri.encodeComponent(text)}';
    await controller?.loadUrl(urlRequest: URLRequest(url: WebUri(dest)));
  }

  /// Adds the current page URL to favorites.
  Future<void> _addCurrentToFav() async {
    final u = await controller?.getUrl();
    if (u == null) return;
    final cur = [...AppRepo.I.favorites.value, u.toString()];
    AppRepo.I.favorites.value = cur;
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已加入收藏')));
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
                        controller?.loadUrl(
                          urlRequest: URLRequest(url: WebUri(h.url)),
                        );
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
                            width: 44,
                            height: 44,
                            child:
                                h.type == 'image'
                                    ? ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.network(
                                        h.url,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (_, __, ___) =>
                                                const Icon(Icons.image),
                                      ),
                                    )
                                    : Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(6),
                                        color: Colors.black12,
                                      ),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        h.type == 'audio'
                                            ? Icons.audiotrack
                                            : Icons.ondemand_video,
                                      ),
                                    ),
                          ),
                          title: Text(
                            h.url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Row(
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
          child: ValueListenableBuilder(
            valueListenable: repo.downloads,
            builder: (_, List<DownloadTask> list, __) {
              // Sort newest first
              final tasks = [...list]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
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
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: tasks.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final t = tasks[i];
                        final prog = (t.total == null || t.total == 0)
                            ? null
                            : t.received / (t.total!);
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
                        return ListTile(
                          leading: leading,
                          title: Text(
                            t.name ?? t.url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('狀態: ${t.state}'),
                              Text('時間: ${t.timestamp.toLocal().toString().split('.').first}'),
                              if (prog != null) LinearProgressIndicator(value: prog),
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
}
