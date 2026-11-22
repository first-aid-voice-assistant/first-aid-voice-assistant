import 'package:url_launcher/url_launcher.dart';

abstract interface class EmergencyDialer {
  Future<bool> dialEmergency();
}

class PhoneEmergencyDialer implements EmergencyDialer {
  const PhoneEmergencyDialer();

  static final Uri emergencyNumber = Uri(scheme: 'tel', path: '112');

  @override
  Future<bool> dialEmergency() async {
    try {
      return await launchUrl(emergencyNumber);
    } catch (_) {
      return false;
    }
  }
}
