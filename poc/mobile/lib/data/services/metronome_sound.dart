import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

abstract interface class MetronomeSound {
  Future<void> click();

  Future<void> dispose();
}

class AudioPlayersMetronomeSound implements MetronomeSound {
  static const String clickAsset = 'sounds/metronome_click.wav';

  final AudioPlayer _player = AudioPlayer();
  Future<void>? _configured;

  Future<void> _configure() async {
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setAudioContext(
      AudioContextConfig(
        route: AudioContextConfigRoute.speaker,
        focus: AudioContextConfigFocus.mixWithOthers,
      ).build(),
    );
  }

  @override
  Future<void> click() async {
    try {
      await (_configured ??= _configure());
      await _player.play(AssetSource(clickAsset));
    } catch (e) {
      debugPrint('Metronome click failed: $e');
    }
  }

  @override
  Future<void> dispose() => _player.dispose();
}
