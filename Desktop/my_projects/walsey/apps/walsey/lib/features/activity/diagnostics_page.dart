import 'package:flutter/material.dart';

import '../../connection/led_connection_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../ui/log_view.dart';

/// Raw diagnostic log, kept one tap away so the main pages can stay readable.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key, required this.service});

  final LedConnectionService service;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppConnectionState>(
    valueListenable: service.state,
    builder: (context, state, _) {
      final compact = MediaQuery.sizeOf(context).width < 720;
      return Scaffold(
        body: SafeArea(
          child: WPageBody(
            compact: compact,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: WalseySpacing.xs),
                  const Expanded(
                    child: WPageHeader(
                      title: 'Diagnostics',
                      caption:
                          'Raw connection and command log. The handshake '
                          'password is redacted before it is written.',
                    ),
                  ),
                  WBadge(
                    label: '${state.logs.length} lines',
                    tone: WBadgeTone.offline,
                  ),
                ],
              ),
              WCard(
                padding: const EdgeInsets.all(WalseySpacing.xs),
                child: SizedBox(
                  height: compact ? 460 : 520,
                  child: LogView(logs: state.logs),
                ),
              ),
              const WInfoBanner(
                tone: WInfoTone.info,
                message:
                    'Diagnostic output, not device state. Stages are labelled: '
                    'VOICE RECOGNIZED (transcript) → VOICE INTERPRETED (plan or '
                    'rejection) → PLAN STEP / ACTION STARTED → RESULT … BLE '
                    'WRITE OK (frame written, LED reaction unknown). Only a '
                    'HARDWARE RESPONSE line is a controller reply, and only a '
                    'USER OBSERVATION line records a visible LED change.',
              ),
            ],
          ),
        ),
      );
    },
  );
}
