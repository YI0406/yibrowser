import 'package:flutter/cupertino.dart';
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
import 'package:url_launcher/url_launcher.dart';
import 'video_player_page.dart';
import 'image_preview_page.dart';
import 'coventmp3.dart';
import 'iap.dart';
import 'app_localizations.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

String _defaultFolderName() =>
    LanguageService.instance.translate('media.folder.defaultName');

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

class _TaskActionOption {
  final String key;
  final IconData icon;
  final String label;
  const _TaskActionOption({
    required this.key,
    required this.icon,
    required this.label,
  });
}

String _fmtSpeed(num bytesPerSecond) {
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s', 'TB/s'];
  double value = bytesPerSecond.toDouble();
  int index = 0;
  while (value >= 1024.0 && index < units.length - 1) {
    value /= 1024.0;
    index++;
  }
  final decimals =
      value >= 100
          ? 0
          : value >= 10
          ? 1
          : 2;
  return '${value.toStringAsFixed(decimals)} ${units[index]}';
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

class _RateSnapshot {
  final int bytes;
  final DateTime timestamp;
  final double? speed;

  const _RateSnapshot(this.bytes, this.timestamp, this.speed);
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
    with SingleTickerProviderStateMixin, LanguageAwareState<MediaPage> {
  late final TabController _tab = TabController(length: 3, vsync: this);
  static const String _kFolderSheetDefaultKey = '__default_media_folder__';
  static const String _kFolderExpansionPrefKey = 'media.folderExpansionState';

  Timer? _convertTicker;
  final TextEditingController _searchCtl = TextEditingController();
  String _search = '';
  Timer? _searchDebounce;
  final TextEditingController _hiddenSearchCtl = TextEditingController();
  String _hiddenSearch = '';
  final Map<String, _RateSnapshot> _directSpeedSnaps = {};
  Timer? _hiddenSearchDebounce;

  bool _metaRefreshQueued = false;
  final Set<DownloadTask> _selected = <DownloadTask>{};
  final Set<DownloadTask> _hiddenSelected = <DownloadTask>{};
  bool _isEditing = false;
  bool _hiddenEditing = false;
  bool _hiddenUnlocked = false;
  bool _authenticatingHidden = false;
  int _lastTabIndex = 0;
  final Map<String, bool> _folderExpanded = <String, bool>{};
  bool _folderExpansionLoaded = false;

  @override
  void initState() {
    super.initState();
    _lastTabIndex = _tab.index;
    _tab.addListener(_handleTabChange);
    // Previously performed biometric authentication here. The app no longer
    // locks the media section behind Face ID/Touch ID.
    Future.microtask(() async {
      try {
        await AppRepo.I.rescanDownloadsFolder();
      } catch (_) {}
      if (mounted) setState(() {});
    });
    _loadFolderExpansionPreferences();
  }

  @override
  void dispose() {
    _convertTicker?.cancel();
    _convertTicker = null;
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _hiddenSearchDebounce?.cancel();
    _hiddenSearchDebounce = null;
    try {
      _tab.removeListener(_handleTabChange);
    } catch (_) {}
    try {
      _tab.dispose();
    } catch (_) {}
    try {
      _searchCtl.dispose();
    } catch (_) {}
    try {
      _hiddenSearchCtl.dispose();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _attemptUnlockHidden({bool revertOnFail = true}) async {
    if (_authenticatingHidden) return;
    _authenticatingHidden = true;
    final previousIndex = _lastTabIndex;
    try {
      if (!AppRepo.I.isPremiumUnlocked) {
        final ok = await PurchaseService().ensurePremium(
          context: context,
          featureName: context.l10n('feature.hidden'),
        );
        if (!mounted) return;
        if (!ok) {
          if (revertOnFail) {
            _tab.animateTo(previousIndex);
            _lastTabIndex = previousIndex;
          }
          return;
        }
      }

      final result = await Locker.unlock(
        reason: context.l10n('media.unlock.reasonHidden'),
      );
      if (!mounted) return;
      if (result.success) {
        setState(() {
          _hiddenUnlocked = true;
        });
        _lastTabIndex = _tab.index;
      } else {
        if (result.requiresPermission) {
          await _showBiometricPermissionDialog();
        }
        if (revertOnFail) {
          _tab.animateTo(previousIndex);
          _lastTabIndex = previousIndex;
        }
      }
    } finally {
      _authenticatingHidden = false;
    }
  }

  Future<void> _showBiometricPermissionDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n('media.unlock.permissionTitle')),
          content: Text(context.l10n('media.unlock.permissionDescription')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n('common.later')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(_openDeviceSettings());
              },
              child: Text(context.l10n('common.goToSettings')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openDeviceSettings() async {
    final uri = Uri.parse('app-settings:');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  void _handleTabChange() {
    final index = _tab.index;
    final previous = _tab.previousIndex;
    if (previous == 2 && index != 2 && _hiddenUnlocked) {
      setState(() {
        _hiddenUnlocked = false;
        if (_hiddenEditing) {
          _hiddenEditing = false;
          _hiddenSelected.clear();
        }
      });
    } else if (index != 2 && _hiddenEditing) {
      setState(() {
        _hiddenEditing = false;
        _hiddenSelected.clear();
      });
    }
    if (index == 2 && !_hiddenUnlocked) {
      unawaited(_attemptUnlockHidden());
      return;
    }

    if (index != 0 && _isEditing) {
      setState(() {
        _isEditing = false;
        _selected.clear();
      });
    }
    if (index == 0) {
      AppRepo.I.refreshDownloadsView();
    }

    _lastTabIndex = index;
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: repo.downloads,
      builder: (context, list, _) {
        final allTasks = [...list]
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final Map<String, DownloadTask> byPath = {};
        for (final task in allTasks) {
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
            if (t.hidden) s += 50;
            return s;
          }

          byPath[key] = score(task) >= score(existing) ? task : existing;
        }
        final List<DownloadTask> sortedTasks =
            byPath.values.toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        List<DownloadTask> hiddenTasks =
            sortedTasks.where((t) => t.hidden).toList();
        List<DownloadTask> visibleTasks =
            sortedTasks.where((t) => !t.hidden).toList();
        if (_search.isNotEmpty) {
          final q = _search.toLowerCase();
          visibleTasks =
              visibleTasks.where((t) {
                final name = (t.name ?? '').toLowerCase();
                final url = t.url.toLowerCase();
                final file = path.basename(t.savePath).toLowerCase();
                return name.contains(q) || url.contains(q) || file.contains(q);
              }).toList();
        }
        if (_hiddenSearch.isNotEmpty) {
          final q = _hiddenSearch.toLowerCase();
          hiddenTasks =
              hiddenTasks.where((t) {
                final name = (t.name ?? '').toLowerCase();
                final url = t.url.toLowerCase();
                final file = path.basename(t.savePath).toLowerCase();
                return name.contains(q) || url.contains(q) || file.contains(q);
              }).toList();
        }
        final hasActiveConversion = sortedTasks.any(
          (t) =>
              t.kind == 'hls' &&
              t.state == 'downloading' &&
              t.total != null &&
              t.received >= (t.total ?? 0),
        );
        _ensureConvertTicker(hasActiveConversion);
        final hasMissingMeta = sortedTasks.any(_needsMeta);
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
        _selected.removeWhere((task) => !visibleTasks.contains(task));
        _hiddenSelected.removeWhere((task) => !hiddenTasks.contains(task));

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
                    tabs: [
                      Tab(text: context.l10n('media.tab.media')),
                      Tab(text: context.l10n('media.tab.favorites')),
                      Tab(
                        icon: Icon(
                          _hiddenUnlocked
                              ? Icons.visibility
                              : Icons.visibility_off_outlined,
                          semanticLabel: context.l10n('media.hidden.badge'),
                        ),
                      ),
                    ],
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
                          child: _buildTopControls(context, visibleTasks),
                        ),
                        Expanded(
                          child: ValueListenableBuilder<List<MediaFolder>>(
                            valueListenable: repo.mediaFolders,
                            builder: (context, folders, __) {
                              final sections = _buildSections(
                                visibleTasks,
                                folders,
                              );
                              _syncFolderExpansion(sections.map((s) => s.id));
                              return ListView.builder(
                                padding: const EdgeInsets.only(bottom: 16),
                                itemCount: sections.length,
                                itemBuilder: (context, index) {
                                  final section = sections[index];
                                  final key = _folderKey(section.id);
                                  final expanded =
                                      _folderExpanded[key] ??
                                      _defaultExpanded(key);
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
                                                    ? context.l10n(
                                                      'media.empty.folder',
                                                    )
                                                    : context.l10n(
                                                      'media.empty.search',
                                                    ),
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
                                                        (
                                                          task,
                                                        ) => _buildTaskTile(
                                                          context: context,
                                                          task: task,
                                                          sectionTasks:
                                                              section.tasks,
                                                          isEditing: _isEditing,
                                                          selection: _selected,
                                                          onToggleSelect:
                                                              _toggleSelect,
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
                    _buildHiddenTab(context, hiddenTasks),
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
                label: Text(context.l10n('media.action.addFolder')),
              )
            else
              TextButton(
                onPressed: () {
                  setState(() {
                    _isEditing = true;
                  });
                },
                child: Text(context.l10n('common.edit')),
              ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                await AppRepo.I.rescanDownloadsFolder(
                  regenerateThumbnails: true,
                );
                if (mounted) setState(() {});
              },
              child: Text(context.l10n('media.action.rescan')),
            ),
            if (_isEditing && _selected.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                context.l10n(
                  'media.selection.count',
                  params: {'count': '${_selected.length}'},
                ),
              ),
            ],
            const Spacer(),
            if (_isEditing)
              TextButton(
                onPressed: () {
                  setState(() {
                    _isEditing = false;
                    _selected.clear();
                  });
                },
                child: Text(context.l10n('common.done')),
              ),
          ],
        ),
        if (_isEditing) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: _buildSelectionActionButtons(context, visibleTasks),
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
                    hintText: context.l10n('media.search.placeholder'),
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

  Widget _buildHiddenTopControls(
    BuildContext context,
    List<DownloadTask> hiddenTasks,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () {
                setState(() {
                  if (_hiddenEditing) {
                    _hiddenEditing = false;
                    _hiddenSelected.clear();
                  } else {
                    _hiddenEditing = true;
                  }
                });
              },
              child: Text(
                _hiddenEditing
                    ? context.l10n('common.done')
                    : context.l10n('common.edit'),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                await AppRepo.I.rescanDownloadsFolder(
                  regenerateThumbnails: true,
                );
                if (mounted) setState(() {});
              },
              child: Text(context.l10n('media.action.rescan')),
            ),
            if (_hiddenEditing && _hiddenSelected.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                context.l10n(
                  'media.selection.count',
                  params: {'count': '${_hiddenSelected.length}'},
                ),
              ),
            ],
          ],
        ),
        if (_hiddenEditing) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: _buildHiddenSelectionActionButtons(context, hiddenTasks),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _hiddenSearchCtl,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) {
                    _hiddenSearchDebounce?.cancel();
                    _hiddenSearchDebounce = Timer(
                      const Duration(milliseconds: 250),
                      () {
                        if (!mounted) return;
                        setState(() => _hiddenSearch = value.trim());
                      },
                    );
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: context.l10n('media.search.placeholder'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon:
                        _hiddenSearch.isNotEmpty
                            ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _hiddenSearchCtl.clear();
                                setState(() => _hiddenSearch = '');
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

  Widget _buildHiddenTab(BuildContext context, List<DownloadTask> hiddenTasks) {
    if (!_hiddenUnlocked) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            Text(context.l10n('media.hidden.unlockPrompt')),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                unawaited(_attemptUnlockHidden(revertOnFail: false));
              },
              child: Text(context.l10n('common.unlock')),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: _buildHiddenTopControls(context, hiddenTasks),
        ),
        Expanded(
          child:
              hiddenTasks.isEmpty
                  ? Center(child: Text(context.l10n('media.hidden.empty')))
                  : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: hiddenTasks.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final task = hiddenTasks[index];
                      return _buildTaskTile(
                        context: context,
                        task: task,
                        sectionTasks: hiddenTasks,
                        isEditing: _hiddenEditing,
                        selection: _hiddenSelected,
                        onToggleSelect: _toggleHiddenSelect,
                        hiddenContext: true,
                      );
                    },
                  ),
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
          _persistFolderExpansion();
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
                    tooltip: context.l10n('media.reorder.up'),
                    onPressed:
                        _canMoveFolder(folder.id, -1)
                            ? () => _moveFolder(folder.id, -1)
                            : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward),
                    tooltip: context.l10n('media.reorder.down'),
                    onPressed:
                        _canMoveFolder(folder.id, 1)
                            ? () => _moveFolder(folder.id, 1)
                            : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: context.l10n('common.rename'),
                    onPressed: () => _promptRenameFolder(context, folder),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: context.l10n('common.delete'),
                    onPressed: () => _confirmDeleteFolder(context, folder),
                  ),
                ],
              )
              : null,
      onTap: () {
        setState(() {
          _folderExpanded[key] = !expanded;
        });
        _persistFolderExpansion();
      },
    );
  }

  List<_TaskActionOption> _taskActionOptions(
    BuildContext context, {
    required bool hiddenContext,
  }) {
    return [
      _TaskActionOption(
        key: 'rename',
        icon: Icons.edit,
        label: context.l10n('media.action.editName'),
      ),
      if (!hiddenContext)
        _TaskActionOption(
          key: 'move',
          icon: Icons.folder_open,
          label: context.l10n('media.action.moveTo'),
        ),
      _TaskActionOption(
        key: 'edit-export',
        icon: Icons.content_cut,
        label: context.l10n('media.action.editExport'),
      ),
      _TaskActionOption(
        key: 'share',
        icon: Icons.share,
        label: context.l10n('media.action.export'),
      ),
      _TaskActionOption(
        key: hiddenContext ? 'unhide' : 'hide',
        icon: hiddenContext ? Icons.visibility : Icons.visibility_off,
        label:
            hiddenContext
                ? context.l10n('media.action.unhide')
                : context.l10n('media.action.hide'),
      ),
      _TaskActionOption(
        key: 'delete',
        icon: Icons.delete,
        label: context.l10n('common.delete'),
      ),
    ];
  }

  Future<String?> _showTaskActionsSheet(
    BuildContext context,
    List<_TaskActionOption> options,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      builder:
          (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children:
                  options
                      .map(
                        (opt) => ListTile(
                          leading: Icon(opt.icon),
                          title: Text(opt.label),
                          onTap: () => Navigator.pop(context, opt.key),
                        ),
                      )
                      .toList(),
            ),
          ),
    );
  }

  Future<void> _handleTaskAction(
    BuildContext context,
    DownloadTask task,
    String? action,
    String resolvedType, {
    required bool hiddenContext,
  }) async {
    if (action == null) return;
    if (action == 'rename') {
      _renameTask(context, task);
      return;
    }
    if (action == 'move') {
      await _moveTasksToFolder(context, [task]);
      return;
    }
    if (action == 'edit-export') {
      final ok = await PurchaseService().ensurePremium(
        context: context,
        featureName: context.l10n('feature.editExport'),
      );
      if (!ok) return;
      if (!_fileHasContent(task.savePath)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n('media.error.incompleteFile'))),
        );
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
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
      if (!mounted) return;
      await AppRepo.I.rescanDownloadsFolder();
      if (mounted) setState(() {});
      return;
    }
    if (action == 'share') {
      final ok = await PurchaseService().ensurePremium(
        context: context,
        featureName: context.l10n('feature.export'),
      );
      if (!ok) return;
      if (File(task.savePath).existsSync()) {
        await _sharePaths(context, [task.savePath]);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n('media.error.missingFile'))),
        );
      }
      return;
    }
    if (action == 'hide') {
      _hideTasks(context, [task]);
      return;
    }
    if (action == 'unhide') {
      _unhideTasks(context, [task]);
      return;
    }
    if (action == 'delete') {
      await AppRepo.I.removeTasks([task]);
      return;
    }
  }

  Widget _buildTaskTile({
    required BuildContext context,
    required DownloadTask task,
    required List<DownloadTask> sectionTasks,
    required bool isEditing,
    required Set<DownloadTask> selection,
    required void Function(DownloadTask) onToggleSelect,
    bool hiddenContext = false,
  }) {
    final resolvedType = AppRepo.I.resolvedTaskType(task);
    final fileName = task.name ?? path.basename(task.savePath);
    final status = _stateLabel(task);
    final bool isDirectDownloading =
        task.kind != 'hls' && task.state.toLowerCase() == 'downloading';

    final selected = selection.contains(task);
    int displayBytes = task.total ?? 0;
    if (task.kind == 'hls' && task.state.toLowerCase() != 'done') {
      // HLS 任務在片段下載階段會以「片段數」或「毫秒」暫存於 total，
      // 並非真實的位元組數。此時改以實際檔案長度（若可取得）顯示，
      // 避免出現「總片段 B」等單位錯誤的字串。
      displayBytes = 0;
    }
    if (isDirectDownloading) {
      displayBytes = math.max(displayBytes, task.received);
    }
    if (displayBytes <= 0) {
      try {
        final file = File(task.savePath);
        if (file.existsSync()) {
          displayBytes = file.lengthSync();
        }
      } catch (_) {}
    }
    if (!isDirectDownloading) {
      _purgeDirectSpeedSnapshot(task.savePath);
    }
    Widget? leadingThumb;
    final isDone = task.state.toLowerCase() == 'done';
    if (resolvedType == 'image' && isDone && _fileHasContent(task.savePath)) {
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

    final actionOptions = _taskActionOptions(
      context,
      hiddenContext: hiddenContext,
    );

    return ListTile(
      selected: selected,
      leading: leadingThumb ?? const Icon(Icons.insert_drive_file),
      title: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status),
          if (isDirectDownloading) ...[
            () {
              final total = task.total ?? 0;
              final hasTotal = total > 0;
              final sizeValue =
                  hasTotal
                      ? '${formatFileSize(task.received)} / ${formatFileSize(total)}'
                      : formatFileSize(task.received);
              return Text(
                context.l10n(
                  'browser.download.sizeLabel',
                  params: {'size': sizeValue},
                ),
              );
            }(),
            if ((task.total ?? 0) > 0)
              () {
                final total = task.total ?? 0;
                final ratio = (task.received / total.toDouble()).clamp(
                  0.0,
                  1.0,
                );
                final pct = (ratio * 100).toStringAsFixed(1);
                return Text(
                  context.l10n(
                    'browser.download.progressLabel',
                    params: {'progress': '$pct%'},
                  ),
                );
              }(),
            () {
              final speed = _directSpeedFor(task);
              if (speed != null) {
                return Text(
                  context.l10n(
                    'browser.download.speedLabel',
                    params: {'speed': _fmtSpeed(speed)},
                  ),
                );
              }
              return Text(context.l10n('browser.download.speedMeasuring'));
            }(),
          ],
          if (!isDirectDownloading && displayBytes > 0)
            Text(
              context.l10n(
                'media.details.size',
                params: {'size': _fmtSize(displayBytes)},
              ),
            ),
          if (task.duration != null)
            Text(
              context.l10n(
                'media.details.duration',
                params: {'duration': formatDuration(task.duration!)},
              ),
            ),
        ],
      ),
      onTap: () {
        if (isEditing) {
          onToggleSelect(task);
        } else {
          _openTask(context, task, candidates: sectionTasks);
        }
      },
      onLongPress: () async {
        if (isEditing) {
          onToggleSelect(task);
          return;
        }
        final action = await _showTaskActionsSheet(context, actionOptions);
        await _handleTaskAction(
          context,
          task,
          action,
          resolvedType,
          hiddenContext: hiddenContext,
        );
      },
      trailing:
          isEditing
              ? Checkbox(
                value: selected,
                onChanged: (_) => onToggleSelect(task),
              )
              : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      task.favorite ? Icons.favorite : Icons.favorite_border,
                      color: task.favorite ? Colors.redAccent : null,
                    ),
                    tooltip:
                        task.favorite
                            ? context.l10n('media.action.unfavorite')
                            : context.l10n('media.action.favorite'),
                    onPressed: () => _toggleFavorite(task),
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    iconSize: 22,
                    padding: EdgeInsets.zero,
                    splashRadius: 22,
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    iconSize: 24,
                    constraints: const BoxConstraints(minWidth: 40),
                    icon: const Icon(CupertinoIcons.ellipsis_circle),
                    onSelected:
                        (value) => _handleTaskAction(
                          context,
                          task,
                          value,
                          resolvedType,
                          hiddenContext: hiddenContext,
                        ),
                    itemBuilder:
                        (_) =>
                            actionOptions
                                .map(
                                  (opt) => PopupMenuItem<String>(
                                    value: opt.key,
                                    child: Row(
                                      children: [
                                        Icon(opt.icon, size: 20),
                                        const SizedBox(width: 12),
                                        Expanded(child: Text(opt.label)),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                  ),
                ],
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
    final defaultFolderName = _defaultFolderName();
    final sections = <_FolderSection>[
      _FolderSection(
        id: null,
        name: defaultFolderName,
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
  double? _directSpeedFor(DownloadTask task) {
    final key = task.savePath;
    final now = DateTime.now();
    final prev = _directSpeedSnaps[key];
    double? computed;
    if (prev != null) {
      final elapsedMs = now.difference(prev.timestamp).inMilliseconds;
      if (elapsedMs > 0) {
        final delta = task.received - prev.bytes;
        if (delta > 0) {
          computed = delta / (elapsedMs / 1000.0);
        } else if (delta == 0) {
          computed = prev.speed;
        } else {
          computed = null;
        }
      } else {
        computed = prev.speed;
      }
    }
    final cached = computed ?? prev?.speed;
    _directSpeedSnaps[key] = _RateSnapshot(task.received, now, cached);
    return cached;
  }

  void _purgeDirectSpeedSnapshot(String key) {
    _directSpeedSnaps.remove(key);
  }

  String _stateLabel(DownloadTask t) {
    final isHls = t.kind == 'hls';
    final l10n = LanguageService.instance;
    if (t.state == 'paused' || t.paused) {
      return l10n.translate('media.state.paused');
    }
    if (t.state == 'error') {
      return l10n.translate('media.state.error');
    }
    if (t.state == 'done') {
      return l10n.translate('media.state.done');
    }
    if (isHls) {
      final total = t.total ?? 0;
      if (t.state == 'downloading') {
        if (total > 0 && t.received >= total) {
          return l10n.translate('media.state.converting');
        }
        return l10n.translate('media.state.downloading');
      }
      return l10n.translate('media.state.queued');
    }
    if (t.state == 'downloading') {
      return l10n.translate('media.state.downloading');
    }
    if (t.state == 'queued') {
      return l10n.translate('media.state.queued');
    }

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

  void _toggleHiddenSelect(DownloadTask task) {
    setState(() {
      if (_hiddenSelected.contains(task)) {
        _hiddenSelected.remove(task);
      } else {
        _hiddenSelected.add(task);
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

  void _selectAllHidden(List<DownloadTask> tasks) {
    setState(() {
      _hiddenSelected
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
    final counts = <String?, int>{};
    for (final item in repo.downloads.value) {
      final key = item.folderId;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    counts.putIfAbsent(null, () => 0);
    String formatName(String? id, String name) => '$name（${counts[id] ?? 0}）';
    final defaultFolderName = context.l10n('media.folder.defaultName');
    final ids = <String?>[null, ...folders.map((f) => f.id)];
    final names = <String>[
      formatName(null, defaultFolderName),
      ...folders.map((f) => formatName(f.id, f.name)),
    ];
    final currentKey = currentId ?? _kFolderSheetDefaultKey;
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(context.l10n('media.folder.select'))),
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
        content: Text(
          context.l10n('media.snack.moved', params: {'folder': folderName}),
        ),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n('media.dialog.deleteSelected.title')),
          content: Text(
            context.l10n(
              'media.dialog.deleteSelected.message',
              params: {'count': '${_selected.length}'},
            ),
          ),

          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n('common.delete')),
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

  Future<void> _deleteHiddenSelected() async {
    if (_hiddenSelected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n('media.dialog.deleteSelected.title')),
          content: Text(
            context.l10n(
              'media.dialog.deleteSelected.message',
              params: {'count': '${_hiddenSelected.length}'},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n('common.delete')),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;
    final tasks = _hiddenSelected.toList();
    await AppRepo.I.removeTasks(tasks);
    if (!mounted) return;
    setState(() {
      _hiddenSelected.clear();
      _hiddenEditing = false;
    });
  }

  Widget _buildSelectionActionButtons(
    BuildContext context,
    List<DownloadTask> visibleTasks,
  ) {
    OutlinedButton buildSelectAllButton() => OutlinedButton(
      onPressed: visibleTasks.isEmpty ? null : () => _selectAll(visibleTasks),
      child: Text(context.l10n('media.action.selectAll')),
    );
    OutlinedButton buildDeleteButton() => OutlinedButton(
      onPressed: _selected.isEmpty ? null : () => _deleteSelected(),
      child: Text(context.l10n('common.delete')),
    );
    OutlinedButton buildHideButton() => OutlinedButton(
      onPressed: _selected.isEmpty ? null : () => _hideSelected(context),
      child: Text(context.l10n('media.action.hide')),
    );
    OutlinedButton buildMoveButton() => OutlinedButton(
      onPressed:
          _selected.isEmpty ? null : () => _moveSelectedToFolder(context),
      child: Text(context.l10n('media.action.moveTo')),
    );
    OutlinedButton buildExportButton() => OutlinedButton(
      onPressed: _selected.isEmpty ? null : () => _exportSelected(context),
      child: Text(context.l10n('media.action.export')),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 520;
        final topRow = [
          buildSelectAllButton(),
          buildDeleteButton(),
          buildHideButton(),
        ];
        final bottomRow = [buildMoveButton(), buildExportButton()];
        if (isWide) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [...topRow, ...bottomRow],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: topRow),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: bottomRow),
          ],
        );
      },
    );
  }

  Widget _buildHiddenSelectionActionButtons(
    BuildContext context,
    List<DownloadTask> hiddenTasks,
  ) {
    OutlinedButton buildSelectAllButton() => OutlinedButton(
      onPressed:
          hiddenTasks.isEmpty ? null : () => _selectAllHidden(hiddenTasks),
      child: Text(context.l10n('media.action.selectAll')),
    );
    OutlinedButton buildDeleteButton() => OutlinedButton(
      onPressed: _hiddenSelected.isEmpty ? null : () => _deleteHiddenSelected(),
      child: Text(context.l10n('common.delete')),
    );
    OutlinedButton buildUnhideButton() => OutlinedButton(
      onPressed:
          _hiddenSelected.isEmpty ? null : () => _unhideSelected(context),
      child: Text(context.l10n('media.action.unhide')),
    );
    OutlinedButton buildExportButton() => OutlinedButton(
      onPressed:
          _hiddenSelected.isEmpty ? null : () => _exportHiddenSelected(context),
      child: Text(context.l10n('media.action.export')),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 520;
        final firstRow = [
          buildSelectAllButton(),
          buildDeleteButton(),
          buildUnhideButton(),
        ];
        final secondRow = [buildExportButton()];
        if (isWide) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [...firstRow, ...secondRow],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: firstRow),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: secondRow),
          ],
        );
      },
    );
  }

  Future<bool> _exportTasks(
    BuildContext context,
    Iterable<DownloadTask> tasks,
  ) async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: context.l10n('feature.export'),
    );
    if (!ok) return false;
    final paths = <String>[];
    for (final task in tasks) {
      if (File(task.savePath).existsSync()) {
        paths.add(task.savePath);
      }
    }
    if (paths.isEmpty) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: Duration(seconds: 1),
          content: Text(context.l10n('media.snack.noExportable')),
        ),
      );
      return false;
    }
    return await _sharePaths(context, paths);
  }

  Future<void> _exportSelected(BuildContext context) async {
    if (_selected.isEmpty) return;
    final exported = await _exportTasks(context, _selected);
    if (!mounted || !exported) return;
    setState(() {
      _selected.clear();
      _isEditing = false;
    });
  }

  Future<void> _exportHiddenSelected(BuildContext context) async {
    if (_hiddenSelected.isEmpty) return;
    final exported = await _exportTasks(context, _hiddenSelected);
    if (!mounted || !exported) return;
    setState(() {
      _hiddenSelected.clear();
      _hiddenEditing = false;
    });
  }

  void _toggleFavorite(DownloadTask task) {
    AppRepo.I.setFavorite(task, !task.favorite);
    setState(() {});
  }

  void _hideTasks(BuildContext context, List<DownloadTask> tasks) {
    if (tasks.isEmpty) return;
    AppRepo.I.setTasksHidden(tasks, true);
    if (!mounted) return;
    setState(() {
      _selected.removeAll(tasks);
      _hiddenSelected.removeAll(tasks);
      _isEditing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          context.l10n(
            'media.snack.hiddenCount',
            params: {'count': '${tasks.length}'},
          ),
        ),
      ),
    );
  }

  void _unhideTasks(BuildContext context, List<DownloadTask> tasks) {
    if (tasks.isEmpty) return;
    AppRepo.I.setTasksHidden(tasks, false);
    if (!mounted) return;
    setState(() {
      _hiddenSelected.removeAll(tasks);
      _hiddenEditing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          context.l10n(
            'media.snack.unhiddenCount',
            params: {'count': '${tasks.length}'},
          ),
        ),
      ),
    );
  }

  void _hideSelected(BuildContext context) {
    if (_selected.isEmpty) return;
    _hideTasks(context, _selected.toList());
  }

  void _unhideSelected(BuildContext context) {
    if (_hiddenSelected.isEmpty) return;
    _unhideTasks(context, _hiddenSelected.toList());
  }

  void _renameTask(BuildContext context, DownloadTask task) {
    final controller = TextEditingController(text: task.name ?? '');
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(context.l10n('common.rename')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: context.l10n('media.prompt.enterNewName'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) {
                  AppRepo.I.renameTask(task, value);
                }
                Navigator.pop(context);
              },
              child: Text(context.l10n('common.save')),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _sharePaths(BuildContext context, List<String> paths) async {
    if (paths.isEmpty) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('media.snack.noExportable')),
        ),
      );
      return false;
    }
    try {
      await AppRepo.I.sharePaths(paths);
      return true;
    } catch (err) {
      debugPrint('[Media] Share failed: $err');
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(context.l10n('media.error.shareFailed')),
        ),
      );
      return false;
    }
  }

  Future<void> _handleShare(BuildContext context, DownloadTask task) async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: context.l10n('feature.export'),
    );
    if (!ok) return;
    if (!File(task.savePath).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('media.error.missingFile')),
        ),
      );
      return;
    }
    await _sharePaths(context, [task.savePath]);
  }

  Future<void> _openTask(
    BuildContext context,
    DownloadTask task, {
    List<DownloadTask>? candidates,
  }) async {
    if (!File(task.savePath).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('media.error.missingFile')),
        ),
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
          SnackBar(
            duration: const Duration(seconds: 1),
            content: Text(context.l10n('media.error.incompleteFile')),
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
  bool _defaultExpanded(String key) => key == _folderKey(null);

  Future<void> _loadFolderExpansionPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kFolderExpansionPrefKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final restored = <String, bool>{};
          decoded.forEach((key, value) {
            if (key is String) {
              restored[key] = value == true;
            }
          });
          if (mounted) {
            setState(() {
              _folderExpanded
                ..clear()
                ..addAll(restored);
            });
          } else {
            _folderExpanded
              ..clear()
              ..addAll(restored);
          }
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _folderExpanded.putIfAbsent(_folderKey(null), () => true);
        _folderExpansionLoaded = true;
      });
    } else {
      _folderExpanded.putIfAbsent(_folderKey(null), () => true);
      _folderExpansionLoaded = true;
    }
  }

  Future<void> _persistFolderExpansion() async {
    if (!_folderExpansionLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kFolderExpansionPrefKey,
        jsonEncode(_folderExpanded),
      );
    } catch (_) {}
  }

  void _syncFolderExpansion(Iterable<String?> ids) {
    final keys = ids.map(_folderKey).toSet();
    bool changed = false;
    final removed =
        _folderExpanded.keys.where((key) => !keys.contains(key)).toList();
    for (final key in removed) {
      _folderExpanded.remove(key);
      changed = true;
    }
    for (final key in keys) {
      if (!_folderExpanded.containsKey(key)) {
        _folderExpanded[key] = _defaultExpanded(key);
        changed = true;
      }
    }
    if (changed) {
      _persistFolderExpansion();
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
          title: Text(context.l10n('media.dialog.renameFolder.title')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: context.l10n('media.prompt.enterNewName'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) {
                  AppRepo.I.renameMediaFolder(folder.id, value);
                }
                Navigator.pop(context);
              },
              child: Text(context.l10n('common.save')),
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
        final defaultFolderName = _defaultFolderName();
        return AlertDialog(
          title: Text(context.l10n('media.dialog.deleteFolder.title')),
          content: Text(
            context.l10n(
              'media.dialog.deleteFolder.message',
              params: {'name': folder.name, 'defaultFolder': defaultFolderName},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n('common.delete')),
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
          title: Text(context.l10n('media.dialog.createFolder.title')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: context.l10n('media.prompt.folderName'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context, controller.text.trim());
              },
              child: Text(context.l10n('common.create')),
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
    _persistFolderExpansion();
  }

  String _folderNameForId(String? id, {List<MediaFolder>? folders}) {
    final list = folders ?? AppRepo.I.mediaFolders.value;
    if (id == null) return _defaultFolderName();
    for (final folder in list) {
      if (folder.id == id) return folder.name;
    }
    return _defaultFolderName();
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
      featureName: context.l10n('feature.export'),
    );
    if (!ok) return;
    if (!File(task.savePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('media.error.missingFile')),
        ),
      );
      return;
    }
    try {
      await AppRepo.I.sharePaths([task.savePath]);
    } catch (err) {
      debugPrint('[Favorites] Share failed: $err');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(context.l10n('media.error.shareFailed')),
        ),
      );
    }
  }

  Future<void> _handleOpen(
    BuildContext context,
    DownloadTask task, {
    List<DownloadTask>? candidates,
  }) async {
    if (!File(task.savePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('media.error.missingFile')),
        ),
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
          SnackBar(
            duration: const Duration(seconds: 1),
            content: Text(context.l10n('media.error.incompleteFile')),
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
        featureName: context.l10n('feature.export'),
      );
      if (!ok) return;
      try {
        await AppRepo.I.sharePaths([task.savePath]);
      } catch (err) {
        debugPrint('[Favorites] Share failed: $err');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(context.l10n('media.error.shareFailed')),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder<List<DownloadTask>>(
      valueListenable: repo.downloads,
      builder: (context, tasks, _) {
        final favs =
            tasks.where((t) => t.favorite && !t.hidden).toList()
              ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        if (favs.isEmpty) {
          return Center(child: Text(context.l10n('media.empty.favorites')));
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
            final bool isHls = task.kind == 'hls';
            final bool isConverting =
                isHls &&
                task.state.toLowerCase() == 'downloading' &&
                task.total != null &&
                task.received >= task.total!;
            double? progressValue;
            if (task.state.toLowerCase() == 'downloading') {
              if (!isConverting && task.total != null && task.total! > 0) {
                final ratio = task.received / task.total!.toDouble();
                progressValue = ratio.clamp(0.0, 1.0).toDouble();
              } else {
                progressValue = null;
              }
            }
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
                  Text(
                    task.state == 'done'
                        ? context.l10n('media.state.done')
                        : task.state,
                  ),
                  if (sizeBytes > 0)
                    Text(
                      context.l10n(
                        'media.details.size',
                        params: {'size': formatFileSize(sizeBytes)},
                      ),
                    ),
                  if (task.duration != null)
                    Text(
                      context.l10n(
                        'media.details.duration',
                        params: {'duration': formatDuration(task.duration!)},
                      ),
                    ),
                ],
              ),
              onTap: () => _handleOpen(context, task, candidates: favs),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (task.state.toLowerCase() == 'downloading')
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          value: isConverting ? null : progressValue,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.favorite, color: Colors.redAccent),
                    tooltip: context.l10n('media.action.unfavorite'),
                    onPressed: () => repo.setFavorite(task, false),
                  ),
                ],
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
                              title: Text(
                                context.l10n('media.action.editName'),
                              ),
                              onTap: () => Navigator.pop(context, 'rename'),
                            ),
                            ListTile(
                              leading: const Icon(Icons.content_cut),
                              title: Text(
                                context.l10n('media.action.editExport'),
                              ),
                              onTap:
                                  () => Navigator.pop(context, 'edit-export'),
                            ),
                            ListTile(
                              leading: const Icon(Icons.share),

                              title: Text(context.l10n('media.action.export')),
                            ),
                            ListTile(
                              leading: const Icon(Icons.visibility_off),
                              title: Text(context.l10n('media.action.hide')),
                              onTap: () => Navigator.pop(context, 'hide'),
                            ),
                            ListTile(
                              leading: const Icon(Icons.delete),
                              title: Text(context.l10n('common.delete')),
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
                          title: Text(context.l10n('common.rename')),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            decoration: InputDecoration(
                              hintText: context.l10n(
                                'media.prompt.enterNewName',
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(context.l10n('common.cancel')),
                            ),
                            TextButton(
                              onPressed: () {
                                final value = controller.text.trim();
                                if (value.isNotEmpty) {
                                  AppRepo.I.renameTask(task, value);
                                }
                                Navigator.pop(context);
                              },
                              child: Text(context.l10n('common.save')),
                            ),
                          ],
                        ),
                  );
                } else if (action == 'edit-export') {
                  final ok = await PurchaseService().ensurePremium(
                    context: context,
                    featureName: context.l10n('feature.editExport'),
                  );
                  if (!ok) return;
                  if (!_fileHasContent(task.savePath)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.l10n('media.error.incompleteFile'),
                        ),
                      ),
                    );
                    return;
                  }
                  await Navigator.of(context).push(
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
                    featureName: context.l10n('feature.export'),
                  );
                  if (!ok) return;
                  await _handleShare(context, task);
                } else if (action == 'hide') {
                  AppRepo.I.setTaskHidden(task, true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: Duration(seconds: 1),
                      content: Text(
                        context.l10n(
                          'media.snack.hiddenCount',
                          params: {'count': '1'},
                        ),
                      ),
                    ),
                  );
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
