import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/widgets.dart';

class AutomationsPage extends StatelessWidget {
  const AutomationsPage({super.key, required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => WPageBody(
    compact: compact,
    children: [
      WPlannedFeature(
        compact: compact,
        icon: Icons.bolt_outlined,
        title: 'Automations',
        summary:
            'Routines that combine supported devices and actions: when '
            'something happens, optionally check a condition, then run an '
            'explicit sequence. There is no execution engine or storage in '
            'this build, so nothing on this page runs.',
        requirements: const [
          'A persisted routine model with validated triggers, conditions and '
              'actions.',
          'A scheduler / event source, including connection events that '
              'already exist in the app.',
          'An execution engine that maps actions onto the existing typed '
              'command facade — no parallel command path, no automatic frames.',
          'A clear consent step, because running LED commands automatically '
              'conflicts with the current rule that every frame is explicit.',
          'Execution history with real outcomes and a way to stop a routine.',
        ],
        note:
            'The existing app deliberately never sends a frame automatically. '
            'Automations must solve that explicitly rather than silently '
            'weakening the guarantee.',
      ),
      WCard(
        label: 'A routine, once implemented',
        child: Column(
          children: [
            WListRow(
              title: 'Trigger',
              caption: 'Example: a controller connects over Bluetooth.',
              leading: const Icon(
                Icons.play_circle_outline,
                size: 18,
                color: WalseyColors.textMuted,
              ),
              trailing: const WBadge(
                label: 'Concept',
                tone: WBadgeTone.planned,
              ),
            ),
            WListRow(
              title: 'Condition',
              caption: 'Example: the resolved layout is filler.',
              leading: const Icon(
                Icons.filter_alt_outlined,
                size: 18,
                color: WalseyColors.textMuted,
              ),
              trailing: const WBadge(
                label: 'Concept',
                tone: WBadgeTone.planned,
              ),
            ),
            WListRow(
              title: 'Action',
              caption:
                  'Example: send a colour frame through the existing LED '
                  'control service.',
              leading: const Icon(
                Icons.lightbulb_outline,
                size: 18,
                color: WalseyColors.textMuted,
              ),
              trailing: const WBadge(
                label: 'Concept',
                tone: WBadgeTone.planned,
              ),
              showDivider: false,
            ),
          ],
        ),
      ),
      const WInfoBanner(
        tone: WInfoTone.warning,
        title: 'No routine is active',
        message:
            'There are no toggles or save buttons here on purpose. Until the '
            'engine exists, an automation control would be decorative.',
      ),
    ],
  );
}
