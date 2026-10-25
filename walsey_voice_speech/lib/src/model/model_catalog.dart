/// One downloadable Vosk language model.
///
/// The catalogue is deliberately short: every entry was checked against
/// `https://alphacephei.com/vosk/models/model-list.json` (size + MD5) and the
/// model page (licence). No model is bundled, downloaded at startup or fetched
/// implicitly — [ModelStore.install] only runs after an explicit user action.
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
  });

  /// Directory name inside the app's model folder.
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

  /// Honest note about accuracy or scope. Shown in the model manager.
  final String caveat;

  /// Approximate size in whole megabytes.
  int get archiveSizeMegabytes => archiveSizeBytes ~/ (1024 * 1024);

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

  /// Every model offered by the setup UI.
  static const List<SpeechModel> all = [englishUs, french, arabic];

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
  });

  final String id;
  final String label;

  /// Short explanation shown next to the selector.
  final String detail;

  /// `null` when no Vosk model is published for this language.
  final SpeechModel? model;

  bool get isSupported => model != null;

  static const SpeechLanguage englishUs = SpeechLanguage(
    id: 'en-US',
    label: 'English (US)',
    detail: 'Model: vosk-model-small-en-us-0.15',
    model: SpeechModel.englishUs,
  );

  static const SpeechLanguage french = SpeechLanguage(
    id: 'fr-FR',
    label: 'French',
    detail: 'Model: vosk-model-small-fr-0.22',
    model: SpeechModel.french,
  );

  static const SpeechLanguage arabic = SpeechLanguage(
    id: 'ar',
    label: 'Arabic (MSA)',
    detail: 'Model: vosk-model-small-ar-0.3',
    model: SpeechModel.arabic,
  );

  /// Kept visible on purpose: there is no Algerian Darija model, so choosing
  /// this entry explains the limitation instead of hiding the language.
  static const SpeechLanguage algerianDarija = SpeechLanguage(
    id: 'ar-DZ',
    label: 'Algerian Darija',
    detail:
        'No Vosk model exists for this dialect; recognition is unavailable.',
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
