import 'package:first_aid_voice_assistant/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats seconds with one decimal and a decimal comma', () {
    expect(formatSeconds(const Duration(milliseconds: 1840)), '1,8 s');
    expect(formatSeconds(const Duration(seconds: 36)), '36,0 s');
  });

  test('formats elapsed time as minutes and seconds', () {
    expect(formatElapsed(const Duration(seconds: 134)), '02:14');
    expect(formatElapsed(Duration.zero), '00:00');
    expect(formatElapsed(const Duration(minutes: 12, seconds: 5)), '12:05');
  });

  test('formats the time of day with leading zeros', () {
    expect(formatClock(DateTime(2026, 10, 27, 9, 5, 3)), '09:05:03');
  });
}
