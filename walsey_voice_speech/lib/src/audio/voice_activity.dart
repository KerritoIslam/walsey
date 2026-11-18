import 'dart:math' as math;
import 'dart:typed_data';

/// What the detector observed in the audio stream.
enum VoiceActivityEventType {
  /// Enough voiced audio has accumulated to count as speech.
  speechStart,

  /// The configured silence tail was reached after speech.
  speechEnd,

  /// The configured maximum utterance length was reached.
  maxSpeechReached,
}

/// One observation, with its offset from the first sample ever fed.
final class VoiceActivityEvent {
  const VoiceActivityEvent({
    required this.type,
    required this.elapsed,
  });

  final VoiceActivityEventType type;

  /// Offset of the event from [VoiceActivityDetector.reset].
  final Duration elapsed;

  @override
  String toString() => 'VoiceActivityEvent(${type.name}, $elapsed)';
}

/// Tuning for [VoiceActivityDetector].
///
/// The defaults are deliberately conservative for command speech: 200 ms of
/// voiced audio before a start (a click or a door cannot trigger it), and
/// 700 ms of silence before an end (a natural pause inside "set brightness…
/// to fifty" does not split the take).
final class VoiceActivityConfig {
  const VoiceActivityConfig({
    this.speechThresholdDbfs = -42,
    this.silenceDuration = const Duration(milliseconds: 700),
    this.minSpeechDuration = const Duration(milliseconds: 200),
    this.maxSpeechDuration = const Duration(seconds: 15),
    this.frameDuration = const Duration(milliseconds: 20),
  });

  /// A frame at or above this level counts as voiced. −42 dBFS is above room
  /// noise on the measured Windows capture path and below normal speech.
  final double speechThresholdDbfs;

  /// Silence needed after speech before the utterance is considered over.
  final Duration silenceDuration;

  /// Voiced audio needed before `speechStart` is emitted.
  final Duration minSpeechDuration;

  /// Hard cap, so a stuck stream cannot buffer forever.
  final Duration maxSpeechDuration;

  /// Analysis frame length. 20 ms keeps the end-of-speech granularity small
  /// without doing an RMS scan for every 10 ms chunk the recorder delivers.
  final Duration frameDuration;
}

/// Deterministic, pure-Dart energy voice-activity detector.
///
/// It is deliberately not a neural VAD: the only job is to decide *when* a
/// command started and stopped, from 16-bit mono PCM, on the UI isolate with
/// negligible cost. Every decision is a documented threshold, so its behaviour
/// is testable and explainable.
///
/// The detector keeps no audio. Callers own the buffer (the wake pipeline keeps
/// a bounded pre-roll ring); feeding chunks that split a frame is supported.
final class VoiceActivityDetector {
  VoiceActivityDetector({
    this.sampleRate = 16000,
    this.config = const VoiceActivityConfig(),
  }) {
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'must be positive');
    }
    _frameSamples = math.max(
      1,
      (sampleRate * config.frameDuration.inMicroseconds / 1000000).round(),
    );
  }

  final int sampleRate;
  final VoiceActivityConfig config;

  late final int _frameSamples;
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Total samples processed since [reset].
  int _processedSamples = 0;

  /// True between `speechStart` and `speechEnd`.
  bool _speaking = false;

  /// Voiced samples accumulated in the current candidate run (pre-start).
  int _voicedRun = 0;

  /// Consecutive silent samples after the last voiced frame while speaking.
  int _silenceRun = 0;

  /// Total voiced samples in the active utterance.
  int _utteranceVoiced = 0;

  /// Set when [VoiceActivityConfig.maxSpeechDuration] was hit. Audio is then
  /// ignored until [reset], so one over-long take cannot restart itself.
  bool _exhausted = false;

  bool get isSpeaking => _speaking;

  /// Whether the detector stopped after the maximum utterance length.
  bool get isExhausted => _exhausted;

  /// Stream time consumed so far.
  Duration get elapsed => Duration(
        microseconds:
            (_processedSamples * 1000000 / sampleRate).round(),
      );

  /// Drops all buffered samples and state. The next [add] starts at time zero.
  void reset() {
    _pending.clear();
    _processedSamples = 0;
    _speaking = false;
    _voicedRun = 0;
    _silenceRun = 0;
    _utteranceVoiced = 0;
    _exhausted = false;
  }

  /// Feeds one PCM16 little-endian chunk and returns the events it completed.
  List<VoiceActivityEvent> add(Uint8List pcm) {
    if (pcm.isEmpty || _exhausted) return const [];
    _pending.add(pcm);
    final bytes = _pending.takeBytes();
    final frameBytes = _frameSamples * 2;
    final events = <VoiceActivityEvent>[];
    var offset = 0;

    while (bytes.length - offset >= frameBytes) {
      final db = _frameDbfs(bytes, offset);
      _step(db, events);
      _processedSamples += _frameSamples;
      offset += frameBytes;
      if (_exhausted) break;
    }
    if (offset < bytes.length) {
      _pending.add(Uint8List.sublistView(bytes, offset));
    }
    return events;
  }

  void _step(double db, List<VoiceActivityEvent> events) {
    final voiced = db >= config.speechThresholdDbfs;

    if (!_speaking) {
      if (voiced) {
        _voicedRun += _frameSamples;
      } else {
        // A short dip does not erase a candidate, but a long gap does.
        _voicedRun = math.max(
          0,
          _voicedRun - _frameSamples,
        );
      }
      if (_voicedRun >= _samplesFor(config.minSpeechDuration)) {
        _speaking = true;
        _utteranceVoiced = _voicedRun;
        _silenceRun = 0;
        events.add(
          VoiceActivityEvent(
            type: VoiceActivityEventType.speechStart,
            elapsed: _processedSamples == 0
                ? Duration.zero
                : Duration(
                    microseconds:
                        (_processedSamples * 1000000 / sampleRate).round(),
                  ),
          ),
        );
      }
      return;
    }

    // Speaking.
    if (voiced) {
      _utteranceVoiced += _frameSamples;
      _silenceRun = 0;
    } else {
      _silenceRun += _frameSamples;
    }

    final maxReached = _utteranceVoiced >= _samplesFor(config.maxSpeechDuration);
    if (maxReached) {
      _exhausted = true;
      _end(VoiceActivityEventType.maxSpeechReached, events);
      return;
    }
    if (_silenceRun >= _samplesFor(config.silenceDuration)) {
      _end(VoiceActivityEventType.speechEnd, events);
    }
  }

  void _end(VoiceActivityEventType type, List<VoiceActivityEvent> events) {
    _speaking = false;
    _voicedRun = 0;
    _silenceRun = 0;
    _utteranceVoiced = 0;
    final endSample = _processedSamples + _frameSamples;
    events.add(
      VoiceActivityEvent(
        type: type,
        elapsed: Duration(
          microseconds: (endSample * 1000000 / sampleRate).round(),
        ),
      ),
    );
  }

  int _samplesFor(Duration duration) {
    final samples = (sampleRate * duration.inMicroseconds / 1000000).round();
    return samples < 1 ? 1 : samples;
  }

  double _frameDbfs(Uint8List bytes, int offset) {
    final data = ByteData.sublistView(bytes, offset);
    var sum = 0.0;
    for (var i = 0; i < _frameSamples; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += sample * sample;
    }
    final rms = math.sqrt(sum / _frameSamples);
    if (rms <= 1e-7) return -140;
    return 20 * (math.log(rms) / math.ln10);
  }
}
