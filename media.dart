import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'soure.dart';
import 'browser.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'video_player_page.dart';
import 'image_preview_page.dart';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String formatFileSize(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  } else if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(2)} MB';
  } else if (bytes >= kb) {
    return '${(bytes / kb).toStringAsFixed(2)} KB';
  } else {
    return '$bytes B';
  }
}

bool _fileHasContent(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return false;
    return file.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// MediaPage displays two tabs: 媒體 (ongoing downloads + completed files) and 我的收藏.
///
/// Previously this page required Face ID (or other biometrics) to unlock
/// sensitive content, but the lock has been removed. The tabs are now
/// always accessible without authentication.
class MediaPage extends StatefulWidget {
  const MediaPage({super.key});

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void initState() {
    super.initState();
    // Previously performed biometric authentication here. The app no longer
    // locks the media section behind Face ID/Touch ID.
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('媒體'),
            bottom: TabBar(
              controller: _tab,
              tabs: const [Tab(text: '媒體'), Tab(text: '我的收藏')],
            ),
          ),
          body: TabBarView(
            controller: _tab,
            children: const [_MediaAll(), _MyFavorites()],
          ),
        ),
      ],
    );
  }
}

/// Shows ongoing and completed download tasks with progress indicators and sharing options.
class _MediaAll extends StatefulWidget {
  const _MediaAll();

  @override
  State<_MediaAll> createState() => _MediaAllState();
}

class _MediaAllState extends State<_MediaAll> {
  Timer? _convertTicker;
  // --- Search state ---
  final TextEditingController _searchCtl = TextEditingController();
  String _search = '';
  Timer? _searchDebounce;

  /// Formats a byte count as a human readable string (KB, MB, GB, etc).
  String _fmtSize(int bytes) => formatFileSize(bytes);

  int _currentReceived(DownloadTask t) {
    // Prefer task's reported bytes; if zero, fall back to file length on disk.
    if (t.received != null && t.received > 0) return t.received;
    try {
      final f = File(t.savePath);
      if (f.existsSync()) {
        final len = f.lengthSync();
        if (len > 0) return len;
      }
    } catch (_) {}
    return 0;
  }

  /// Translate a task's internal state into a human‑friendly label. HLS tasks
  /// need to differentiate between downloading segments and the conversion
  /// phase, which both share the same state value ('downloading'). When all
  /// segments have been downloaded but conversion is ongoing, this returns
  /// '轉換中'. For non‑HLS tasks, common states are mapped to Chinese terms.
  String _stateLabel(DownloadTask t) {
    final isHls = t.kind == 'hls';
    // Paused overrides other statuses.
    if (t.state == 'paused' || t.paused) return '已暫停';
    if (t.state == 'error') return '失敗';
    if (t.state == 'done') return '已完成';
    if (isHls) {
      final total = t.total ?? 0;
      if (t.state == 'downloading') {
        if (total > 0 && t.received >= total) {
          return '轉換中';
        }
        return '下載中';
      }
      return '排隊中';
    } else {
      if (t.state == 'downloading') return '下載中';
      if (t.state == 'queued') return '排隊中';
      return t.state;
    }
  }

  // 1) 狀態欄位與判斷函式
  bool _metaRefreshQueued = false;

  bool _needsMeta(DownloadTask t) {
    if (t.state != 'done') return false;
    final hasThumb =
        (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync());
    final hasDuration = t.duration != null && t.duration! > Duration.zero;
    return !(hasThumb && hasDuration);
  }

  bool _selectMode = false;
  final Set<DownloadTask> _selected = {};

  void _renameTask(BuildContext context, DownloadTask task) {
    final controller = TextEditingController(text: task.name ?? '');
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('重新命名'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '輸入新的名稱'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) {
                  AppRepo.I.renameTask(task, value);
                }
                Navigator.pop(context);
              },
              child: const Text('儲存'),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    // Automatically rescan the downloads folder when the media page is
    // first displayed. This picks up files saved via the Files app or
    // other means and triggers preview generation for videos.
    Future.microtask(() async {
      try {
        await AppRepo.I.rescanDownloadsFolder();
      } catch (_) {}
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _convertTicker?.cancel();
    _searchDebounce?.cancel();
    try {
      _searchCtl.dispose();
    } catch (_) {}
    super.dispose();
  }

  void _ensureConvertTicker(bool active) {
    if (active) {
      if (_convertTicker == null) {
        _convertTicker = Timer.periodic(const Duration(milliseconds: 700), (_) {
          if (mounted) setState(() {});
        });
      }
    } else {
      _convertTicker?.cancel();
      _convertTicker = null;
    }
  }

  void _toggleSelect(DownloadTask t) {
    setState(() {
      if (_selected.contains(t)) {
        _selected.remove(t);
      } else {
        _selected.add(t);
      }
    });
  }

  void _selectAll(List<DownloadTask> tasks) {
    setState(() {
      _selected
        ..clear()
        ..addAll(tasks);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    await AppRepo.I.removeTasks(_selected.toList());
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  Future<void> _openTask(BuildContext context, DownloadTask t) async {
    if (!File(t.savePath).existsSync()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('檔案已不存在')));
      return;
    }
    final resolvedType = AppRepo.I.resolvedTaskType(t);
    if (resolvedType == 'video' || resolvedType == 'audio') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => VideoPlayerPage(
                path: t.savePath,
                title: t.name ?? path.basename(t.savePath),
              ),
        ),
      );
    } else if (resolvedType == 'image') {
      if (!_fileHasContent(t.savePath)) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('檔案尚未完成或已損毀')));
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => ImagePreviewPage(
                filePath: t.savePath,
                title: t.name ?? path.basename(t.savePath),
              ),
        ),
      );
    } else {
      await Share.shareXFiles([XFile(t.savePath)]);
    }
  }

  void _toggleFavorite(DownloadTask task) {
    AppRepo.I.setFavorite(task, !task.favorite);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (_selectMode) ...[
                TextButton(
                  onPressed: () {
                    _selectAll(repo.downloads.value);
                  },
                  child: const Text('全選'),
                ),
                TextButton(onPressed: _deleteSelected, child: const Text('刪除')),
                TextButton(
                  onPressed: () async {
                    if (_selected.isEmpty) return;
                    try {
                      final files =
                          _selected.map((t) => XFile(t.savePath)).toList();
                      await Share.shareXFiles(files);
                      setState(() {
                        _selected.clear();
                        _selectMode = false;
                      });
                    } catch (e) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('匯出失敗: $e')));
                    }
                  },
                  child: const Text('匯出...'),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _selectMode = false;
                      _selected.clear();
                    });
                  },
                ),
              ] else ...[
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectMode = true;
                    });
                  },
                  child: const Text('選取'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    await AppRepo.I.rescanDownloadsFolder(
                      regenerateThumbnails: true,
                    );
                    if (mounted) setState(() {});
                  },
                  child: const Text('重新掃描'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _searchCtl,
                      textInputAction: TextInputAction.search,
                      onChanged: (value) {
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(
                          const Duration(milliseconds: 250),
                          () {
                            if (!mounted) return;
                            setState(() => _search = value.trim());
                          },
                        );
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜尋名稱/檔名',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon:
                            _search.isNotEmpty
                                ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchCtl.clear();
                                    setState(() => _search = '');
                                  },
                                )
                                : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<DownloadTask>>(
            valueListenable: repo.downloads,
            builder: (context, list, _) {
              var tasks = [...list]
                ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
              final Map<String, DownloadTask> byPath = {};
              for (final task in tasks) {
                final key = path.normalize(task.savePath);
                final existing = byPath[key];
                if (existing == null) {
                  byPath[key] = task;
                  continue;
                }
                int score(DownloadTask t) {
                  var s = 0;
                  if (t.thumbnailPath != null &&
                      File(t.thumbnailPath!).existsSync())
                    s += 2;
                  if (t.duration != null && t.duration! > Duration.zero) s += 2;
                  if ((t.name ?? '').isNotEmpty) s += 1;
                  if (t.favorite) s += 1;
                  if (t.total != null && t.total! > 0) s += 1;
                  return s;
                }

                byPath[key] = score(task) >= score(existing) ? task : existing;
              }
              tasks =
                  byPath.values.toList()
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
              if (_search.isNotEmpty) {
                final q = _search.toLowerCase();
                tasks =
                    tasks.where((t) {
                      final name = (t.name ?? '').toLowerCase();
                      final url = t.url.toLowerCase();
                      final file = path.basename(t.savePath).toLowerCase();
                      return name.contains(q) ||
                          url.contains(q) ||
                          file.contains(q);
                    }).toList();
              }
              final hasActiveConversion = tasks.any(
                (t) =>
                    t.kind == 'hls' &&
                    t.state == 'downloading' &&
                    t.total != null &&
                    t.received >= (t.total ?? 0),
              );
              _ensureConvertTicker(hasActiveConversion);
              final hasMissingMeta = tasks.any(_needsMeta);
              if (hasMissingMeta && !_metaRefreshQueued) {
                _metaRefreshQueued = true;
                Future(() async {
                  try {
                    await AppRepo.I.rescanDownloadsFolder();
                  } catch (_) {}
                  if (mounted) {
                    setState(() => _metaRefreshQueued = false);
                  } else {
                    _metaRefreshQueued = false;
                  }
                });
              }
              if (tasks.isEmpty) {
                return const Center(child: Text('尚無下載'));
              }
              return ListView.separated(
                itemCount: tasks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  final selected = _selected.contains(task);
                  final fileName = task.name ?? path.basename(task.savePath);
                  final status = _stateLabel(task);
                  final sizeBytes =
                      task.state == 'done'
                          ? (File(task.savePath).existsSync()
                              ? File(task.savePath).lengthSync()
                              : 0)
                          : _currentReceived(task);
                  final displayBytes =
                      task.kind == 'hls'
                          ? sizeBytes
                          : math.max(sizeBytes, task.total ?? 0);
                  final resolvedType = AppRepo.I.resolvedTaskType(task);
                  Widget? leadingThumb;
                  final isDone = task.state.toLowerCase() == 'done';
                  if (resolvedType == 'image' &&
                      isDone &&
                      _fileHasContent(task.savePath)) {
                    final file = File(task.savePath);
                    leadingThumb = ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        file,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.image),
                      ),
                    );
                  } else if (task.thumbnailPath != null &&
                      File(task.thumbnailPath!).existsSync()) {
                    leadingThumb = ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(task.thumbnailPath!),
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.movie),
                      ),
                    );
                  } else if (resolvedType == 'audio') {
                    leadingThumb = const Icon(Icons.audiotrack);
                  } else if (resolvedType == 'image') {
                    leadingThumb = const Icon(Icons.image);
                  }
                  return ListTile(
                    selected: selected,
                    leading:
                        leadingThumb ?? const Icon(Icons.insert_drive_file),
                    title: Text(
                      fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(status),
                        if (displayBytes > 0)
                          Text('大小: ${_fmtSize(displayBytes)}'),
                        if (task.duration != null)
                          Text('時長: ${formatDuration(task.duration!)}'),
                      ],
                    ),
                    onTap: () {
                      if (_selectMode) {
                        _toggleSelect(task);
                      } else {
                        _openTask(context, task);
                      }
                    },
                    onLongPress: () async {
                      if (_selectMode) {
                        _toggleSelect(task);
                        return;
                      }
                      final action = await showModalBottomSheet<String>(
                        context: context,
                        builder:
                            (_) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.edit),
                                    title: const Text('編輯名稱'),
                                    onTap:
                                        () => Navigator.pop(context, 'rename'),
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.share),
                                    title: const Text('匯出...'),
                                    onTap:
                                        () => Navigator.pop(context, 'share'),
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.delete),
                                    title: const Text('刪除'),
                                    onTap:
                                        () => Navigator.pop(context, 'delete'),
                                  ),
                                ],
                              ),
                            ),
                      );
                      if (action == 'rename') {
                        _renameTask(context, task);
                      } else if (action == 'share') {
                        if (File(task.savePath).existsSync()) {
                          await Share.shareXFiles([XFile(task.savePath)]);
                        }
                      } else if (action == 'delete') {
                        await AppRepo.I.removeTasks([task]);
                      }
                    },
                    trailing:
                        _selectMode
                            ? Checkbox(
                              value: selected,
                              onChanged: (_) => _toggleSelect(task),
                            )
                            : IconButton(
                              icon: Icon(
                                task.favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: task.favorite ? Colors.redAccent : null,
                              ),
                              tooltip: task.favorite ? '取消收藏' : '加入收藏',
                              onPressed: () => _toggleFavorite(task),
                            ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Displays favourited download tasks.
class _MyFavorites extends StatelessWidget {
  const _MyFavorites();

  Future<void> _handleShare(BuildContext context, DownloadTask task) async {
    if (!File(task.savePath).existsSync()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('檔案已不存在')));
      return;
    }
    await Share.shareXFiles([XFile(task.savePath)]);
  }

  Future<void> _handleOpen(BuildContext context, DownloadTask task) async {
    if (!File(task.savePath).existsSync()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('檔案已不存在')));
      return;
    }
    final resolvedType = AppRepo.I.resolvedTaskType(task);
    if (resolvedType == 'video' || resolvedType == 'audio') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => VideoPlayerPage(
                path: task.savePath,
                title: task.name ?? path.basename(task.savePath),
              ),
        ),
      );
    } else if (resolvedType == 'image') {
      if (!_fileHasContent(task.savePath)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('檔案尚未完成或已損毀')));
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => ImagePreviewPage(
                filePath: task.savePath,
                title: task.name ?? path.basename(task.savePath),
              ),
        ),
      );
    } else {
      await Share.shareXFiles([XFile(task.savePath)]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: repo.downloads,
      builder: (context, tasks, _) {
        final favs =
            tasks.where((t) => t.favorite).toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        if (favs.isEmpty) {
          return const Center(child: Text('尚無收藏'));
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: favs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final task = favs[index];
            final name = task.name ?? path.basename(task.savePath);
            final fileLength =
                File(task.savePath).existsSync()
                    ? File(task.savePath).lengthSync()
                    : 0;
            final sizeBytes =
                task.kind == 'hls'
                    ? fileLength
                    : math.max(fileLength, task.total ?? 0);
            final resolvedType = AppRepo.I.resolvedTaskType(task);
            Widget? leadingThumb;
            final isDone = task.state.toLowerCase() == 'done';
            if (resolvedType == 'image' &&
                isDone &&
                _fileHasContent(task.savePath)) {
              final file = File(task.savePath);
              leadingThumb = ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(
                  file,
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.image),
                ),
              );
            } else if (task.thumbnailPath != null &&
                File(task.thumbnailPath!).existsSync()) {
              leadingThumb = ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(
                  File(task.thumbnailPath!),
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.movie),
                ),
              );
            } else if (resolvedType == 'audio') {
              leadingThumb = const Icon(Icons.audiotrack);
            } else if (resolvedType == 'image') {
              leadingThumb = const Icon(Icons.image);
            }
            return ListTile(
              leading: leadingThumb ?? const Icon(Icons.insert_drive_file),
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(task.state == 'done' ? '已完成' : task.state),
                  if (sizeBytes > 0) Text('大小: ${formatFileSize(sizeBytes)}'),
                  if (task.duration != null)
                    Text('時長: ${formatDuration(task.duration!)}'),
                ],
              ),
              onTap: () => _handleOpen(context, task),
              trailing: IconButton(
                icon: const Icon(Icons.favorite, color: Colors.redAccent),
                tooltip: '取消收藏',
                onPressed: () => repo.setFavorite(task, false),
              ),
              onLongPress: () async {
                final action = await showModalBottomSheet<String>(
                  context: context,
                  builder:
                      (_) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.edit),
                              title: const Text('編輯名稱'),
                              onTap: () => Navigator.pop(context, 'rename'),
                            ),
                            ListTile(
                              leading: const Icon(Icons.share),
                              title: const Text('匯出...'),
                              onTap: () => Navigator.pop(context, 'share'),
                            ),
                            ListTile(
                              leading: const Icon(Icons.delete),
                              title: const Text('刪除'),
                              onTap: () => Navigator.pop(context, 'delete'),
                            ),
                          ],
                        ),
                      ),
                );
                if (action == 'rename') {
                  final controller = TextEditingController(
                    text: task.name ?? '',
                  );
                  showDialog(
                    context: context,
                    builder:
                        (_) => AlertDialog(
                          title: const Text('重新命名'),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            decoration: const InputDecoration(
                              hintText: '輸入新的名稱',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () {
                                final value = controller.text.trim();
                                if (value.isNotEmpty) {
                                  AppRepo.I.renameTask(task, value);
                                }
                                Navigator.pop(context);
                              },
                              child: const Text('儲存'),
                            ),
                          ],
                        ),
                  );
                } else if (action == 'share') {
                  await _handleShare(context, task);
                } else if (action == 'delete') {
                  await AppRepo.I.removeTasks([task]);
                }
              },
            );
          },
        );
      },
    );
  }
}
