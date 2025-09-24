import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

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

class _ShareReviewPageState extends State<ShareReviewPage> {
  late final PageController _pageController;
  int _currentIndex = 0;
  _ShareReviewAction? _processing;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _handleConfirm() async {
    if (_processing != null) return;
    setState(() => _processing = _ShareReviewAction.confirm);
    ShareReviewResult? result;
    try {
      result = await widget.onConfirm(
        List<IncomingShare>.unmodifiable(widget.items),
      );
    } catch (err) {
      if (!mounted) return;
      setState(() => _processing = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('匯入失敗：$err')));
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
      result = await widget.onDiscard(
        List<IncomingShare>.unmodifiable(widget.items),
      );
    } catch (err) {
      if (!mounted) return;
      setState(() => _processing = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('取消匯入失敗：$err')));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.items;
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
          title: const Text('匯入預覽'),
          centerTitle: true,
          leading: TextButton(
            onPressed: _processing == null ? _handleCancel : null,
            child: const Text('取消'),
          ),
          actions: [
            TextButton(
              onPressed: _processing == null ? _handleConfirm : null,
              child: const Text('完成'),
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
                        items.length > 1 ? '左右滑動以檢視所有項目' : '預覽內容',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
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
                                ? '保存中...'
                                : '取消中...',
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
      return _GenericPreview(
        icon: Icons.audiotrack,
        name: item.effectiveName,
        color: theme.colorScheme.primary,
      );
    }

    return _GenericPreview(
      icon: Icons.insert_drive_file,
      name: item.effectiveName,
      color: theme.colorScheme.secondary,
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
                '找不到檔案',
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
                '影片載入失敗',
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
