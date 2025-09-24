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
import 'coventmp3.dart';
import 'iap.dart';

const String _kDefaultFolderName = '我的下載';

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

/// MediaPage displays two tabs: 媒體 (ongoing downloads + completed files) and 收藏.
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
  static const String _kFolderSheetDefaultKey = '__default_media_folder__';

  Timer? _convertTicker;
  final TextEditingController _searchCtl = TextEditingController();
  String _search = '';
  Timer? _searchDebounce;

  bool _metaRefreshQueued = false;
  final Set<DownloadTask> _selected = <DownloadTask>{};
  bool _isEditing = false;
  final Map<String, bool> _folderExpanded = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (_tab.index == 1 && _isEditing) {
        setState(() {
          _isEditing = false;
          _selected.clear();
        });
      }
    });
    // Previously performed biometric authentication here. The app no longer
    // locks the media section behind Face ID/Touch ID.
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
    _convertTicker = null;
    _searchDebounce?.cancel();
    _searchDebounce = null;
    try {
      _tab.dispose();
    } catch (_) {}
    try {
      _searchCtl.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder<List<DownloadTask>>(
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
                File(t.thumbnailPath!).existsSync()) {
              s += 2;
            }
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
                return name.contains(q) || url.contains(q) || file.contains(q);
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
        _selected.removeWhere((task) => !tasks.contains(task));

        return SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TabBar(
                    controller: _tab,
                    isScrollable: true,
                    tabs: const [Tab(text: '媒體'), Tab(text: '收藏')],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [
                    Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: _buildTopControls(context, tasks),
                        ),
                        Expanded(
                          child: ValueListenableBuilder<List<MediaFolder>>(
                            valueListenable: repo.mediaFolders,
                            builder: (context, folders, __) {
                              final sections = _buildSections(tasks, folders);
                              _syncFolderExpansion(sections.map((s) => s.id));
                              return ListView.builder(
                                padding: const EdgeInsets.only(bottom: 16),
                                itemCount: sections.length,
                                itemBuilder: (context, index) {
                                  final section = sections[index];
                                  final key = _folderKey(section.id);
                                  final expanded = _folderExpanded[key] ?? true;
                                  MediaFolder? folder;
                                  if (section.id != null) {
                                    for (final item in folders) {
                                      if (item.id == section.id) {
                                        folder = item;
                                        break;
                                      }
                                    }
                                  }
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _buildFolderHeader(
                                        context: context,
                                        section: section,
                                        folder: folder,
                                        expanded: expanded,
                                      ),
                                      if (expanded)
                                        section.tasks.isEmpty
                                            ? Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                    vertical: 12,
                                                  ),
                                              child: Text(
                                                _search.isEmpty
                                                    ? '此資料夾尚無媒體'
                                                    : '沒有符合搜尋的媒體',
                                                style:
                                                    Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall,
                                              ),
                                            )
                                            : Column(
                                              children:
                                                  section.tasks
                                                      .map(
                                                        (task) =>
                                                            _buildTaskTile(
                                                              context: context,
                                                              task: task,
                                                              sectionTasks:
                                                                  section.tasks,
                                                            ),
                                                      )
                                                      .toList(),
                                            ),
                                      const Divider(height: 1),
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const _MyFavorites(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopControls(
    BuildContext context,
    List<DownloadTask> visibleTasks,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_isEditing)
              TextButton.icon(
                onPressed: () => _promptCreateFolder(context),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新增收納'),
              )
            else
              TextButton(
                onPressed: () {
                  setState(() {
                    _isEditing = true;
                  });
                },
                child: const Text('編輯'),
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
            const Spacer(),
            if (_isEditing)
              TextButton(
                onPressed: () {
                  setState(() {
                    _isEditing = false;
                    _selected.clear();
                  });
                },
                child: const Text('完成'),
              ),
          ],
        ),
        if (_isEditing) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed:
                    visibleTasks.isEmpty
                        ? null
                        : () => _selectAll(visibleTasks),
                child: const Text('全選'),
              ),
              OutlinedButton(
                onPressed:
                    _selected.isEmpty
                        ? null
                        : () => _moveSelectedToFolder(context),
                child: const Text('移動到...'),
              ),
              OutlinedButton(
                onPressed: _selected.isEmpty ? null : () => _deleteSelected(),
                child: const Text('刪除'),
              ),
              OutlinedButton(
                onPressed:
                    _selected.isEmpty ? null : () => _exportSelected(context),
                child: const Text('匯出...'),
              ),
              if (_selected.isNotEmpty) Text('已選取 ${_selected.length} 項'),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
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
        ),
      ],
    );
  }

  Widget _buildFolderHeader({
    required BuildContext context,
    required _FolderSection section,
    required MediaFolder? folder,
    required bool expanded,
  }) {
    final key = _folderKey(section.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: IconButton(
        icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
        onPressed: () {
          setState(() {
            _folderExpanded[key] = !expanded;
          });
        },
      ),
      title: Text('${section.name} (${section.tasks.length})'),
      trailing:
          _isEditing && folder != null
              ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: '上移',
                    onPressed:
                        _canMoveFolder(folder.id, -1)
                            ? () => _moveFolder(folder.id, -1)
                            : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward),
                    tooltip: '下移',
                    onPressed:
                        _canMoveFolder(folder.id, 1)
                            ? () => _moveFolder(folder.id, 1)
                            : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: '重新命名',
                    onPressed: () => _promptRenameFolder(context, folder),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '刪除',
                    onPressed: () => _confirmDeleteFolder(context, folder),
                  ),
                ],
              )
              : null,
      onTap: () {
        setState(() {
          _folderExpanded[key] = !expanded;
        });
      },
    );
  }

  Widget _buildTaskTile({
    required BuildContext context,
    required DownloadTask task,
    required List<DownloadTask> sectionTasks,
  }) {
    final resolvedType = AppRepo.I.resolvedTaskType(task);
    final fileName = task.name ?? path.basename(task.savePath);
    final status = _stateLabel(task);
    final selected = _selected.contains(task);
    int displayBytes = task.total ?? 0;
    if (displayBytes <= 0) {
      try {
        final file = File(task.savePath);
        if (file.existsSync()) {
          displayBytes = file.lengthSync();
        }
      } catch (_) {}
    }
    Widget? leadingThumb;
    if (task.state == 'done' &&
        resolvedType == 'video' &&
        File(task.savePath).existsSync()) {
      leadingThumb = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(task.savePath),
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.movie),
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
      leading: leadingThumb ?? const Icon(Icons.insert_drive_file),
      title: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status),
          if (displayBytes > 0) Text('大小: ${_fmtSize(displayBytes)}'),
          if (task.duration != null)
            Text('時長: ${formatDuration(task.duration!)}'),
        ],
      ),
      onTap: () {
        if (_isEditing) {
          _toggleSelect(task);
        } else {
          _openTask(context, task, candidates: sectionTasks);
        }
      },
      onLongPress: () async {
        if (_isEditing) {
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
                      onTap: () => Navigator.pop(context, 'rename'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.folder_open),
                      title: const Text('移動到...'),
                      onTap: () => Navigator.pop(context, 'move'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.content_cut),
                      title: const Text('編輯導出...'),
                      onTap: () => Navigator.pop(context, 'edit-export'),
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
          _renameTask(context, task);
        } else if (action == 'move') {
          await _moveTasksToFolder(context, [task]);
        } else if (action == 'edit-export') {
          final ok = await PurchaseService().ensurePremium(
            context: context,
            featureName: '編輯導出',
          );
          if (!ok) return;
          if (!_fileHasContent(task.savePath)) {
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('檔案尚未完成或已損毀')));
            return;
          }
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder:
                  (_) => MediaSegmentExportPage(
                    sourcePath: task.savePath,
                    displayName: task.name ?? path.basename(task.savePath),
                    mediaType: resolvedType,
                    initialDuration: task.duration,
                  ),
            ),
          );
        } else if (action == 'share') {
          final ok = await PurchaseService().ensurePremium(
            context: context,
            featureName: '匯出',
          );
          if (!ok) return;
          if (File(task.savePath).existsSync()) {
            await Share.shareXFiles([XFile(task.savePath)]);
          } else if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('檔案已不存在')));
          }
        } else if (action == 'delete') {
          await AppRepo.I.removeTasks([task]);
        }
      },
      trailing:
          _isEditing
              ? Checkbox(value: selected, onChanged: (_) => _toggleSelect(task))
              : IconButton(
                icon: Icon(
                  task.favorite ? Icons.favorite : Icons.favorite_border,
                  color: task.favorite ? Colors.redAccent : null,
                ),
                tooltip: task.favorite ? '取消收藏' : '加入收藏',
                onPressed: () => _toggleFavorite(task),
              ),
    );
  }

  List<_FolderSection> _buildSections(
    List<DownloadTask> tasks,
    List<MediaFolder> folders,
  ) {
    final Map<String?, List<DownloadTask>> grouped = {};
    for (final task in tasks) {
      final key = task.folderId;
      grouped.putIfAbsent(key, () => []).add(task);
    }
    final sections = <_FolderSection>[
      _FolderSection(
        id: null,
        name: _kDefaultFolderName,
        tasks: grouped[null] ?? [],
      ),
    ];
    for (final folder in folders) {
      sections.add(
        _FolderSection(
          id: folder.id,
          name: folder.name,
          tasks: grouped[folder.id] ?? [],
        ),
      );
    }
    return sections;
  }

  String _fmtSize(int bytes) => formatFileSize(bytes);

  String _stateLabel(DownloadTask t) {
    final isHls = t.kind == 'hls';
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
    }
    if (t.state == 'downloading') return '下載中';
    if (t.state == 'queued') return '排隊中';
    return t.state;
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

  bool _needsMeta(DownloadTask t) {
    if (t.state != 'done') return false;
    final hasThumb =
        (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync());
    final hasDuration = t.duration != null && t.duration! > Duration.zero;
    return !(hasThumb && hasDuration);
  }

  void _toggleSelect(DownloadTask task) {
    setState(() {
      if (_selected.contains(task)) {
        _selected.remove(task);
      } else {
        _selected.add(task);
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

  Future<void> _moveSelectedToFolder(BuildContext context) async {
    if (_selected.isEmpty) return;
    await _moveTasksToFolder(context, _selected.toList());
  }

  Future<void> _moveTasksToFolder(
    BuildContext context,
    List<DownloadTask> tasks,
  ) async {
    if (tasks.isEmpty) return;
    final repo = AppRepo.I;
    final folders = repo.mediaFolders.value;
    String? currentId;
    if (tasks.isNotEmpty) {
      final first = tasks.first.folderId;
      final sameFolder = tasks.every((task) => task.folderId == first);
      if (sameFolder) currentId = first;
    }
    final ids = <String?>[null, ...folders.map((f) => f.id)];
    final names = <String>[_kDefaultFolderName, ...folders.map((f) => f.name)];
    final currentKey = currentId ?? _kFolderSheetDefaultKey;
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('選擇資料夾')),
              for (var i = 0; i < ids.length; i++)
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(names[i]),
                  trailing:
                      (ids[i] ?? _kFolderSheetDefaultKey) == currentKey
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                  onTap: () {
                    final key = ids[i] ?? _kFolderSheetDefaultKey;
                    Navigator.of(context).pop(key);
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (result == null) return;
    final String? folderId = result == _kFolderSheetDefaultKey ? null : result;
    repo.setTasksFolder(tasks, folderId);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _isEditing = false;
    });
    final folderName = _folderNameForId(folderId, folders: folders);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('已移動到 $folderName'),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('刪除已選取的檔案'),
          content: Text('確定要刪除 ${_selected.length} 項嗎？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('刪除'),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;
    final tasks = _selected.toList();
    await AppRepo.I.removeTasks(tasks);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _isEditing = false;
    });
  }

  Future<void> _exportSelected(BuildContext context) async {
    if (_selected.isEmpty) return;
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: '匯出',
    );
    if (!ok) return;
    final files = <XFile>[];
    for (final task in _selected) {
      if (File(task.savePath).existsSync()) {
        files.add(XFile(task.savePath));
      }
    }
    if (files.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          content: Text('沒有可匯出的檔案'),
        ),
      );
      return;
    }
    await Share.shareXFiles(files);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _isEditing = false;
    });
  }

  void _toggleFavorite(DownloadTask task) {
    AppRepo.I.setFavorite(task, !task.favorite);
    setState(() {});
  }

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

  Future<void> _handleShare(BuildContext context, DownloadTask task) async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: '匯出',
    );
    if (!ok) return;
    if (!File(task.savePath).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(duration: Duration(seconds: 1), content: Text('檔案已不存在')),
      );
      return;
    }
    await Share.shareXFiles([XFile(task.savePath)]);
  }

  Future<void> _openTask(
    BuildContext context,
    DownloadTask task, {
    List<DownloadTask>? candidates,
  }) async {
    if (!File(task.savePath).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(duration: Duration(seconds: 1), content: Text('檔案已不存在')),
      );
      return;
    }
    final resolvedType = AppRepo.I.resolvedTaskType(task);
    if (resolvedType == 'video' || resolvedType == 'audio') {
      List<DownloadTask>? playlist;
      int? initialIndex;
      if (candidates != null) {
        final filtered = <DownloadTask>[];
        for (final item in candidates) {
          final type = AppRepo.I.resolvedTaskType(item);
          final exists = File(item.savePath).existsSync();
          if (exists && (type == 'video' || type == 'audio')) {
            filtered.add(item);
          }
        }
        if (filtered.isNotEmpty) {
          final idx = filtered.indexWhere(
            (item) => item.savePath == task.savePath,
          );
          if (idx >= 0) {
            playlist = filtered;
            initialIndex = idx;
          }
        }
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => VideoPlayerPage(
                path: task.savePath,
                title: task.name ?? path.basename(task.savePath),
                playlist: playlist,
                initialIndex: initialIndex,
              ),
        ),
      );
    } else if (resolvedType == 'image') {
      if (!_fileHasContent(task.savePath)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 1),
            content: Text('檔案尚未完成或已損毀'),
          ),
        );
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
      await _handleShare(context, task);
    }
  }

  String _folderKey(String? id) => 'folder:${id ?? '__default__'}';

  void _syncFolderExpansion(Iterable<String?> ids) {
    final keys = ids.map(_folderKey).toSet();
    _folderExpanded.removeWhere((key, _) => !keys.contains(key));
    for (final key in keys) {
      _folderExpanded.putIfAbsent(key, () => true);
    }
  }

  bool _canMoveFolder(String id, int delta) {
    final list = AppRepo.I.mediaFolders.value;
    final idx = list.indexWhere((f) => f.id == id);
    if (idx < 0) return false;
    final target = idx + delta;
    return target >= 0 && target < list.length;
  }

  void _moveFolder(String id, int delta) {
    final list = [...AppRepo.I.mediaFolders.value];
    final idx = list.indexWhere((f) => f.id == id);
    if (idx < 0) return;
    final target = idx + delta;
    if (target < 0 || target >= list.length) return;
    final item = list.removeAt(idx);
    list.insert(target, item);
    AppRepo.I.reorderMediaFolders(list);
    setState(() {});
  }

  void _promptRenameFolder(BuildContext context, MediaFolder folder) {
    final controller = TextEditingController(text: folder.name);
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('重新命名資料夾'),
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
                  AppRepo.I.renameMediaFolder(folder.id, value);
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

  Future<void> _confirmDeleteFolder(
    BuildContext context,
    MediaFolder folder,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('刪除資料夾'),
          content: Text(
            '確定要刪除「${folder.name}」嗎？其中的檔案會移至${_kDefaultFolderName}。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('刪除'),
            ),
          ],
        );
      },
    );
    if (confirm == true) {
      AppRepo.I.deleteMediaFolder(folder.id);
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _promptCreateFolder(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('新增資料夾'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '輸入資料夾名稱'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context, controller.text.trim());
              },
              child: const Text('建立'),
            ),
          ],
        );
      },
    );
    if (name == null) return;
    final folder = AppRepo.I.createMediaFolder(name);
    if (!mounted) return;
    setState(() {
      _folderExpanded[_folderKey(folder.id)] = true;
    });
  }

  String _folderNameForId(String? id, {List<MediaFolder>? folders}) {
    final list = folders ?? AppRepo.I.mediaFolders.value;
    if (id == null) return _kDefaultFolderName;
    for (final folder in list) {
      if (folder.id == id) return folder.name;
    }
    return _kDefaultFolderName;
  }
}

class _FolderSection {
  final String? id;
  final String name;
  final List<DownloadTask> tasks;

  const _FolderSection({
    required this.id,
    required this.name,
    required this.tasks,
  });
}

/// Displays favourited download tasks.
class _MyFavorites extends StatelessWidget {
  const _MyFavorites();

  Future<void> _handleShare(BuildContext context, DownloadTask task) async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: '匯出',
    );
    if (!ok) return;
    if (!File(task.savePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(duration: Duration(seconds: 1), content: Text('檔案已不存在')),
      );
      return;
    }
    await Share.shareXFiles([XFile(task.savePath)]);
  }

  Future<void> _handleOpen(
    BuildContext context,
    DownloadTask task, {
    List<DownloadTask>? candidates,
  }) async {
    if (!File(task.savePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(duration: Duration(seconds: 1), content: Text('檔案已不存在')),
      );
      return;
    }
    final resolvedType = AppRepo.I.resolvedTaskType(task);
    if (resolvedType == 'video' || resolvedType == 'audio') {
      List<DownloadTask>? playlist;
      int? initialIndex;
      if (candidates != null) {
        final filtered = <DownloadTask>[];
        for (final item in candidates) {
          final type = AppRepo.I.resolvedTaskType(item);
          final exists = File(item.savePath).existsSync();
          if (exists && (type == 'video' || type == 'audio')) {
            filtered.add(item);
          }
        }
        if (filtered.isNotEmpty) {
          final idx = filtered.indexWhere(
            (item) => item.savePath == task.savePath,
          );
          if (idx >= 0) {
            playlist = filtered;
            initialIndex = idx;
          }
        }
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => VideoPlayerPage(
                path: task.savePath,
                title: task.name ?? path.basename(task.savePath),
                playlist: playlist,
                initialIndex: initialIndex,
              ),
        ),
      );
    } else if (resolvedType == 'image') {
      if (!_fileHasContent(task.savePath)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 1),
            content: Text('檔案尚未完成或已損毀'),
          ),
        );
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
      final ok = await PurchaseService().ensurePremium(
        context: context,
        featureName: '匯出',
      );
      if (!ok) return;
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
              onTap: () => _handleOpen(context, task, candidates: favs),
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
                              leading: const Icon(Icons.content_cut),
                              title: const Text('編輯導出...'),
                              onTap:
                                  () => Navigator.pop(context, 'edit-export'),
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
                } else if (action == 'edit-export') {
                  final ok = await PurchaseService().ensurePremium(
                    context: context,
                    featureName: '編輯導出',
                  );
                  if (!ok) return;
                  if (!_fileHasContent(task.savePath)) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('檔案尚未完成或已損毀')));
                    return;
                  }
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => MediaSegmentExportPage(
                            sourcePath: task.savePath,
                            displayName:
                                task.name ?? path.basename(task.savePath),
                            mediaType: resolvedType,
                            initialDuration: task.duration,
                          ),
                    ),
                  );
                } else if (action == 'share') {
                  final ok = await PurchaseService().ensurePremium(
                    context: context,
                    featureName: '匯出',
                  );
                  if (!ok) return;
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
