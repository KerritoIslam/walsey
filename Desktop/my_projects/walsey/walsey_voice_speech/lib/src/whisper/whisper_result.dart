/// Assembles the raw whisper.cpp output into one transcript string.
///
/// This is deliberately the only transformation applied to what the engine
/// returned: segments are joined with single spaces and whitespace runs are
/// collapsed. No punctuation is stripped, no words are rewritten and no
/// "did you mean" correction happens — the parser must see exactly what
/// Whisper heard, so that a transcription error and a parser error stay
/// visibly separate.
String? whisperTranscriptText(List<String> segments) {
  final joined = segments
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .join(' ');
  if (joined.isEmpty) {
    return null;
  }
  return joined
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
