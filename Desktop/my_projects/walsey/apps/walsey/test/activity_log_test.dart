import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walsey/state/activity_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('adds newest entries first and notifies listeners', () {
    final log = ActivityLog();
    addTearDown(log.dispose);
    var notifications = 0;
    log.addListener(() => notifications++);

    log.add(
      kind: ActivityKind.connection,
      title: 'Connected',
      time: DateTime(2026, 10, 31, 9, 0, 0),
    );
    log.add(
      kind: ActivityKind.command,
      title: 'Colour sent',
      detail: 'frame 7b ff 07',
      success: true,
      time: DateTime(2026, 10, 31, 9, 1, 2),
    );

    expect(log.entries, hasLength(2));
    expect(log.entries.first.title, 'Colour sent');
    expect(log.entries.first.success, isTrue);
    expect(log.entries.first.timeLabel, '09:01:02');
    expect(log.entries.last.title, 'Connected');
    expect(log.entries.last.success, isNull);
    expect(notifications, 2);
  });

  test('caps history at the configured limit', () {
    final log = ActivityLog(limit: 3);
    addTearDown(log.dispose);

    for (var index = 0; index < 5; index++) {
      log.add(kind: ActivityKind.system, title: 'entry $index');
    }

    expect(log.entries.map((entry) => entry.title), [
      'entry 4',
      'entry 3',
      'entry 2',
    ]);
  });

  test('persists entries and reloads them in order', () async {
    final prefs = await SharedPreferences.getInstance();
    final log = ActivityLog(prefs: prefs);

    log.add(
      kind: ActivityKind.voice,
      title: 'Heard "turn the lights on"',
      detail: 'Interpreted as power on',
      time: DateTime(2026, 10, 31, 12, 30, 15),
    );
    log.add(
      kind: ActivityKind.command,
      title: 'Power on · write completed',
      detail: 'Frame 7b 04 04 01',
      success: true,
      time: DateTime(2026, 10, 31, 12, 31, 0),
    );
    log.dispose();

    // Persistence is fire-and-forget; the cached value is already updated.
    final reloaded = await ActivityLog.load();
    addTearDown(reloaded.dispose);

    expect(reloaded.entries, hasLength(2));
    expect(reloaded.entries.first.title, 'Power on · write completed');
    expect(reloaded.entries.first.kind, ActivityKind.command);
    expect(reloaded.entries.first.success, isTrue);
    expect(reloaded.entries.first.time, DateTime(2026, 10, 31, 12, 31, 0));
    expect(reloaded.entries.last.kind, ActivityKind.voice);
    expect(reloaded.entries.last.detail, 'Interpreted as power on');
    expect(reloaded.entries.last.success, isNull);
  });

  test('clear removes both live and persisted history', () async {
    final prefs = await SharedPreferences.getInstance();
    final log = ActivityLog(prefs: prefs);

    log.add(kind: ActivityKind.system, title: 'something happened');
    expect(log.entries, isNotEmpty);

    await log.clear();
    expect(log.entries, isEmpty);

    final reloaded = await ActivityLog.load();
    addTearDown(reloaded.dispose);
    expect(reloaded.entries, isEmpty);
    log.dispose();
  });

  test('ignores corrupt stored history instead of throwing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'walsey.activity': 'not json at all',
    });

    final log = await ActivityLog.load();
    addTearDown(log.dispose);
    expect(log.entries, isEmpty);
  });

  test('skips malformed entries but keeps valid ones', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'walsey.activity':
          '[{"t":"2026-10-31T08:00:00.000","k":"command","title":"ok",'
              '"detail":"frame","success":true},'
              '{"t":"nope","k":"command","title":"bad time"},'
              '{"t":"2026-10-31T08:01:00.000","k":"unknown-kind","title":"bad kind"},'
              '{"t":"2026-10-31T08:02:00.000","k":"voice","title":"kept"}]',
    });

    final log = await ActivityLog.load();
    addTearDown(log.dispose);

    expect(log.entries.map((entry) => entry.title), ['ok', 'kept']);
    expect(log.entries.first.success, isTrue);
    expect(log.entries.last.success, isNull);
  });
}
