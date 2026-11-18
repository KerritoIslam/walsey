/// One downloadable offline model.
///
/// The catalogue is deliberately short: every entry was checked against its
/// publisher (Vosk entries against
/// `https://alphacephei.com/vosk/models/model-list.json`, size + MD5; the
/// Whisper entry against `https://huggingface.co/ggerganov/whisper.cpp`,
/// exact published size + repo licence MIT). No model is bundled, downloaded
/// at startup or fetched implicitly — [ModelStore.install] only runs after an
/// explicit user action.
///
/// Hugging Face publishes no digest for GGUF files, so the Whisper entry's
/// MD5/SHA-256 were computed from the downloaded artifact whose size was
/// verified byte-for-byte against Hugging Face's published `X-Linked-Size`
/// (147,964,211 bytes, checked 2026-10-26).
enum ModelKind {
  /// A Vosk Kaldi archive: a zip of `am/`, `conf/` and graph folders.
  voskArchive,

  /// A single whisper.cpp GGUF model file, installed as-is.
  whisperGgml,
}

final class SpeechModel {
  const SpeechModel({
    required this.id,
    required this.languageId,
    required this.languageLabel,
    required this.downloadUrl,
    required this.archiveSizeBytes,
    required this.archiveMd5,
    required this.license,
    required this.caveat,
    this.kind = ModelKind.voskArchive,
    this.modelFileName,
    this.modelSha256,
  });

  /// What the engine expects this entry to be.
  final ModelKind kind;

  /// Directory name inside the app's model folder (Vosk), or the file name
  /// of the installed GGUF file (Whisper, via [modelFileName]).
  final String id;

  /// BCP-47-ish identifier used by the UI and the recognizer.
  final String languageId;

  /// Human-readable language name.
  final String languageLabel;

  final String downloadUrl;

  /// Size of the zip archive, used for the explicit setup UI.
  final int archiveSizeBytes;

  /// MD5 published by Alpha Cephei, verified after download.
  final String archiveMd5;

  final String license;

  /// For [ModelKind.whisperGgml]: the exact file name to install, e.g.
  /// `ggml-base.en.bin`. `null` for Vosk archives (extracted directories).
  final String? modelFileName;

  /// For [ModelKind.whisperGgml]: SHA-256 of the exact model file. Vosk
  /// archives are verified by [archiveMd5] alone, as published by
  /// Alpha Cephei.
  final String? modelSha256;

  /// Honest note about accuracy or scope. Shown in the model manager.
  final String caveat;

  /// Approximate size in whole megabytes.
  int get archiveSizeMegabytes => archiveSizeBytes ~/ (1024 * 1024);

  /// The primary engine model: whisper.cpp `base.en`, English-only. Replaces
  /// the Vosk small model as the shipped configuration (it transcribed the
  /// synthetic Stage 1 benchmark corpus more accurately), at the cost of
  /// ~141 MB on disk and batch decoding instead of streaming partials.
  static const SpeechModel whisperBaseEnglish = SpeechModel(
    id: 'ggml-base.en',
    languageId: 'en-US',
    languageLabel: 'English (US)',
    kind: ModelKind.whisperGgml,
    modelFileName: 'ggml-base.en.bin',
    downloadUrl:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/'
        'ggml-base.en.bin',
    archiveSizeBytes: 147964211,
    archiveMd5: '4279db3d7b18d9f6e4d5817a16af4f09',
    modelSha256:
        'a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002',
    license: 'MIT',
    caveat:
        'Whisper base.en GGUF (~141 MB), the primary recognition model. '
        'English-only, matching the Stage 1 parser. Larger and slower than '
        'the Vosk small model but measurably more accurate on the synthetic '
        'benchmark. Checksums are computed from the verified Hugging Face '
        'download; HF publishes no official digest for this file.',
  );

  /// American English small model. The only language exercised by the Stage 1
  /// parser's vocabulary, and the reference model for manual tests.
  static const SpeechModel englishUs = SpeechModel(
    id: 'vosk-model-small-en-us-0.15',
    languageId: 'en-US',
    languageLabel: 'English (US)',
    downloadUrl:
        'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip',
    archiveSizeBytes: 41205931,
    archiveMd5: '09ab50ccd62b674cbaa231b825f9c1cb',
    license: 'Apache License 2.0',
    caveat:
        'Reference small model (about 40 MB). Written and spoken English '
        'commands only; the Stage 1 parser itself is English-only.',
  );

  static const SpeechModel french = SpeechModel(
    id: 'vosk-model-small-fr-0.22',
    languageId: 'fr-FR',
    languageLabel: 'French',
    downloadUrl:
        'https://alphacephei.com/vosk/models/vosk-model-small-fr-0.22.zip',
    archiveSizeBytes: 42233323,
    archiveMd5: '8873b1234503f6edd55f54bfff31cf3e',
    license: 'Apache License 2.0',
    caveat:
        'Small French model (about 40 MB). Recognition is French, but the '
        'existing command parser only understands English, so French speech '
        'is expected to end as an unsupported command. Not tested on hardware.',
  );

  static const SpeechModel arabic = SpeechModel(
    id: 'vosk-model-small-ar-0.3',
    languageId: 'ar',
    languageLabel: 'Arabic (MSA)',
    downloadUrl:
        'https://alphacephei.com/vosk/models/vosk-model-small-ar-0.3.zip',
    archiveSizeBytes: 104351896,
    archiveMd5: '0eb578c0779f85ef039b7ee5bc1b64ed',
    license: 'Apache License 2.0',
    caveat:
        'Small Modern Standard Arabic model (about 100 MB). It is not a '
        'dialect model: Algerian Darija is not covered. The command parser is '
        'English-only, so Arabic speech will not produce a valid command. Not '
        'tested on hardware.',
  );

  /// Every model offered by the setup UI: the primary engine model first,
  /// then the Vosk fallback models (kept installable for comparison and
  /// rollback, never required by the Whisper flow).
  static const List<SpeechModel> all = [
    whisperBaseEnglish,
    englishUs,
    french,
    arabic,
  ];

  static SpeechModel? byLanguageId(String languageId) {
    for (final model in all) {
      if (model.languageId == languageId) {
        return model;
      }
    }
    return null;
  }
}

/// A selectable recognition language, which may not have a model yet.
final class SpeechLanguage {
  const SpeechLanguage({
    required this.id,
    required this.label,
    required this.detail,
    this.model,
    this.whisperModel,
  });

  final String id;
  final String label;

  /// Short explanation shown next to the selector.
  final String detail;

  /// `null` when no Vosk model is published for this language. Vosk is the
  /// kept fallback engine; these entries stay installable for comparison.
  final SpeechModel? model;

  /// The model the primary engine (Whisper) uses, `null` when no whisper.cpp
  /// model for this language ships in this build.
  final SpeechModel? whisperModel;

  bool get isSupported => model != null;

  static const SpeechLanguage englishUs = SpeechLanguage(
    id: 'en-US',
    label: 'English (US)',
    detail: 'Model: ggml-base.en (Whisper, English only)',
    model: SpeechModel.englishUs,
    whisperModel: SpeechModel.whisperBaseEnglish,
  );

  static const SpeechLanguage french = SpeechLanguage(
    id: 'fr-FR',
    label: 'French',
    detail:
        'No Whisper model for French in this build; the Vosk fallback still '
        'covers it.',
    model: SpeechModel.french,
  );

  static const SpeechLanguage arabic = SpeechLanguage(
    id: 'ar',
    label: 'Arabic (MSA)',
    detail:
        'No Whisper model for Arabic in this build; the Vosk fallback still '
        'covers it.',
    model: SpeechModel.arabic,
  );

  /// Kept visible on purpose: there is no model for this dialect, so choosing
  /// this entry explains the limitation instead of hiding the language.
  static const SpeechLanguage algerianDarija = SpeechLanguage(
    id: 'ar-DZ',
    label: 'Algerian Darija',
    detail:
        'No offline model exists for this dialect; recognition is '
        'unavailable.',
  );

  static const List<SpeechLanguage> all = [
    englishUs,
    french,
    arabic,
    algerianDarija,
  ];

  static const SpeechLanguage defaultLanguage = englishUs;

  static SpeechLanguage? byId(String id) {
    for (final language in all) {
      if (language.id == id) {
        return language;
      }
    }
    return null;
  }
}
