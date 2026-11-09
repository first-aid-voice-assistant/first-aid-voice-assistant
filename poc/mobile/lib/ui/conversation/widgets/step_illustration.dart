import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../domain/models/illustration.dart';
import '../../../utils/format.dart';
import '../../core/themes/theme.dart';

class StepIllustration extends StatefulWidget {
  const StepIllustration({
    super.key,
    required this.media,
    required this.shownFor,
    this.beats,
  });

  final String? media;
  final Duration Function() shownFor;
  final Stream<void>? beats;

  @override
  State<StepIllustration> createState() => _StepIllustrationState();
}

class _StepIllustrationState extends State<StepIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);
  StreamSubscription<void>? _beats;

  Illustration get _illustration => Illustrations.of(widget.media);

  bool get _followsBeats => _illustration.hasMetronome && widget.beats != null;

  @override
  void initState() {
    super.initState();
    _beats = widget.beats?.listen((_) => _onBeat());
    _restartMotion();
  }

  void _onBeat() {
    if (!_followsBeats || !mounted) return;
    _motion.forward(from: 0);
  }

  @override
  void didUpdateWidget(StepIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.beats, widget.beats)) {
      _beats?.cancel();
      _beats = widget.beats?.listen((_) => _onBeat());
    }
    if (!identical(Illustrations.of(oldWidget.media), _illustration)) {
      _restartMotion();
    }
  }

  void _restartMotion() {
    final period = _illustration.period;
    if (period == Duration.zero) {
      _motion
        ..stop()
        ..value = 0;
      return;
    }
    _motion.duration = period;
    if (_followsBeats) {
      _motion
        ..stop()
        ..value = 0;
    } else {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _beats?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final illustration = _illustration;
    final overlay = illustration.overlay;
    return Semantics(
      image: true,
      label: 'Ilustracja bieżącej czynności',
      child: AspectRatio(
        aspectRatio: Illustration.width / Illustration.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = constraints.maxWidth / Illustration.width;
            return Stack(
              fit: StackFit.expand,
              children: [
                SvgPicture.asset(illustration.base),
                if (overlay != null)
                  AnimatedBuilder(
                    animation: _motion,
                    builder: (context, child) =>
                        _move(illustration, scale, child!),
                    child: SvgPicture.asset(overlay),
                  ),
                if (illustration.hasMetronome)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: _Metronome(beat: _motion, shownFor: widget.shownFor),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _move(Illustration illustration, double scale, Widget child) {
    final phase = _motion.value;
    final swing = sin(pi * phase);
    return switch (illustration.movement) {
      IllustrationMovement.press => Transform.translate(
        offset: Offset(0, _pressDepth(phase) * Illustration.pressDepth * scale),
        child: child,
      ),
      IllustrationMovement.pulse => Opacity(
        opacity: 0.25 + 0.75 * swing,
        child: child,
      ),
      IllustrationMovement.shake => Transform.translate(
        offset: Offset(
          sin(2 * pi * phase) * Illustration.shakeWidth * scale,
          0,
        ),
        child: child,
      ),
      IllustrationMovement.tilt => Transform.rotate(
        angle: Illustration.tiltAngle * swing,
        origin: Offset(
          (illustration.pivotX - Illustration.width / 2) * scale,
          (illustration.pivotY - Illustration.height / 2) * scale,
        ),
        child: child,
      ),
      IllustrationMovement.breathe => Transform.translate(
        offset: Offset(0, -swing * Illustration.breathHeight * scale),
        child: child,
      ),
      IllustrationMovement.none => child,
    };
  }

  static double _pressDepth(double phase) {
    const down = 0.35;
    return phase < down
        ? Curves.easeOut.transform(phase / down)
        : 1 - Curves.easeInOut.transform((phase - down) / (1 - down));
  }
}

class _Metronome extends StatelessWidget {
  const _Metronome({required this.beat, required this.shownFor});

  final Animation<double> beat;
  final Duration Function() shownFor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: beat,
      builder: (context, _) {
        final accent = beat.value < 0.2 ? 1 - beat.value / 0.2 : 0.0;
        return Semantics(
          container: true,
          label:
              'Rytm uciśnięć ${Illustration.compressionsPerMinute} na minutę',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatElapsed(shownFor()),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Transform.scale(
                scale: 1 + 0.2 * accent,
                child: Container(
                  width: 58,
                  height: 58,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(
                      AppColors.primarySoft,
                      AppColors.primary,
                      accent,
                    ),
                    border: Border.all(color: AppColors.primary, width: 2),
                  ),
                  child: Text(
                    '${Illustration.compressionsPerMinute}\n/min',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      color: Color.lerp(
                        AppColors.primary,
                        Colors.white,
                        accent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
