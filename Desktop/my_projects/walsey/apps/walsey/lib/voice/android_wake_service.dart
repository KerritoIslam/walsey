import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A failure starting or stopping the Android microphone foreground service.
///
/// Starting is explicit and user-facing, so every failure is surfaced. It is
/// never turned into a silent "maybe listening" state.
final class AndroidWakeServiceException implements Exception {
  const AndroidWakeServiceException(this.message);

  final String message;

  @override
  String toString() => 'AndroidWakeServiceException: $message';
}

/// Dart side of the Android microphone foreground service.
///
/// The service is only a **lifecycle shell**: it shows the mandatory, visible
/// notification with a Stop action and keeps the process alive. It does not
/// open the microphone and does not recognise anything. A detector must already
/// be running (which no shipped code path does today), otherwise starting this
/// would be a fake "listening" indicator.
///
/// Android requires the service to be started from a visible activity and the
/// `RECORD_AUDIO` permission to be granted; both are enforced on the native
/// side, not assumed here.
final class AndroidWakeService {
  AndroidWakeService({
    MethodChannel? channel,
    bool? platformSupported,
  })  : _channel = channel ?? const MethodChannel('walsey/wake_service'),
        _platformSupportedOverride = platformSupported {
    _channel.setMethodCallHandler(_handleCall);
  }

  static const String channelName = 'walsey/wake_service';

  final MethodChannel _channel;
  final bool? _platformSupportedOverride;

  final StreamController<void> _stopRequests = StreamController<void>.broadcast();
  bool _disposed = false;

  /// Emits when the user presses "Stop listening" on the notification.
  Stream<void> get stopRequests => _stopRequests.stream;

  bool get isSupportedPlatform =>
      _platformSupportedOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  /// Whether the native side provides the service (Android 8.0+).
  Future<bool> isSupported() async {
    if (!isSupportedPlatform) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Starts the foreground service. Call only while a detector the user
  /// explicitly enabled is running, and only after `isSupported()`.
  Future<void> start() async {
    if (_disposed) {
      throw const AndroidWakeServiceException('the bridge was disposed');
    }
    if (!isSupportedPlatform) {
      throw const AndroidWakeServiceException(
        'the wake-word foreground service is Android-only',
      );
    }
    try {
      await _channel.invokeMethod<void>('start');
    } on PlatformException catch (error) {
      throw AndroidWakeServiceException(
        switch (error.code) {
          'permission' => 'Microphone permission is required before '
              'the wake-word service can start.',
          'unsupported' => 'This Android version does not support the '
              'wake-word foreground service.',
          _ => error.message ?? 'The wake-word service could not start.',
        },
      );
    } on MissingPluginException {
      throw const AndroidWakeServiceException(
        'The wake-word foreground service is not available in this build.',
      );
    }
  }

  /// Stops the service. Safe to call when it is not running.
  Future<void> stop() async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Stopping is best-effort: the user already asked to stop.
    } on MissingPluginException {
      // No native side: nothing to stop.
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method == 'onStopRequested' && !_stopRequests.isClosed) {
      _stopRequests.add(null);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await stop();
    await _stopRequests.close();
  }
}
