import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../jobs/job_controller.dart';
import '../ebook/book_format.dart';
import '../ebook/calibre_service.dart';
import '../l10n/app_localizations.dart';
import 'operation_sheet.dart';

final class DropPage extends StatefulWidget {
  const DropPage({
    required this.controller,
    required this.onShowJobs,
    super.key,
  });

  final JobController controller;
  final VoidCallback onShowJobs;

  @override
  State<DropPage> createState() => _DropPageState();
}

final class _DropPageState extends State<DropPage> {
  var _dragging = false;
  String? _validationMessage;

  @override
  Widget build(BuildContext context) {
    return MacosScaffold(
      toolBar: ToolBar(title: Text(context.l10n.t('translate'))),
      children: [
        ContentArea(
          builder: (context, scrollController) => AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Expanded(
                    child: DropTarget(
                      onDragEntered: (_) => setState(() => _dragging = true),
                      onDragExited: (_) => setState(() => _dragging = false),
                      onDragDone: (details) {
                        setState(() => _dragging = false);
                        _acceptPaths(
                          details.files.map((file) => file.path).toList(),
                        );
                      },
                      child: GestureDetector(
                        onTap: _chooseFiles,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          decoration: BoxDecoration(
                            color: _dragging
                                ? MacosTheme.of(
                                    context,
                                  ).primaryColor.withValues(alpha: 0.08)
                                : MacosColors.transparent,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              width: _dragging ? 2 : 1,
                              color: _dragging
                                  ? MacosTheme.of(context).primaryColor
                                  : MacosColors.systemGrayColor.withValues(
                                      alpha: 0.45,
                                    ),
                            ),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: MacosTheme.of(
                                      context,
                                    ).primaryColor.withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: MacosIcon(
                                    CupertinoIcons.tray_arrow_down,
                                    size: 36,
                                    color: MacosTheme.of(context).primaryColor,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  _dragging
                                      ? context.l10n.t('dropAdd')
                                      : context.l10n.t('dropBooks'),
                                  style: MacosTheme.of(
                                    context,
                                  ).typography.title2,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  context.l10n.t('clickChoose'),
                                  style: MacosTheme.of(
                                    context,
                                  ).typography.subheadline,
                                ),
                                if (_validationMessage != null) ...[
                                  const SizedBox(height: 16),
                                  Text(
                                    _validationMessage!,
                                    style: MacosTheme.of(context)
                                        .typography
                                        .subheadline
                                        .copyWith(
                                          color: MacosColors.systemRedColor,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        context.l10n.t('epubOnly'),
                        style: MacosTheme.of(context).typography.caption1,
                      ),
                      if (widget.controller.jobs.isNotEmpty)
                        PushButton(
                          controlSize: ControlSize.regular,
                          secondary: true,
                          onPressed: widget.onShowJobs,
                          child: Text(
                            widget.controller.runningJobCount == 0
                                ? context.l10n.t('viewJobs')
                                : '${widget.controller.runningJobCount} '
                                      'running · View jobs',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseFiles() async {
    const group = XTypeGroup(
      label: 'Ebooks',
      extensions: ['epub', 'mobi', 'azw3'],
    );
    final files = await openFiles(acceptedTypeGroups: [group]);
    await _acceptPaths(files.map((file) => file.path).toList());
  }

  Future<void> _acceptPaths(List<String> values) async {
    final ebookPaths = values
        .where((value) => BookFormat.fromPath(value) != null)
        .toList(growable: false);
    if (ebookPaths.isEmpty) {
      setState(() {
        _validationMessage = context.l10n.t('noEpub');
      });
      return;
    }
    final requiresCalibre = ebookPaths.any(
      (value) => BookFormat.fromPath(value)?.requiresCalibre ?? false,
    );
    if (requiresCalibre && !await _ensureCalibre()) {
      return;
    }
    if (!mounted) return;
    setState(() => _validationMessage = null);
    final options = await showOperationSheet(
      context: context,
      fileCount: ebookPaths.length,
      settings: widget.controller.settings,
      hasConvertibleInput: requiresCalibre,
    );
    if (options == null) {
      return;
    }
    try {
      await widget.controller.enqueue(
        sourcePaths: ebookPaths,
        outputDirectory: options.outputDirectory,
        targetLanguage: options.targetLanguage,
        keepOriginal: options.keepOriginal,
        preserveSourceFormat: options.preserveSourceFormat,
        provider: options.provider,
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _validationMessage =
              'Unable to access the selected files. Choose them again. '
              '$error';
        });
      }
      return;
    }
    widget.onShowJobs();
  }

  Future<bool> _ensureCalibre() async {
    await widget.controller.refreshCalibre();
    if (!mounted) return false;
    while (widget.controller.calibreInstallation == null) {
      final action = await _showMissingCalibreDialog();
      if (!mounted) return false;
      if (action == null || action == _CalibreAction.cancel) return false;
      if (action == _CalibreAction.retry) {
        await widget.controller.refreshCalibre();
        if (!mounted) return false;
      }
    }
    return mounted;
  }

  Future<_CalibreAction?> _showMissingCalibreDialog() {
    return showCupertinoDialog<_CalibreAction>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(context.l10n.t('calibreRequired')),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${context.l10n.t('calibreInstallHelp')}\n\n'
            '${CalibreService.installCommand}',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(_CalibreAction.cancel),
            child: Text(context.l10n.t('cancel')),
          ),
          CupertinoDialogAction(
            onPressed: () {
              Clipboard.setData(
                const ClipboardData(text: CalibreService.installCommand),
              );
              Navigator.of(context).pop(_CalibreAction.copy);
            },
            child: Text(context.l10n.t('copyCommand')),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(_CalibreAction.retry),
            child: Text(context.l10n.t('retryDetection')),
          ),
        ],
      ),
    );
  }
}

enum _CalibreAction { cancel, copy, retry }
