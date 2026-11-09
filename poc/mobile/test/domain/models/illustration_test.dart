import 'dart:io';

import 'package:first_aid_voice_assistant/domain/models/illustration.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pictures named in the scenarios of the shared knowledge base (repository root).
Set<String> mediaInScenarios() {
  final media = RegExp(r'^\s*media:\s*(\S+)\s*$', multiLine: true);
  return {
    for (final file in Directory('../../knowledge/scenarios').listSync())
      if (file is File && file.path.endsWith('.yaml'))
        for (final match in media.allMatches(file.readAsStringSync()))
          match.group(1)!,
  };
}

void main() {
  test('every picture named in the scenarios has an illustration', () {
    final named = mediaInScenarios();

    expect(named, contains('cpr/compressions'));
    expect(
      named.difference(Illustrations.byMedia.keys.toSet()),
      isEmpty,
      reason: 'add the missing keys to Illustrations.byMedia',
    );
  });

  test('every illustration file exists', () {
    final files = {
      Illustrations.start.base,
      Illustrations.scene.base,
      for (final illustration in Illustrations.byMedia.values) ...[
        illustration.base,
        ?illustration.overlay,
      ],
    };

    for (final path in files) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  test('compressions move at 110 per minute with a metronome', () {
    final compressions = Illustrations.of('cpr/compressions');

    expect(compressions.hasMetronome, isTrue);
    expect(compressions.period.inMilliseconds, 545);
    expect(Illustrations.of('cpr/call-112').hasMetronome, isFalse);
  });

  test(
    'before a step the start picture is shown, an unknown one is the scene',
    () {
      expect(Illustrations.of(null), same(Illustrations.start));
      expect(Illustrations.of('cpr/unknown'), same(Illustrations.scene));
    },
  );
}
