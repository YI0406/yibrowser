import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'soure.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as path;
import 'package:volume_controller/volume_controller.dart';

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
    return Scaffold(
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
  /// Formats a byte count as a human readable string (KB, MB, GB, etc).
  String _fmtSize(int bytes) {
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

  /// Formats a [Duration] as a human readable string. If the duration has
  /// hours, the format is hh:mm:ss; otherwise mm:ss.
  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
    final repo = AppRepo.I;
    final toDelete = List<DownloadTask>.from(_selected);
    await repo.removeTasks(toDelete);
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  Future<void> _saveSelected() async {
    if (_selected.isEmpty) return;
    final repo = AppRepo.I;
    for (final t in _selected) {
      await repo.saveFileToGallery(t.savePath);
    }
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  void _renameTask(BuildContext context, DownloadTask t) {
    final controller = TextEditingController(text: t.name ?? '');
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
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  AppRepo.I.renameTask(t, name);
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

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Column(
      children: [
        // Top bar for selection actions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              if (_selectMode) ...[
                TextButton(
                  onPressed: () {
                    final list = repo.downloads.value;
                    _selectAll(list);
                  },
                  child: const Text('全選'),
                ),
                TextButton(onPressed: _deleteSelected, child: const Text('刪除')),
                TextButton(onPressed: _saveSelected, child: const Text('存相簿')),
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
                    await AppRepo.I.rescanDownloadsFolder();
                    if (mounted) setState(() {});
                  },
                  child: const Text('重新掃描'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: repo,
            builder: (_, __) {
              return ValueListenableBuilder(
                valueListenable: repo.downloads,
                builder: (_, List<DownloadTask> list, __) {
                  // Sort by timestamp descending (latest first)
                  final tasks = [...list]
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
                  // --- Deduplicate and validate tasks by savePath ---
                  bool _exists(String p) {
                    try {
                      return File(p).existsSync();
                    } catch (_) {
                      return false;
                    }
                  }

                  final Map<String, DownloadTask> byPath = {};
                  for (final t in tasks) {
                    // If it's a completed file but missing on disk, drop it.
                    if (t.state == 'done' && !_exists(t.savePath)) {
                      continue;
                    }
                    final key = t.savePath;
                    final cur = byPath[key];
                    if (cur == null) {
                      byPath[key] = t;
                    } else {
                      // Prefer the entry with thumbnail/duration/name (richer metadata)
                      final curScore =
                          ((cur.thumbnailPath != null &&
                                  File(cur.thumbnailPath!).existsSync())
                              ? 1
                              : 0) +
                          ((cur.duration != null &&
                                  cur.duration! > Duration.zero)
                              ? 1
                              : 0) +
                          ((cur.name != null && cur.name!.isNotEmpty) ? 1 : 0);
                      final newScore =
                          ((t.thumbnailPath != null &&
                                  File(t.thumbnailPath!).existsSync())
                              ? 1
                              : 0) +
                          ((t.duration != null && t.duration! > Duration.zero)
                              ? 1
                              : 0) +
                          ((t.name != null && t.name!.isNotEmpty) ? 1 : 0);
                      byPath[key] = newScore >= curScore ? t : cur;
                    }
                  }
                  final tasksDedup =
                      byPath.values.toList()
                        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
                  // 2) 若有已完成但缺縮圖/時長的項目，節流觸發一次背景掃描
                  final hasMissingMeta = tasksDedup.any(_needsMeta);
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
                  if (tasksDedup.isEmpty) {
                    return const Center(child: Text('尚無下載'));
                  }
                  return ListView.separated(
                    itemCount: tasksDedup.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final t = tasksDedup[i];
                      final selected = _selected.contains(t);
                  final bool isHls = t.kind == 'hls';
                  final int totalSegs = t.total ?? 0;
                  final bool isDownloadingSegments =
                      isHls && t.state == 'downloading' && totalSegs > 0 && t.received < totalSegs;
                  final bool isConverting =
                      isHls && t.state == 'downloading' && totalSegs > 0 && t.received >= totalSegs;
                  // For non‑HLS tasks, prefer the current received bytes (which may
                  // read from the file when t.received is zero). For HLS we use
                  // t.received directly as it represents segment count.
                  final int receivedNow = isHls ? t.received : _currentReceived(t);
                  double? prog;
                  if (isHls && totalSegs > 0) {
                    prog = t.received / totalSegs;
                  } else if (!isHls && t.state == 'downloading' && t.total != null && t.total! > 0) {
                    prog = receivedNow / (t.total!.toDouble());
                  }
                      return GestureDetector(
                        onTap: () {
                          if (_selectMode) {
                            _toggleSelect(t);
                          } else if (t.state == 'done') {
                            if (!File(t.savePath).existsSync()) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('檔案不存在，已重新掃描下載資料夾'),
                                ),
                              );
                              unawaited(AppRepo.I.rescanDownloadsFolder());
                              return;
                            }
                            // Open completed media based on its type
                            if (t.type == 'video') {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder:
                                      (_) => VideoPlayerPage(
                                        path: t.savePath,
                                        title:
                                            t.name ?? path.basename(t.savePath),
                                      ),
                                ),
                              );
                            } else if (t.type == 'image') {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder:
                                      (_) => FileViewerPage(
                                        path: t.savePath,
                                        title:
                                            t.name ?? path.basename(t.savePath),
                                      ),
                                ),
                              );
                            } else {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder:
                                      (_) => FileViewerPage(
                                        path: t.savePath,
                                        title:
                                            t.name ?? path.basename(t.savePath),
                                      ),
                                ),
                              );
                            }
                          }
                        },
                        onLongPress: () {
                          if (!_selectMode) {
                            setState(() {
                              _selectMode = true;
                              _selected.add(t);
                            });
                          }
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).dividerColor.withOpacity(0.3),
                            ),
                          ),
                          child: Stack(
                            children: [
                              // Main row: thumbnail + texts
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Thumbnail with possible selection overlay
                                  Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: SizedBox(
                                          width: 64,
                                          height: 64,
                                          child:
                                              (t.thumbnailPath != null &&
                                                      File(
                                                        t.thumbnailPath!,
                                                      ).existsSync())
                                                  ? Image.file(
                                                    File(t.thumbnailPath!),
                                                    fit: BoxFit.cover,
                                                  )
                                                  : (() {
                                                    if (t.type == 'video') {
                                                      return const Icon(
                                                        Icons.ondemand_video,
                                                        size: 40,
                                                      );
                                                    } else if (t.type ==
                                                        'audio') {
                                                      return const Icon(
                                                        Icons.audiotrack,
                                                        size: 40,
                                                      );
                                                    } else {
                                                      return const Icon(
                                                        Icons
                                                            .file_download_outlined,
                                                        size: 40,
                                                      );
                                                    }
                                                  })(),
                                        ),
                                      ),
                                      if (_selectMode)
                                        Positioned(
                                          top: 4,
                                          left: 4,
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              color: Colors.black54,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Checkbox(
                                              value: selected,
                                              onChanged:
                                                  (_) => _toggleSelect(t),
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              checkColor: Colors.white,
                                              tristate: false,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(width: 10),
                                  // Title + subtitle
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t.name ?? path.basename(t.savePath),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                        const SizedBox(height: 4),
                                   // Build status and details based on task kind/state
                                   Builder(
                                     builder: (_) {
                                       final List<Widget> lines = [];
                                       // Status line
                                       lines.add(
                                         Text(
                                           '狀態: ${_stateLabel(t)}',
                                           style: const TextStyle(fontSize: 12),
                                         ),
                                       );
                                       if (isHls) {
                                         if (isDownloadingSegments) {
                                           // Show segment count and percent
                                           lines.add(
                                             Text(
                                               '片段: ${t.received}/${t.total}',
                                               style: const TextStyle(fontSize: 12),
                                             ),
                                           );
                                           final String pctStr = prog != null
                                               ? (prog * 100).toStringAsFixed(1)
                                               : '0.0';
                                           lines.add(
                                             Text(
                                               '進度: ${pctStr}%',
                                               style: const TextStyle(fontSize: 12),
                                             ),
                                           );
                                         } else if (isConverting) {
                                           // Show current file size during conversion
                                           int fileLen = 0;
                                           try {
                                             final f = File(t.savePath);
                                             if (f.existsSync()) {
                                               fileLen = f.lengthSync();
                                             }
                                           } catch (_) {}
                                           lines.add(
                                             Text(
                                               fileLen > 0
                                                   ? '大小: ${_fmtSize(fileLen)}'
                                                   : '大小: 轉換中…',
                                               style: const TextStyle(fontSize: 12),
                                             ),
                                           );
                                         } else {
                                           // Completed or error: show final size if available
                                           int fileLen = 0;
                                           try {
                                             final f = File(t.savePath);
                                             if (f.existsSync()) {
                                               fileLen = f.lengthSync();
                                             }
                                           } catch (_) {}
                                           if (fileLen > 0) {
                                             lines.add(
                                               Text(
                                                 '大小: ${_fmtSize(fileLen)}',
                                                 style: const TextStyle(fontSize: 12),
                                               ),
                                             );
                                           }
                                         }
                                       } else {
                                         // Non‑HLS file tasks
                                         if (t.state == 'downloading') {
                                           // Show bytes downloaded so far
                                           lines.add(
                                             Text(
                                               '大小: ${_fmtSize(receivedNow)}',
                                               style: const TextStyle(fontSize: 12),
                                             ),
                                           );
                                           if (prog != null) {
                                             final String pctStr =
                                                 (prog * 100).toStringAsFixed(1);
                                             lines.add(
                                               Text(
                                                 '進度: ${pctStr}%',
                                                 style: const TextStyle(fontSize: 12),
                                               ),
                                             );
                                           }
                                         } else {
                                           // Completed or error: show final file size
                                           int fileLen = 0;
                                           try {
                                             final f = File(t.savePath);
                                             if (f.existsSync()) {
                                               fileLen = f.lengthSync();
                                             }
                                           } catch (_) {}
                                           if (fileLen > 0) {
                                             lines.add(
                                               Text(
                                                 '大小: ${_fmtSize(fileLen)}',
                                                 style: const TextStyle(fontSize: 12),
                                               ),
                                             );
                                           }
                                         }
                                       }
                                       // Add timestamp and duration when not actively downloading segments
                                       final bool showTimeAndDur = !(t.state == 'downloading' && (isHls && isDownloadingSegments || (!isHls && t.total != null && t.total! > 0)));
                                       if (showTimeAndDur) {
                                         lines.add(
                                           Text(
                                             '時間: ${t.timestamp.toLocal().toString().split('.')[0]}',
                                             style: const TextStyle(fontSize: 12),
                                           ),
                                         );
                                         if (t.duration != null) {
                                           lines.add(
                                             Text(
                                               '時長: ${_fmtDuration(t.duration!)}',
                                               style: const TextStyle(fontSize: 12),
                                             ),
                                           );
                                         } else if (t.type == 'video' || t.type == 'audio') {
                                           lines.add(
                                             const Text(
                                               '時長: 解析中…',
                                               style: TextStyle(fontSize: 12),
                                             ),
                                           );
                                         }
                                       }
                                       return Column(
                                         crossAxisAlignment:
                                             CrossAxisAlignment.start,
                                         children: lines,
                                       );
                                     },
                                   ),
                                   // Show a progress bar for tasks actively downloading (HLS segments or files)
                                   if ((isHls && isDownloadingSegments) || (!isHls && t.state == 'downloading'))
                                     LinearProgressIndicator(
                                       value: prog == null ? null : prog.clamp(0.0, 1.0),
                                     ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              // Top-right overlay action buttons
                              if (!_selectMode)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (t.state == 'downloading' &&
                                          !(t.paused)) ...[
                                        IconButton(
                                          icon: const Icon(
                                            Icons.pause,
                                            size: 20,
                                          ),
                                          tooltip: '暫停',
                                          onPressed: () => repo.pauseTask(t),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 20,
                                          ),
                                          tooltip: '刪除此任務',
                                          onPressed:
                                              () => repo.removeTasks([t]),
                                        ),
                                      ] else if (t.state == 'paused' ||
                                          t.paused) ...[
                                        IconButton(
                                          icon: const Icon(
                                            Icons.play_arrow,
                                            size: 20,
                                          ),
                                          tooltip: '繼續',
                                          onPressed: () => repo.resumeTask(t),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 20,
                                          ),
                                          tooltip: '刪除此任務',
                                          onPressed:
                                              () => repo.removeTasks([t]),
                                        ),
                                      ] else ...[
                                        // For completed tasks, replace the delete button with a favourite toggle.
                                        IconButton(
                                          icon: Icon(
                                            t.favorite
                                                ? Icons.favorite
                                                : Icons.favorite_border,
                                            size: 20,
                                            color:
                                                t.favorite
                                                    ? Colors.redAccent
                                                    : null,
                                          ),
                                          tooltip: t.favorite ? '取消收藏' : '收藏',
                                          onPressed: () {
                                            repo.setFavorite(t, !t.favorite);
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
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

/// Lists favorite media URLs. Allows removal of favorites.
class _MyFavorites extends StatelessWidget {
  const _MyFavorites();

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return AnimatedBuilder(
      animation: repo,
      builder: (_, __) {
        return ValueListenableBuilder(
          valueListenable: repo.downloads,
          builder: (_, List<DownloadTask> list, __) {
            final favs = list.where((t) => t.favorite).toList();
            favs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
            if (favs.isEmpty) {
              return const Center(child: Text('尚無收藏'));
            }
            return ListView.separated(
              itemCount: favs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = favs[i];
                // Compute a human readable file size string. Use the total
                // property when present; otherwise fall back to reading the
                // file length from disk. If neither is available, return
                // unknown.
                String _fmtSize(int bytes) {
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

                int _resolveSize(DownloadTask t) {
                  if (t.total != null && t.total! > 0) {
                    return t.total!;
                  }
                  try {
                    final f = File(t.savePath);
                    if (f.existsSync()) {
                      return f.lengthSync();
                    }
                  } catch (_) {}
                  return 0;
                }

                Widget leadingWidget;
                if (t.thumbnailPath != null &&
                    File(t.thumbnailPath!).existsSync()) {
                  leadingWidget = ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(
                      File(t.thumbnailPath!),
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    ),
                  );
                } else if (t.type == 'video') {
                  leadingWidget = const Icon(Icons.ondemand_video);
                } else if (t.type == 'audio') {
                  leadingWidget = const Icon(Icons.audiotrack);
                } else {
                  leadingWidget = const Icon(Icons.insert_drive_file);
                }
                return ListTile(
                  leading: leadingWidget,
                  title: Text(
                    t.name ?? path.basename(t.savePath),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Show the file size instead of the path or URL.
                      Text(
                        '大小: ${_fmtSize(_resolveSize(t))}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      // Show duration for favourite videos when available
                      if (t.duration != null)
                        Text(
                          '時長: ${formatDuration(t.duration!)}',
                          style: const TextStyle(fontSize: 12),
                        )
                      else if (t.type == 'video')
                        const Text('時長: 解析中…', style: TextStyle(fontSize: 12)),
                      Text(
                        '時間: ${t.timestamp.toLocal().toString().split('.')[0]}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '取消收藏',
                        onPressed: () => repo.setFavorite(t, false),
                      ),
                      IconButton(
                        icon: const Icon(Icons.drive_file_rename_outline),
                        tooltip: '重新命名',
                        onPressed: () {
                          final controller = TextEditingController(
                            text: t.name ?? '',
                          );
                          showDialog(
                            context: context,
                            builder: (_) {
                              return AlertDialog(
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
                                      final name = controller.text.trim();
                                      if (name.isNotEmpty) {
                                        repo.renameTask(t, name);
                                      }
                                      Navigator.pop(context);
                                    },
                                    child: const Text('確定'),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.share),
                        tooltip: '分享',
                        onPressed: () => repo.shareFile(t.savePath),
                      ),
                    ],
                  ),
                  onTap: () {
                    if (t.type == 'video') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder:
                              (_) => VideoPlayerPage(
                                path: t.savePath,
                                title: t.name ?? t.url,
                              ),
                        ),
                      );
                    } else if (t.type == 'image') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder:
                              (_) => FileViewerPage(
                                path: t.savePath,
                                title: t.name ?? t.url,
                              ),
                        ),
                      );
                    } else {
                      // Attempt to preview other file types using file viewer; if it fails, users can share.
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder:
                              (_) => FileViewerPage(
                                path: t.savePath,
                                title: t.name ?? t.url,
                              ),
                        ),
                      );
                    }
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

//撥放器
/// A simple page for playing a downloaded video using [VideoPlayer].
class VideoPlayerPage extends StatefulWidget {
  final String path;
  final String title;

  /// Optional starting position for playback. When non‑null the player
  /// seeks to this position after initialization. This is useful when
  /// launching the full screen player from the mini player so that
  /// playback continues seamlessly.
  final Duration? startAt;

  const VideoPlayerPage({
    super.key,
    required this.path,
    this.title = '播放器',
    this.startAt,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

/// A simple page for previewing non-video media files such as images and
/// documents. Images are displayed directly; other file types are loaded
/// via an embedded WebView using a `file://` URL. If the file cannot be
/// rendered by the WebView, users can still share it from the media list.
class FileViewerPage extends StatelessWidget {
  final String path;
  final String title;
  const FileViewerPage({super.key, required this.path, this.title = ''});

  @override
  Widget build(BuildContext context) {
    final ext = path.toLowerCase().split('.').last;
    final isImage = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);
    final displayName = title.isNotEmpty ? title : path.split('/').last;
    return Scaffold(
      appBar: AppBar(title: Text(displayName)),
      body:
          isImage
              ? Center(
                child: InteractiveViewer(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder:
                        (_, __, ___) =>
                            const Icon(Icons.broken_image, size: 48),
                  ),
                ),
              )
              : InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri('file://${Uri.encodeFull(path)}'),
                ),
                initialSettings: InAppWebViewSettings(
                  allowsInlineMediaPlayback: true,
                  mediaPlaybackRequiresUserGesture: false,
                ),
              ),
    );
  }
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  static final Map<String, Duration> _resumePositions = {};
  late VideoPlayerController _vc;
  bool _ready = false;

  late final VolumeController _volc;

  // 控制列顯示邏輯
  bool _showControls = true;
  Timer? _autoHideTimer;

  // 進度拖曳
  bool _dragging = false;
  Duration _dragPos = Duration.zero;

  // 音量
  double _volume = 1.0;
  bool _muted = false;

  // 倍速
  double _speed = 1.0;

  // We no longer support a dedicated fullscreen state controlled by the app;
  // instead, the top right button toggles the mini player overlay. The
  // fullscreen flag remains for backward compatibility but is unused.
  bool _fullscreen = false;

  // 長按快進/快退 2X（以定時跳秒模擬）
  Timer? _ffTimer; // forward fast
  Timer? _rwTimer; // rewind fast
  static const _tick = Duration(milliseconds: 200);
  static const _stepFast = Duration(milliseconds: 400); // 0.4s/0.2s ≈ 2X

  @override
  void initState() {
    super.initState();
    _volc = VolumeController.instance;
    // 當系統音量變化時，同步到播放器音量與 UI（新版 API）
    _volc.showSystemUI = true; // 不顯示系統音量浮窗（需要時可改為 true）
    _volc.addListener((v) async {
      _volume = v;
      _muted = v == 0.0;
      try {
        await _vc.setVolume(v);
      } catch (_) {}
      if (mounted) setState(() {});
    });
    // 讀取目前系統音量並套到播放器
    Future.microtask(() async {
      try {
        final v = await _volc.getVolume();
        _volume = v;
        _muted = v == 0.0;
        try {
          await _vc.setVolume(v);
        } catch (_) {}
        if (mounted) setState(() {});
      } catch (_) {}
    });
    // Support both local files and remote URLs. Use network streaming
    // when the provided path is an HTTP(S) URL. This allows playing
    // videos directly from the browser without downloading them first.
    if (widget.path.startsWith('http://') ||
        widget.path.startsWith('https://')) {
      _vc = VideoPlayerController.network(widget.path);
    } else {
      _vc = VideoPlayerController.file(File(widget.path));
    }
    _vc
      ..initialize().then((_) async {
        if (!mounted) return;
        setState(() => _ready = true);
        await _vc.setPlaybackSpeed(_speed);
        // Determine a starting position for playback. Priority:
        // 1. explicit startAt passed to this page
        // 2. saved resume position for this file
        // 3. mini player startAt value (when handing off from mini)
        Duration? seekTo;
        if (widget.startAt != null && widget.startAt! > Duration.zero) {
          seekTo = widget.startAt;
        } else {
          final saved = _resumePositions[widget.path];
          if (saved != null && saved > Duration.zero) {
            seekTo = saved;
          } else {
            final mp = AppRepo.I.miniPlayer.value;
            if (mp != null &&
                mp.startAt != null &&
                mp.startAt! > Duration.zero) {
              seekTo = mp.startAt;
            }
          }
        }
        if (seekTo != null) {
          final dur = _vc.value.duration;
          if (dur == Duration.zero || seekTo < dur) {
            await _vc.seekTo(seekTo);
          }
        }
        // Start playing automatically when the video is ready.
        _vc.play();
        _startAutoHide();
      });

    // Listen to changes in the video controller to update the UI (e.g. progress).
    _vc.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _ffTimer?.cancel();
    _rwTimer?.cancel();
    if (_fullscreen) _exitFullscreen();
    // Save current position for resume.
    try {
      _resumePositions[widget.path] = _vc.value.position;
    } catch (_) {}
    _vc.dispose();
    try {
      _volc.removeListener();
    } catch (_) {}
    super.dispose();
  }

  void _togglePlay() {
    if (!_ready) return;
    if (_vc.value.isPlaying) {
      _vc.pause();
    } else {
      _vc.play();
      _startAutoHide();
    }
    setState(() {});
  }

  void _startAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _vc.value.isPlaying && !_dragging) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls && _vc.value.isPlaying) _startAutoHide();
  }

  void _setSpeed(double v) async {
    _speed = v;
    await _vc.setPlaybackSpeed(v);
    setState(() {});
  }

  void _setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    _muted = _volume == 0.0;
    try {
      await _volc.setVolume(_volume); // 改動：設定系統音量
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _toggleMute() async {
    if (_muted) {
      _muted = false;
      _volume = (_volume == 0.0) ? 0.5 : _volume;
    } else {
      _muted = true;
      _volume = 0.0;
    }
    try {
      await _volc.setVolume(_volume); // 改動：設定系統音量
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _seekRelative(Duration d) async {
    final now = _vc.value.position;
    final target = _clamp(now + d, Duration.zero, _vc.value.duration);
    await _vc.seekTo(target);
    if (_vc.value.isPlaying) _startAutoHide();
    setState(() {});
  }

  void _onDragStart() {
    setState(() {
      _dragging = true;
      _showControls = true;
    });
    _autoHideTimer?.cancel();
  }

  void _onDragUpdate(double valueMs) {
    final target = Duration(milliseconds: valueMs.round());
    setState(() => _dragPos = target);
  }

  void _onDragEnd(double valueMs) async {
    final target = Duration(milliseconds: valueMs.round());
    await _vc.seekTo(target);
    setState(() {
      _dragging = false;
    });
    if (_vc.value.isPlaying) _startAutoHide();
  }

  // 全螢幕/離開
  Future<void> _enterFullscreen() async {
    _fullscreen = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp, // 仍允許直向
    ]);
    setState(() {});
  }

  Future<void> _exitFullscreen() async {
    _fullscreen = false;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    setState(() {});
  }

  // 長按快進/快退 2X（以定時 seek 模擬；鬆手停止）
  void _startFastForward() {
    _ffTimer?.cancel();
    _ffTimer = Timer.periodic(_tick, (_) => _seekRelative(_stepFast));
  }

  void _stopFastForward() {
    _ffTimer?.cancel();
    _ffTimer = null;
    if (_vc.value.isPlaying) _startAutoHide();
  }

  void _startRewind() {
    _rwTimer?.cancel();
    _rwTimer = Timer.periodic(_tick, (_) => _seekRelative(-_stepFast));
  }

  void _stopRewind() {
    _rwTimer?.cancel();
    _rwTimer = null;
    if (_vc.value.isPlaying) _startAutoHide();
  }

  @override
  Widget build(BuildContext context) {
    final aspect =
        (_ready && _vc.value.size != Size.zero)
            ? _vc.value.aspectRatio
            : 16 / 9;

    final pos = _vc.value.position;
    final dur = _vc.value.duration;
    final double totalMs =
        dur.inMilliseconds.toDouble().clamp(1.0, double.maxFinite) as double;
    final double currentMs =
        (_dragging ? _dragPos : pos).inMilliseconds.toDouble().clamp(
              0.0,
              totalMs,
            )
            as double;

    Widget video =
        _ready
            ? VideoPlayer(_vc)
            : const Center(child: CircularProgressIndicator());

    final overlay = AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Container(
          color: Colors.black26,
          child: Column(
            children: [
              // 上方標題/返回列（非必要可隱藏）
              SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.picture_in_picture_alt),
                      tooltip: '迷你播放',
                      onPressed: () {
                        final pos = _vc.value.position;
                        // Save to local resume map
                        _resumePositions[widget.path] = pos;
                        // Also push the latest startAt into repo to ensure the mini player picks it up even if rebuilt
                        AppRepo.I.updateMiniPlayerStartAt(pos);
                        // Open the mini player with explicit startAt
                        AppRepo.I.openMiniPlayer(
                          widget.path,
                          widget.title,
                          startAt: pos,
                        );
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // 中間主控（播放/暫停、快進鈕）
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    color: Colors.white,
                    iconSize: 36,
                    icon: const Icon(Icons.replay_30),
                    onPressed:
                        () => _seekRelative(const Duration(seconds: -30)),
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: _togglePlay,
                    child: CircleAvatar(
                      backgroundColor: Colors.black54,
                      radius: 28,
                      child: Icon(
                        _vc.value.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    color: Colors.white,
                    iconSize: 36,
                    icon: const Icon(Icons.forward_30),
                    onPressed: () => _seekRelative(const Duration(seconds: 30)),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 進度與秒數＋工具列
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    // 進度條（可拖動，顯示秒數）
                    Row(
                      children: [
                        Text(
                          _fmt(_dragging ? _dragPos : pos),
                          style: const TextStyle(
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            min: 0.0,
                            max: totalMs,
                            value: currentMs,
                            onChangeStart: (_) => _onDragStart(),
                            onChanged: (v) => _onDragUpdate(v),
                            onChangeEnd: (v) => _onDragEnd(v),
                          ),
                        ),
                        Text(
                          _fmt(dur),
                          style: const TextStyle(
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),

                    // 下方工具列：音量（靜音/滑桿）、快進 1m/5m、速度選擇
                    Row(
                      children: [
                        // 音量：靜音切換 + 動態圖示
                        IconButton(
                          tooltip: _muted ? '取消靜音' : '靜音',
                          icon: Icon(
                            (_muted || _volume == 0.0)
                                ? Icons.volume_off
                                : (_volume < 0.33
                                    ? Icons.volume_mute
                                    : (_volume < 0.66
                                        ? Icons.volume_down
                                        : Icons.volume_up)),
                            color: Colors.white,
                          ),
                          onPressed: _toggleMute,
                        ),
                        // 音量滑桿（0.0 ~ 1.0），與系統音量雙向同步
                        Expanded(
                          child: Slider(
                            min: 0.0,
                            max: 1.0,
                            value: _muted ? 0.0 : _volume.clamp(0.0, 1.0),
                            onChanged: (v) => _setVolume(v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${((_muted ? 0.0 : _volume) * 100).round()}%',
                          style: const TextStyle(color: Colors.white),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed:
                              () => _seekRelative(const Duration(minutes: 1)),
                          child: const Text('+1m'),
                        ),
                        const SizedBox(width: 6),
                        TextButton(
                          onPressed:
                              () => _seekRelative(const Duration(minutes: 5)),
                          child: const Text('+5m'),
                        ),
                        const SizedBox(width: 6),
                        PopupMenuButton<double>(
                          initialValue: _speed,
                          icon: const Icon(Icons.speed, color: Colors.white),
                          onSelected: (v) => _setSpeed(v),
                          itemBuilder:
                              (_) => const [
                                PopupMenuItem(value: 0.5, child: Text('0.5x')),
                                PopupMenuItem(value: 1.0, child: Text('1.0x')),
                                PopupMenuItem(value: 1.5, child: Text('1.5x')),
                                PopupMenuItem(value: 2.0, child: Text('2.0x')),
                              ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SafeArea(top: false, child: const SizedBox(height: 0)),
            ],
          ),
        ),
      ),
    );

    // 手勢區：單擊顯示/隱藏控制；左右半邊長按快退/快進 2X
    Widget gestureLayer = LayoutBuilder(
      builder: (ctx, box) {
        final width = box.maxWidth;
        return Listener(
          onPointerDown: (ev) {
            // 讓點擊不直接穿透
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onLongPressStart: (d) {
              final dx = d.localPosition.dx;
              if (dx < width / 2) {
                // 左半邊：快退
                _startRewind();
              } else {
                // 右半邊：快進
                _startFastForward();
              }
              setState(() => _showControls = true);
            },
            onLongPressEnd: (_) {
              _stopFastForward();
              _stopRewind();
            },
          ),
        );
      },
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(child: AspectRatio(aspectRatio: aspect, child: video)),
            // 手勢層
            Positioned.fill(child: gestureLayer),
            // 控制層
            Positioned.fill(child: overlay),
          ],
        ),
      ),
    );
  }

  static Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// Formats a [Duration] into a human readable hh:mm:ss or mm:ss string. This
/// function is defined outside of any class so it can be reused across
/// multiple widgets (e.g. favourites, downloads). If [d] is null, returns
/// an empty string.
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
