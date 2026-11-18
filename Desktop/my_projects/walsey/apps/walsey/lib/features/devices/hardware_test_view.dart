import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../../connection/led_connection_service.dart';
import '../../control/led_control_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

/// The controlled first-hardware-test procedure, restyled but deliberately
/// unchanged in behaviour: one explicit frame per press, no automation, and
/// no claim that a BLE write changed the LEDs.
class HardwareTestView extends StatelessWidget {
  const HardwareTestView({
    super.key,
    required this.service,
    required this.controls,
    required this.busy,
  });

  final LedConnectionService service;
  final LedControlService controls;
  final bool busy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WCard(
        label: 'Diagnostics',
        trailing: const WBadge(label: 'Evidence: decompiled app', tone: WBadgeTone.planned),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Controlled first test',
              style: WalseyType.sectionTitle,
            ),
            const SizedBox(height: WalseySpacing.sm),
            const Text(
              'Send ONE frame per press and watch the strip. Start at step 1. '
              'If a step produces no visible change, stop and investigate the '
              'protocol instead of trying random frames. Every frame below is '
              'decompiled-app evidence, not hardware-confirmed.',
              style: WalseyType.caption,
            ),
            const SizedBox(height: WalseySpacing.md),
            Text(
              'Variant ${controls.variantLabel} · layout ${controls.layoutLabel}. '
              'Logs show the resolved variant, command, frame hex, write mode '
              'and write result. The handshake password is redacted.',
              style: WalseyType.caption,
            ),
          ],
        ),
      ),
      _TestStep(
        number: 1,
        title: 'Authenticate (handshake)',
        detail:
            'Writes 2A 02 **** <tb> <min> AF once. LED_UNION reports the '
            'controller ignores commands until this is sent. Side effect: it '
            'sets the controller clock. No LEDs should change.',
        action: busy ? null : () => unawaited(controls.authenticate()),
      ),
      _TestStep(
        number: 2,
        title: 'Check password status (2A 05)',
        detail:
            'Writes the password query and waits up to 2 s for a notification '
            'reply. This is the only documented response; it proves the '
            'controller accepted a 2A frame. It does not change the LEDs.',
        action: busy ? null : () => unawaited(controls.checkPasswordStatus()),
      ),
      _TestStep(
        number: 3,
        title: 'Power OFF',
        detail:
            'Writes 7B 04 04 00 FF FF FF FF BF (filler). Reversible baseline: '
            'if the strip is on, it should turn off. Never observed on this '
            'unit.',
        action: busy ? null : () => unawaited(controls.setPower(on: false)),
      ),
      _TestStep(
        number: 4,
        title: 'Power ON',
        detail: 'Writes 7B 04 04 01 FF FF FF FF BF (filler).',
        action: busy ? null : () => unawaited(controls.setPower(on: true)),
      ),
      _TestStep(
        number: 5,
        title: 'Set RED',
        detail:
            'Writes 7B FF 07 FF 00 00 00 FF BF (filler). If the result is a '
            'different colour or only part of the strip reacts, suspect pixel '
            'count / channel order (H9), not the frame.',
        action: busy
            ? null
            : () => unawaited(controls.setColor(RgbColor(255, 0, 0))),
      ),
      WCard(
        label: 'Record what you saw',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recorded separately from the BLE write result. Manual '
              'observations never raise protocol evidence automatically.',
              style: WalseyType.caption,
            ),
            const SizedBox(height: WalseySpacing.lg),
            Wrap(
              spacing: WalseySpacing.sm,
              runSpacing: WalseySpacing.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: () =>
                      service.logObservation(ledsChanged: true),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('LEDs changed'),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      service.logObservation(ledsChanged: false),
                  icon: const Icon(Icons.visibility_off_outlined, size: 18),
                  label: const Text('No visible change'),
                ),
              ],
            ),
          ],
        ),
      ),
      WCard(
        child: Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Emergency stop', style: WalseyType.rowTitle),
                  SizedBox(height: 2),
                  Text(
                    'Sends the power-off frame. Always available.',
                    style: WalseyType.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: WalseySpacing.md),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: WalseyColors.error,
                foregroundColor: Colors.white,
              ),
              onPressed: busy
                  ? null
                  : () => unawaited(controls.setPower(on: false)),
              child: const Text('ALL OFF'),
            ),
          ],
        ),
      ),
    ],
  );
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
  Widget build(BuildContext context) => WCard(
    padding: const EdgeInsets.all(WalseySpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: WalseyColors.surfaceRaised,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$number',
                style: WalseyType.badge.copyWith(color: WalseyColors.text),
              ),
            ),
            const SizedBox(width: WalseySpacing.md),
            Expanded(child: Text(title, style: WalseyType.rowTitle)),
            const SizedBox(width: WalseySpacing.sm),
            FilledButton.tonal(
              onPressed: action,
              style: FilledButton.styleFrom(
                backgroundColor: WalseyColors.surfaceRaised,
                foregroundColor: WalseyColors.text,
                minimumSize: const Size(76, 38),
              ),
              child: const Text('Send'),
            ),
          ],
        ),
        const SizedBox(height: WalseySpacing.sm),
        Text(detail, style: WalseyType.caption),
      ],
    ),
  );
}
