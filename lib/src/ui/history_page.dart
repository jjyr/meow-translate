import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:path/path.dart' as path;

import '../jobs/job_controller.dart';
import '../jobs/job_log_repository.dart';
import '../l10n/app_localizations.dart';
import '../jobs/translation_job.dart';
import '../settings/app_settings.dart';

final class HistoryPage extends StatelessWidget {
  const HistoryPage({required this.controller, super.key});

  final JobController controller;

  @override
  Widget build(BuildContext context) {
    return MacosScaffold(
      toolBar: ToolBar(title: Text(context.l10n.t('jobs'))),
      children: [
        ContentArea(
          builder: (context, scrollController) => AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              if (controller.jobs.isEmpty) {
                return Center(
                  child: Text(
                    context.l10n.t('noJobs'),
                    style: MacosTheme.of(context).typography.title3,
                  ),
                );
              }
              return ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.all(24),
                itemCount: controller.jobs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) => _JobCard(
                  job: controller.jobs[index],
                  controller: controller,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

final class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.controller});

  final TranslationJob job;
  final JobController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final needsAttention = job.status == TranslationJobStatus.waitingForAction;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.brightness.isDark
            ? MacosColors.controlBackgroundColor.darkColor
            : MacosColors.controlBackgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: needsAttention
              ? MacosColors.systemOrangeColor.withValues(alpha: 0.65)
              : theme.dividerColor,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MacosIcon(
                  _statusIcon(job.status),
                  size: 22,
                  color: _statusColor(job.status),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        path.basename(job.sourcePath),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.headline,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_statusLabel(context, job.status)} · '
                        '${job.provider.label}'
                        ' · ${job.targetLanguage}'
                        '${job.keepOriginal ? ' · Bilingual' : ''}',
                        style: theme.typography.subheadline,
                      ),
                    ],
                  ),
                ),
                _JobActions(job: job, controller: controller),
              ],
            ),
            if (job.totalUnits > 0 &&
                job.status != TranslationJobStatus.completed) ...[
              const SizedBox(height: 14),
              ProgressBar(value: job.progress * 100),
              const SizedBox(height: 6),
              Text(
                '${job.completedUnits} of ${job.totalUnits} units translated'
                '${job.failedUnitIds.isEmpty ? '' : ' · '
                          '${job.failedUnitIds.length} failed'}',
                style: theme.typography.caption1,
              ),
            ],
            if (job.errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MacosColors.systemOrangeColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  job.errorMessage!,
                  style: theme.typography.caption1,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (job.outputPath != null) ...[
              const SizedBox(height: 10),
              Text(
                job.outputPath!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.caption1,
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(TranslationJobStatus status) => switch (status) {
    TranslationJobStatus.queued => CupertinoIcons.clock,
    TranslationJobStatus.convertingInput => CupertinoIcons.arrow_2_circlepath,
    TranslationJobStatus.unpacking => CupertinoIcons.archivebox,
    TranslationJobStatus.translating => CupertinoIcons.text_bubble,
    TranslationJobStatus.repacking => CupertinoIcons.archivebox_fill,
    TranslationJobStatus.convertingOutput => CupertinoIcons.arrow_2_circlepath,
    TranslationJobStatus.paused => CupertinoIcons.pause_circle,
    TranslationJobStatus.waitingForAction =>
      CupertinoIcons.exclamationmark_triangle,
    TranslationJobStatus.completed => CupertinoIcons.check_mark_circled_solid,
    TranslationJobStatus.abandoned => CupertinoIcons.xmark_circle,
  };

  Color _statusColor(TranslationJobStatus status) => switch (status) {
    TranslationJobStatus.waitingForAction => MacosColors.systemOrangeColor,
    TranslationJobStatus.completed => MacosColors.systemGreenColor,
    TranslationJobStatus.paused => MacosColors.systemYellowColor,
    TranslationJobStatus.abandoned => MacosColors.systemGrayColor,
    _ => MacosColors.systemBlueColor,
  };

  String _statusLabel(BuildContext context, TranslationJobStatus status) =>
      switch (status) {
        TranslationJobStatus.convertingInput => context.l10n.t(
          'statusConvertingInput',
        ),
        TranslationJobStatus.convertingOutput => context.l10n.t(
          'statusConvertingOutput',
        ),
        TranslationJobStatus.paused => context.l10n.t('statusPaused'),
        _ => status.label,
      };
}

final class _JobActions extends StatelessWidget {
  const _JobActions({required this.job, required this.controller});

  final TranslationJob job;
  final JobController controller;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: () => _showJobLog(context),
        child: Text(context.l10n.t('logs')),
      ),
    ];
    if (job.status == TranslationJobStatus.waitingForAction) {
      actions.addAll([
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => _confirmRetranslateAll(context),
          child: Text(context.l10n.t('retranslateAll')),
        ),
        PushButton(
          controlSize: ControlSize.regular,
          color: MacosTheme.of(context).primaryColor,
          onPressed: () => controller.retry(job.id),
          child: Text(context.l10n.t('retryFailedUnits')),
        ),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => controller.abandon(job.id),
          child: Text(context.l10n.t('abandon')),
        ),
      ]);
    } else if (job.status == TranslationJobStatus.paused) {
      actions.addAll([
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => _confirmRetranslateAll(context),
          child: Text(context.l10n.t('retranslateAll')),
        ),
        PushButton(
          controlSize: ControlSize.regular,
          color: MacosTheme.of(context).primaryColor,
          onPressed: () => controller.resume(job.id),
          child: Text(context.l10n.t('resume')),
        ),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => controller.abandon(job.id),
          child: Text(context.l10n.t('abandon')),
        ),
      ]);
    } else if (job.status == TranslationJobStatus.completed &&
        job.outputPath != null) {
      actions.addAll([
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => _confirmRetranslateAll(context),
          child: Text(context.l10n.t('retranslateAll')),
        ),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => controller.desktopServices.reveal(job.outputPath!),
          child: Text(context.l10n.t('showFinder')),
        ),
      ]);
    } else if (job.status.isRunning ||
        job.status == TranslationJobStatus.queued) {
      actions.addAll([
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => controller.pause(job.id),
          child: Text(context.l10n.t('pause')),
        ),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => controller.abandon(job.id),
          child: Text(context.l10n.t('cancel')),
        ),
      ]);
    }
    return Wrap(spacing: 8, runSpacing: 8, children: actions);
  }

  Future<void> _confirmRetranslateAll(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(context.l10n.t('retranslateAll')),
        content: Text(context.l10n.t('retranslateConfirm')),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.t('cancel')),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.t('retranslateAll')),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await controller.retranslateAll(job.id);
    }
  }

  Future<void> _showJobLog(BuildContext context) {
    return showMacosSheet<void>(
      context: context,
      builder: (context) => MacosSheet(
        child: SizedBox(
          width: 760,
          height: 520,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.t('jobLog'),
                  style: MacosTheme.of(context).typography.title2,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) => FutureBuilder<List<JobLogEntry>>(
                      future: controller.readJobLog(job.id),
                      builder: (context, snapshot) {
                        final entries = snapshot.data ?? const <JobLogEntry>[];
                        if (entries.isEmpty) {
                          return Center(child: Text(context.l10n.t('noLogs')));
                        }
                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          color: MacosTheme.of(
                            context,
                          ).canvasColor.withValues(alpha: 0.45),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              entries
                                  .map((entry) => entry.displayText)
                                  .join('\n'),
                              style: const TextStyle(
                                fontFamily: 'Menlo',
                                fontSize: 11,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PushButton(
                      controlSize: ControlSize.regular,
                      secondary: true,
                      onPressed: () async {
                        final entries = await controller.readJobLog(job.id);
                        await Clipboard.setData(
                          ClipboardData(
                            text: entries
                                .map((entry) => entry.displayText)
                                .join('\n'),
                          ),
                        );
                      },
                      child: Text(context.l10n.t('copyLogs')),
                    ),
                    const SizedBox(width: 8),
                    PushButton(
                      controlSize: ControlSize.regular,
                      secondary: true,
                      onPressed: () => controller.desktopServices.reveal(
                        controller.jobLogFile(job.id).path,
                      ),
                      child: Text(context.l10n.t('showLogFile')),
                    ),
                    const SizedBox(width: 8),
                    PushButton(
                      controlSize: ControlSize.regular,
                      color: MacosTheme.of(context).primaryColor,
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.t('close')),
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
