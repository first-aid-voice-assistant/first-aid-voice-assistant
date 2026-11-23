import 'dart:convert';

import 'package:first_aid_voice_assistant/data/repositories/event_log_repository.dart';
import 'package:first_aid_voice_assistant/domain/models/event_log_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 11, 10, 9, 15, 32);

  EventLogEntry entry(String action, int secondsAfterStart, {String? id}) =>
      EventLogEntry(
        id: id ?? '$action-$secondsAfterStart',
        timestamp: start.add(Duration(seconds: secondsAfterStart)),
        elapsed: const Duration(seconds: 99),
        action: action,
        transcript: 'tekst',
      );

  List<String> actions(EventLogRepository log) => [
    for (final e in log.entries) e.action,
  ];

  test('counts the elapsed time from its own first entry', () {
    final log = EventLogRepository()
      ..add(entry('CALL_EMERGENCY', 0))
      ..add(entry('CHEST_COMPRESSIONS', 50));

    expect(log.entries.map((e) => e.elapsed), [
      Duration.zero,
      const Duration(seconds: 50),
    ]);
  });

  test('keeps entries in the order they were said, not received', () {
    final log = EventLogRepository()
      ..add(entry('CHEST_COMPRESSIONS', 50))
      ..add(entry('CALL_EMERGENCY', 10));

    expect(actions(log), ['CALL_EMERGENCY', 'CHEST_COMPRESSIONS']);
    expect(log.entries.last.elapsed, const Duration(seconds: 40));
  });

  test('logs an action repeated right after itself once', () {
    final log = EventLogRepository();

    expect(log.add(entry('CHEST_COMPRESSIONS', 0)), isNotNull);
    expect(log.add(entry('CHEST_COMPRESSIONS', 20)), isNull);
    log.add(entry('RESCUE_BREATHS', 40));
    log.add(entry('CHEST_COMPRESSIONS', 50));

    expect(actions(log), [
      'CHEST_COMPRESSIONS',
      'RESCUE_BREATHS',
      'CHEST_COMPRESSIONS',
    ]);
  });

  test('ignores an entry it already has', () {
    final log = EventLogRepository()..add(entry('CALL_EMERGENCY', 0, id: 'a'));

    expect(log.add(entry('CHECK_BREATHING', 5, id: 'a')), isNull);
    expect(actions(log), ['CALL_EMERGENCY']);
  });

  test('exports the shared entry format', () {
    final log = EventLogRepository()
      ..add(entry('CALL_EMERGENCY', 0))
      ..add(entry('CHEST_COMPRESSIONS', 2));

    final exported = jsonDecode(log.toJson()) as List<dynamic>;

    expect(exported.last, {
      'id': 'CHEST_COMPRESSIONS-2',
      'timestamp': '2026-11-10T09:15:34.000Z',
      'elapsed_s': 2.0,
      'action': 'CHEST_COMPRESSIONS',
      'transcript': 'tekst',
    });
  });
}
