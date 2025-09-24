import 'package:flutter/material.dart';
import 'soure.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:async';
import 'iap.dart';

/// HomePage displays a grid of shortcuts. Each shortcut shows its favicon,
/// name and actions to edit or delete. The grid supports drag‑and‑drop
/// reordering via long press. Tapping an item triggers the [onOpen] callback
/// which should navigate to the browser page and load the URL.
class HomePage extends StatefulWidget {
  final void Function(String url)? onOpen;
  const HomePage({super.key, this.onOpen});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  bool _didDragSinceLongPress = false;
  int _draggingIndex = -1;
  int? _hoverIndex;
  OverlayEntry? _menuEntry;
  bool _menuOpen = false;
  Timer? _pressTimer;
  Offset? _pressDownGlobalPos;
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
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Text('編輯'),
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
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Text('刪除'),
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
  }

  /// Shows a context menu near the long‑pressed tile allowing the user to
  /// edit or delete the given [item]. The menu appears at the pointer
  /// position provided by [pos].
  void _showContextMenu(Offset pos, HomeItem item) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('編輯')),
        PopupMenuItem(value: 'delete', child: Text('刪除')),
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
        title: const Text('主頁'),
        actions: [
          // Toggle between edit (reorder) mode and normal mode. In edit mode
          // the user can drag tiles to reorder. In normal mode long press
          // shows a context menu.
          IconButton(
            icon: Icon(_editMode ? Icons.check : Icons.edit),
            tooltip: _editMode ? '完成' : '編輯',
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
            tooltip: '新增捷徑',
            onPressed: _handleAddShortcut,
          ),
        ],
      ),
      body: ValueListenableBuilder<List<HomeItem>>(
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
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              // Fixed responsive logic:
              // - Target tile size: 108px (content) + spacing accounted below
              // - Horizontal padding on GridView: 8 * 2
              // - Spacing between tiles: 8
              // This makes phones常見為 3~4 格、平板 5~8 格，並保持方形比例
              const double gridPadding = 8; // same as GridView padding
              const double spacing = 8; // crossAxisSpacing/mainAxisSpacing
              const double targetTileExtent = 108; // desired square tile width
              final double usable = width - gridPadding * 2;
              // columns = floor((usable + spacing) / (target + spacing))
              int columns =
                  ((usable + spacing) / (targetTileExtent + spacing)).floor();
              // Clamp to sane limits
              columns = columns.clamp(2, 8);
              final int crossAxisCount = columns;
              return GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 1.0,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final itemsLen = items.length;
                  final bool showPreview =
                      _editMode &&
                      _draggingIndex >= 0 &&
                      _hoverIndex != null &&
                      _hoverIndex != _draggingIndex;
                  if (showPreview) {
                    // If current grid slot is the hover position, render a placeholder (empty slot) with drop support.
                    if (index == _hoverIndex) {
                      return DragTarget<int>(
                        onWillAccept: (from) => from != null && from != index,
                        onAccept: (from) {
                          // Commit reorder INTO the placeholder slot
                          AppRepo.I.reorderHomeItems(from, _hoverIndex!);
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
                    // Map current grid position to the source item index from the original list.
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
                    final mappedItem = items[mappedIndex];
                    return _buildTile(context, index, mappedItem);
                  } else {
                    // Normal rendering without preview reordering.
                    final item = items[index];
                    return _buildTile(context, index, item);
                  }
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTile(BuildContext context, int index, HomeItem item) {
    final repo = AppRepo.I;
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
          width: 100,
          height: 100,
          child: Transform.scale(
            scale: 1.05,
            child: _buildTileContent(
              context,
              item,
              dragging: true,
              editing: true, // feedback follows edit visuals
              index: index,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.0,
        child: _buildTileContent(
          context,
          item,
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
          repo.reorderHomeItems(from, to);
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
            child: _buildTileContent(
              context,
              item,
              editing: _editMode, // show jiggle only in edit mode
              index: index,
            ),
          );
        },
      ),
    );
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

    Widget buildFallbackIcon() {
      final fallbackGradientColors =
          isDark
              ? [
                theme.colorScheme.primary.withOpacity(0.42),
                theme.colorScheme.primary.withOpacity(0.16),
              ]
              : [
                theme.colorScheme.primary.withOpacity(0.72),
                theme.colorScheme.primary.withOpacity(0.45),
              ];
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
              color:
                  isDark
                      ? theme.colorScheme.onPrimary.withOpacity(0.9)
                      : theme.colorScheme.onPrimaryContainer,
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

    Widget iconChild;
    if (host.isNotEmpty && faviconDirect != null) {
      iconChild = buildNetworkIcon(
        faviconDirect!,
        faviconS2 != null
            ? buildNetworkIcon(faviconS2!, buildFallbackIcon())
            : buildFallbackIcon(),
      );
    } else {
      iconChild = buildFallbackIcon();
    }

    final cardShadowColor =
        isDark
            ? Colors.black.withOpacity(dragging ? 0.45 : 0.32)
            : Colors.black.withOpacity(dragging ? 0.18 : 0.1);
    final borderColor = theme.colorScheme.outline.withOpacity(
      isDark ? 0.28 : 0.16,
    );
    final highlightShadow =
        isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.white.withOpacity(0.45);
    final tileGradient =
        isDark
            ? [const Color(0xFF2E3141), const Color(0xFF191B24)]
            : [const Color(0xFFF7F7FB), const Color(0xFFE8EAF0)];
    final iconBorderColor = theme.colorScheme.outline.withOpacity(
      isDark ? 0.55 : 0.3,
    );

    Widget content = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tileGradient,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor, width: 0.9),
        boxShadow: [
          BoxShadow(
            color: cardShadowColor,
            blurRadius: dragging ? 26 : 18,
            spreadRadius: -2,
            offset: Offset(0, dragging ? 18 : 10),
          ),
          BoxShadow(
            color: highlightShadow,
            blurRadius: 18,
            spreadRadius: -8,
            offset: const Offset(-8, -8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 12,
            right: 16,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    isDark
                        ? Colors.white.withOpacity(0.04)
                        : Colors.white.withOpacity(0.35),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors:
                        isDark
                            ? [
                              Colors.white.withOpacity(0.18),
                              Colors.white.withOpacity(0.05),
                            ]
                            : [
                              Colors.white.withOpacity(0.95),
                              const Color(0xFFE7E9F2),
                            ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(color: iconBorderColor, width: 1.1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isDark ? 0.45 : 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(6),
                child: ClipOval(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: theme.colorScheme.surface),
                    child: iconChild,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Text(
                  displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style:
                      theme.textTheme.titleMedium?.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        color: theme.colorScheme.onSurface.withOpacity(0.95),
                      ) ??
                      TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        color: theme.colorScheme.onSurface.withOpacity(0.95),
                      ),
                ),
              ),
              if (host.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors:
                          isDark
                              ? [
                                theme.colorScheme.primary.withOpacity(0.32),
                                theme.colorScheme.primary.withOpacity(0.18),
                              ]
                              : [
                                theme.colorScheme.primary.withOpacity(0.18),
                                theme.colorScheme.primary.withOpacity(0.12),
                              ],
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.15),
                    ),
                  ),
                  child: Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          color: theme.colorScheme.onPrimary.withOpacity(
                            isDark ? 0.92 : 0.8,
                          ),
                        ) ??
                        TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          color: theme.colorScheme.onPrimary.withOpacity(
                            isDark ? 0.92 : 0.8,
                          ),
                        ),
                  ),
                ),
              ],
            ],
          ),
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
        featureName: '新增更多主頁捷徑',
      );
      return;
    }
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('新增捷徑'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名稱'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrl,
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
                final url = urlCtrl.text.trim();
                if (name.isNotEmpty && url.isNotEmpty) {
                  AppRepo.I.addHomeItem(url, name);
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

  Future<void> _handleAddShortcut() async {
    if (AppRepo.I.hasReachedFreeHomeShortcutLimit) {
      await PurchaseService().showPurchasePrompt(
        context,
        featureName: '新增更多主頁捷徑',
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
                controller: urlCtrl,
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
                final url = urlCtrl.text.trim();
                final index = AppRepo.I.homeItems.value.indexOf(item);
                if (index >= 0) {
                  AppRepo.I.updateHomeItem(index, url: url, name: name);
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
                  title: const Text('編輯'),
                  onTap: () {
                    Navigator.pop(context);
                    _editItem(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('刪除'),
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
