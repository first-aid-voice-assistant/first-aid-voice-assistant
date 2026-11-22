import 'dart:async';

abstract interface class BeatClock {
  bool get isRunning;

  void start(Duration period, void Function() onBeat);

  void stop();
}

class TimerBeatClock implements BeatClock {
  Timer? _timer;
  Stopwatch? _elapsed;
  Duration _period = Duration.zero;
  int _beats = 0;
  void Function()? _onBeat;

  @override
  bool get isRunning => _timer != null;

  @override
  void start(Duration period, void Function() onBeat) {
    stop();
    _period = period;
    _onBeat = onBeat;
    _beats = 0;
    _elapsed = Stopwatch()..start();
    _beat();
  }

  void _beat() {
    final elapsed = _elapsed;
    final onBeat = _onBeat;
    if (elapsed == null || onBeat == null) return;
    _beats++;
    final next = _period * _beats - elapsed.elapsed;
    _timer = Timer(next.isNegative ? Duration.zero : next, _beat);
    onBeat();
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _elapsed = null;
    _onBeat = null;
  }
}
