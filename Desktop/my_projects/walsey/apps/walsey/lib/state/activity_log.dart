import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ActivityKind { command, connection, voice, system }

@immutable
final class ActivityEntry {
  const ActivityEntry({
    required this.time,
    required this.kind,
    required this.title,
    this.detail = '',
    this.success,
  });

  final DateTime time;
  final ActivityKind kind;
  final String title;
  final String detail;

  /// `true` = BLE write completed, `false` = failed/refused, null = neutral.
  final bool? success;

  String get timeLabel =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() => {
    't': time.toIso8601String(),
    'k': kind.name,
    'title': title,
    'detail': detail,
    'success': success,
  };

  static ActivityEntry? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final time = DateTime.tryParse('${raw['t']}');
    ActivityKind? kind;
    for (final value in ActivityKind.values) {
      if (value.name == raw['k']) kind = value;
    }
    final title = raw['title'];
    if (time == null || kind == null || title is! String) return null;
    final detail = raw['detail'];
    final success = raw['success'];
    return ActivityEntry(
      time: time,
      kind: kind,
      title: title,
      detail: detail is String ? detail : '',
      success: success is bool ? success : null,
    );
  }
}

/// Structured activity ledger: commands sent, connection lifecycle and voice
/// outcomes. Diagnosis strings continue to live in [LedConnectionService];
/// this ledger is the human-facing history and is safe to persist because the
/// service already redacts the handshake password before logging.
final class ActivityLog extends ChangeNotifier {
  ActivityLog({SharedPreferences? prefs, this.limit = 200})
    // ignore: prefer_initializing_formals
    : _prefs = prefs;

  static const _key = 'walsey.activity';

  final SharedPreferences? _prefs;
  final int limit;
  final List<ActivityEntry> _entries = [];

  List<ActivityEntry> get entries => List<ActivityEntry>.unmodifiable(_entries);

  static Future<ActivityLog> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object catch (error) {
      debugPrint('[WalseyApp] activity history unavailable: $error');
    }
    final log = ActivityLog(prefs: prefs);
    final raw = prefs?.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final entry = ActivityEntry.fromJson(item);
            if (entry != null) log._entries.add(entry);
          }
        }
      } on Object catch (error) {
        debugPrint('[WalseyApp] could not read activity history: $error');
      }
    }
    return log;
  }

  void add({
    required ActivityKind kind,
    required String title,
    String detail = '',
    bool? success,
    DateTime? time,
  }) {
    _entries.insert(
      0,
      ActivityEntry(
        time: time ?? DateTime.now(),
        kind: kind,
        title: title,
        detail: detail,
        success: success,
      ),
    );
    if (_entries.length > limit) _entries.removeRange(limit, _entries.length);
    notifyListeners();
    _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    try {
      await _prefs?.remove(_key);
    } on Object catch (error) {
      debugPrint('[WalseyApp] could not clear activity history: $error');
    }
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final encoded = jsonEncode(
        _entries.map((entry) => entry.toJson()).toList(),
      );
      // Fire-and-forget: history must never block a command.
      prefs.setString(_key, encoded);
    } on Object catch (error) {
      debugPrint('[WalseyApp] could not persist activity history: $error');
    }
  }
}
