import 'package:flutter/material.dart';

/// Primary navigation entries. Home, Devices, Studio, Assistant and Settings
/// are the five mobile destinations; the rest are desktop sidebar entries or
/// secondary pages.
enum WalseyPage {
  home,
  devices,
  connect,
  studio,
  automations,
  assistant,
  activity,
  settings,
}

extension WalseyPageInfo on WalseyPage {
  String get label => switch (this) {
    WalseyPage.home => 'Home',
    WalseyPage.devices => 'Devices',
    WalseyPage.connect => 'Connect',
    WalseyPage.studio => 'Studio',
    WalseyPage.automations => 'Automations',
    WalseyPage.assistant => 'Assistant',
    WalseyPage.activity => 'Activity',
    WalseyPage.settings => 'Settings',
  };

  IconData get icon => switch (this) {
    WalseyPage.home => Icons.home_outlined,
    WalseyPage.devices => Icons.devices_other_outlined,
    WalseyPage.connect => Icons.sync_alt,
    WalseyPage.studio => Icons.lightbulb_outline,
    WalseyPage.automations => Icons.bolt_outlined,
    WalseyPage.assistant => Icons.mic_none_outlined,
    WalseyPage.activity => Icons.history,
    WalseyPage.settings => Icons.settings_outlined,
  };

  IconData get selectedIcon => switch (this) {
    WalseyPage.home => Icons.home,
    WalseyPage.devices => Icons.devices_other,
    WalseyPage.connect => Icons.sync_alt,
    WalseyPage.studio => Icons.lightbulb,
    WalseyPage.automations => Icons.bolt,
    WalseyPage.assistant => Icons.mic,
    WalseyPage.activity => Icons.history,
    WalseyPage.settings => Icons.settings,
  };

  /// Capabilities designed but not implemented in this build.
  bool get planned =>
      this == WalseyPage.connect || this == WalseyPage.automations;
}

const List<WalseyPage>mobileDestinations = [
  WalseyPage.home,
  WalseyPage.devices,
  WalseyPage.studio,
  WalseyPage.assistant,
  WalseyPage.settings,
];

const List<WalseyPage>sidebarPrimary = [
  WalseyPage.home,
  WalseyPage.devices,
  WalseyPage.connect,
  WalseyPage.studio,
  WalseyPage.automations,
  WalseyPage.assistant,
];

const List<WalseyPage>sidebarSecondary = [
  WalseyPage.activity,
  WalseyPage.settings,
];
