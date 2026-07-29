import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:path/path.dart' as path;

import '../jobs/job_controller.dart';
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
                        '${job.status.label} · ${job.provider.label}'
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
    TranslationJobStatus.unpacking => CupertinoIcons.archivebox,
    TranslationJobStatus.translating => CupertinoIcons.text_bubble,
    TranslationJobStatus.repacking => CupertinoIcons.archivebox_fill,
    TranslationJobStatus.waitingForAction =>
      CupertinoIcons.exclamationmark_triangle,
    TranslationJobStatus.completed => CupertinoIcons.check_mark_circled_solid,
    TranslationJobStatus.abandoned => CupertinoIcons.xmark_circle,
  };

  Color _statusColor(TranslationJobStatus status) => switch (status) {
    TranslationJobStatus.waitingForAction => MacosColors.systemOrangeColor,
    TranslationJobStatus.completed => MacosColors.systemGreenColor,
    TranslationJobStatus.abandoned => MacosColors.systemGrayColor,
    _ => MacosColors.systemBlueColor,
  };
}

final class _JobActions extends StatelessWidget {
  const _JobActions({required this.job, required this.controller});

  final TranslationJob job;
  final JobController controller;

  @override
  Widget build(BuildContext context) {
    if (job.status == TranslationJobStatus.waitingForAction) {
      return Row(
        children: [
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: () => controller.abandon(job.id),
            child: Text(context.l10n.t('abandon')),
          ),
          const SizedBox(width: 8),
          PushButton(
            controlSize: ControlSize.regular,
            color: MacosTheme.of(context).primaryColor,
            onPressed: () => controller.retry(job.id),
            child: Text(context.l10n.t('retry')),
          ),
        ],
      );
    }
    if (job.status == TranslationJobStatus.completed &&
        job.outputPath != null) {
      return PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: () => controller.desktopServices.reveal(job.outputPath!),
        child: Text(context.l10n.t('showFinder')),
      );
    }
    if (job.status.isRunning || job.status == TranslationJobStatus.queued) {
      return PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: () => controller.abandon(job.id),
        child: Text(context.l10n.t('cancel')),
      );
    }
    return const SizedBox.shrink();
  }
}
