import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/conversation_entry.dart';
import '../../../domain/models/event_log_entry.dart';
import '../../../domain/models/utterance.dart';
import '../../../utils/format.dart';
import '../../core/themes/theme.dart';
import '../view_models/conversation_view_model.dart';

enum HistoryTab { conversation, eventLog }

Future<void> showConversationHistory(
  BuildContext context,
  ConversationViewModel viewModel, {
  HistoryTab initialTab = HistoryTab.conversation,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: AppColors.background,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: ConversationHistory(viewModel: viewModel, initialTab: initialTab),
    ),
  );
}

class ConversationHistory extends StatelessWidget {
  const ConversationHistory({
    super.key,
    required this.viewModel,
    this.initialTab = HistoryTab.conversation,
  });

  final ConversationViewModel viewModel;
  final HistoryTab initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: HistoryTab.values.length,
      initialIndex: initialTab.index,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Historia',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: 'Zamknij',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: viewModel,
            builder: (context, _) {
              final logged = viewModel.eventLog.length;
              return TabBar(
                labelColor: AppColors.text,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.primary,
                labelStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                tabs: [
                  const Tab(text: 'Rozmowa'),
                  Tab(text: logged == 0 ? 'Dziennik' : 'Dziennik ($logged)'),
                ],
              );
            },
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ConversationTab(viewModel: viewModel),
                _EventLogTab(viewModel: viewModel),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTab extends StatelessWidget {
  const _ConversationTab({required this.viewModel});

  final ConversationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final partial = viewModel.partialText;
        final items = <Widget>[
          if (partial.isNotEmpty) _PartialBubble(text: partial),
          for (final entry in viewModel.entries.reversed)
            switch (entry) {
              UserMessage(:final utterance) => _UserBubble(
                utterance: utterance,
              ),
              final AssistantMessage answer => _AssistantBubble(answer: answer),
            },
        ];
        if (items.isEmpty) {
          return const _EmptyTab(text: 'Rozmowa jeszcze się nie zaczęła.');
        }
        return ListView.separated(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, i) => items[i],
        );
      },
    );
  }
}

class _EventLogTab extends StatelessWidget {
  const _EventLogTab({required this.viewModel});

  final ConversationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final entries = viewModel.eventLog;
        if (entries.isEmpty) {
          return const _EmptyTab(
            text:
                'Dziennik jest pusty.\nCzynności, o których powiesz w rozmowie '
                '(np. „uciskam”), pojawią się tutaj z godziną.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView.separated(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) =>
                    _EventLogRow(entry: entries[entries.length - 1 - i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: _CopyLogButton(json: () => viewModel.eventLogJson),
            ),
          ],
        );
      },
    );
  }
}

class _EventLogRow extends StatelessWidget {
  const _EventLogRow({required this.entry});

  final EventLogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatClock(entry.timestamp.toLocal()),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '+${formatElapsed(entry.elapsed)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '„${entry.transcript}”',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    fontStyle: FontStyle.italic,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyLogButton extends StatefulWidget {
  const _CopyLogButton({required this.json});

  final String Function() json;

  @override
  State<_CopyLogButton> createState() => _CopyLogButtonState();
}

class _CopyLogButtonState extends State<_CopyLogButton> {
  bool _copied = false;
  Timer? _reset;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.json()));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _copy,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        minimumSize: const Size.fromHeight(48),
      ),
      icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
      label: Text(_copied ? 'Skopiowano' : 'Kopiuj dziennik (JSON)'),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
        ),
      ),
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
