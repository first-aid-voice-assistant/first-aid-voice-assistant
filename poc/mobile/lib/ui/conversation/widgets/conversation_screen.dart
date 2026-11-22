import 'package:flutter/material.dart';

import '../../../data/services/emergency_dialer.dart';
import '../../../domain/models/conversation_entry.dart';
import '../../core/themes/theme.dart';
import '../../core/ui/demo_banner.dart';
import '../view_models/conversation_view_model.dart';
import 'conversation_history.dart';
import 'step_illustration.dart';

const String firstPrompt = 'Naciśnij przycisk i powiedz, co się stało.';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.createViewModel,
    required this.emergencyDialer,
  });

  final ConversationViewModel Function() createViewModel;
  final EmergencyDialer emergencyDialer;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  late final ConversationViewModel _viewModel = widget.createViewModel();

  @override
  void initState() {
    super.initState();
    _viewModel.initialize();
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _callEmergency() async {
    final messenger = ScaffoldMessenger.of(context);
    if (await widget.emergencyDialer.dialEmergency()) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Nie udało się otworzyć telefonu. Wybierz numer 112 ręcznie.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Rozmowa testowa',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: const [DemoBadge(), SizedBox(width: 16)],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _viewModel,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              children: [
                if (_viewModel.status == ConversationStatus.preparingModel ||
                    _viewModel.status == ConversationStatus.failed) ...[
                  _ModelStatus(viewModel: _viewModel),
                  const SizedBox(height: 12),
                ],
                Expanded(child: _StepView(viewModel: _viewModel)),
                const SizedBox(height: 8),
                _StatusLine(viewModel: _viewModel),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _RoundAction(
                        label: 'Zadzwoń',
                        semanticsLabel: 'Zadzwoń pod 112',
                        onTap: _callEmergency,
                        foreground: AppColors.primary,
                        border: AppColors.primary,
                        child: const Text(
                          '112',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: _TalkButton(viewModel: _viewModel),
                    ),
                    Expanded(
                      child: _RoundAction(
                        label: 'Historia',
                        semanticsLabel: 'Historia rozmowy',
                        onTap: () =>
                            showConversationHistory(context, _viewModel),
                        foreground: AppColors.text,
                        border: AppColors.divider,
                        child: const Icon(Icons.history_rounded, size: 28),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepView extends StatelessWidget {
  const _StepView({required this.viewModel});

  final ConversationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final answer = viewModel.latestAnswer;
    final userText = viewModel.latestUserText;
    final waiting =
        viewModel.entries.isNotEmpty &&
        viewModel.entries.last is AssistantMessage &&
        answer == null;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          flex: 5,
          child: StepIllustration(
            media: viewModel.media,
            shownFor: () => viewModel.mediaShownFor,
            onBeat: viewModel.onMetronomeBeat,
          ),
        ),
        const SizedBox(height: 20),
        Flexible(
          flex: 4,
          child: SingleChildScrollView(
            child: Semantics(
              liveRegion: true,
              child: Text(
                answer ?? (waiting ? '…' : firstPrompt),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: answer == null ? 18 : 22,
                  height: 1.35,
                  fontWeight: answer == null
                      ? FontWeight.w600
                      : FontWeight.w800,
                  color: answer == null
                      ? AppColors.textSecondary
                      : AppColors.text,
                ),
              ),
            ),
          ),
        ),
        if (userText != null) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.person_outline_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  userText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
    required this.foreground,
    required this.border,
    required this.child,
  });

  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;
  final Color foreground;
  final Color border;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 16),
        Semantics(
          button: true,
          label: semanticsLabel,
          excludeSemantics: true,
          child: Material(
            color: AppColors.surface,
            shape: CircleBorder(side: BorderSide(color: border, width: 2)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 64,
                height: 64,
                child: IconTheme(
                  data: IconThemeData(color: foreground),
                  child: Center(child: child),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF444444),
          ),
        ),
      ],
    );
  }
}

class _ModelStatus extends StatelessWidget {
  const _ModelStatus({required this.viewModel});

  final ConversationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final preparing = viewModel.status == ConversationStatus.preparingModel;
    final failed = viewModel.status == ConversationStatus.failed;
    final (color, text) = switch (viewModel.status) {
      ConversationStatus.preparingModel => (
        AppColors.busy,
        viewModel.downloadProgress == null
            ? 'Przygotowanie: ${viewModel.preparingLabel}…'
            : 'Pobieranie: ${viewModel.preparingLabel} '
                  '${(viewModel.downloadProgress! * 100).floor()}% (tylko za pierwszym razem)',
      ),
      ConversationStatus.failed => (
        AppColors.primary,
        '${viewModel.preparingLabel} niedostępny',
      ),
      _ => (
        AppColors.ok,
        '${viewModel.modelLabel} · ${viewModel.voiceLabel} · gotowe',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (failed)
                TextButton(
                  onPressed: viewModel.initialize,
                  child: const Text('Ponów'),
                ),
            ],
          ),
          if (preparing) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: viewModel.downloadProgress,
              color: AppColors.primary,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.viewModel});

  final ConversationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final message = viewModel.message;
    final activity = viewModel.assistantActivity;
    final (text, color) = switch (viewModel.status) {
      _ when activity == AssistantActivity.speaking => (
        'Asystent mówi…',
        AppColors.ok,
      ),
      _ when activity == AssistantActivity.thinking => (
        'Asystent myśli…',
        AppColors.busy,
      ),
      ConversationStatus.recording => (
        'Słucham… gdy skończysz, mikrofon sam się wyłączy',
        AppColors.primary,
      ),
      ConversationStatus.transcribing => (
        'Kończę rozpoznawanie…',
        AppColors.busy,
      ),
      _ when message != null => (message, AppColors.textSecondary),
      _ => ('', AppColors.textSecondary),
    };
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Semantics(
              liveRegion: true,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ),
          if (activity != AssistantActivity.idle)
            TextButton(
              onPressed: viewModel.stopAnswer,
              child: const Text('Przerwij'),
            ),
        ],
      ),
    );
  }
}

class _TalkButton extends StatelessWidget {
  const _TalkButton({required this.viewModel});

  final ConversationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final recording = viewModel.isRecording;
    final enabled = viewModel.canRecord || recording;
    return Column(
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: recording ? 'Zakończ mówienie' : 'Zacznij mówić',
          child: GestureDetector(
            onTap: enabled ? viewModel.toggleRecording : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: recording ? 108 : 96,
              height: recording ? 108 : 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? AppColors.primary : const Color(0xFFBDBDC2),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(
                            alpha: recording ? 0.5 : 0.35,
                          ),
                          blurRadius: recording ? 28 : 20,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                recording ? Icons.stop_rounded : Icons.mic_none_rounded,
                color: Colors.white,
                size: 40,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          recording
              ? 'Naciśnij, aby zakończyć'
              : viewModel.assistantActivity == AssistantActivity.idle
              ? 'Naciśnij i mów'
              : 'Poczekaj, aż asystent skończy',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF444444),
          ),
        ),
      ],
    );
  }
}
