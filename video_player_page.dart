import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:volume_controller/volume_controller.dart';

import 'native_player.dart';
import 'soure.dart';

class VideoPlayerPage extends StatefulWidget {
  final String path;
  final String title;
  final Duration? startAt;
  final List<DownloadTask>? playlist;
  final int? initialIndex;

  const VideoPlayerPage({
    super.key,
    required this.path,
    this.title = '播放器',
    this.startAt,
    this.playlist,
    this.initialIndex,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver {
  final NativePlayerController _player = NativePlayerController();
  final VolumeController _systemVolume = VolumeController.instance;
  final GlobalKey _surfaceKey = GlobalKey();
  late String _currentPath;
  late String _currentTitle;
  Duration? _pendingStartAt;
  int? _currentPlaylistIndex;
  List<DownloadTask> _playlist = <DownloadTask>[];
  bool _completionHandled = false;

  static final Map<String, Duration> _resumePositions = {};

  bool _showControls = true;
  Timer? _hideTimer;
  bool _dragging = false;
  Duration _dragTarget = Duration.zero;
  double _playbackRate = 1.0;
  double _currentVolume = 1.0;
  bool _initialized = false;
  bool _autoPiPRequested = false;
  Duration _lastPersistedPosition = Duration.zero;

  NativePlayerValue _latestValue = const NativePlayerValue.uninitialized();

  Offset? _panStartPosition;
  Offset _panDelta = Offset.zero;
  Duration _seekGestureBase = Duration.zero;
  Duration _seekPreviewPosition = Duration.zero;
  bool _isSeekGesture = false;
  bool _isVolumeGesture = false;
  bool _showSeekOverlay = false;
  bool _showVolumeOverlay = false;
  double _volumeGestureBase = 0.0;
  double _volumePreview = 0.0;
  bool _speedBoostActive = false;
  double _speedBoostOriginalRate = 1.0;
  bool _showSpeedOverlay = false;
  Size _videoSurfaceSize = Size.zero;
  bool get _hasPlaylist =>
      _playlist.isNotEmpty && _currentPlaylistIndex != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentPath = widget.path;
    _currentTitle = widget.title;
    _pendingStartAt = widget.startAt;
    if (widget.playlist != null && widget.playlist!.isNotEmpty) {
      _playlist = List<DownloadTask>.from(widget.playlist!);
      int? resolvedIndex = widget.initialIndex;
      if (resolvedIndex == null ||
          resolvedIndex < 0 ||
          resolvedIndex >= _playlist.length) {
        resolvedIndex = _playlist.indexWhere(
          (task) => task.savePath == widget.path,
        );
      }
      if (resolvedIndex != null &&
          resolvedIndex >= 0 &&
          resolvedIndex < _playlist.length) {
        _currentPlaylistIndex = resolvedIndex;
        final entry = _playlist[resolvedIndex];
        _currentPath = entry.savePath;
        _currentTitle = entry.name ?? p.basename(entry.savePath);
      }
    }
    _player.addListener(_handlePlayerValue);
    _initializePlayer();
    _bindVolume();
  }

  Future<void> _initializePlayer() async {
    await _player.setSource(_currentPath);
    final initial = _pendingStartAt;
    if (initial != null && initial > Duration.zero) {
      _dragTarget = initial;
    } else {
      final resume =
          _resumePositions[_currentPath] ??
          AppRepo.I.resumePositionFor(_currentPath);
      if (resume != null && resume > Duration.zero) {
        _dragTarget = resume;
      } else {
        _dragTarget = Duration.zero;
      }
    }
    _pendingStartAt = null;
    _completionHandled = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateViewport());
  }

  void _bindVolume() {
    _systemVolume.showSystemUI = true;
    _systemVolume.addListener((value) async {
      _currentVolume = value;
      try {
        await _player.setVolume(value);
      } catch (_) {}
      if (mounted) setState(() {});
    });
    Future.microtask(() async {
      try {
        _currentVolume = await _systemVolume.getVolume();
        await _player.setVolume(_currentVolume);
      } catch (_) {}
      if (mounted) setState(() {});
    });
  }

  void _handlePlayerValue() {
    final previous = _latestValue;
    final value = _player.value;
    _latestValue = value;
    final newSpeed = value.speed;
    if ((newSpeed - _playbackRate).abs() > 0.0001) {
      _playbackRate = newSpeed;
      if (mounted) setState(() {});
    }
    final pos = value.position;
    if ((pos - _lastPersistedPosition).abs() >= const Duration(seconds: 5)) {
      _lastPersistedPosition = pos;
      _resumePositions[_currentPath] = pos;
      AppRepo.I.setResumePosition(_currentPath, pos);
    }
    if (!_initialized && value.isInitialized) {
      _initialized = true;
      if (_dragTarget > Duration.zero) {
        unawaited(_player.seekTo(_dragTarget));
      }
      if (!value.isPlaying) {
        unawaited(_player.play());
      }
      _scheduleHideControls();
    }
    if (value.isCompleted && !previous.isCompleted) {
      _handlePlaybackCompleted();
    } else if (!value.isCompleted) {
      _completionHandled = false;
    }
  }

  int? _nextPlayableIndex(int current) {
    if (_playlist.isEmpty) return null;
    for (int i = current + 1; i < _playlist.length; i++) {
      final task = _playlist[i];
      final type = AppRepo.I.resolvedTaskType(task);
      final exists = File(task.savePath).existsSync();
      if (exists && (type == 'video' || type == 'audio')) {
        return i;
      }
    }
    return null;
  }

  Future<void> _switchToPlaylistIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    final task = _playlist[index];
    final type = AppRepo.I.resolvedTaskType(task);
    final exists = File(task.savePath).existsSync();
    if (!(exists && (type == 'video' || type == 'audio'))) {
      final fallback = _nextPlayableIndex(index);
      if (fallback != null) {
        await _switchToPlaylistIndex(fallback);
      }
      return;
    }
    final currentValue = _player.value;
    final currentPos = currentValue.position;
    _resumePositions[_currentPath] = currentPos;
    AppRepo.I.setResumePosition(_currentPath, currentPos);
    final newTitle = task.name ?? p.basename(task.savePath);
    setState(() {
      _currentPlaylistIndex = index;
      _currentPath = task.savePath;
      _currentTitle = newTitle;
      _pendingStartAt = null;
      _dragTarget = Duration.zero;
      _initialized = false;
      _completionHandled = false;
    });
    await _initializePlayer();
  }

  void _handlePlaybackCompleted() {
    if (!_hasPlaylist) return;
    if (_completionHandled) return;
    final currentIndex = _currentPlaylistIndex;
    if (currentIndex == null) return;
    final nextIndex = _nextPlayableIndex(currentIndex);
    if (nextIndex == null) return;
    _completionHandled = true;
    unawaited(_switchToPlaylistIndex(nextIndex));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_handlePlayerValue);
    final value = _player.value;
    final pos = value.position;
    _resumePositions[_currentPath] = pos;
    AppRepo.I.setResumePosition(_currentPath, pos);
    if (!value.inPip) {
      // Ensure playback stops when leaving the page to avoid lingering native sessions.
      unawaited(_player.pause());
      unawaited(_player.stopPictureInPicture());
    }
    _hideTimer?.cancel();
    try {
      _systemVolume.removeListener();
    } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.inactive && !_autoPiPRequested) {
      _autoPiPRequested = true;
      () async {
        if (await _player.isPiPPossible()) {
          await _player.enterPictureInPicture();
        }
      }();
    } else if (state == AppLifecycleState.resumed) {
      _autoPiPRequested = false;
      () async {
        await _player.stopPictureInPicture();
      }();
    }
  }

  void _updateViewport() {
    if (!Platform.isIOS) return;
    final ctx = _surfaceKey.currentContext;
    if (ctx == null) return;
    final render = ctx.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;
    final size = render.size;
    final offset = render.localToGlobal(Offset.zero);
    final rect = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    unawaited(_player.updateViewport(rect));
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _scheduleHideControls();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!_dragging && mounted && _player.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _onDragStart(double valueMs) {
    _dragging = true;
    _dragTarget = Duration(milliseconds: valueMs.round());
    setState(() {});
  }

  void _onDragUpdate(double valueMs) {
    _dragTarget = Duration(milliseconds: valueMs.round());
    setState(() {});
  }

  Future<void> _onDragEnd(double valueMs) async {
    _dragging = false;
    _dragTarget = Duration(milliseconds: valueMs.round());
    await _player.seekTo(_dragTarget);
    if (_player.value.isPlaying) _scheduleHideControls();
    setState(() {});
  }

  Future<void> _togglePlayPause() async {
    if (_player.value.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _scheduleHideControls();
  }

  Future<void> _changeRate(double rate) async {
    _playbackRate = rate;
    if (_speedBoostActive) {
      _speedBoostOriginalRate = rate;
    }
    await _player.setPlaybackRate(rate);
    setState(() {});
  }

  Future<void> _enterPiP() async {
    if (await _player.enterPictureInPicture()) {
      setState(() {});
    }
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

  String _fmtDelta(Duration diff) {
    final prefix = diff.isNegative ? '-' : '+';
    final abs = diff.abs();
    final h = abs.inHours;
    final m = abs.inMinutes % 60;
    final s = abs.inSeconds % 60;
    final body =
        h > 0
            ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
            : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$prefix$body';
  }

  Widget _buildOverlayContainer(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  void _handlePanDown(DragDownDetails details) {
    _panStartPosition = details.localPosition;
    _panDelta = Offset.zero;
    _seekGestureBase = _latestValue.position;
    _seekPreviewPosition = _seekGestureBase;
    _volumeGestureBase = _currentVolume;
    _volumePreview = _currentVolume;
    _isSeekGesture = false;
    _isVolumeGesture = false;
    _showSeekOverlay = false;
    _showVolumeOverlay = false;
    _hideTimer?.cancel();
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_panStartPosition == null) return;
    _panDelta += details.delta;
    const threshold = 12.0;
    final absDx = _panDelta.dx.abs();
    final absDy = _panDelta.dy.abs();
    if (!_isSeekGesture && !_isVolumeGesture) {
      if (absDx > threshold && absDx > absDy) {
        _isSeekGesture = true;
        _showSeekOverlay = true;
        unawaited(_endSpeedBoost());
      } else if (absDy > threshold && absDy > absDx) {
        _isVolumeGesture = true;
        _showVolumeOverlay = true;
        unawaited(_endSpeedBoost());
      }
    }

    if (_isSeekGesture) {
      final durationMs = _latestValue.duration.inMilliseconds;
      if (durationMs > 0) {
        final fallbackWidth = MediaQuery.of(context).size.width;
        final width =
            _videoSurfaceSize.width > 0
                ? _videoSurfaceSize.width
                : (fallbackWidth <= 0 ? 1.0 : fallbackWidth);
        double fraction = 0;
        if (width > 0) fraction = _panDelta.dx / width;
        final targetMs =
            (_seekGestureBase.inMilliseconds + (fraction * durationMs)).round();
        final clampedMs = targetMs.clamp(0, durationMs).toInt();
        _seekPreviewPosition = Duration(milliseconds: clampedMs);
        setState(() {});
      }
    } else if (_isVolumeGesture) {
      final fallbackHeight = MediaQuery.of(context).size.height;
      final height =
          _videoSurfaceSize.height > 0
              ? _videoSurfaceSize.height
              : (fallbackHeight <= 0 ? 1.0 : fallbackHeight);
      double fraction = 0;
      if (height > 0) fraction = -_panDelta.dy / height;
      final double targetVolume =
          ((_volumeGestureBase + fraction).clamp(0.0, 1.0) as num).toDouble();
      _volumePreview = targetVolume;
      _currentVolume = targetVolume;
      setState(() {});
      unawaited(_systemVolume.setVolume(targetVolume));
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_isSeekGesture) {
      final target = _seekPreviewPosition;
      unawaited(_player.seekTo(target));
    }
    _resetGestureState();
  }

  void _handlePanCancel() {
    _resetGestureState();
  }

  void _resetGestureState() {
    final shouldUpdate =
        _showSeekOverlay ||
        _showVolumeOverlay ||
        _isSeekGesture ||
        _isVolumeGesture;
    _panStartPosition = null;
    _panDelta = Offset.zero;
    _isSeekGesture = false;
    _isVolumeGesture = false;
    if (shouldUpdate) {
      setState(() {
        _showSeekOverlay = false;
        _showVolumeOverlay = false;
      });
    } else {
      _showSeekOverlay = false;
      _showVolumeOverlay = false;
    }
    _scheduleHideControls();
  }

  Future<void> _startSpeedBoost() async {
    if (_speedBoostActive) return;
    _speedBoostActive = true;
    _speedBoostOriginalRate = _latestValue.speed;
    _showSpeedOverlay = true;
    if (mounted) setState(() {});
    if (_latestValue.isInitialized && !_latestValue.isPlaying) {
      unawaited(_player.play());
    }
    unawaited(_player.setPlaybackRate(4.0));
  }

  Future<void> _endSpeedBoost() async {
    final wasActive = _speedBoostActive;
    _speedBoostActive = false;
    final shouldUpdate = _showSpeedOverlay;
    _showSpeedOverlay = false;
    if (shouldUpdate && mounted) setState(() {});
    if (wasActive) {
      final targetRate = _speedBoostOriginalRate;
      unawaited(_player.setPlaybackRate(targetRate));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.of(context).padding;
    final title = _currentTitle;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<NativePlayerValue>(
          valueListenable: _player,
          builder: (context, value, _) {
            final totalDuration = value.duration;
            final duration =
                totalDuration > Duration.zero
                    ? totalDuration
                    : const Duration(seconds: 1);
            final position = _dragging ? _dragTarget : value.position;
            final aspectRatio = value.aspectRatio;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _togglePlayPause,
              onPanDown: _handlePanDown,
              onPanUpdate: _handlePanUpdate,
              onPanEnd: _handlePanEnd,
              onPanCancel: _handlePanCancel,
              onLongPressStart: (_) => unawaited(_startSpeedBoost()),
              onLongPressEnd: (_) => unawaited(_endSpeedBoost()),
              onLongPressCancel: () => unawaited(_endSpeedBoost()),
              child: Stack(
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: aspectRatio,
                      child: LayoutBuilder(
                        builder: (ctx, constraints) {
                          _videoSurfaceSize = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => _updateViewport(),
                          );
                          return Container(
                            key: _surfaceKey,
                            color: Colors.black,
                            child: const NativeVideoSurface(),
                          );
                        },
                      ),
                    ),
                  ),
                  if (_showSpeedOverlay)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: _buildOverlayContainer(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(
                                  Icons.speed,
                                  color: Colors.white,
                                  size: 28,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '4x',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_showSeekOverlay)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: _buildOverlayContainer(
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _seekPreviewPosition >= _seekGestureBase
                                      ? Icons.fast_forward
                                      : Icons.fast_rewind,
                                  color: Colors.white,
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${_fmt(_seekPreviewPosition)} / ${_fmt(totalDuration > Duration.zero ? totalDuration : Duration.zero)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _fmtDelta(
                                    _seekPreviewPosition - _seekGestureBase,
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_showVolumeOverlay)
                    Positioned(
                      right: 24,
                      top: mediaPadding.top + 40,
                      child: _buildOverlayContainer(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _volumePreview <= 0.01
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${(_volumePreview * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_showControls)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black45,
                                Colors.transparent,
                                Colors.black45,
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_showControls) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: EdgeInsets.only(
                          left: 8,
                          right: 8,
                          top: mediaPadding.top + 4,
                          bottom: 8,
                        ),
                        color: Colors.black45,
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.picture_in_picture_alt,
                                color: Colors.white,
                              ),
                              onPressed: _enterPiP,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: mediaPadding.bottom + 16,
                      left: 12,
                      right: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              trackHeight: 2.5,
                            ),
                            child: Slider(
                              min: 0,
                              max: duration.inMilliseconds.toDouble(),
                              value:
                                  position.inMilliseconds
                                      .clamp(0, duration.inMilliseconds)
                                      .toDouble(),
                              onChangeStart: _onDragStart,
                              onChanged: _onDragUpdate,
                              onChangeEnd: _onDragEnd,
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                _fmt(position),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _fmt(duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.replay_10,
                                  color: Colors.white,
                                ),
                                iconSize: 30,
                                onPressed: () {
                                  final target =
                                      value.position -
                                      const Duration(seconds: 10);
                                  _player.seekTo(
                                    target < Duration.zero
                                        ? Duration.zero
                                        : target,
                                  );
                                },
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: _togglePlayPause,
                                child: CircleAvatar(
                                  radius: 28,
                                  backgroundColor: Colors.white24,
                                  child: Icon(
                                    value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                icon: const Icon(
                                  Icons.forward_10,
                                  color: Colors.white,
                                ),
                                iconSize: 30,
                                onPressed: () {
                                  final target =
                                      value.position +
                                      const Duration(seconds: 10);
                                  _player.seekTo(
                                    target > duration ? duration : target,
                                  );
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              PopupMenuButton<double>(
                                tooltip: '播放速度',
                                onSelected: _changeRate,
                                itemBuilder:
                                    (_) => const [
                                      PopupMenuItem(
                                        value: 0.5,
                                        child: Text('0.5x'),
                                      ),
                                      PopupMenuItem(
                                        value: 1.0,
                                        child: Text('1.0x'),
                                      ),
                                      PopupMenuItem(
                                        value: 1.25,
                                        child: Text('1.25x'),
                                      ),
                                      PopupMenuItem(
                                        value: 1.5,
                                        child: Text('1.5x'),
                                      ),
                                      PopupMenuItem(
                                        value: 2.0,
                                        child: Text('2.0x'),
                                      ),
                                    ],
                                child: Text(
                                  '${_playbackRate.toStringAsFixed(2)}x',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                _currentVolume <= 0.01
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                (_currentVolume * 100).round().toString(),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!_showControls)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SizedBox(height: mediaPadding.top),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
