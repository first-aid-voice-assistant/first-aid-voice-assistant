import 'package:first_aid_voice_assistant/data/services/beat_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('beats at once and then once per period', () async {
    final clock = TimerBeatClock();
    var beats = 0;

    clock.start(const Duration(milliseconds: 20), () => beats++);
    expect(beats, 1);
    expect(clock.isRunning, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    clock.stop();

    expect(beats, inInclusiveRange(2, 4));
  });

  test('stops beating when stopped', () async {
    final clock = TimerBeatClock();
    var beats = 0;
    clock.start(const Duration(milliseconds: 10), () => beats++);

    clock.stop();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(beats, 1);
    expect(clock.isRunning, isFalse);
  });

  test('a beat may stop the clock', () async {
    final clock = TimerBeatClock();
    var beats = 0;

    clock.start(const Duration(milliseconds: 10), () {
      beats++;
      clock.stop();
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(beats, 1);
  });
}
