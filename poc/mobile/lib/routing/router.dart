import 'package:flutter/material.dart';

import '../config/dependencies.dart';
import '../ui/conversation/widgets/conversation_screen.dart';
import '../ui/settings/widgets/settings_screen.dart';
import '../ui/start/widgets/start_screen.dart';

abstract final class Routes {
  static const String start = '/';
  static const String conversation = '/conversation';
  static const String settings = '/settings';
}

Route<void> buildRoute(RouteSettings route, AppDependencies dependencies) {
  return MaterialPageRoute<void>(
    settings: route,
    builder: (context) => switch (route.name) {
      Routes.conversation => ConversationScreen(
        createViewModel: dependencies.createConversationViewModel,
        emergencyDialer: dependencies.emergencyDialer,
      ),
      Routes.settings => SettingsScreen(
        settings: dependencies.settings,
        modelStore: dependencies.modelStore,
        createSpeechOutput: dependencies.createSpeechOutput,
      ),
      _ => StartScreen(
        onStart: () => Navigator.of(context).pushNamed(Routes.conversation),
        onOpenSettings: () => Navigator.of(context).pushNamed(Routes.settings),
      ),
    },
  );
}
