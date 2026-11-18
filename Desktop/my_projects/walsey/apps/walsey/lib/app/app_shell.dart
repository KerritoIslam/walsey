import 'dart:async';

import 'package:flutter/material.dart';

import '../app/connection_presentation.dart';
import '../app/walsey_navigation.dart';
import '../connection/led_connection_service.dart';
import '../design/tokens.dart';
import '../design/widgets.dart';
import '../features/activity/activity_page.dart';
import '../features/activity/diagnostics_page.dart';
import '../features/assistant/assistant_page.dart';
import '../features/automations/automations_page.dart';
import '../features/connect/connect_page.dart';
import '../features/devices/devices_page.dart';
import '../features/home/home_page.dart';
import '../features/settings/settings_page.dart';
import '../features/studio/led_studio_page.dart';
import '../state/activity_log.dart';
import '../state/app_settings.dart';
import '../ui/log_view.dart';

/// Responsive application shell.
///
/// Windows: fixed sidebar + content + optional diagnostic dock.
/// Android: five-destination bottom navigation.
class WalseyShell extends StatefulWidget {
  const WalseyShell({
    super.key,
    required this.service,
    this.settings,
    this.activity,
  });

  final LedConnectionService service;
  final AppSettingsService? settings;
  final ActivityLog? activity;

  @override
  State<WalseyShell> createState() => _WalseyShellState();
}

class _WalseyShellState extends State<WalseyShell> {
  late final bool _ownsSettings = widget.settings == null;
  late final bool _ownsActivity = widget.activity == null;
  late final AppSettingsService _settings =
      widget.settings ?? AppSettingsService.inMemory();
  late final ActivityLog _activity = widget.activity ?? ActivityLog();

  WalseyPage _page = WalseyPage.home;
  late AppConnectionPhase _lastPhase;

  @override
  void initState() {
    super.initState();
    _lastPhase = widget.service.current.phase;
    widget.service.state.addListener(_onConnectionState);
  }

  @override
  void dispose() {
    widget.service.state.removeListener(_onConnectionState);
    if (_ownsSettings) _settings.dispose();
    if (_ownsActivity) _activity.dispose();
    super.dispose();
  }

  void _onConnectionState() {
    final state = widget.service.current;
    final previous = _lastPhase;
    if (state.phase == previous) return;
    _lastPhase = state.phase;

    switch (state.phase) {
      case AppConnectionPhase.connected:
        final name = deviceLabel(state.selected);
        _activity.add(
          kind: ActivityKind.connection,
          title: 'Connected to $name',
          detail: state.variant == null
              ? 'Link validated; controls unavailable.'
              : 'Variant ${state.variant!.advertisedName} · layout '
                    '${state.variant!.layout.name}',
          success: true,
        );
        unawaited(_settings.rememberDevice(name));
      case AppConnectionPhase.failed:
        _activity.add(
          kind: ActivityKind.connection,
          title: 'Connection unavailable',
          detail: state.error ?? 'Connection failed.',
          success: false,
        );
      case AppConnectionPhase.disconnected:
        if (previous == AppConnectionPhase.disconnecting ||
            previous == AppConnectionPhase.connected) {
          _activity.add(
            kind: ActivityKind.connection,
            title: 'Disconnected',
            detail: 'The Bluetooth link was released.',
          );
        }
      case AppConnectionPhase.scanning:
      case AppConnectionPhase.connecting:
      case AppConnectionPhase.discovering:
      case AppConnectionPhase.disconnecting:
        break;
    }
  }

  void _select(WalseyPage page) => setState(() => _page = page);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppSettings>(
    valueListenable: _settings.listenable,
    builder: (context, settings, _) => ValueListenableBuilder<AppConnectionState>(
      valueListenable: widget.service.state,
      builder: (context, state, _) {
        final compact = MediaQuery.sizeOf(context).width < 900;
        final page = _pageFor(state, compact);
        if (compact) {
          return Scaffold(
            body: SafeArea(bottom: false, child: page),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _mobileIndex(),
              onDestinationSelected: (index) =>
                  _select(mobileDestinations[index]),
              destinations: [
                for (final destination in mobileDestinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: destination.label,
                  ),
              ],
            ),
          );
        }
        return Scaffold(
          body: Row(
            children: [
              _Sidebar(
                selected: _page,
                state: state,
                onSelect: _select,
                onOpenDevices: () => _select(WalseyPage.devices),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: SafeArea(bottom: false, child: page)),
                    if (settings.showDiagnosticsPanel)
                      _DiagnosticDock(
                        service: widget.service,
                        onHide: () =>
                            _settings.setShowDiagnosticsPanel(false),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  int _mobileIndex() {
    final index = mobileDestinations.indexOf(_page);
    return index < 0 ? 0 : index;
  }

  Widget _pageFor(AppConnectionState state, bool compact) => switch (_page) {
    WalseyPage.home => HomePage(
      service: widget.service,
      state: state,
      settings: _settings,
      activity: _activity,
      onNavigate: _select,
      compact: compact,
    ),
    WalseyPage.devices => DevicesPage(
      service: widget.service,
      state: state,
      onNavigate: _select,
      compact: compact,
    ),
    WalseyPage.studio => LedStudioPage(
      state: state,
      controls: widget.service.controls,
      settings: _settings,
      onNavigate: _select,
      compact: compact,
    ),
    WalseyPage.assistant => AssistantPage(
      service: widget.service,
      connected: state.controlsAvailable,
      compact: compact,
      activity: _activity,
      settings: _settings,
    ),
    WalseyPage.connect => ConnectPage(compact: compact),
    WalseyPage.automations => AutomationsPage(compact: compact),
    WalseyPage.activity => ActivityPage(
      activity: _activity,
      service: widget.service,
      onNavigate: _select,
      compact: compact,
    ),
    WalseyPage.settings => SettingsPage(
      settings: _settings,
      activity: _activity,
      service: widget.service,
      onNavigate: _select,
      compact: compact,
    ),
  };
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.state,
    required this.onSelect,
    required this.onOpenDevices,
  });

  final WalseyPage selected;
  final AppConnectionState state;
  final ValueChanged<WalseyPage> onSelect;
  final VoidCallback onOpenDevices;

  @override
  Widget build(BuildContext context) => Container(
    width: WalseySpacing.sidebarWidth,
    decoration: const BoxDecoration(
      color: WalseyColors.bg,
      border: Border(right: BorderSide(color: WalseyColors.border)),
    ),
    padding: const EdgeInsets.fromLTRB(
      WalseySpacing.lg,
      WalseySpacing.xxxl,
      WalseySpacing.lg,
      WalseySpacing.lg,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: WalseySpacing.lg),
          child: Row(
            children: [
              Icon(Icons.blur_on, size: 22, color: WalseyColors.primaryText),
              SizedBox(width: WalseySpacing.sm),
              Text(
                'Walsey',
                style: TextStyle(
                  fontFamily: WalseyType.family,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: WalseyColors.text,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: WalseySpacing.xxxl),
        for (final page in sidebarPrimary)
          _SidebarButton(
            page: page,
            selected: selected == page,
            onTap: () => onSelect(page),
          ),
        const Spacer(),
        const Divider(height: 1),
        const SizedBox(height: WalseySpacing.md),
        for (final page in sidebarSecondary)
          _SidebarButton(
            page: page,
            selected: selected == page,
            onTap: () => onSelect(page),
          ),
        const SizedBox(height: WalseySpacing.md),
        _SidebarStatus(state: state, onTap: onOpenDevices),
      ],
    ),
  );
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.page,
    required this.selected,
    required this.onTap,
  });

  final WalseyPage page;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(WalseyRadius.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(WalseyRadius.control),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WalseySpacing.lg,
              ),
              child: Row(
                children: [
                  Icon(
                    selected ? page.selectedIcon : page.icon,
                    size: 18,
                    color: selected ? primary : WalseyColors.textSecondary,
                  ),
                  const SizedBox(width: WalseySpacing.md),
                  Expanded(
                    child: Text(
                      page.label,
                      style: TextStyle(
                        fontFamily: WalseyType.family,
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected ? Colors.white : WalseyColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (page.planned)
                    Tooltip(
                      message: 'Planned capability',
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: selected
                              ? WalseyColors.primaryText
                              : WalseyColors.textMuted,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus({required this.state, required this.onTap});

  final AppConnectionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(WalseyRadius.card),
    child: Container(
      padding: const EdgeInsets.all(WalseySpacing.lg),
      decoration: BoxDecoration(
        color: WalseyColors.surface,
        borderRadius: BorderRadius.circular(WalseyRadius.card),
        border: Border.all(color: WalseyColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  state.isConnected
                      ? deviceLabel(state.selected)
                      : 'No controller',
                  style: WalseyType.caption.copyWith(
                    color: WalseyColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: WalseySpacing.xs),
              WBadge(
                label: connectionPhaseLabel(state),
                tone: connectionTone(state),
              ),
            ],
          ),
          const SizedBox(height: WalseySpacing.xs),
          Text(
            state.isConnected
                ? 'No state read-back'
                : 'Bluetooth · LEDDMX',
            style: WalseyType.caption,
          ),
        ],
      ),
    ),
  );
}

class _DiagnosticDock extends StatelessWidget {
  const _DiagnosticDock({required this.service, required this.onHide});

  final LedConnectionService service;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppConnectionState>(
    valueListenable: service.state,
    builder: (context, state, _) => Container(
      height: 168,
      decoration: const BoxDecoration(
        color: WalseyColors.bg,
        border: Border(top: BorderSide(color: WalseyColors.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WalseySpacing.huge,
              WalseySpacing.xs,
              WalseySpacing.md,
              0,
            ),
            child: Row(
              children: [
                const WSectionLabel('Diagnostics'),
                const SizedBox(width: WalseySpacing.md),
                Text(
                  '${state.logs.length} lines',
                  style: WalseyType.caption,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DiagnosticsPage(service: service),
                    ),
                  ),
                  child: const Text('Full log'),
                ),
                TextButton(
                  onPressed: onHide,
                  child: const Text('Hide'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: WalseySpacing.md, right: WalseySpacing.sm),
              child: LogView(logs: state.logs),
            ),
          ),
        ],
      ),
    ),
  );
}
