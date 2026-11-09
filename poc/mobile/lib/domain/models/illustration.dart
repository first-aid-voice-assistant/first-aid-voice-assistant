enum IllustrationMovement { none, press, pulse, shake, tilt, breathe }

class Illustration {
  const Illustration({
    required this.base,
    this.overlay,
    this.movement = IllustrationMovement.none,
    this.pivotX = 0,
    this.pivotY = 0,
  });

  static const double width = 520;
  static const double height = 300;
  static const int compressionsPerMinute = 110;
  static const double pressDepth = 8;
  static const double shakeWidth = 5;
  static const double tiltAngle = -0.15;
  static const double breathHeight = 6;

  final String base;
  final String? overlay;
  final IllustrationMovement movement;
  final double pivotX;
  final double pivotY;

  bool get hasMetronome => movement == IllustrationMovement.press;

  Duration get period => switch (movement) {
    IllustrationMovement.press => Duration(
      microseconds: Duration.microsecondsPerMinute ~/ compressionsPerMinute,
    ),
    IllustrationMovement.pulse => const Duration(milliseconds: 1200),
    IllustrationMovement.shake => const Duration(milliseconds: 400),
    IllustrationMovement.tilt => const Duration(milliseconds: 2400),
    IllustrationMovement.breathe => const Duration(milliseconds: 2400),
    IllustrationMovement.none => Duration.zero,
  };
}

abstract final class Illustrations {
  static const String _dir = 'assets/illustrations/cpr';

  static const Illustration start = Illustration(base: '$_dir/start.svg');

  static const Illustration scene = Illustration(base: '$_dir/scene.svg');

  static const Illustration _call = Illustration(
    base: '$_dir/call_112.svg',
    overlay: '$_dir/call_112_waves.svg',
    movement: IllustrationMovement.pulse,
  );

  static const Map<String, Illustration> byMedia = {
    'cpr/scene-safety': Illustration(
      base: '$_dir/scene_safety.svg',
      overlay: '$_dir/scene_safety_look.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/keep-away': Illustration(
      base: '$_dir/keep_away.svg',
      overlay: '$_dir/keep_away_fire.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/shake-shoulders': Illustration(
      base: '$_dir/shake_shoulders.svg',
      overlay: '$_dir/shake_shoulders_hands.svg',
      movement: IllustrationMovement.shake,
    ),
    'cpr/call-112': _call,
    'cpr/speakerphone': Illustration(
      base: '$_dir/speakerphone.svg',
      overlay: '$_dir/call_112_waves.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/stay-observe': Illustration(
      base: '$_dir/stay_observe.svg',
      overlay: '$_dir/stay_observe_chest.svg',
      movement: IllustrationMovement.breathe,
    ),
    'cpr/lay-on-back': Illustration(
      base: '$_dir/lay_on_back.svg',
      overlay: '$_dir/lay_on_back_arrow.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/head-tilt': Illustration(
      base: '$_dir/head_tilt.svg',
      overlay: '$_dir/head_tilt_head.svg',
      movement: IllustrationMovement.tilt,
      pivotX: 115,
      pivotY: 232,
    ),
    'cpr/check-breathing': Illustration(
      base: '$_dir/check_breathing.svg',
      overlay: '$_dir/check_breathing_signs.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/kneel': scene,
    'cpr/hand-position': Illustration(
      base: '$_dir/hand_position.svg',
      overlay: '$_dir/hand_position_target.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/compressions': Illustration(
      base: '$_dir/compressions.svg',
      overlay: '$_dir/compressions_rescuer.svg',
      movement: IllustrationMovement.press,
    ),
    'cpr/pinch-nose': Illustration(
      base: '$_dir/pinch_nose.svg',
      overlay: '$_dir/pinch_nose_target.svg',
      movement: IllustrationMovement.pulse,
    ),
    'cpr/rescue-breath': Illustration(
      base: '$_dir/rescue_breath.svg',
      overlay: '$_dir/rescue_breath_chest.svg',
      movement: IllustrationMovement.breathe,
    ),
  };

  static Illustration of(String? media) =>
      media == null ? start : byMedia[media] ?? scene;
}
