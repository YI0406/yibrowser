import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';

/// Shared method channel used to communicate with the iOS native `PlayerEngine`.
const MethodChannel _playerChannel = MethodChannel('app.player');
const EventChannel _playerEvents = EventChannel('app.player/events');

/// Renders the native AVPlayer backed surface inside Flutter via UiKitView.
class NativeVideoSurface extends StatelessWidget {
  const NativeVideoSurface({super.key});

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }
    return UiKitView(
      viewType: 'native-player-view',
      layoutDirection: TextDirection.ltr,
      creationParams: null,
      creationParamsCodec: StandardMessageCodec(),
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    );
  }
}

/// Embedded AirPlay route picker button for iOS.
class AirPlayRouteButton extends StatelessWidget {
  const AirPlayRouteButton({
    super.key,
    this.tintColor = const Color(0xFFFFFFFF),
    this.activeTintColor = const Color(0xFF40C4FF),
  });

  final Color tintColor;
  final Color activeTintColor;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          UiKitView(
            viewType: 'airplay-route-picker',
            layoutDirection: TextDirection.ltr,
            creationParams: <String, dynamic>{
              'tintColor': tintColor.value,
              'activeTintColor': activeTintColor.value,
            },
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          ),
        ],
      ),
    );
  }
}

/// Immutable snapshot of the native player state exposed to Flutter widgets.
@immutable
class NativePlayerValue {
  const NativePlayerValue({
    required this.duration,
    required this.position,
    required this.isPlaying,
    required this.isReady,
    required this.isBuffering,
    required this.presentationSize,
    required this.isCompleted,
    required this.inPip,
    required this.volume,
    required this.speed,
  });

  const NativePlayerValue.uninitialized()
    : duration = Duration.zero,
      position = Duration.zero,
      isPlaying = false,
      isReady = false,
      isBuffering = false,
      isCompleted = false,
      inPip = false,
      volume = 1.0,
      speed = 1.0,
      presentationSize = Size.zero;

  final Duration duration;
  final Duration position;
  final bool isPlaying;
  final bool isReady;
  final bool isBuffering;
  final bool isCompleted;
  final bool inPip;
  final Size presentationSize;
  final double volume;
  final double speed;

  double get aspectRatio {
    final w = presentationSize.width;
    final h = presentationSize.height;
    if (w <= 0 || h <= 0) return 16 / 9;
    return max(0.01, w / h);
  }

  bool get isInitialized => isReady && duration >= Duration.zero;

  NativePlayerValue copyWith({
    Duration? duration,
    Duration? position,
    bool? isPlaying,
    bool? isReady,
    bool? isBuffering,
    bool? isCompleted,
    bool? inPip,
    Size? presentationSize,
    double? volume,
    double? speed,
  }) {
    return NativePlayerValue(
      duration: duration ?? this.duration,
      position: position ?? this.position,
      isPlaying: isPlaying ?? this.isPlaying,
      isReady: isReady ?? this.isReady,
      isBuffering: isBuffering ?? this.isBuffering,
      isCompleted: isCompleted ?? this.isCompleted,
      inPip: inPip ?? this.inPip,
      presentationSize: presentationSize ?? this.presentationSize,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
    );
  }
}

/// Singleton controller that mirrors the native player state and forwards commands.
class NativePlayerController extends ValueNotifier<NativePlayerValue> {
  factory NativePlayerController() => _instance;

  NativePlayerController._internal()
    : super(const NativePlayerValue.uninitialized()) {
    _eventSub ??= _playerEvents.receiveBroadcastStream().listen(_onEvent);
  }

  static final NativePlayerController _instance =
      NativePlayerController._internal();
  static StreamSubscription<dynamic>? _eventSub;

  static void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    final controller = _instance;
    final value = controller.value;

    Duration? _ms(dynamic v) {
      if (v is int) return Duration(milliseconds: v);
      if (v is double) return Duration(milliseconds: v.round());
      return null;
    }

    Size? _sizeFrom(Map<dynamic, dynamic> src) {
      final w = (src['width'] as num?)?.toDouble();
      final h = (src['height'] as num?)?.toDouble();
      if (w == null || h == null) return null;
      return Size(w, h);
    }

    switch (type) {
      case 'progress':
      case 'status':
        final pos = _ms(event['positionMs']) ?? value.position;
        final dur = _ms(event['durationMs']) ?? value.duration;
        final playing = (event['isPlaying'] as bool?) ?? value.isPlaying;
        final ready = (event['isReady'] as bool?) ?? value.isReady;
        final buffering = (event['isBuffering'] as bool?) ?? value.isBuffering;
        final volume = (event['volume'] as num?)?.toDouble() ?? value.volume;
        final speed = (event['speed'] as num?)?.toDouble() ?? value.speed;
        controller.value = value.copyWith(
          position: pos,
          duration: dur,
          isPlaying: playing,
          isReady: ready,
          isBuffering: buffering,
          isCompleted:
              dur > Duration.zero &&
              (pos >= dur - const Duration(milliseconds: 400)),
          volume: volume,
          speed: speed,
        );
        break;
      case 'presentation':
        final size = _sizeFrom(event);
        if (size != null) {
          controller.value = value.copyWith(presentationSize: size);
        }
        break;
      case 'pip':
        final state = event['state'] as String?;
        final inPip = state == 'started';
        Duration? pos;
        if (event['positionMs'] != null) pos = _ms(event['positionMs']);
        controller.value = value.copyWith(
          inPip: inPip,
          position: pos ?? value.position,
        );
        break;
      case 'ended':
        controller.value = value.copyWith(
          position: value.duration,
          isPlaying: false,
          isCompleted: true,
          volume: value.volume,
          speed: value.speed,
        );
        break;
      case 'error':
        debugPrint(
          '[NativePlayerController] error: ${event['message'] ?? 'unknown'}',
        );
        controller.value = value.copyWith(isPlaying: false);
        break;
    }
  }

  /// Load a new media item. This replaces the current player item but keeps
  /// playback state listeners intact.
  Future<void> setSource(String url) async {
    await _playerChannel.invokeMethod('setSource', url);
    final state = await _playerChannel.invokeMapMethod<String, dynamic>(
      'currentState',
    );
    if (state != null) {
      final payload = Map<String, dynamic>.from(state);
      payload['type'] = 'status';
      _onEvent(payload);
    }
  }

  Future<void> play() async {
    await _playerChannel.invokeMethod('play');
  }

  Future<void> pause() async {
    await _playerChannel.invokeMethod('pause');
  }

  Future<void> seekTo(Duration position) async {
    await _playerChannel.invokeMethod('seekTo', position.inMilliseconds);
  }

  Future<void> setPlaybackRate(double rate) async {
    await _playerChannel.invokeMethod('setRate', rate);
    value = value.copyWith(speed: rate);
  }

  Future<void> setVolume(double volume) async {
    await _playerChannel.invokeMethod('setVolume', volume.clamp(0.0, 1.0));
  }

  Future<bool> enterPictureInPicture() async {
    final ok = await _playerChannel.invokeMethod<bool>('enterPiP');
    return ok ?? false;
  }

  Future<void> stopPictureInPicture() async {
    await _playerChannel.invokeMethod('stopPiP');
  }

  Future<bool> isPiPPossible() async {
    final ok = await _playerChannel.invokeMethod<bool>('isPiPPossible');
    return ok ?? false;
  }

  Future<void> updateViewport(Rect rect) async {
    await _playerChannel.invokeMethod('updateViewport', {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
  }

  /// Cleans up listeners. Because the native player is a singleton we keep the
  /// event channel attached until the app shuts down, so dispose is a no-op.
  @override
  void dispose() {
    super.dispose();
  }
}
