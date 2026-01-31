import 'dart:io';

import 'package:flutter/material.dart';
import 'soure.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:async';
import 'iap.dart';
import 'soure.dart';
import 'app_localizations.dart';

class _QuickAction {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    this.onTap,
  });
}

enum _HomeTileKind { quick, item }

class _HomeTile {
  final _HomeTileKind kind;
  final String id;
  final HomeItem? item;
  final _QuickAction? action;

  const _HomeTile.quick({required this.id, required this.action})
      : kind = _HomeTileKind.quick,
        item = null;

  const _HomeTile.item({required this.id, required this.item})
      : kind = _HomeTileKind.item,
        action = null;
}

/// HomePage displays a grid of shortcuts. Each shortcut shows its favicon,
/// name and actions to edit or delete. The grid supports drag‑and‑drop
/// reordering via long press. Tapping an item triggers the [onOpen] callback
/// which should navigate to the browser page and load the URL.
class HomePage extends StatefulWidget {
  final void Function(String url)? onOpen;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenFavorites;
  final VoidCallback? onOpenDownloads;
  final VoidCallback? onOpenAddDownload;
  final VoidCallback? onOpenMedia;
  final VoidCallback? onOpenTabs;
  final VoidCallback? onOpenHistory;

  const HomePage({
    super.key,
    this.onOpen,
    this.onOpenSettings,
    this.onOpenFavorites,
    this.onOpenDownloads,
    this.onOpenAddDownload,
    this.onOpenMedia,
    this.onOpenTabs,
    this.onOpenHistory,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, LanguageAwareState<HomePage> {
  bool _didDragSinceLongPress = false;
  int _draggingIndex = -1;
  int? _hoverIndex;
  OverlayEntry? _menuEntry;
  bool _menuOpen = false;
  Timer? _pressTimer;
  Offset? _pressDownGlobalPos;
  final TextEditingController _addDownloadUrlCtrl = TextEditingController();

  @override
  void dispose() {
    _addDownloadUrlCtrl.dispose();
    super.dispose();
  }
  void _dismissMenu() {
    if (_menuEntry != null) {
      _menuEntry!.remove();
      _menuEntry = null;
    }
    _menuOpen = false;
  }

  void _showOverlayMenu(Offset globalPos, HomeItem item) {
    _dismissMenu();
    final overlay = Overlay.of(context);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (context) {
        // Position the menu near the press point
        return Stack(
          children: [
            // Non-blocking backdrop (do not capture events during current touch)
            Positioned.fill(
              child: IgnorePointer(ignoring: true, child: SizedBox.expand()),
            ),
            Positioned(
              left: globalPos.dx,
              top: globalPos.dy,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context).colorScheme.surface,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 160),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () {
                          _dismissMenu();
                          _editItem(item);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Text(context.l10n('common.edit')),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          _dismissMenu();
                          final idx = AppRepo.I.homeItems.value.indexOf(item);
                          if (idx >= 0) {
                            AppRepo.I.removeHomeItemAt(idx);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Text(context.l10n('common.delete')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    _menuEntry = entry;
    _menuOpen = true;
    overlay.insert(entry);
  }

  int _mapSourceIndex(int pos, int drag, int hover, int len) {
    if (hover == drag) return pos;
    if (hover > drag) {
      // Dragging forward: items between [drag+1, hover] shift left by 1; placeholder at hover.
      if (pos < drag) return pos;
      if (pos >= drag && pos < hover) return pos + 1;
      if (pos > hover) return pos;
      // pos == hover -> placeholder handled by caller
      return -1;
    } else {
      // Dragging backward: items between [hover, drag-1] shift right by 1; placeholder at hover.
      if (pos < hover) return pos;
      if (pos > hover && pos <= drag) return pos - 1;
      if (pos > drag) return pos;
      // pos == hover -> placeholder handled by caller
      return -1;
    }
  }

  List<_HomeTile> _buildHomeTiles(List<HomeItem> items) {
    final actions = _quickActionsMap();
    final order = AppRepo.I.homeTilesOrder.value;
    final itemsById = {for (final item in items) item.id: item};
    final tiles = <_HomeTile>[];
    final usedItems = <String>{};
    for (final id in order) {
      if (id.startsWith('quick.')) {
        final action = actions[id];
        if (action != null) {
          tiles.add(_HomeTile.quick(id: id, action: action));
        }
        continue;
      }
      if (id.startsWith('item:')) {
        final itemId = id.substring('item:'.length);
        final item = itemsById[itemId];
        if (item != null) {
          tiles.add(_HomeTile.item(id: id, item: item));
          usedItems.add(itemId);
        }
      }
    }
    for (final item in items) {
      if (usedItems.contains(item.id)) continue;
      tiles.add(_HomeTile.item(id: 'item:${item.id}', item: item));
    }
    return tiles;
  }

  Map<String, _QuickAction> _quickActionsMap() {
    return {
      'quick.settings': _QuickAction(
        icon: Icons.settings,
        label: context.l10n('home.quick.settings'),
        onTap: widget.onOpenSettings,
      ),
      'quick.favorites': _QuickAction(
        icon: Icons.favorite,
        label: context.l10n('home.quick.favorites'),
        onTap: widget.onOpenFavorites,
      ),
      'quick.downloads': _QuickAction(
        icon: Icons.download_rounded,
        label: context.l10n('home.quick.downloads'),
        onTap: widget.onOpenDownloads,
      ),
      'quick.add_download': _QuickAction(
        icon: Icons.add_circle_outline,
        label: context.l10n('home.quick.addDownload'),
        onTap: _showAddDownloadPrompt,
      ),
      'quick.media': _QuickAction(
        icon: Icons.video_library_outlined,
        label: context.l10n('home.quick.media'),
        onTap: widget.onOpenMedia,
      ),
      'quick.tabs': _QuickAction(
        icon: Icons.tab,
        label: context.l10n('home.quick.tabs'),
        onTap: widget.onOpenTabs,
      ),
      'quick.history': _QuickAction(
        icon: Icons.history,
        label: context.l10n('home.quick.history'),
        onTap: widget.onOpenHistory,
      ),
      'quick.clear_cache': _QuickAction(
        icon: Icons.cleaning_services_outlined,
        label: context.l10n('home.quick.clearCache'),
        onTap: _handleClearCache,
      ),
    };
  }

  void _reorderTiles(int from, int to, List<_HomeTile> tiles) {
    if (from == to) return;
    final next = List<_HomeTile>.from(tiles);
    final moved = next.removeAt(from);
    next.insert(to, moved);
    final order = <String>[];
    for (final tile in next) {
      if (tile.kind == _HomeTileKind.quick) {
        order.add(tile.id);
      } else if (tile.item != null) {
        order.add('item:${tile.item!.id}');
      }
    }
    AppRepo.I.setHomeTilesOrder(order);
  }

  Widget _buildPlaceholderTile() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
          width: 2,
          style: BorderStyle.solid,
        ),
      ),
    );
  }

  // Whether the home page is in edit (reorder) mode. When true, tiles can
  // be dragged to rearrange their order. When false, tiles open URLs on tap
  // and show a context menu on long press.
  bool _editMode = false;

  AnimationController? _jitterController;
  Animation<double>? _jitterAnimation;

  final Map<int, double> _jitterPhase = {};
  double _phaseFor(int index) {
    return _jitterPhase.putIfAbsent(index, () {
      // deterministic phase per index
      return (index * 0.7) % (2 * math.pi);
    });
  }

  @override
  void initState() {
    super.initState();
    _jitterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _jitterAnimation = Tween<double>(
      begin: -2.0,
      end: 2.0,
    ).animate(_jitterController!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(AppRepo.I.refreshMissingHomeIcons());
    });
  }

  /// Shows a context menu near the long‑pressed tile allowing the user to
  /// edit or delete the given [item]. The menu appears at the pointer
  /// position provided by [pos].
  void _showContextMenu(Offset pos, HomeItem item) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(value: 'edit', child: Text(context.l10n('common.edit'))),
        PopupMenuItem(
          value: 'delete',
          child: Text(context.l10n('common.delete')),
        ),
      ],
    );
    if (selected == null) return;
    switch (selected) {
      case 'edit':
        _editItem(item);
        break;
      case 'delete':
        final idx = AppRepo.I.homeItems.value.indexOf(item);
        if (idx >= 0) {
          AppRepo.I.removeHomeItemAt(idx);
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n('home.title')),
        actions: [
          // Toggle between edit (reorder) mode and normal mode. In edit mode
          // the user can drag tiles to reorder. In normal mode long press
          // shows a context menu.
          IconButton(
            icon: Icon(_editMode ? Icons.check : Icons.edit),
            tooltip:
                _editMode
                    ? context.l10n('common.done')
                    : context.l10n('common.edit'),
            onPressed: () {
              setState(() {
                _editMode = !_editMode;
                _draggingIndex = -1;
                if (_editMode) {
                  _jitterController?.repeat(reverse: true);
                } else {
                  _jitterController?.stop();
                  _jitterController?.reset();
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: context.l10n('home.action.addShortcut'),
            onPressed: _handleAddShortcut,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([repo.homeItems, repo.homeTilesOrder]),
        builder: (context, _) {
          final items = repo.homeItems.value;
          final tiles = _buildHomeTiles(items);
          if (tiles.isEmpty) {
            return Center(
              child: Text(
                context.l10n('home.emptyState'),
                textAlign: TextAlign.center,
              ),
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              const double gridPadding = 8;
              const double spacing = 8;
              const double targetTileExtent = 96;
              final double usable = math.max(0, width - gridPadding * 2);
              int columns =
                  ((usable + spacing) / (targetTileExtent + spacing)).round();
              if (columns < 1) {
                columns = 1;
              }
              columns = columns.clamp(1, 8);
              final double tileWidth =
                  (usable - spacing * (columns - 1)) / columns;
              const double extraHeight = 56;
              double childAspectRatio =
                  tileWidth <= 0 ? 0.7 : tileWidth / (tileWidth + extraHeight);
              childAspectRatio = math.max(
                0.62,
                math.min(childAspectRatio, 0.82),
              );
              final int crossAxisCount = columns;
              return GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: childAspectRatio,
                ),
                itemCount: tiles.length,
                itemBuilder: (context, index) {
                  final itemsLen = tiles.length;
                  final bool showPreview =
                      _editMode &&
                      _draggingIndex >= 0 &&
                      _hoverIndex != null &&
                      _hoverIndex != _draggingIndex;
                  if (showPreview) {
                    if (index == _hoverIndex) {
                      return DragTarget<int>(
                        onWillAccept: (from) => from != null && from != index,
                        onAccept: (from) {
                          _reorderTiles(from, _hoverIndex!, tiles);
                          setState(() {
                            _draggingIndex = -1;
                            _hoverIndex = null;
                          });
                        },
                        builder: (context, candidate, rejected) {
                          final hovering = candidate.isNotEmpty;
                          return AnimatedScale(
                            scale: hovering ? 1.05 : 1.0,
                            duration: const Duration(milliseconds: 150),
                            child: _buildPlaceholderTile(),
                          );
                        },
                      );
                    }
                    final src = _mapSourceIndex(
                      index,
                      _draggingIndex,
                      _hoverIndex!,
                      itemsLen,
                    );
                    final mappedIndex =
                        (src >= 0 && src < itemsLen)
                            ? src
                            : index.clamp(0, itemsLen - 1);
                    final mappedTile = tiles[mappedIndex];
                    return _buildTile(context, index, mappedTile, tiles);
                  } else {
                    final tile = tiles[index];
                    return _buildTile(context, index, tile, tiles);
                  }
                },
              );
            },
          );
        },
      ),
    );
  }


  String? _normalizeHttpUrl(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }
    final scheme = parsed.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return parsed.toString();
    }
    return null;
  }

  Future<void> _showAddDownloadPrompt() async {
    _addDownloadUrlCtrl.text = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n('browser.dialog.addDownload.title')),
          content: TextField(
            controller: _addDownloadUrlCtrl,
            decoration: InputDecoration(
              labelText: dialogContext.l10n('common.url'),
              hintText: 'https://',
            ),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogContext.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(dialogContext.l10n('common.add')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    var raw = _addDownloadUrlCtrl.text.trim();
    if (raw.isEmpty) {
      return;
    }
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    final normalized = _normalizeHttpUrl(raw);
    if (normalized == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('common.invalidUrl')),
        ),
      );
      return;
    }
    await AppRepo.I.enqueueDownload(normalized);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(context.l10n('browser.snack.addedToQueue')),
      ),
    );
  }

  Future<void> _handleClearCache() async {
    final size = await AppRepo.I.getCacheSize();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n('settings.cache.title')),
          content: Text(
            dialogContext.l10n(
              'settings.cache.subtitle',
              params: {'size': AppRepo.I.formatBytes(size)},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogContext.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(dialogContext.l10n('common.clear')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await AppRepo.I.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(context.l10n('settings.cache.cleared')),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    int index,
    _HomeTile tile,
    List<_HomeTile> tiles,
  ) {
    // Always allow LongPressDraggable so user can drag to enter edit mode like iOS.
    return LongPressDraggable<int>(
      data: index,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () {
        setState(() {
          _pressTimer?.cancel();
          _pressDownGlobalPos = null;
          _dismissMenu(); // close menu if it was opened by long-press
          _didDragSinceLongPress = true;
          _draggingIndex = index;
          if (!_editMode) {
            _editMode = true;
            _jitterController?.repeat(reverse: true);
          }
        });
        HapticFeedback.mediumImpact();
      },
      onDragCompleted: () {
        setState(() {
          _draggingIndex = -1;
          _hoverIndex = null;
          // keep _editMode = true until user presses 完成 (like iOS)
          _didDragSinceLongPress = false;
        });
      },
      onDraggableCanceled: (_, __) {
        setState(() {
          _draggingIndex = -1;
          _hoverIndex = null;
          _didDragSinceLongPress = false;
        });
      },
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 104,
          height: 132,
          child: Transform.scale(
            scale: 1.05,
            child:
                tile.kind == _HomeTileKind.quick
                    ? _buildQuickTileContent(
                      context,
                      tile.action!,
                      dragging: true,
                      editing: true,
                      index: index,
                    )
                    : _buildTileContent(
                      context,
                      tile.item!,
                      dragging: true,
                      editing: true,
                      index: index,
                    ),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.0,
        child:
            tile.kind == _HomeTileKind.quick
                ? _buildQuickTileContent(
                  context,
                  tile.action!,
                  editing: _editMode,
                  index: index,
                )
                : _buildTileContent(
                  context,
                  tile.item!,
                  editing: _editMode,
                  index: index,
                ),
      ),
      child: DragTarget<int>(
        onWillAccept: (from) {
          final ok = from != null && from != index;
          setState(() {
            _hoverIndex = ok ? index : null;
          });
          return ok;
        },
        onMove: (_) {
          if (_hoverIndex != index) {
            setState(() {
              _hoverIndex = index;
            });
            HapticFeedback.mediumImpact();
          }
        },
        onLeave: (_) {
          if (_hoverIndex == index) {
            setState(() {
              _hoverIndex = null;
            });
          }
        },
        onAccept: (from) {
          final to = _hoverIndex ?? index;
          _reorderTiles(from, to, tiles);
          setState(() {
            _draggingIndex = -1;
            _hoverIndex = null;
            // remain in edit mode; user taps 完成 to exit (iOS-like)
          });
          HapticFeedback.mediumImpact(); // 完成換位震動
        },
        builder: (context, candidate, rejected) {
          final hovering = candidate.isNotEmpty;
          return AnimatedScale(
            scale: hovering ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 150),
            child:
                tile.kind == _HomeTileKind.quick
                    ? _buildQuickTileContent(
                      context,
                      tile.action!,
                      editing: _editMode,
                      index: index,
                    )
                    : _buildTileContent(
                      context,
                      tile.item!,
                      editing: _editMode,
                      index: index,
                    ),
          );
        },
      ),
    );
  }

  Widget _buildQuickTileContent(
    BuildContext context,
    _QuickAction action, {
    bool dragging = false,
    bool editing = false,
    int? index,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconBackground =
        isDark
            ? const Color(0xFF2C2C2E)
            : theme.colorScheme.surfaceVariant.withOpacity(0.9);
    final iconBorderColor = theme.colorScheme.outlineVariant.withOpacity(
      isDark ? 0.45 : 0.28,
    );
    final shadowColor =
        isDark
            ? Colors.black.withOpacity(dragging ? 0.5 : 0.35)
            : Colors.black.withOpacity(dragging ? 0.18 : 0.1);
    final titleStyle =
        theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          letterSpacing: 0.2,
          height: 1.25,
          color: theme.colorScheme.onSurface.withOpacity(0.95),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          letterSpacing: 0.2,
          height: 1.25,
          color: theme.colorScheme.onSurface.withOpacity(0.95),
        );
    final showLabels = !dragging;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: iconBackground,
              border: Border.all(color: iconBorderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: dragging ? 20 : 14,
                  offset: Offset(0, dragging ? 12 : 6),
                  spreadRadius: -2,
                ),
              ],
            ),
            padding: const EdgeInsets.all(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: DecoratedBox(
                decoration: BoxDecoration(color: theme.colorScheme.surface),
                child: Icon(
                  action.icon,
                  size: 28,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          if (showLabels) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: titleStyle,
              ),
            ),
          ],
        ],
      ),
    );

    Widget wrapped = content;
    if (editing) {
      wrapped = AnimatedBuilder(
        animation: _jitterController!,
        builder: (context, child) {
          final phi = _phaseFor(index ?? 0);
          final angle =
              math.sin((_jitterController!.value * 2 * math.pi) + phi) * 0.04;
          return Transform.rotate(angle: angle, child: child);
        },
        child: content,
      );
    }

    if (!editing) {
      return GestureDetector(
        onTap: action.onTap,
        onLongPress: () {
          setState(() {
            _editMode = true;
            _jitterController?.repeat(reverse: true);
          });
          HapticFeedback.mediumImpact();
        },
        child: wrapped,
      );
    }

    return wrapped;
  }

  Widget _buildTileContent(
    BuildContext context,
    HomeItem item, {
    bool dragging = false,
    bool editing = false,
    int? index,
  }) {
    String _normalizeUrl(String input) {
      final trimmed = input.trim();
      if (trimmed.isEmpty) return trimmed;
      final schemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
      if (schemePattern.hasMatch(trimmed)) {
        return trimmed;
      }
      if (trimmed.startsWith('//')) {
        return 'https:$trimmed';
      }
      final guess = Uri.tryParse('https://$trimmed');
      return guess?.toString() ?? trimmed;
    }

    final normalizedUrl = _normalizeUrl(item.url);
    final uri = Uri.tryParse(normalizedUrl);
    final host = uri?.host ?? '';
    // 先嘗試網站自己的 favicon.ico，失敗再退回 Google s2 服務
    final faviconDirect = host.isNotEmpty ? 'https://$host/favicon.ico' : null;
    final faviconS2 =
        host.isNotEmpty
            ? 'https://www.google.com/s2/favicons?domain=$host&sz=128'
            : null;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final displayName = item.name.isNotEmpty ? item.name : host;
    final fallbackSource = displayName.isNotEmpty ? displayName : host;
    String fallbackText = '?';
    if (fallbackSource.isNotEmpty) {
      final firstCodeUnit = fallbackSource.runes.first;
      fallbackText = String.fromCharCode(firstCodeUnit).toUpperCase();
    }

    double _clamp(double value, double min, double max) {
      if (value < min) return min;
      if (value > max) return max;
      return value;
    }

    List<Color> _randomizedGradientFor(String seed) {
      if (seed.isEmpty) {
        return isDark
            ? [
              theme.colorScheme.primary.withOpacity(0.42),
              theme.colorScheme.primary.withOpacity(0.16),
            ]
            : [
              theme.colorScheme.primary.withOpacity(0.72),
              theme.colorScheme.primary.withOpacity(0.45),
            ];
      }

      int hash = 0x811C9DC5;
      for (final codeUnit in seed.codeUnits) {
        hash ^= codeUnit;
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
      }

      final hue = (hash & 0xFFFF) % 360;
      final satComponent = ((hash >> 16) & 0xFF) / 255.0;
      final saturation = _clamp(0.55 + satComponent * 0.35, 0.35, 0.95);
      final baseValue = isDark ? 0.58 : 0.88;
      final baseColor = HSVColor.fromAHSV(
        1.0,
        hue.toDouble(),
        saturation,
        baseValue,
      );

      final lighter =
          baseColor
              .withValue(
                _clamp(baseColor.value * (isDark ? 1.08 : 0.92), 0.25, 1.0),
              )
              .withSaturation(
                _clamp(
                  baseColor.saturation * (isDark ? 0.92 : 1.04),
                  0.3,
                  0.95,
                ),
              )
              .toColor();
      final darker =
          baseColor
              .withValue(
                _clamp(baseColor.value * (isDark ? 0.72 : 1.06), 0.2, 1.0),
              )
              .withSaturation(
                _clamp(baseColor.saturation * (isDark ? 1.05 : 0.9), 0.3, 0.95),
              )
              .toColor();

      return [lighter, darker];
    }

    Color _fallbackLetterColor(List<Color> gradient) {
      final blended = Color.lerp(gradient.first, gradient.last, 0.5)!;
      final luminance = blended.computeLuminance();
      final lightText = Colors.white.withOpacity(isDark ? 0.92 : 0.95);
      final darkText = Colors.black.withOpacity(isDark ? 0.85 : 0.9);
      return luminance > 0.55 ? darkText : lightText;
    }

    Widget buildFallbackIcon() {
      final fallbackGradientColors = _randomizedGradientFor(fallbackSource);
      final fallbackLetterColor = _fallbackLetterColor(fallbackGradientColors);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: fallbackGradientColors,
          ),
        ),
        child: Center(
          child: Text(
            fallbackText,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: fallbackLetterColor,
            ),
          ),
        ),
      );
    }

    Widget buildNetworkIcon(String url, Widget fallback) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    Widget iconChild = buildFallbackIcon();
    final iconPath = item.iconPath;
    var hasLocalIcon = false;
    if (iconPath != null && iconPath.isNotEmpty) {
      final file = File(iconPath);
      if (file.existsSync()) {
        iconChild = Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => buildFallbackIcon(),
        );
        hasLocalIcon = true;
      }
    }
    if (!hasLocalIcon) {
      if (host.isNotEmpty && faviconDirect != null) {
        iconChild = buildNetworkIcon(
          faviconDirect!,
          faviconS2 != null
              ? buildNetworkIcon(faviconS2!, buildFallbackIcon())
              : buildFallbackIcon(),
        );
      }
    }

    final iconBackground =
        isDark
            ? const Color(0xFF2C2C2E)
            : theme.colorScheme.surfaceVariant.withOpacity(0.9);
    final iconBorderColor = theme.colorScheme.outlineVariant.withOpacity(
      isDark ? 0.45 : 0.28,
    );
    final shadowColor =
        isDark
            ? Colors.black.withOpacity(dragging ? 0.5 : 0.35)
            : Colors.black.withOpacity(dragging ? 0.18 : 0.1);
    final titleStyle =
        theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          letterSpacing: 0.2,
          height: 1.25,
          color: theme.colorScheme.onSurface.withOpacity(0.95),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          letterSpacing: 0.2,
          height: 1.25,
          color: theme.colorScheme.onSurface.withOpacity(0.95),
        );
    final hostStyle =
        theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.9),
        ) ??
        TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.9),
        );
    final showLabels = !dragging;
    Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: iconBackground,
              border: Border.all(color: iconBorderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: dragging ? 20 : 14,
                  offset: Offset(0, dragging ? 12 : 6),
                  spreadRadius: -2,
                ),
              ],
            ),
            padding: const EdgeInsets.all(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: DecoratedBox(
                decoration: BoxDecoration(color: theme.colorScheme.surface),
                child: iconChild,
              ),
            ),
          ),
          if (showLabels) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: titleStyle,
              ),
            ),
            if (host.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(
                    isDark ? 0.45 : 0.7,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: hostStyle,
                ),
              ),
            ],
          ],
        ],
      ),
    );

    if (!editing) {
      return GestureDetector(
        onTap: () {
          final target = normalizedUrl.isNotEmpty ? normalizedUrl : item.url;
          widget.onOpen?.call(target);
        },
        onLongPress: () {
          setState(() {
            _editMode = true;
            _jitterController?.repeat(reverse: true);
          });
          HapticFeedback.mediumImpact(); // 進入編輯模式震動
        },
        child: content,
      );
    } else {
      // Add overlay with edit and delete buttons, keeping tile size consistent
      return LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              SizedBox.expand(
                child: AnimatedBuilder(
                  animation: _jitterController!,
                  builder: (context, child) {
                    final phi = _phaseFor(index ?? 0);
                    final angle =
                        math.sin(
                          (_jitterController!.value * 2 * math.pi) + phi,
                        ) *
                        0.04;
                    return Transform.rotate(angle: angle, child: child);
                  },
                  child: content,
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: () {
                    final idx = AppRepo.I.homeItems.value.indexOf(item);
                    if (idx >= 0) {
                      AppRepo.I.removeHomeItemAt(idx);
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 4,
                right: 4,
                child: GestureDetector(
                  onTap: () {
                    _editItem(item);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(
                      Icons.edit,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _showAddDialog() async {
    if (AppRepo.I.hasReachedFreeHomeShortcutLimit) {
      await PurchaseService().showPurchasePrompt(
        context,
        featureName: context.l10n('feature.addHomeShortcut'),
      );
      return;
    }
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(context.l10n('home.dialog.addTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: context.l10n('common.name'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: context.l10n('common.url'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final url = urlCtrl.text.trim();
                if (name.isNotEmpty && url.isNotEmpty) {
                  AppRepo.I.addHomeItem(url, name);
                }
                Navigator.pop(context);
              },
              child: Text(context.l10n('common.add')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleAddShortcut() async {
    if (AppRepo.I.hasReachedFreeHomeShortcutLimit) {
      await PurchaseService().showPurchasePrompt(
        context,
        featureName: context.l10n('feature.addHomeShortcut'),
      );
      return;
    }
    await _showAddDialog();
  }

  void _editItem(HomeItem item) {
    final nameCtrl = TextEditingController(text: item.name);
    final urlCtrl = TextEditingController(text: item.url);
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(context.l10n('home.dialog.editTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: context.l10n('common.name'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: context.l10n('common.url'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final url = urlCtrl.text.trim();
                final index = AppRepo.I.homeItems.value.indexOf(item);
                if (index >= 0) {
                  AppRepo.I.updateHomeItem(index, url: url, name: name);
                }
                Navigator.pop(context);
              },
              child: Text(context.l10n('common.confirm')),
            ),
          ],
        );
      },
    );
  }

  void _showItemMenu(HomeItem item) {
    final index = AppRepo.I.homeItems.value.indexOf(item);
    if (index < 0) return;
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
                  title: Text(context.l10n('common.edit')),
                  onTap: () {
                    Navigator.pop(context);
                    _editItem(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: Text(context.l10n('common.delete')),
                  onTap: () {
                    Navigator.pop(context);
                    AppRepo.I.removeHomeItemAt(index);
                  },
                ),
              ],
            ),
          ),
    );
  }
}
