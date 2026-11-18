import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// The decoder-bias writes touch native memory, so the guard that decides
/// whether a write is allowed is the safety-critical part. These tests build a
/// struct in Dart with the pinned release's defaults and prove the guard
/// accepts exactly that and nothing else. No native library is loaded.
void main() {
  group('pinned whisper_full_params guard', () {
    late Pointer<Void> params;
    late Pointer<Utf8> prompt;

    setUp(() {
      params = WhisperBindings.debugAllocatePinnedParams();
      prompt = 'Walsey. LEDDMX.'.toNativeUtf8();
    });

    tearDown(() {
      // The `language` string allocated by the helper is intentionally left
      // alone: it is three bytes per test, and freeing a pointer we can no
      // longer reach would be the more dangerous habit.
      malloc.free(params);
      malloc.free(prompt);
    });

    test('accepts the pinned layout and writes the prompt once', () {
      expect(WhisperBindings.setInitialPrompt(params, prompt), isTrue);
      expect(
        WhisperBindings.setInitialPrompt(params, prompt),
        isFalse,
        reason: 'a prompt already exists; overwriting it is never the intent',
      );
    });

    test('refuses a null struct or prompt instead of guessing', () {
      expect(WhisperBindings.setInitialPrompt(nullptr, prompt), isFalse);
      expect(WhisperBindings.setInitialPrompt(params, nullptr), isFalse);
      expect(WhisperBindings.setGreedyBestOf(nullptr, 1), isFalse);
    });

    test('refuses a struct whose greedy default drifted', () {
      final drifted = WhisperBindings.debugAllocatePinnedParams(greedyBestOf: 4);
      addTearDown(() => malloc.free(drifted));

      expect(WhisperBindings.setInitialPrompt(drifted, prompt), isFalse);
      expect(WhisperBindings.setGreedyBestOf(drifted, 1), isFalse);
    });

    test('caps greedy candidates, and only from the library default', () {
      expect(WhisperBindings.setGreedyBestOf(params, 1), isTrue);
      expect(
        WhisperBindings.setGreedyBestOf(params, 1),
        isFalse,
        reason: 'after the first write the struct no longer matches the guard',
      );
      expect(WhisperBindings.setGreedyBestOf(params, 0), isFalse);
      expect(WhisperBindings.setGreedyBestOf(params, 99), isFalse);
    });
  });

  test('the shipped prompt still contains every word class it exists for', () {
    // A shortened or reworded prompt silently loses the biasing that fixed the
    // measured failures (see docs/voice_accuracy.md), so pin the classes.
    for (final fragment in [
      'Walsey',
      'LEDDMX',
      'green',
      'cyan',
      'percent',
      'effect 7',
      'scan for devices',
      'then',
    ]) {
      expect(
        whisperVocabularyPrompt,
        contains(fragment),
        reason: 'the vocabulary prompt lost "$fragment"',
      );
    }
  });
}
