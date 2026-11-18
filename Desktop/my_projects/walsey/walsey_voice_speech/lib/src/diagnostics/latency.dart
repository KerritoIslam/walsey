/// Measured latency of one push-to-talk session.
///
/// Every value is a real measurement, taken either in
/// `PushToTalkController` (session orchestration) or in `SessionDiagnostics`
/// (microphone delivery). Nothing here is estimated or synthesized, and a
/// missing mark stays `null` instead of being reported as zero.
///
/// The split exists so the expensive parts can be attributed:
///
/// * [pressToEngineReady] — permission, model lookup/load and engine spawn
///   (the model is loaded once and reused, so only the first session pays the
///   full model cost);
/// * [engineReadyToFirstAudio] — recorder open + first PCM chunk;
/// * [speechDuration] — first chunk to the release, i.e. how long the user
///   actually spoke;
/// * [stopToTranscript] — Whisper/Vosk decode after release;
/// * [transcriptToParsed] — the deterministic Stage 1/plan parser;
/// * [pressToInterpreted] — the end-to-end number a user feels.
final class VoiceLatency {
  const VoiceLatency({
    this.pressToEngineReady,
    this.engineReadyToFirstAudio,
    this.pressToFirstAudio,
    this.speechDuration,
    this.stopToTranscript,
    this.transcriptToParsed,
    this.pressToInterpreted,
  });

  final Duration? pressToEngineReady;
  final Duration? engineReadyToFirstAudio;
  final Duration? pressToFirstAudio;
  final Duration? speechDuration;
  final Duration? stopToTranscript;
  final Duration? transcriptToParsed;
  final Duration? pressToInterpreted;

  /// Whether at least one stage was measured for this session.
  bool get hasData =>
      pressToEngineReady != null ||
      pressToFirstAudio != null ||
      stopToTranscript != null ||
      transcriptToParsed != null;

  /// Compact, user-facing rows for the assistant panel.
  List<(String, String)> get rows {
    String? ms(Duration? value) =>
        value == null ? null : '${value.inMilliseconds} ms';
    return [
      if (ms(pressToEngineReady) case final value?)
        ('Engine/model ready', value),
      if (ms(engineReadyToFirstAudio) case final value?)
        ('Recorder open → first audio', value),
      if (ms(pressToFirstAudio) case final value?)
        ('Press → first audio', value),
      if (ms(speechDuration) case final value?) ('Speech captured', value),
      if (ms(stopToTranscript) case final value?)
        ('Release → transcript', value),
      if (ms(transcriptToParsed) case final value?)
        ('Parse', value),
      if (ms(pressToInterpreted) case final value?)
        ('Press → interpreted', value),
    ];
  }

  /// One-line log summary (empty when nothing was measured).
  String get logLine => [
        for (final (label, value) in rows) '$label=$value',
      ].join(', ');
}
