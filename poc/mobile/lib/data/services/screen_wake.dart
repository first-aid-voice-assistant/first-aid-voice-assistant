import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

abstract interface class ScreenWake {
  Future<void> keepOn();

  Future<void> release();
}

class WakelockScreenWake implements ScreenWake {
  const WakelockScreenWake();

  @override
  Future<void> keepOn() => _set(true);

  @override
  Future<void> release() => _set(false);

  Future<void> _set(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('Keeping the screen on failed: $e');
    }
  }
}
