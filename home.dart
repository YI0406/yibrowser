import 'package:flutter/material.dart';
import 'soure.dart';
import 'package:flutter/services.dart';

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

class _HomePageState extends State<HomePage> {
  int _draggingIndex = -1;

  // Whether the home page is in edit (reorder) mode. When true, tiles can
  // be dragged to rearrange their order. When false, tiles open URLs on tap
  // and show a context menu on long press.
  bool _editMode = false;

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
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增捷徑',
            onPressed: _showAddDialog,
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
              // Compute the number of columns based on available width. Use a
              // slightly smaller tile width so that icons appear smaller and
              // more columns fit on the screen.
              final int count = (width / 100).floor();
              final crossAxisCount = count >= 2 ? count : 2;
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
                  final item = items[index];
                  return _buildTile(context, index, item);
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
    // In edit mode enable drag and reorder; in normal mode show a simple tile.
    if (_editMode) {
      return LongPressDraggable<int>(
        data: index,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          setState(() {
            _draggingIndex = index;
          });
          // Provide a light haptic feedback when starting a drag in edit mode.
          HapticFeedback.lightImpact();
        },
        onDragCompleted: () {
          setState(() {
            _draggingIndex = -1;
          });
        },
        onDraggableCanceled: (_, __) {
          setState(() {
            _draggingIndex = -1;
          });
        },
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 100,
            height: 100,
            child: _buildTileContent(context, item, dragging: true),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.0,
          child: _buildTileContent(context, item),
        ),
        child: DragTarget<int>(
          onWillAccept: (from) => from != null && from != index,
          onAccept: (from) {
            repo.reorderHomeItems(from, index);
          },
          builder: (context, candidate, rejected) {
            return _buildTileContent(context, item);
          },
        ),
      );
    } else {
      // Normal mode: no drag; use simple gesture detection.
      return _buildTileContent(context, item);
    }
  }

  Widget _buildTileContent(
    BuildContext context,
    HomeItem item, {
    bool dragging = false,
  }) {
    final uri = Uri.tryParse(item.url);
    final host = uri?.host ?? '';
    // 先嘗試網站自己的 favicon.ico，失敗再退回 Google s2 服務
    final faviconDirect = host.isNotEmpty ? 'https://$host/favicon.ico' : null;
    final faviconS2 =
        host.isNotEmpty
            ? 'https://www.google.com/s2/favicons?domain=$host&sz=128'
            : null;
    return GestureDetector(
      onTap: () {
        if (widget.onOpen != null) {
          widget.onOpen!(item.url);
        }
      },
      // When not in edit mode, show a context menu near the tap position.
      onLongPressStart: (details) {
        if (!_editMode) {
          // Provide a subtle haptic feedback when long pressing an icon in
          // normal mode.
          HapticFeedback.lightImpact();
          _showContextMenu(details.globalPosition, item);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
          boxShadow:
              dragging
                  ? [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ]
                  : [],
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.hardEdge,
              child:
                  host.isNotEmpty
                      ? Image.network(
                        faviconDirect!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) {
                          return faviconS2 != null
                              ? Image.network(
                                faviconS2,
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (_, __, ___) => const Icon(
                                      Icons.public,
                                      color: Colors.black54,
                                    ),
                              )
                              : const Icon(Icons.public, color: Colors.black54);
                        },
                      )
                      : const Icon(Icons.public, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                item.name.isNotEmpty ? item.name : host,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  void _showAddDialog() {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
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
