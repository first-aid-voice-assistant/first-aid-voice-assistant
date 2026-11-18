import 'package:flutter/material.dart';

import '../../../domain/models/conversation_entry.dart';
import '../../../domain/models/utterance.dart';
import '../../../utils/format.dart';
import '../../core/themes/theme.dart';
import '../view_models/conversation_view_model.dart';

Future<void> showConversationHistory(
  BuildContext context,
  ConversationViewModel viewModel,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.background,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) =>
            ConversationHistory(viewModel: viewModel, controller: scroll),
      ),
    ),
  );
}

class ConversationHistory extends StatelessWidget {
  const ConversationHistory({
    super.key,
    required this.viewModel,
    this.controller,
  });

  final ConversationViewModel viewModel;
  final ScrollController? controller;

  bool get _showsPartial => viewModel.partialText.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final entries = viewModel.entries;
    final items = <Widget>[
      if (_showsPartial) _PartialBubble(text: viewModel.partialText),
      for (final entry in entries.reversed)
        switch (entry) {
          UserMessage(:final utterance) => _UserBubble(utterance: utterance),
          final AssistantMessage answer => _AssistantBubble(answer: answer),
        },
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            'Historia rozmowy',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text(
                    'Rozmowa jeszcze się nie zaczęła.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : ListView.separated(
                  controller: controller,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => items[i],
                ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.utterance});

  final Utterance utterance;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: const BoxDecoration(
                color: AppColors.userBubble,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Text(
                utterance.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${formatClock(utterance.endedAt)} · mowa ${formatSeconds(utterance.speechDuration)}'
              ' · tekst po ${formatSeconds(utterance.transcriptionDuration)}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.answer});

  final AssistantMessage answer;

  @override
  Widget build(BuildContext context) {
    final failed = answer.state == AnswerState.failed;
    final interrupted = answer.state == AnswerState.interrupted;
    final details = [
      if (answer.reminder) 'przypomnienie',
      if (answer.firstSoundAfter != null)
        'głos po ${formatSeconds(answer.firstSoundAfter!)}',
      if (answer.firstTokenTime != null)
        'model ${formatSeconds(answer.firstTokenTime!)}',
      if (interrupted) 'przerwano',
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: failed ? AppColors.primarySoft : AppColors.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(18),
                ),
              ),
              child: Text(
                answer.text.isEmpty ? '…' : answer.text,
                style: TextStyle(
                  color: interrupted ? AppColors.textSecondary : AppColors.text,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                details.join(' · '),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PartialBubble extends StatelessWidget {
  const _PartialBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.userBubble.withValues(alpha: 0.55),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.4,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ),
    );
  }
}
