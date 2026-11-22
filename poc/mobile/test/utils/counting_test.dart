import 'package:first_aid_voice_assistant/utils/counting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counting aloud in words or digits', () {
    expect(isCountingOrFiller('raz, dwa, trzy, cztery'), isTrue);
    expect(isCountingOrFiller('dwadzieścia jeden dwadzieścia dwa'), isTrue);
    expect(isCountingOrFiller('14, 15, 16'), isTrue);
  });

  test('sounds without words', () {
    expect(isCountingOrFiller('Yyy...'), isTrue);
    expect(isCountingOrFiller('mhm'), isTrue);
    expect(isCountingOrFiller('eee, hmm'), isTrue);
  });

  test('reaching thirty is a message: the compressions are done', () {
    expect(isCountingOrFiller('dwadzieścia dziewięć, trzydzieści'), isFalse);
    expect(isCountingOrFiller('28, 29, 30'), isFalse);
  });

  test('anything else is a message', () {
    expect(isCountingOrFiller('dwa razy'), isFalse);
    expect(isCountingOrFiller('nie oddycha'), isFalse);
    expect(isCountingOrFiller('aha'), isFalse);
    expect(isCountingOrFiller('tak'), isFalse);
  });
}
