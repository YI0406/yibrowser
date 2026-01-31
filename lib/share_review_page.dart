import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';
import 'package:open_filex/open_filex.dart';
import 'app_localizations.dart';

class IncomingShare {
  const IncomingShare({
    required this.path,
    this.typeHint,
    this.relativePath,
    this.displayName,
  });

  final String path;
  final String? typeHint;
  final String? relativePath;
  final String? displayName;

  String get effectiveName {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return p.basename(path);
  }
}

class ShareReviewResult {
  const ShareReviewResult({
    required this.imported,
    this.message,
    this.successCount = 0,
    this.failureCount = 0,
  });

  final bool imported;
  final String? message;
  final int successCount;
  final int failureCount;
}

enum _ShareReviewAction { confirm, discard }

class ShareReviewPage extends StatefulWidget {
  const ShareReviewPage({
    super.key,
    required this.items,
    required this.onConfirm,
    required this.onDiscard,
  });

  final List<IncomingShare> items;
  final Future<ShareReviewResult> Function(List<IncomingShare>) onConfirm;
  final Future<ShareReviewResult> Function(List<IncomingShare>) onDiscard;

  @override
  State<ShareReviewPage> createState() => _ShareReviewPageState();
}

class _ShareReviewPageState extends State<ShareReviewPage>
    with LanguageAwareState<ShareReviewPage> {
  late final PageController _pageController;
  final List<IncomingShare> _items = [];
  final List<IncomingShare> _removedItems = [];
  int _currentIndex = 0;
  _ShareReviewAction? _processing;
  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _items.addAll(widget.items);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _cleanupItems(List<IncomingShare> items) async {
    if (items.isEmpty) return;
    for (final item in items) {
      final file = File(item.path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (err) {
          debugPrint('[ShareReview] Failed to delete ${item.path}: $err');
        }
      }
    }
  }

  Future<void> _handleConfirm() async {
    if (_processing != null) return;
    setState(() => _processing = _ShareReviewAction.confirm);
    ShareReviewResult? result;
    try {
      await _cleanupItems(List<IncomingShare>.unmodifiable(_removedItems));
      result = await widget.onConfirm(List<IncomingShare>.unmodifiable(_items));
    } catch (err) {
      if (!mounted) return;
      setState(() => _processing = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n(
              'shareReview.snack.importFailed',
              params: {'error': '$err'},
            ),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _handleCancel() async {
    if (_processing != null) return;
    setState(() => _processing = _ShareReviewAction.discard);
    ShareReviewResult? result;
    try {
      final allItems = List<IncomingShare>.unmodifiable([
        ..._items,
        ..._removedItems,
      ]);
      result = await widget.onDiscard(allItems);
    } catch (err) {
      if (!mounted) return;
      setState(() => _processing = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n(
              'shareReview.snack.cancelFailed',
              params: {'error': '$err'},
            ),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _discardCurrentItem() async {
    if (_processing != null) return;
    if (_items.isEmpty) return;
    final removeIndex = _currentIndex.clamp(0, _items.length - 1);
    final removed = _items.removeAt(removeIndex);
    _removedItems.add(removed);
    if (!mounted) return;
    if (_items.isEmpty) {
      setState(() {
        _currentIndex = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n('shareReview.snack.allDiscarded'))),
      );
      await _handleCancel();
      return;
    }
    final newIndex = _currentIndex.clamp(0, _items.length - 1);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        newIndex,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
    setState(() {
      _currentIndex = newIndex;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n(
            'shareReview.snack.itemDiscarded',
            params: {'name': removed.effectiveName},
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    final hasItems = items.isNotEmpty;
    final clampedIndex =
        hasItems ? _currentIndex.clamp(0, items.length - 1) : 0;
    final currentItem = hasItems ? items[clampedIndex] : null;

    return WillPopScope(
      onWillPop: () async {
        await _handleCancel();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n('shareReview.dialog.title')),
          centerTitle: true,
          leading: TextButton(
            onPressed: _processing == null ? _handleCancel : null,
            child: Text(context.l10n('common.cancel'), softWrap: false),
          ),
          actions: [
            TextButton(
              onPressed: _processing == null ? _handleConfirm : null,
              child: Text(context.l10n('share.importPreview.action.import')),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        if (items.isEmpty)
                          const _EmptySharePreview()
                        else
                          PageView.builder(
                            controller: _pageController,
                            physics:
                                items.length > 1
                                    ? const PageScrollPhysics()
                                    : const NeverScrollableScrollPhysics(),
                            itemCount: items.length,
                            onPageChanged: (value) {
                              setState(() => _currentIndex = value);
                            },
                            itemBuilder: (context, index) {
                              final item = items[index];
                              return _SharePreviewItemView(item: item);
                            },
                          ),
                        if (items.isNotEmpty)
                          Positioned(
                            top: 16,
                            right: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.55),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${clampedIndex + 1}/${items.length}',
                                style:
                                    theme.textTheme.labelLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ) ??
                                    const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (currentItem != null) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                      child: Text(
                        currentItem.effectiveName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ) ??
                            const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                            ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(
                        items.length > 1
                            ? context.l10n('shareReview.carousel.hintMultiple')
                            : context.l10n('shareReview.carousel.hintSingle'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (hasItems)
                Positioned(
                  top: 16,
                  left: 16,
                  child: IconButton.filled(
                    onPressed: _processing == null ? _discardCurrentItem : null,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: context.l10n('shareReview.tooltip.discardItem'),
                  ),
                ),
              if (_processing != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.45),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            _processing == _ShareReviewAction.confirm
                                ? context.l10n('shareReview.status.saving')
                                : context.l10n('common.canceling'),
                            style:
                                theme.textTheme.bodyMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ) ??
                                const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharePreviewItemView extends StatelessWidget {
  const _SharePreviewItemView({required this.item});

  final IncomingShare item;

  bool get _isVideo {
    final type = item.typeHint?.toLowerCase() ?? '';
    if (type.contains('video')) return true;
    final lower = item.path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv');
  }

  bool get _isImage {
    final type = item.typeHint?.toLowerCase() ?? '';
    if (type.contains('image')) return true;
    final lower = item.path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool get _isAudio {
    final type = item.typeHint?.toLowerCase() ?? '';
    if (type.contains('audio')) return true;
    final lower = item.path.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.wav');
  }

  bool get _isDocument {
    final type = item.typeHint?.toLowerCase() ?? '';
    if (type.contains('pdf') ||
        type.contains('word') ||
        type.contains('presentation') ||
        type.contains('spreadsheet') ||
        type.contains('text')) {
      return true;
    }
    final lower = item.path.toLowerCase();
    return lower.endsWith('.pdf') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.ppt') ||
        lower.endsWith('.pptx') ||
        lower.endsWith('.xls') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.rtf');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final horizontalPadding = size.width > 720 ? 120.0 : 20.0;
    final preview = _buildPreview(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 24,
      ),
      child: preview,
    );
  }

  Widget _buildPreview(BuildContext context) {
    final theme = Theme.of(context);

    final file = File(item.path);
    if (!file.existsSync()) {
      return _MissingPreview(name: item.effectiveName);
    }

    if (_isVideo) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: _VideoPreview(path: item.path),
      );
    }

    if (_isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Image.file(
            file,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
      );
    }

    if (_isAudio) {
      return _AudioPreview(path: item.path);
    }

    if (_isDocument) {
      return _DocumentPreview(item: item);
    }

    return _GenericPreview(
      icon: Icons.insert_drive_file,
      name: item.effectiveName,
      color: theme.colorScheme.secondary,
    );
  }
}

class _EmptySharePreview extends StatelessWidget {
  const _EmptySharePreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 72,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n('shareReview.empty.title'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n('shareReview.empty.subtitle'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({required this.path});

  final String path;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..setLooping(false);
    _controller.addListener(_onControllerUpdated);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _initialized = true);
        })
        .catchError((err) {
          if (!mounted) return;
          setState(() => _error = err);
        });
  }

  void _onControllerUpdated() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdated);
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_initialized) return;
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final minutesStr = minutes.toString().padLeft(2, '0');
    final secondsStr = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final hoursStr = hours.toString().padLeft(2, '0');
      return '$hoursStr:$minutesStr:$secondsStr';
    }
    return '$minutesStr:$secondsStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    if (_error != null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n('shareReview.error.audioLoad'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_initialized) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final value = _controller.value;
    final duration = value.duration;
    final position = value.position;
    final maxMillis =
        duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final sliderValue = position.inMilliseconds.toDouble().clamp(
      0.0,
      maxMillis,
    );
    final isPlaying = value.isPlaying;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.audiotrack, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Slider(
              value: sliderValue,
              min: 0.0,
              max: maxMillis,
              onChanged: (value) {
                final clamped = value.clamp(0.0, maxMillis);
                final target = Duration(milliseconds: clamped.round());
                _controller.seekTo(target);
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(position)),
                Text(_formatDuration(duration)),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _togglePlay,
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
              label: Text(
                isPlaying
                    ? context.l10n('common.pause')
                    : context.l10n('common.play'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentPreview extends StatelessWidget {
  const _DocumentPreview({required this.item});

  final IncomingShare item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final extension =
        p.extension(item.path).replaceFirst('.', '').toUpperCase();
    final label = extension.isNotEmpty ? extension : null;
    final messenger = ScaffoldMessenger.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description,
              size: 72,
              color: theme.colorScheme.secondary,
            ),
            if (label != null) ...[
              const SizedBox(height: 8),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              item.effectiveName,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final result = await OpenFilex.open(item.path);
                if (result.type != ResultType.done) {
                  final reason =
                      result.message ?? context.l10n('common.unknownError');
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        context.l10n(
                          'shareReview.error.openFile',
                          params: {'error': reason},
                        ),
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: Text(context.l10n('common.open')),
            ),
          ],
        ),
      ),
    );
  }
}

class _GenericPreview extends StatelessWidget {
  const _GenericPreview({
    required this.icon,
    required this.name,
    required this.color,
  });

  final IconData icon;
  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: color),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingPreview extends StatelessWidget {
  const _MissingPreview({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n('shareReview.error.fileNotFound'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                name,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.path});

  final String path;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller =
        VideoPlayerController.file(File(widget.path))
          ..setLooping(true)
          ..initialize()
              .then((_) {
                if (!mounted) return;
                setState(() => _initialized = true);
                _controller.play();
              })
              .catchError((err) {
                if (!mounted) return;
                setState(() => _error = err);
              });
    _controller.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_initialized) return;
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Container(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.6),
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n('shareReview.error.videoLoad'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }

    final aspectRatio = _controller.value.aspectRatio;
    final ratio =
        aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
    final isPlaying = _controller.value.isPlaying;

    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(aspectRatio: ratio, child: VideoPlayer(_controller)),
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: VideoProgressIndicator(
              _controller,
              allowScrubbing: true,
              colors: VideoProgressColors(
                playedColor: theme.colorScheme.primary,
                backgroundColor: Colors.white24,
                bufferedColor: Colors.white38,
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: isPlaying ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(24),
              child: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 48,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
