import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../connection/led_connection_service.dart';
import '../control/led_control_service.dart';

/// Deliberately conservative first-hardware-test path.
///
/// Each button writes exactly one frame. Nothing here runs automatically and
/// nothing treats a BLE write as proof that the LEDs reacted.
class HardwareTestTab extends StatelessWidget {
  const HardwareTestTab({
    super.key,
    required this.service,
    required this.controls,
    required this.busy,
  });

  final LedConnectionService service;
  final LedControlService controls;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Card(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Controlled first test',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                const Text(
                  'Send ONE frame per press and watch the strip. Start at step '
                  '1. If step 2 or 3 produces no change, stop and investigate '
                  'the protocol instead of trying random frames. Frames below '
                  'are decompiled-app evidence, not hardware-confirmed.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Logs show the resolved variant, command, frame hex, write '
                  'mode and write result. The handshake password is redacted.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        _TestStep(
          number: 1,
          title: 'Authenticate (handshake)',
          detail: 'Writes 2A 02 **** <tb> <min> AF once. LED_UNION reports the '
              'controller ignores commands until this is sent. Side effect: it '
              'sets the controller clock. No LEDs should change.',
          action: busy
              ? null
              : () => unawaited(controls.authenticate()),
        ),
        _TestStep(
          number: 2,
          title: 'Check password status (2A 05)',
          detail: 'Writes the password query and waits up to 2 s for a '
              'notification reply. This is the only documented response; it '
              'proves the controller accepted a 2A frame. It does not change '
              'the LEDs.',
          action: busy
              ? null
              : () => unawaited(controls.checkPasswordStatus()),
        ),
        _TestStep(
          number: 3,
          title: 'Power OFF',
          detail: 'Writes 7B 04 04 00 FF FF FF FF BF (filler). Reversible '
              'baseline: if the strip is on, it should turn off. The frame has '
              'never been observed on this unit.',
          action: busy
              ? null
              : () => unawaited(controls.setPower(on: false)),
        ),
        _TestStep(
          number: 4,
          title: 'Power ON',
          detail: 'Writes 7B 04 04 01 FF FF FF FF BF (filler).',
          action: busy
              ? null
              : () => unawaited(controls.setPower(on: true)),
        ),
        _TestStep(
          number: 5,
          title: 'Set RED',
          detail: 'Writes 7B FF 07 FF 00 00 00 FF BF (filler). If the result '
              'is a different colour or only part of the strip reacts, suspect '
              'pixel count / channel order (H9), not the frame.',
          action: busy
              ? null
              : () => unawaited(controls.setColor(RgbColor(255, 0, 0))),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Record what you saw',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                const Text(
                  'Recorded separately from the BLE write result. Manual '
                  'observations never raise protocol evidence automatically.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => service.logObservation(
                        ledsChanged: true,
                      ),
                      icon: const Icon(Icons.visibility),
                      label: const Text('LEDs changed'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => service.logObservation(
                        ledsChanged: false,
                      ),
                      icon: const Icon(Icons.visibility_off),
                      label: const Text('No visible change'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Turn the LEDs off immediately',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: busy
                      ? null
                      : () => unawaited(controls.setPower(on: false)),
                  child: const Text('ALL OFF'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _TestStep extends StatelessWidget {
  const _TestStep({
    required this.number,
    required this.title,
    required this.detail,
    required this.action,
  });

  final int number;
  final String title;
  final String detail;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text('$number')),
        title: Text(title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(detail, style: const TextStyle(fontSize: 12)),
        ),
        trailing: FilledButton.tonal(
          onPressed: action,
          child: const Text('Send'),
        ),
      ),
    );
  }
}
