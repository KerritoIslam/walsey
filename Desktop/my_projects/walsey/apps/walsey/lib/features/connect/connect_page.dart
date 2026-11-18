import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/widgets.dart';

class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key, required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => WPageBody(
    compact: compact,
    children: [
      WPlannedFeature(
        compact: compact,
        icon: Icons.sync_alt,
        title: 'Phone ↔ PC',
        summary:
            'One Walsey ecosystem across your phone and computer: files, '
            'clipboard, notifications and remote input. The LED controller is '
            'the only device integration implemented in this build, so this '
            'page documents the requirement instead of faking a connection.',
        requirements: const [
          'A pairing and trust service shared by Windows and Android, with an '
              'explicit code confirmation and a stored device identity.',
          'A file-transfer service with real chunked progress, cancellation '
              'and a resume story — never a simulated progress bar.',
          'Platform adapters for clipboard and notification access, including '
              'the Android notification-listener permission flow.',
          'A remote-input channel with authentication and a clear consent '
              'model on the receiving device.',
          'End-to-end tests across two real devices before any control is '
              'presented as working.',
        ],
        note:
            'Navigation keeps this entry visible so the roadmap is honest and '
            'the eventual feature has a home. No pairing, transfer, clipboard '
            'or notification code exists yet.',
      ),
      WCard(
        label: 'Planned capabilities',
        child: Column(
          children: [
            for (final capability in const [
              (Icons.folder_outlined, 'File transfer', 'Both directions'),
              (Icons.content_copy, 'Clipboard sync', 'Text and links'),
              (Icons.notifications_none, 'Notification sync', 'Phone → PC'),
              (Icons.keyboard_outlined, 'Remote input', 'PC controls phone'),
            ])
              WListRow(
                title: capability.$2,
                caption: capability.$3,
                leading: Icon(
                  capability.$1,
                  size: 18,
                  color: WalseyColors.textMuted,
                ),
                trailing: const WBadge(
                  label: 'Not built',
                  tone: WBadgeTone.offline,
                ),
              ),
          ],
        ),
      ),
      const WInfoBanner(
        tone: WInfoTone.info,
        title: 'Current working integration',
        message:
            'Walsey can discover, connect to and command a documented LEDDMX '
            'controller over Bluetooth Low Energy. That path is real; '
            'everything on this page is still a plan.',
      ),
    ],
  );
}
