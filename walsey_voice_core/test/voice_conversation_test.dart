import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

void main() {
  group('voice conversation memory', () {
    test('a fresh target is reusable', () {
      var now = DateTime(2026, 11, 12, 10);
      final conversation = VoiceConversation(clock: () => now);
      conversation.record(intent: VoiceIntent.powerOn, deviceName: 'LEDDMX-03-6B4A');

      expect(conversation.hasFreshTarget, isTrue);
      expect(conversation.deviceName, 'LEDDMX-03-6B4A');
      expect(conversation.lastIntent, VoiceIntent.powerOn);
    });

    test('memory expires after the stale window', () {
      var now = DateTime(2026, 11, 12, 10);
      final conversation = VoiceConversation(
        clock: () => now,
        staleAfter: const Duration(minutes: 10),
      );
      conversation.record(intent: VoiceIntent.setColor, deviceName: 'LEDDMX-02');

      now = now.add(const Duration(minutes: 9));
      expect(conversation.hasFreshTarget, isTrue);

      now = now.add(const Duration(minutes: 2));
      expect(conversation.hasFreshTarget, isFalse);
      expect(conversation.deviceName, isNull);
      expect(conversation.lastIntent, isNull);
    });

    test('invalidate clears memory immediately', () {
      final conversation = VoiceConversation();
      conversation.record(intent: VoiceIntent.powerOn, deviceName: 'LEDDMX-03');

      conversation.invalidate();

      expect(conversation.hasFreshTarget, isFalse);
      expect(conversation.deviceName, isNull);
    });

    test('recording without a device does not keep the old target', () {
      final conversation = VoiceConversation();
      conversation.record(intent: VoiceIntent.powerOn, deviceName: 'LEDDMX-03');
      conversation.record(intent: VoiceIntent.queryStatus);

      expect(conversation.hasFreshTarget, isFalse);
    });
  });

  group('follow-up planning', () {
    test('a pronoun follow-up plans a reconnect before the action', () {
      final conversation = VoiceConversation()
        ..record(intent: VoiceIntent.powerOn, deviceName: 'LEDDMX-03-6B4A');
      final planner = VoicePlanParser(conversation: conversation);

      final result = planner.parse('make them blue');

      expect(result, isA<VoicePlanReady>());
      final steps = (result as VoicePlanReady).plan.steps;
      expect(steps.first, isA<ReconnectLastDeviceStep>());
      expect(steps.last, isA<SetColorStep>());
    });

    test('without memory the same follow-up stays a single step', () {
      final planner = VoicePlanParser();

      final result = planner.parse('make them blue');

      expect(result, isA<VoicePlanReady>());
      expect(
        (result as VoicePlanReady).plan.steps.single,
        isA<SetColorStep>(),
      );
    });

    test('a plan that already connects is not given a second reconnect', () {
      final conversation = VoiceConversation()
        ..record(intent: VoiceIntent.powerOn, deviceName: 'LEDDMX-03-6B4A');
      final planner = VoicePlanParser(conversation: conversation);

      final result = planner.parse('scan for devices and turn it on');

      expect(result, isA<VoicePlanReady>());
      final steps = (result as VoicePlanReady).plan.steps;
      expect(steps.whereType<ReconnectLastDeviceStep>(), isEmpty);
      expect(steps.first, isA<ScanDevicesStep>());
      expect(steps.last, isA<SetPowerStep>());
    });

    test('an explicit light noun does not use the follow-up shortcut', () {
      final conversation = VoiceConversation()
        ..record(intent: VoiceIntent.powerOn, deviceName: 'LEDDMX-03-6B4A');
      final planner = VoicePlanParser(conversation: conversation);

      final result = planner.parse('turn on the lights');

      expect(result, isA<VoicePlanReady>());
      expect(
        (result as VoicePlanReady).plan.steps.single,
        isA<SetPowerStep>(),
      );
    });
  });
}
