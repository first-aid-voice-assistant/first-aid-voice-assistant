class EventLogEntry {
  const EventLogEntry({
    required this.id,
    required this.timestamp,
    required this.elapsed,
    required this.action,
    required this.transcript,
    this.label,
    this.confidence,
    this.source,
  });

  final String id;

  final DateTime timestamp;

  final Duration elapsed;

  final String action;

  final String transcript;

  final String? label;

  final double? confidence;

  final String? source;

  String get displayName => label ?? action;

  EventLogEntry withElapsed(Duration elapsed) => EventLogEntry(
    id: id,
    timestamp: timestamp,
    elapsed: elapsed,
    action: action,
    transcript: transcript,
    label: label,
    confidence: confidence,
    source: source,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'elapsed_s': elapsed.inMilliseconds / 1000,
    'action': action,
    'transcript': transcript,
    if (confidence != null) 'confidence': confidence,
    if (source != null) 'source': source,
  };
}
