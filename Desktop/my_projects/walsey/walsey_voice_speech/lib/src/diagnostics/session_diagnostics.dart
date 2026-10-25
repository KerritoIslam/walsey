import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_stats.dart';
import 'wav.dart';

/// Per-session audio diagnostics for the recognition pipeline.
///
/// This is a measurement instrument, not a feature of the assistant: it records
/// what the microphone actually delivered (format-independent byte counts,
/// level, clipping, duration versus wall clock), keeps the raw Vosk transcript
/// next to the parsed result, and can write the captured samples to a WAV file.
///
/// Audio is buffered in memory only, capped at [maxBufferedSeconds], and written
/// to disk only when the user asks for it. Nothing here is uploaded, and the
/// buffer is cleared when a new session starts.
class SessionDiagnostics extends ChangeNotifier {
  SessionDiagnostics({
    this.maxBufferedSeconds = 30,
    this.maxBufferedBytes = 4 * 1024 * 1024,
  });

  /// Longest take kept in memory for WAV export; longer audio is still measured
  /// but only the first [maxBufferedSeconds] are retained.
  final int maxBufferedSeconds;

  /// Hard memory cap for the audio buffer, whichever limit is hit first.
  final int maxBufferedBytes;

  AudioStats? _stats;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _bufferedBytes = 0;
  bool _bufferTruncated = false;
  int _declaredSampleRate = 16000;
  String? _rawTranscript;
  String? _wavPath;
  Stopwatch? _wallClock;
  Duration? _captureWallTime;
  Duration? _finalizeWallTime;
  int _bytesSincePartial = 0;
  bool _hasSession = false;
  Duration? _firstChunkDelay;

  /// Statistics for the last session, or `null` before the first one.
  AudioStats? get stats => _stats;

  /// The exact text Vosk returned, before any parser normalization.
  String? get rawTranscript => _rawTranscript;

  /// Path of the last WAV written by [saveWav], if any.
  String? get wavPath => _wavPath;

  /// True once a session has started and has not been cleared.
  bool get hasSession => _hasSession;

  /// Bytes the microphone delivered after the most recent partial transcript.
  ///
  /// A large value means audio kept arriving after the last stable hypothesis;
  /// combined with [trailingSilenceSeconds] it shows whether the end of the take
  /// looked like a cut-off word or like silence.
  int get bytesSincePartial => _bytesSincePartial;

  /// Wall-clock duration of the capture phase, measured locally.
  Duration? get captureWallTime => _captureWallTime;

  /// How long after the session started the first audio chunk arrived.
  ///
  /// On Windows the `record` plugin needs a few hundred milliseconds to open
  /// the device, and anything said in that window is never captured. Reporting
  /// it makes the cost visible instead of looking like a recognition error.
  Duration? get firstChunkDelay => _firstChunkDelay;

  /// Wall-clock duration until the final transcript arrived.
  Duration? get finalizeWallTime => _finalizeWallTime;

  /// Ratio between the audio duration implied by the sample count and the
  /// wall-clock capture time.
  ///
  /// ~1.0 means the declared sample rate matches what was really delivered; 3.0
  /// would mean a 48 kHz stream was mislabelled as 16 kHz, which silently
  /// destroys recognition. `null` until both measurements exist.
  double? get rateRatio {
    final stats = _stats;
    final wall = _captureWallTime;
    if (stats == null || wall == null || wall.inMilliseconds < 200) {
      return null;
    }
    return stats.durationSeconds / (wall.inMilliseconds / 1000);
  }

  /// Whether the in-memory copy was cut short by the buffer limits.
  bool get bufferTruncated => _bufferTruncated;

  int get bufferedBytes => _bufferedBytes;

  int get declaredSampleRate => _declaredSampleRate;

  /// Starts a fresh session, discarding the previous take.
  void beginSession({required int sampleRate}) {
    _declaredSampleRate = sampleRate;
    _stats = AudioStats(declaredSampleRate: sampleRate);
    _buffer.clear();
    _bufferedBytes = 0;
    _bufferTruncated = false;
    _rawTranscript = null;
    _wavPath = null;
    _bytesSincePartial = 0;
    _captureWallTime = null;
    _finalizeWallTime = null;
    _firstChunkDelay = null;
    _hasSession = true;
    _wallClock = Stopwatch()..start();
    notifyListeners();
  }

  /// Records one chunk exactly as the recognizer received it.
  void addChunk(Uint8List chunk) {
    final stats = _stats;
    if (stats == null || chunk.isEmpty) {
      return;
    }
    _firstChunkDelay ??= _wallClock?.elapsed;
    stats.addChunk(chunk);
    _bytesSincePartial += chunk.length;

    final cap = maxBufferedSeconds * _declaredSampleRate * 2;
    final limit = cap < maxBufferedBytes ? cap : maxBufferedBytes;
    if (_bufferedBytes + chunk.length <= limit) {
      _buffer.add(chunk);
      _bufferedBytes += chunk.length;
    } else {
      final remaining = limit - _bufferedBytes;
      if (remaining > 0) {
        _buffer.add(Uint8List.sublistView(chunk, 0, remaining));
        _bufferedBytes += remaining;
      }
      _bufferTruncated = true;
    }
    notifyListeners();
  }

  /// Marks a fresh partial transcript; tail accounting restarts here.
  void notePartial() {
    _bytesSincePartial = 0;
  }

  /// Finishes the session and stores the verbatim transcript.
  void complete({required String? transcript}) {
    _rawTranscript = transcript;
    _wallClock?.stop();
    _captureWallTime ??= _wallClock?.elapsed;
    _finalizeWallTime = _wallClock?.elapsed;
    notifyListeners();
  }

  /// Marks the end of the capture phase (microphone closed).
  void closeCapture() {
    _wallClock?.stop();
    _captureWallTime = _wallClock?.elapsed;
  }

  /// The session was cancelled: transcript and export path are discarded.
  void cancel() {
    _rawTranscript = null;
    _wavPath = null;
    _wallClock?.stop();
    notifyListeners();
  }

  /// Clears everything, including the buffered audio.
  void clear() {
    _stats = null;
    _buffer.clear();
    _bufferedBytes = 0;
    _bufferTruncated = false;
    _rawTranscript = null;
    _wavPath = null;
    _bytesSincePartial = 0;
    _captureWallTime = null;
    _finalizeWallTime = null;
    _firstChunkDelay = null;
    _hasSession = false;
    _wallClock = null;
    notifyListeners();
  }

  /// The buffered take as a WAV file (empty when nothing was captured).
  Uint8List wavBytes() => encodePcm16Wav(
    _buffer.toBytes(),
    sampleRate: _declaredSampleRate,
    channels: 1,
  );

  /// Writes the buffered take as a 16 kHz mono PCM16 WAV.
  ///
  /// Returns `null` when no audio was captured. The file name is fixed rather
  /// than overwritten silently: repeated takes get a timestamp suffix.
  Future<File?> saveWav(Directory directory) async {
    if (_bufferedBytes == 0) {
      return null;
    }
    await directory.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'walsey-take-$stamp.wav',
    );
    await file.writeAsBytes(wavBytes(), flush: true);
    _wavPath = file.path;
    notifyListeners();
    return file;
  }

  /// Saves the take under `<app support>/diagnostics`, the folder shown in the
  /// UI. Desktop and Android both resolve this without a file-picker plugin.
  Future<File?> saveWavToAppFolder() async {
    final base = await getApplicationSupportDirectory();
    return saveWav(Directory(p.join(base.path, 'diagnostics')));
  }

  /// Compact human-readable summary used by the diagnostics panel.
  List<(String, String)> get summaryRows {
    final stats = _stats;
    if (stats == null) {
      return const [];
    }
    String db(double value) =>
        value.isFinite ? '${value.toStringAsFixed(1)} dBFS' : 'silent';
    final rows = <(String, String)>[
      ('Duration', '${stats.durationSeconds.toStringAsFixed(2)} s'),
      ('Format', '$_declaredSampleRate Hz, mono, 16-bit PCM'),
      (
        'Chunks',
        '${stats.chunkCount} '
            '(${stats.minChunkBytes}–${stats.maxChunkBytes} B)',
      ),
      ('Peak', db(stats.peakDbfs)),
      ('RMS', db(stats.rmsDbfs)),
      (
        'Clipping',
        '${stats.clippedSamples} samples '
            '(${stats.clippedPercent.toStringAsFixed(2)}%)',
      ),
      (
        'Trailing silence',
        '${stats.trailingSilenceSeconds.toStringAsFixed(2)} s',
      ),
    ];
    final ratio = rateRatio;
    if (ratio != null) {
      rows.add((
        'Rate check',
        '${ratio.toStringAsFixed(2)}× audio/wall clock '
            '(1.00 = rate honoured)',
      ));
    }
    final first = _firstChunkDelay;
    if (first != null) {
      rows.add((
        'First audio',
        '${first.inMilliseconds} ms after session start',
      ));
    }
    rows.add(('Audio after last partial', '$_bytesSincePartial B'));
    return rows;
  }
}
