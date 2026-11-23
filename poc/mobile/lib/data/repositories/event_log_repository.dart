import 'dart:convert';

import '../../domain/models/event_log_entry.dart';

class EventLogRepository {
  final List<EventLogEntry> _entries = [];

  bool get isEmpty => _entries.isEmpty;

  List<EventLogEntry> get entries {
    if (_entries.isEmpty) return const [];
    final start = _entries.first.timestamp;
    return [
      for (final entry in _entries)
        entry.withElapsed(_notNegative(entry.timestamp.difference(start))),
    ];
  }

  EventLogEntry? add(EventLogEntry entry) {
    if (_entries.any((logged) => logged.id == entry.id)) return null;
    final index = _insertionIndex(entry.timestamp);
    if (index > 0 && _entries[index - 1].action == entry.action) return null;
    _entries.insert(index, entry);
    return entries[index];
  }

  void clear() => _entries.clear();

  String toJson() =>
      const JsonEncoder.withIndent('  ')
          .convert([for (final entry in entries) entry.toJson()]);

  int _insertionIndex(DateTime timestamp) {
    var index = _entries.length;
    while (index > 0 && _entries[index - 1].timestamp.isAfter(timestamp)) {
      index--;
    }
    return index;
  }

  static Duration _notNegative(Duration duration) =>
      duration.isNegative ? Duration.zero : duration;
}
