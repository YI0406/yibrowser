import 'dart:io';
import 'dart:math' as math;
import 'package:open_filex/open_filex.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _DragHandle { none, start, end }

class _ExportFormatOption {
  final String id;
  final String label;
  final String extension;
  final String ffmpegArguments;
  final bool isVideo;

  const _ExportFormatOption({
    required this.id,
    required this.label,
    required this.extension,
    required this.ffmpegArguments,
    this.isVideo = false,
  });
}

const List<_ExportFormatOption> _audioFormatOptions = [
  _ExportFormatOption(
    id: 'mp3',
    label: 'MP3 (音訊)',
    extension: 'mp3',
    ffmpegArguments: '-vn -c:a libmp3lame -qscale:a 2',
  ),
  _ExportFormatOption(
    id: 'm4a',
    label: 'M4A (AAC 音訊)',
    extension: 'm4a',
    ffmpegArguments: '-vn -c:a aac -b:a 192k',
  ),
  _ExportFormatOption(
    id: 'aac',
    label: 'AAC',
    extension: 'aac',
    ffmpegArguments: '-vn -c:a aac -b:a 192k',
  ),
  _ExportFormatOption(
    id: 'wav',
    label: 'WAV (PCM)',
    extension: 'wav',
    ffmpegArguments: '-vn -c:a pcm_s16le -ar 44100',
  ),
];

const List<_ExportFormatOption> _videoFormatOptions = [
  _ExportFormatOption(
    id: 'mp4_h264',
    label: 'MP4 (H.264 + AAC)',
    extension: 'mp4',
    ffmpegArguments:
        '-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a aac -b:a 192k',
    isVideo: true,
  ),
  _ExportFormatOption(
    id: 'mov_h264',
    label: 'MOV (H.264 + AAC)',
    extension: 'mov',
    ffmpegArguments:
        '-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a aac -b:a 192k',
    isVideo: true,
  ),
  _ExportFormatOption(
    id: 'mkv_h264',
    label: 'MKV (H.264 + AAC)',
    extension: 'mkv',
    ffmpegArguments:
        '-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a aac -b:a 192k',
    isVideo: true,
  ),
  _ExportFormatOption(
    id: 'webm_vp9',
    label: 'WebM (VP9 + Opus)',
    extension: 'webm',
    ffmpegArguments:
        '-c:v libvpx-vp9 -b:v 1.5M -pix_fmt yuv420p -c:a libopus -b:a 160k',
    isVideo: true,
  ),
];

class MediaSegmentExportPage extends StatefulWidget {
  final String sourcePath;
  final String? displayName;
  final String mediaType;
  final Duration? initialDuration;

  const MediaSegmentExportPage({
    super.key,
    required this.sourcePath,
    this.displayName,
    this.mediaType = 'video',
    this.initialDuration,
  });

  @override
  State<MediaSegmentExportPage> createState() => _MediaSegmentExportPageState();
}

class _MediaSegmentExportPageState extends State<MediaSegmentExportPage> {
  static const double _kMinSelectableSeconds = 0.1;
  static const double _kPlaybackHitSlop = 12.0;
  late final TextEditingController _nameController;
  late final List<_ExportFormatOption> _formatOptions;
  late _ExportFormatOption _selectedFormatOption;
  late String _baseName;

  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _loadError;
  String? _previewError;

  Duration _mediaDuration = Duration.zero;
  Duration _currentPosition = Duration.zero;
  double _durationSeconds = 0.0;
  RangeValues _selection = const RangeValues(0.0, 0.0);
  bool _selectionInitialized = false;
  bool _isPlaying = false;

  bool _waveformGenerating = false;
  String? _waveformError;
  String? _waveformImagePath;
  String? _waveformDirectoryPath;
  bool _waveformScrubbing = false;
  Duration _scrubPreviewPosition = Duration.zero;
  bool _wasPlayingBeforeScrub = false;

  // --- Selection handle dragging on waveform ---
  static const double _kHandleHitWidth = 36.0;
  static const double _kHandleMinGap = 0.05; // seconds
  bool _handleDragging = false;
  bool _downNearHandle = false;
  _DragHandle _activeHandle = _DragHandle.none;
  Duration _handleTooltipTime = Duration.zero;

  // --- RangeSlider value indicator toggle ---
  bool _rangeDragging = false;

  bool _processing = false;
  double? _progress;
  int? _activeSessionId;
  bool _cancelRequested = false;
  String? _lastOutputPath;

  String _lastSuggestedName = '';
  static const String _kLastOutputPathKey = 'last_output_path';
  @override
  void initState() {
    super.initState();
    _formatOptions = _resolveFormatOptions();
    _selectedFormatOption = _formatOptions.firstWhere(
      (option) => option.id == 'mp3',
      orElse: () => _formatOptions.first,
    );
    _baseName = _sanitizeFileName(
      widget.displayName != null && widget.displayName!.trim().isNotEmpty
          ? widget.displayName!
          : p.basenameWithoutExtension(widget.sourcePath),
    );
    if (_baseName.isEmpty) {
      _baseName = 'export';
    }
    _nameController = TextEditingController();
    _applyDuration(widget.initialDuration);
    _updateSuggestedFileName(force: true);
    _initializeController();
    _loadLastOutputPath();
  }

  Future<void> _loadLastOutputPath() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString(_kLastOutputPathKey);
      if (saved != null && saved.isNotEmpty && File(saved).existsSync()) {
        if (mounted) {
          setState(() => _lastOutputPath = saved);
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerUpdate);
    _controller?.dispose();
    _nameController.dispose();
    final sessionId = _activeSessionId;
    if (sessionId != null) {
      () async {
        try {
          await FFmpegKit.cancel(sessionId);
        } catch (_) {}
      }();
    }
    _deleteWaveformDirectory();
    super.dispose();
  }

  void _applyDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
      return;
    }
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) {
      return;
    }
    _mediaDuration = duration;
    _durationSeconds = seconds;
    if (!_selectionInitialized ||
        _selection.end <= 0 ||
        _selection.end > seconds) {
      _selection = RangeValues(0.0, seconds);
      _selectionInitialized = true;
    } else {
      final double start = _selection.start.clamp(0.0, seconds).toDouble();
      final double end = _selection.end.clamp(start, seconds).toDouble();
      _selection = RangeValues(start, end);
    }
    if (_mediaDuration <= Duration.zero) {
      _scrubPreviewPosition = Duration.zero;
    } else if (_scrubPreviewPosition > _mediaDuration) {
      _scrubPreviewPosition = _mediaDuration;
    }
  }

  List<_ExportFormatOption> _resolveFormatOptions() {
    if (widget.mediaType == 'audio') {
      return List<_ExportFormatOption>.from(_audioFormatOptions);
    }
    return [..._videoFormatOptions, ..._audioFormatOptions];
  }

  Future<void> _initializeController() async {
    final file = File(widget.sourcePath);
    if (!await file.exists()) {
      setState(() {
        _loadError = '找不到來源檔案';
        _initializing = false;
      });
      return;
    }
    try {
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      controller.addListener(_handleControllerUpdate);
      controller.setLooping(false);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _applyDuration(controller.value.duration);
      setState(() {
        _initializing = false;
        _previewError = null;
      });
      if (widget.mediaType == 'audio') {
        _generateWaveformPreview();
      }
    } catch (e) {
      setState(() {
        _initializing = false;
        _previewError = '預覽無法載入: $e';
      });
    }
  }

  void _handleControllerUpdate() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (!mounted) return;
    final end = Duration(milliseconds: (_selection.end * 1000).round());
    final pos = value.position;
    final playing = value.isPlaying;
    if (playing &&
        end > Duration.zero &&
        pos >= end - const Duration(milliseconds: 20)) {
      controller.pause();
      controller.seekTo(end);
    }
    if ((pos - _currentPosition).abs() > const Duration(milliseconds: 150) ||
        playing != _isPlaying) {
      setState(() {
        _currentPosition = pos;
        _isPlaying = controller.value.isPlaying;
        if (!_waveformScrubbing) {
          _scrubPreviewPosition = pos;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('編輯導出'),
        actions: [
          if (_processing && _activeSessionId != null)
            TextButton(
              onPressed: _cancelRequested ? null : _cancelExport,
              child: Text(
                _cancelRequested ? '取消中…' : '取消',
                style: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(child: Text(_loadError!));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                widget.mediaType == 'audio' ? Icons.audiotrack : Icons.movie,
              ),
              title: Text(
                widget.displayName?.trim().isNotEmpty == true
                    ? widget.displayName!
                    : p.basename(widget.sourcePath),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    '來源長度: ' +
                        (_durationSeconds > 0
                            ? _formatReadable(_mediaDuration)
                            : '未知'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '來源路徑: ${widget.sourcePath}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_previewError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _previewError!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          _buildPreviewSection(theme),
          const SizedBox(height: 24),
          _buildSelectionSection(theme),
          const SizedBox(height: 24),
          _buildFormatSection(theme),
          const SizedBox(height: 24),
          if (_processing) ...[
            LinearProgressIndicator(
              value: _progress != null ? _progress!.clamp(0.0, 1.0) : null,
            ),
            const SizedBox(height: 12),
          ],
          ElevatedButton.icon(
            onPressed: _processing ? null : _startExport,
            icon: const Icon(Icons.save_alt),
            label: Text(
              _processing
                  ? '匯出中…'
                  : '匯出選取的${_selectedFormatOption.isVideo ? '視訊' : '音訊'}',
            ),
          ),
          const SizedBox(height: 16),
          // Removed "最近匯出" card here.
        ],
      ),
    );
  }

  Widget _buildPreviewSection(ThemeData theme) {
    if (widget.mediaType == 'audio') {
      return _buildAudioPreview(theme);
    }
    return _buildVideoPreview(theme);
  }

  Widget _buildVideoPreview(ThemeData theme) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceVariant,
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.music_note, size: 48),
            SizedBox(height: 8),
            Text('無法預覽，仍可進行匯出'),
          ],
        ),
      );
    }
    final aspect = controller.value.aspectRatio;
    final durationLabel = _formatReadable(_mediaDuration);
    final position = _currentPosition;
    final double sliderMax = _durationSeconds > 0 ? _durationSeconds : 1.0;

    // Slider 參數
    final sliderValue = position.inMilliseconds / 1000.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: aspect > 0 ? aspect : 16 / 9,
            child: VideoPlayer(controller),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(_formatReadable(position)),
            Expanded(
              child: Slider(
                value: sliderValue.clamp(0.0, sliderMax).toDouble(),
                min: 0.0,
                max: sliderMax,
                onChanged: (value) {
                  final target = Duration(milliseconds: (value * 1000).round());
                  controller.seekTo(target);
                  setState(() {
                    _currentPosition = target;
                    if (!_waveformScrubbing) {
                      _scrubPreviewPosition = target;
                    }
                  });
                },
              ),
            ),
            Text(durationLabel),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.replay_10),
              tooltip: '倒退 10 秒',
              onPressed: () => _seekRelative(const Duration(seconds: -10)),
            ),
            IconButton(
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              iconSize: 40,
              tooltip: _isPlaying ? '暫停' : '播放',
              onPressed: _togglePlayback,
            ),
            IconButton(
              icon: const Icon(Icons.forward_10),
              tooltip: '快轉 10 秒',
              onPressed: () => _seekRelative(const Duration(seconds: 10)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAudioPreview(ThemeData theme) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceVariant,
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.audiotrack, size: 48),
            SizedBox(height: 8),
            Text('無法預覽，仍可進行匯出'),
          ],
        ),
      );
    }

    final durationLabel = _formatReadable(_mediaDuration);
    final position = _currentPosition;
    final double sliderMax = _durationSeconds > 0 ? _durationSeconds : 1.0;

    final sliderValue = position.inMilliseconds / 1000.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildWaveformDisplay(theme),
        if (_waveformError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _waveformError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (_waveformError != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _waveformGenerating ? null : _generateWaveformPreview,
              icon: const Icon(Icons.refresh),
              label: const Text('重新產生波形'),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(_formatReadable(position)),
            Expanded(
              child: Slider(
                value: sliderValue.clamp(0.0, sliderMax).toDouble(),
                min: 0.0,
                max: sliderMax,
                onChanged: (value) {
                  final target = Duration(milliseconds: (value * 1000).round());
                  controller.seekTo(target);
                  setState(() {
                    _currentPosition = target;
                    if (!_waveformScrubbing) {
                      _scrubPreviewPosition = target;
                    }
                  });
                },
              ),
            ),
            Text(durationLabel),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.replay_10),
              tooltip: '倒退 10 秒',
              onPressed: () => _seekRelative(const Duration(seconds: -10)),
            ),
            IconButton(
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              iconSize: 40,
              tooltip: _isPlaying ? '暫停' : '播放',
              onPressed: _togglePlayback,
            ),
            IconButton(
              icon: const Icon(Icons.forward_10),
              tooltip: '快轉 10 秒',
              onPressed: () => _seekRelative(const Duration(seconds: 10)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('提示：長按波形並拖曳可預覽時間（顯示毫秒）', style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _buildWaveformDisplay(ThemeData theme) {
    const double height = 180;
    if (_waveformGenerating) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceVariant,
        ),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }

    final imagePath = _waveformImagePath;
    if (imagePath != null && File(imagePath).existsSync()) {
      return SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : MediaQuery.of(context).size.width;
            const double inset = 16.0;
            final double innerWidth = math.max(0.0, width - inset * 2);
            final playbackFraction = _fractionForDuration(_currentPosition);
            final previewFraction = _fractionForDuration(
              _waveformScrubbing ? _scrubPreviewPosition : _currentPosition,
            );
            final playbackLeft =
                (innerWidth * playbackFraction)
                    .clamp(0.0, innerWidth)
                    .toDouble();
            final previewLeft =
                (innerWidth * previewFraction)
                    .clamp(0.0, innerWidth)
                    .toDouble();
            final tooltipLeft =
                ((previewLeft - 40).clamp(
                  0.0,
                  math.max(0.0, innerWidth - 80),
                )).toDouble();
            final startLeft =
                (((_selection.start /
                            (_durationSeconds > 0 ? _durationSeconds : 1.0)) *
                        innerWidth))
                    .clamp(0.0, innerWidth)
                    .toDouble();
            final endLeft =
                (((_selection.end /
                            (_durationSeconds > 0 ? _durationSeconds : 1.0)) *
                        innerWidth))
                    .clamp(0.0, innerWidth)
                    .toDouble();
            final selectionLeft = math.min(startLeft, endLeft);
            final selectionWidth = (endLeft - startLeft).abs();
            final handleTooltipLeft =
                (() {
                  final base =
                      _activeHandle == _DragHandle.start ? startLeft : endLeft;
                  return ((base - 40).clamp(
                    0.0,
                    math.max(0.0, innerWidth - 80),
                  )).toDouble();
                })();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                const double inset = 16.0;
                final dxAdj = details.localPosition.dx - inset;
                if ((dxAdj - playbackLeft).abs() <= _kPlaybackHitSlop) {
                  return; // 忽略點擊在播放線附近
                }
                _handleWaveformTap(dxAdj, innerWidth);
              },
              onHorizontalDragDown: (details) {
                const double inset = 16.0;
                final dxAdj = details.localPosition.dx - inset;
                // 判定是否在起點/終點握把的可點擊區域
                if ((dxAdj - startLeft).abs() <= _kHandleHitWidth) {
                  _activeHandle = _DragHandle.start;
                  _downNearHandle = true;
                  _handleDragging = true;
                  _handleTooltipTime = Duration(
                    milliseconds: (_selection.start * 1000).round(),
                  );
                  setState(() {}); // 讓 tooltip 及狀態即時更新
                } else if ((dxAdj - endLeft).abs() <= _kHandleHitWidth) {
                  _activeHandle = _DragHandle.end;
                  _downNearHandle = true;
                  _handleDragging = true;
                  _handleTooltipTime = Duration(
                    milliseconds: (_selection.end * 1000).round(),
                  );
                  setState(() {});
                } else {
                  _downNearHandle = false;
                }
              },
              onHorizontalDragUpdate: (details) {
                if (!_handleDragging) return;
                const double inset = 16.0;
                final dxAdj = details.localPosition.dx - inset;
                _updateSelectionFromHandleAtDx(
                  _activeHandle,
                  dxAdj,
                  innerWidth,
                );
              },
              onHorizontalDragEnd: (_) {
                if (_handleDragging) {
                  setState(() {
                    _handleDragging = false;
                    _activeHandle = _DragHandle.none;
                    _downNearHandle = false;
                  });
                  _jumpPlayheadToSelectionStart(); // ★ 這行新加的
                }
              },
              // 僅在沒有鎖定握把時，才允許長按預覽，不與握把拖動手勢搶奪
              onLongPressStart: (details) {
                if (_handleDragging || _downNearHandle) return;
                const double inset = 16.0;
                final dxAdj = details.localPosition.dx - inset;
                if ((dxAdj - playbackLeft).abs() <= _kPlaybackHitSlop)
                  return; // 忽略播放線附近
                _handleWaveformLongPressStart(dxAdj, innerWidth);
              },
              onLongPressMoveUpdate: (details) {
                if (_handleDragging || _downNearHandle) return;
                const double inset = 16.0;
                final dxAdj = details.localPosition.dx - inset;
                if ((dxAdj - playbackLeft).abs() <= _kPlaybackHitSlop) return;
                _handleWaveformLongPressUpdate(dxAdj, innerWidth);
              },
              onLongPressEnd: (_) {
                if (_handleDragging || _downNearHandle) return;
                _handleWaveformLongPressEnd();
              },
              // 佔住垂直拖動手勢以避免外層滾動
              onVerticalDragDown: (_) {},
              onVerticalDragUpdate: (_) {},
              onVerticalDragEnd: (_) {},
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: inset),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(File(imagePath), fit: BoxFit.cover),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.colorScheme.outline.withOpacity(0.4),
                          ),
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withOpacity(0.05),
                              Colors.black.withOpacity(0.05),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Selection highlight
                    Positioned(
                      left: selectionLeft,
                      width: selectionWidth,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        color: theme.colorScheme.primary.withOpacity(0.18),
                      ),
                    ),
                    // Start handle line + knob
                    Positioned(
                      left: startLeft - 1,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Positioned(
                      left: startLeft - 12,
                      top: (height / 2) - 12,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // End handle line + knob
                    Positioned(
                      left: endLeft - 1,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Positioned(
                      left: endLeft - 12,
                      top: (height / 2) - 12,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Playback line（僅在播放中顯示，不可點）
                    if (_isPlaying)
                      Positioned(
                        left: playbackLeft,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          ignoring: true,
                          child: Container(
                            width: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    if (_waveformScrubbing)
                      Positioned(
                        left: tooltipLeft,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _formatPrecise(_scrubPreviewPosition),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    if (_handleDragging)
                      Positioned(
                        left: handleTooltipLeft,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _formatPrecise(_handleTooltipTime),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceVariant,
      ),
      alignment: Alignment.center,
      child: const Text('波形圖尚未就緒'),
    );
  }

  double _fractionForDuration(Duration value) {
    final totalMs = _durationSeconds * 1000.0;
    if (totalMs <= 0) return 0.0;
    return ((value.inMilliseconds / totalMs).clamp(0.0, 1.0)).toDouble();
  }

  double _normalizedWaveformFraction(double dx, double width) {
    if (width <= 0) return 0.0;
    final clampedX = dx.clamp(0.0, width);
    return ((clampedX / width).clamp(0.0, 1.0)).toDouble();
  }

  void _updateSelectionFromHandleAtDx(
    _DragHandle handle,
    double dx,
    double width,
  ) {
    if (handle == _DragHandle.none || _durationSeconds <= 0) return;
    final fraction = _normalizedWaveformFraction(dx, width);
    final seconds =
        (_durationSeconds * fraction).clamp(0.0, _durationSeconds).toDouble();
    double start = _selection.start;
    double end = _selection.end;
    final minGap = math.max(_kHandleMinGap, _kMinSelectableSeconds);
    if (handle == _DragHandle.start) {
      start = math.min(seconds, end - minGap);
      start = start.clamp(0.0, _durationSeconds - minGap);
      _handleTooltipTime = Duration(milliseconds: (start * 1000).round());
    } else {
      end = math.max(seconds, start + minGap);
      end = end.clamp(minGap, _durationSeconds);
      _handleTooltipTime = Duration(milliseconds: (end * 1000).round());
    }
    setState(() {
      _selection = RangeValues(start, end);
    });
  }

  void _jumpPlayheadToSelectionStart() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final start = Duration(milliseconds: (_selection.start * 1000).round());
    controller.seekTo(start);
    if (mounted) {
      setState(() {
        _currentPosition = start;
        if (!_waveformScrubbing) {
          _scrubPreviewPosition = start;
        }
      });
    }
  }

  void _handleWaveformTap(double dx, double width) {
    _seekToWaveformFraction(_normalizedWaveformFraction(dx, width));
  }

  void _handleWaveformLongPressStart(double dx, double width) {
    if (_durationSeconds <= 0) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _wasPlayingBeforeScrub = controller.value.isPlaying;
    controller.pause();
    setState(() {
      _isPlaying = false;
      _waveformScrubbing = true;
    });
    _seekToWaveformFraction(_normalizedWaveformFraction(dx, width));
  }

  void _handleWaveformLongPressUpdate(double dx, double width) {
    if (!_waveformScrubbing) return;
    _seekToWaveformFraction(_normalizedWaveformFraction(dx, width));
  }

  void _handleWaveformLongPressEnd() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_wasPlayingBeforeScrub) {
      controller.play();
    }
    setState(() {
      _isPlaying = _wasPlayingBeforeScrub;
      _waveformScrubbing = false;
    });
    _wasPlayingBeforeScrub = false;
  }

  void _seekToWaveformFraction(double fraction) {
    if (_durationSeconds <= 0) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final totalMs = (_durationSeconds * 1000).round();
    final targetMs = (totalMs * fraction.clamp(0.0, 1.0)).round();
    final target = Duration(milliseconds: targetMs);
    controller.seekTo(target);
    setState(() {
      _currentPosition = target;
      _scrubPreviewPosition = target;
    });
  }

  Future<void> _generateWaveformPreview() async {
    if (_waveformGenerating) return;
    if (widget.sourcePath.isEmpty) return;

    _deleteWaveformDirectory();
    setState(() {
      _waveformGenerating = true;
      _waveformError = null;
      _waveformImagePath = null;
    });

    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('media_waveform_');
      final outputPath = p.join(tempDir.path, 'waveform.png');
      const filter = 'aformat=channel_layouts=mono,showwavespic=s=1600x400';
      final command =
          '-y -i ${_quotePath(widget.sourcePath)} -filter_complex "$filter" -frames:v 1 ${_quotePath(outputPath)}';
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      final success = returnCode != null && returnCode.isValueSuccess();
      if (!mounted) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
        return;
      }
      if (success) {
        setState(() {
          _waveformImagePath = outputPath;
          _waveformDirectoryPath = tempDir!.path;
          _waveformError = null;
        });
      } else {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
        setState(() {
          _waveformDirectoryPath = null;
          _waveformError = '波形圖產生失敗，請重試。';
        });
      }
    } catch (e) {
      try {
        if (tempDir != null) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _waveformDirectoryPath = null;
          _waveformError = '波形圖產生失敗: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _waveformGenerating = false;
        });
      }
    }
  }

  void _deleteWaveformDirectory() {
    final dirPath = _waveformDirectoryPath;
    if (dirPath != null) {
      try {
        final dir = Directory(dirPath);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
    _waveformDirectoryPath = null;
    _waveformImagePath = null;
  }

  Widget _buildSelectionSection(ThemeData theme) {
    if (_durationSeconds <= 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [Text('無法取得媒體長度，請直接匯出整段。')],
      );
    }
    final selection = _selection;
    final start = selection.start;
    final end = selection.end;
    final labels = RangeLabels(
      _formatPrecise(Duration(milliseconds: (start * 1000).round())),
      _formatPrecise(Duration(milliseconds: (end * 1000).round())),
    );
    final clipSeconds = math.max(0.0, end - start);
    final clipDuration = Duration(milliseconds: (clipSeconds * 1000).round());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('選取範圍', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            showValueIndicator:
                _rangeDragging
                    ? ShowValueIndicator.always
                    : ShowValueIndicator.never,
          ),
          child: RangeSlider(
            values: selection,
            min: 0.0,
            max: _durationSeconds,
            labels: labels,
            onChangeStart: (_) => setState(() => _rangeDragging = true),
            onChangeEnd: (_) {
              setState(() => _rangeDragging = false);
              _jumpPlayheadToSelectionStart(); // ★ 這行新加的
            },
            onChanged: (values) {
              setState(() {
                _selection = RangeValues(
                  values.start.clamp(0.0, _durationSeconds).toDouble(),
                  values.end.clamp(0.0, _durationSeconds).toDouble(),
                );
              });
            },
          ),
        ),
        Text(
          '起點：${_formatPrecise(Duration(milliseconds: (start * 1000).round()))}',
        ),
        Text(
          '終點：${_formatPrecise(Duration(milliseconds: (end * 1000).round()))}',
        ),
        Text(
          '長度：${_formatPrecise(clipDuration)} (${clipSeconds.toStringAsFixed(3)} 秒)',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _setStartFromCurrent,
              icon: const Icon(Icons.flag),
              label: const Text('以目前時間為起點'),
            ),
            OutlinedButton.icon(
              onPressed: _setEndFromCurrent,
              icon: const Icon(Icons.outlined_flag),
              label: const Text('以目前時間為終點'),
            ),
            OutlinedButton.icon(
              onPressed: _previewSelection,
              icon: const Icon(Icons.play_circle_fill),
              label: const Text('預覽選取範圍'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFormatSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('輸出設定', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        DropdownButtonFormField<_ExportFormatOption>(
          value: _selectedFormatOption,
          items:
              _formatOptions
                  .map(
                    (option) => DropdownMenuItem(
                      value: option,
                      child: Text(option.label),
                    ),
                  )
                  .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _selectedFormatOption = value);
            _updateSuggestedFileName();
          },
          decoration: const InputDecoration(
            labelText: '輸出格式',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: '輸出檔名',
            border: const OutlineInputBorder(),
            helperText:
                '檔案將儲存到與原始檔案相同的資料夾（副檔名會使用 .${_selectedFormatOption.extension}）',
          ),
        ),
      ],
    );
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      final start = Duration(milliseconds: (_selection.start * 1000).round());
      final end = Duration(milliseconds: (_selection.end * 1000).round());
      final pos = controller.value.position;
      if (pos >= end) {
        await controller.seekTo(start);
      }
      await controller.play();
    }
    if (mounted) {
      setState(() => _isPlaying = controller.value.isPlaying);
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final durationMs =
        _mediaDuration.inMilliseconds > 0
            ? _mediaDuration.inMilliseconds
            : controller.value.duration.inMilliseconds;
    final maxMs = math.max(durationMs, 0);
    var target =
        controller.value.position.inMilliseconds + delta.inMilliseconds;
    if (target < 0) target = 0;
    if (target > maxMs) target = maxMs;
    await controller.seekTo(Duration(milliseconds: target));
    if (mounted) {
      setState(() {
        final targetDuration = Duration(milliseconds: target);
        _currentPosition = targetDuration;
        if (!_waveformScrubbing) {
          _scrubPreviewPosition = targetDuration;
        }
      });
    }
  }

  Future<void> _previewSelection() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final start = Duration(milliseconds: (_selection.start * 1000).round());
    await controller.seekTo(start);
    await controller.play();
    if (mounted) {
      setState(() {
        _isPlaying = true;
        _currentPosition = start;
        if (!_waveformScrubbing) {
          _scrubPreviewPosition = start;
        }
      });
    }
  }

  void _setStartFromCurrent() {
    if (_durationSeconds <= 0) return;
    final current = _currentPosition.inMilliseconds / 1000.0;
    double newStart = current.clamp(0.0, _durationSeconds).toDouble();
    double newEnd = _selection.end.clamp(0.0, _durationSeconds).toDouble();
    final double minGap = math.min(_kMinSelectableSeconds, _durationSeconds);
    if (newEnd - newStart < minGap) {
      newEnd = math.min(_durationSeconds, newStart + minGap);
      if (newEnd - newStart < minGap) {
        newStart = math.max(0.0, newEnd - minGap);
      }
    }
    setState(() {
      _selection = RangeValues(newStart, newEnd);
    });
  }

  void _setEndFromCurrent() {
    if (_durationSeconds <= 0) return;
    final current = _currentPosition.inMilliseconds / 1000.0;
    double newEnd = current.clamp(0.0, _durationSeconds).toDouble();
    double newStart = _selection.start.clamp(0.0, _durationSeconds).toDouble();
    final double minGap = math.min(_kMinSelectableSeconds, _durationSeconds);
    if (newEnd - newStart < minGap) {
      newStart = math.max(0.0, newEnd - minGap);
      if (newEnd - newStart < minGap) {
        newEnd = math.min(_durationSeconds, newStart + minGap);
      }
    }
    setState(() {
      _selection = RangeValues(newStart, newEnd);
    });
  }

  void _updateSuggestedFileName({bool force = false}) {
    final ext = _selectedFormatOption.extension;
    final suggestion = '${_baseName}_clip.$ext';
    final current = _nameController.text.trim();
    final shouldReplace =
        force || current.isEmpty || current == _lastSuggestedName;

    if (shouldReplace) {
      _lastSuggestedName = suggestion;
      _nameController.value = TextEditingValue(
        text: suggestion,
        selection: TextSelection.collapsed(offset: suggestion.length),
      );
    } else if (!current.toLowerCase().endsWith('.${ext.toLowerCase()}')) {
      final withoutExt = _removeExtension(current);
      final updated = '$withoutExt.$ext';
      _nameController.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length),
      );
    }
  }

  String _removeExtension(String name) {
    final ext = p.extension(name);
    if (ext.isEmpty) return name;
    return name.substring(0, name.length - ext.length);
  }

  Future<void> _startExport() async {
    if (_processing) return;
    if (_durationSeconds <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          content: Text('無法取得媒體長度'),
        ),
      );
      return;
    }
    final start = Duration(milliseconds: (_selection.start * 1000).round());
    final end = Duration(milliseconds: (_selection.end * 1000).round());
    final clipDuration = end - start;
    if (clipDuration <= Duration.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          content: Text('請選擇有效的時間範圍'),
        ),
      );
      return;
    }
    final formatOption = _selectedFormatOption;
    final extension = formatOption.extension.toLowerCase();
    var outputName = _nameController.text.trim();
    if (outputName.isEmpty) {
      _updateSuggestedFileName(force: true);
      outputName = _nameController.text.trim();
    }
    if (!outputName.toLowerCase().endsWith('.$extension')) {
      outputName = '${_removeExtension(outputName)}.${formatOption.extension}';
    }
    outputName = _sanitizeFileName(outputName);
    if (outputName.isEmpty) {
      outputName = '${_baseName}_clip.${formatOption.extension}';
    }
    if (_nameController.text.trim() != outputName) {
      _lastSuggestedName = outputName;
      _nameController.value = TextEditingValue(
        text: outputName,
        selection: TextSelection.collapsed(offset: outputName.length),
      );
    }
    final dir = File(widget.sourcePath).parent;
    final outputPath = _uniqueOutputPath(dir.path, outputName);
    final buffer = StringBuffer('-y ');
    if (start > Duration.zero) {
      buffer.write('-ss ${_ffmpegTimestamp(start)} ');
    }
    buffer.write("-i ${_quotePath(widget.sourcePath)} ");
    if (clipDuration > Duration.zero) {
      buffer.write('-t ${_ffmpegTimestamp(clipDuration)} ');
    }
    buffer.write('${formatOption.ffmpegArguments} ');
    buffer.write(_quotePath(outputPath));

    setState(() {
      _processing = true;
      _progress = 0.0;
      _cancelRequested = false;
      _lastOutputPath = null;
    });

    try {
      final session = await FFmpegKit.executeAsync(
        buffer.toString(),
        (session) async {
          final rc = await session.getReturnCode();
          final success = rc != null && rc.isValueSuccess();
          final cancelled = rc != null && rc.isValueCancel();
          if (mounted) {
            setState(() {
              _processing = false;
              _progress = null;
              _activeSessionId = null;
              _cancelRequested = false;
              if (success) {
                _lastOutputPath = outputPath;
              }
            });
          }
          // Persist last output path after setState and before snack/share logic
          if (success) {
            try {
              final sp = await SharedPreferences.getInstance();
              await sp.setString(_kLastOutputPathKey, outputPath);
            } catch (_) {}
          }
          if (mounted) {
            // Immediately open the share sheet after export success
            if (success) {
              try {
                await Share.shareXFiles([XFile(outputPath)]);
              } catch (_) {}
            }
            final messenger = ScaffoldMessenger.of(context);
            if (success) {
              messenger.showSnackBar(
                SnackBar(
                  duration: Duration(seconds: 1),
                  content: Text('匯出完成：${p.basename(outputPath)}'),
                ),
              );
            } else if (cancelled) {
              messenger.showSnackBar(
                const SnackBar(
                  duration: Duration(seconds: 1),
                  content: Text('已取消匯出'),
                ),
              );
              try {
                final file = File(outputPath);
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (_) {}
            } else {
              messenger.showSnackBar(
                const SnackBar(
                  duration: Duration(seconds: 1),
                  content: Text('匯出失敗，請稍後再試'),
                ),
              );
              try {
                final file = File(outputPath);
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (_) {}
            }
          }
        },
        null,
        (statistics) {
          if (!mounted) return;
          final totalMs = clipDuration.inMilliseconds;
          if (totalMs <= 0) return;
          final time = statistics.getTime();
          if (time == null) return;
          final progress = (time / totalMs).clamp(0.0, 1.0);
          setState(() {
            _progress = progress;
          });
        },
      );
      final sessionId = await session.getSessionId();
      if (mounted) {
        setState(() {
          _activeSessionId = sessionId;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _progress = null;
          _activeSessionId = null;
          _cancelRequested = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: Duration(seconds: 1), content: Text('啟動轉檔失敗: $e')),
        );
      }
    }
  }

  Future<void> _cancelExport() async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    setState(() {
      _cancelRequested = true;
    });
    try {
      await FFmpegKit.cancel(sessionId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 1),
            content: Text('取消失敗，請稍後再試'),
          ),
        );
      }
    }
  }

  void _openOutputLocation(String path) {
    // Placeholder: on mobile we cannot directly open file explorer.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: Duration(seconds: 1), content: Text('已匯出到：$path')),
    );
  }

  Future<void> _openFile(String path) async {
    try {
      final result = await OpenFilex.open(path);
      if (mounted && result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: Duration(seconds: 1),
            content: Text('無法開啟檔案（${result.message}）'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: Duration(seconds: 1), content: Text('開啟檔案失敗：$e')),
        );
      }
    }
  }

  String _quotePath(String path) {
    final escaped = path.replaceAll("'", "'\\''");
    return "'${escaped}'";
  }

  String _ffmpegTimestamp(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    final millis = d.inMilliseconds % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  String _formatPrecise(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    final millis = d.inMilliseconds % 1000;
    final msLabel = millis.toString().padLeft(3, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}:$msLabel';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}:$msLabel';
  }

  String _formatReadable(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _sanitizeFileName(String name) {
    final cleaned =
        name
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
            .replaceAll('\n', ' ')
            .trim();
    if (cleaned.isEmpty) return 'export';
    return cleaned;
  }

  String _uniqueOutputPath(String directory, String name) {
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var attempt = p.join(directory, '$base$ext');
    var counter = 1;
    while (File(attempt).existsSync()) {
      attempt = p.join(directory, '$base($counter)$ext');
      counter++;
      if (counter > 99) {
        break;
      }
    }
    return attempt;
  }
}
