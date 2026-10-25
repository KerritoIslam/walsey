import 'dart:convert';

/// Extracts the recognized text from a Vosk JSON reply.
///
/// Vosk returns `{"text": "..."}` for results (including per-segment results)
/// and `{"partial": "..."}` for partial hypotheses. All other shapes, empty
/// strings, and broken JSON are treated as "no text" instead of throwing:
/// one malformed reply must not take down a live session.
///
/// Pure function so it is testable without the native library.
String? voskTranscriptText(String json) {
  if (json.trim().isEmpty) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) {
    return null;
  }
  final text = decoded['text'];
  final partial = decoded['partial'];
  final candidate = switch (text) {
    final String value when value.trim().isNotEmpty => value,
    _ => partial is String ? partial : null,
  };
  if (candidate == null) {
    return null;
  }
  final trimmed = candidate.trim();
  return trimmed.isEmpty ? null : trimmed;
}
