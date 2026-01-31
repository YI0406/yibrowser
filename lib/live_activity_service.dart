import 'dart:io';

import 'package:flutter/services.dart';

class LiveActivityService {
  LiveActivityService._();

  static final LiveActivityService instance = LiveActivityService._();
  static const bool _enabled = true;

  static const MethodChannel _channel = MethodChannel(
    'yibrowser/live_activity',
  );

  bool _availabilityChecked = false;
  bool _available = false;

  Future<bool> _ensureAvailable() async {
    if (!_enabled) {
      return false;
    }
    if (!Platform.isIOS) {
      return false;
    }
    if (_availabilityChecked) {
      return _available;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      _available = result ?? false;
    } catch (_) {
      _available = false;
    }
    _availabilityChecked = true;
    return _available;
  }

  Future<void> startOrUpdate(Map<String, Object?> payload) async {
    if (!await _ensureAvailable()) {
      return;
    }
    try {
      await _channel.invokeMethod('startOrUpdate', payload);
    } catch (_) {}
  }

  Future<void> end() async {
    if (!await _ensureAvailable()) {
      return;
    }
    try {
      await _channel.invokeMethod('end');
    } catch (_) {}
  }
}
