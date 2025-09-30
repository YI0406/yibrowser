import 'dart:async';
import 'dart:io';
import 'dart:ui';

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

  const VideoPlayerPage({
    super.key,
    required this.path,
    this.title = '播放器',
    this.startAt,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver {
  final NativePlayerController _player = NativePlayerController();
  final VolumeController _systemVolume = VolumeController.instance;
  final GlobalKey _surfaceKey = GlobalKey();

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player.addListener(_handlePlayerValue);
    _initializePlayer();
    _bindVolume();
  }

  Future<void> _initializePlayer() async {
    await _player.setSource(widget.path);
    if (widget.startAt != null && widget.startAt! > Duration.zero) {
      _dragTarget = widget.startAt!;
    } else {
      final resume = _resumePositions[widget.path] ??
          AppRepo.I.resumePositionFor(widget.path);
      if (resume != null && resume > Duration.zero) {
        _dragTarget = resume;
      }
    }
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
    final value = _player.value;
    final newSpeed = value.speed;
    if ((newSpeed - _playbackRate).abs() > 0.0001) {
      _playbackRate = newSpeed;
      if (mounted) setState(() {});
    }
    final pos = value.position;
    if ((pos - _lastPersistedPosition).abs() >= const Duration(seconds: 5)) {
      _lastPersistedPosition = pos;
      _resumePositions[widget.path] = pos;
      AppRepo.I.setResumePosition(widget.path, pos);
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_handlePlayerValue);
    final value = _player.value;
    final pos = value.position;
    _resumePositions[widget.path] = pos;
    AppRepo.I.setResumePosition(widget.path, pos);
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

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.of(context).padding;
    final title = widget.title;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<NativePlayerValue>(
          valueListenable: _player,
          builder: (context, value, _) {
            final duration = value.duration > Duration.zero ? value.duration : const Duration(seconds: 1);
            final position = _dragging ? _dragTarget : value.position;
            final aspectRatio = value.aspectRatio;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _togglePlayPause,
              child: Stack(
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: aspectRatio,
                      child: LayoutBuilder(
                        builder: (ctx, constraints) {
                          WidgetsBinding.instance.addPostFrameCallback((_) => _updateViewport());
                          return Container(
                            key: _surfaceKey,
                            color: Colors.black,
                            child: const NativeVideoSurface(),
                          );
                        },
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
                        padding: EdgeInsets.only(left: 8, right: 8, top: mediaPadding.top + 4, bottom: 8),
                        color: Colors.black45,
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back, color: Colors.white),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 16),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
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
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              trackHeight: 2.5,
                            ),
                            child: Slider(
                              min: 0,
                              max: duration.inMilliseconds.toDouble(),
                              value: position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble(),
                              onChangeStart: _onDragStart,
                              onChanged: _onDragUpdate,
                              onChangeEnd: _onDragEnd,
                            ),
                          ),
                          Row(
                            children: [
                              Text(_fmt(position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              const Spacer(),
                              Text(_fmt(duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.replay_10, color: Colors.white),
                                iconSize: 30,
                                onPressed: () {
                                  final target = value.position - const Duration(seconds: 10);
                                  _player.seekTo(target < Duration.zero ? Duration.zero : target);
                                },
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: _togglePlayPause,
                                child: CircleAvatar(
                                  radius: 28,
                                  backgroundColor: Colors.white24,
                                  child: Icon(
                                    value.isPlaying ? Icons.pause : Icons.play_arrow,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                icon: const Icon(Icons.forward_10, color: Colors.white),
                                iconSize: 30,
                                onPressed: () {
                                  final target = value.position + const Duration(seconds: 10);
                                  _player.seekTo(target > duration ? duration : target);
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
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 0.5, child: Text('0.5x')),
                                  PopupMenuItem(value: 1.0, child: Text('1.0x')),
                                  PopupMenuItem(value: 1.25, child: Text('1.25x')),
                                  PopupMenuItem(value: 1.5, child: Text('1.5x')),
                                  PopupMenuItem(value: 2.0, child: Text('2.0x')),
                                ],
                                child: Text(
                                  '${_playbackRate.toStringAsFixed(2)}x',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                _currentVolume <= 0.01 ? Icons.volume_off : Icons.volume_up,
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
