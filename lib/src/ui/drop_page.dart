import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:path/path.dart' as path;

import '../jobs/job_controller.dart';
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
      toolBar: const ToolBar(title: Text('Translate')),
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
                                    CupertinoIcons.add,
                                    size: 36,
                                    color: MacosTheme.of(context).primaryColor,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  _dragging
                                      ? 'Drop to add books'
                                      : 'Drop EPUB books here',
                                  style: MacosTheme.of(
                                    context,
                                  ).typography.title2,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'or click to choose one or more files',
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
                        'EPUB 2 and EPUB 3 · DRM-free books only',
                        style: MacosTheme.of(context).typography.caption1,
                      ),
                      if (widget.controller.jobs.isNotEmpty)
                        PushButton(
                          controlSize: ControlSize.regular,
                          secondary: true,
                          onPressed: widget.onShowJobs,
                          child: Text(
                            widget.controller.runningJobCount == 0
                                ? 'View jobs'
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
      label: 'EPUB books',
      extensions: ['epub'],
      uniformTypeIdentifiers: ['org.idpf.epub-container'],
    );
    final files = await openFiles(acceptedTypeGroups: [group]);
    await _acceptPaths(files.map((file) => file.path).toList());
  }

  Future<void> _acceptPaths(List<String> values) async {
    final epubPaths = values
        .where((value) => path.extension(value).toLowerCase() == '.epub')
        .toList(growable: false);
    if (epubPaths.isEmpty) {
      setState(() {
        _validationMessage = 'No supported EPUB files were selected.';
      });
      return;
    }
    setState(() => _validationMessage = null);
    final options = await showOperationSheet(
      context: context,
      fileCount: epubPaths.length,
      settings: widget.controller.settings,
    );
    if (options == null) {
      return;
    }
    try {
      await widget.controller.enqueue(
        sourcePaths: epubPaths,
        outputDirectory: options.outputDirectory,
        targetLanguage: options.targetLanguage,
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
}
