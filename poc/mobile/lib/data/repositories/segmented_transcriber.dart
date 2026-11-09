import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/speech_segmenter.dart';

class TranscribedSegment {
  const TranscribedSegment({
    required this.text,
    required this.region,
    required this.decodedAt,
  });

  final String text;
  final SpeechRegion region;
  final DateTime decodedAt;
}

class SegmentedTranscriber {
  SegmentedTranscriber({
    required this._decode,
    this.partialInterval = const Duration(milliseconds: 500),
    this.minDecodeSamples = 4000,
    this.keptSamples = 16000 * 30,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Future<String> Function(Float32List samples) _decode;
  final DateTime Function() _now;
  final Duration partialInterval;
  final int minDecodeSamples;
  final int keptSamples;

  final _SampleBuffer _audio = _SampleBuffer();
  final Queue<SpeechRegion> _regions = Queue<SpeechRegion>();
  final StreamController<String> _partials =
      StreamController<String>.broadcast();
  final StreamController<TranscribedSegment> _segments =
      StreamController<TranscribedSegment>.broadcast();
  int? _activeStart;
  int _partialEnd = 0;
  int _commits = 0;
  int _produced = 0;
  DateTime? _lastPartialAt;
  bool _busy = false;
  bool _closed = false;
  bool _cancelled = false;
  Object? _lastError;
  Completer<void>? _drained;

  Stream<String> get partialText => _partials.stream;

  Stream<TranscribedSegment> get segments => _segments.stream;

  int get length => _audio.length;

  int get keptFrom => _audio.first;

  void addAudio(Float32List samples) {
    if (_closed) return;
    _audio.add(samples);
    _discardOldAudio();
    _pump();
  }

  void _discardOldAudio() {
    if (_audio.length - _audio.first < 2 * keptSamples) return;
    var keepFrom = _audio.length - keptSamples;
    if (_regions.isNotEmpty) keepFrom = min(keepFrom, _regions.first.start);
    final active = _activeStart;
    if (active != null) keepFrom = min(keepFrom, active);
    _audio.discardBefore(keepFrom);
  }

  void setActiveStart(int? start) {
    if (_closed || start == _activeStart) return;
    _activeStart = start;
    _partialEnd = 0;
    _pump();
  }

  void addRegion(SpeechRegion region) {
    if (_closed) return;
    final end = min(region.end, _audio.length);
    _regions.add(SpeechRegion(min(region.start, end), end));
    _pump();
  }

  Future<void> finish() async {
    _closed = true;
    _activeStart = null;
    _pump();
    await _waitDrained();
    await _close();
    final error = _lastError;
    if (_produced == 0 && error != null) throw error;
  }

  Future<void> cancel() async {
    _closed = true;
    _cancelled = true;
    _regions.clear();
    await _waitDrained();
    await _close();
  }

  void _pump() {
    if (_busy) return;
    if (_cancelled) {
      _completeDrained();
      return;
    }
    if (_regions.isNotEmpty) {
      _run(_commitNext());
      return;
    }
    if (_closed) {
      _completeDrained();
      return;
    }
    final active = _activeStart;
    if (active == null) return;
    final last = _lastPartialAt;
    final due = last == null || _now().difference(last) >= partialInterval;
    final pending = _audio.length - active;
    if (due && _audio.length > _partialEnd && pending >= minDecodeSamples) {
      _run(_updatePartial(active));
    }
  }

  void _run(Future<void> job) {
    _busy = true;
    job
        .catchError((Object error) {
          debugPrint('Speech decoding failed: $error');
          _lastError = error;
        })
        .whenComplete(() {
          _busy = false;
          _pump();
        });
  }

  Future<void> _commitNext() async {
    final region = _regions.removeFirst();
    _commits++;
    try {
      if (region.length < minDecodeSamples) return;
      final text = (await _decode(_audio.slice(region.start, region.end)))
          .trim();
      if (_cancelled || text.isEmpty) return;
      _produced++;
      if (!_segments.isClosed) {
        _segments.add(
          TranscribedSegment(text: text, region: region, decodedAt: _now()),
        );
      }
    } finally {
      _emitPartial('');
    }
  }

  Future<void> _updatePartial(int start) async {
    final end = _audio.length;
    final commits = _commits;
    _lastPartialAt = _now();
    final text = await _decode(_audio.slice(start, end));
    if (_cancelled || _activeStart != start || _commits != commits) return;
    _partialEnd = end;
    _emitPartial(text.trim());
  }

  void _emitPartial(String text) {
    if (!_partials.isClosed) _partials.add(text);
  }

  Future<void> _close() async {
    await Future.wait([_partials.close(), _segments.close()]);
  }

  Future<void> _waitDrained() {
    if (!_busy && (_regions.isEmpty || _cancelled)) {
      return Future<void>.value();
    }
    return (_drained ??= Completer<void>()).future;
  }

  void _completeDrained() {
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }
}

class _SampleBuffer {
  Float32List _data = Float32List(16000 * 10);
  int _offset = 0;
  int _filled = 0;

  int get length => _offset + _filled;

  int get first => _offset;

  void add(Float32List samples) {
    if (_filled + samples.length > _data.length) {
      final grown = Float32List(
        max(_data.length * 2, _filled + samples.length),
      );
      grown.setRange(0, _filled, _data);
      _data = grown;
    }
    _data.setRange(_filled, _filled + samples.length, samples);
    _filled += samples.length;
  }

  void discardBefore(int index) {
    final dropped = min(index, length) - _offset;
    if (dropped <= 0) return;
    _data.setRange(0, _filled - dropped, _data, dropped);
    _filled -= dropped;
    _offset += dropped;
  }

  Float32List slice(int start, int end) {
    final from = max(start, _offset) - _offset;
    final to = max(end, _offset) - _offset;
    return Float32List.fromList(_data.sublist(from, max(from, to)));
  }
}
