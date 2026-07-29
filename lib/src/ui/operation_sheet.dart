import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../settings/app_settings.dart';

final class OperationOptions {
  const OperationOptions({
    required this.outputDirectory,
    required this.targetLanguage,
    required this.provider,
  });

  final String outputDirectory;
  final String targetLanguage;
  final TranslationProvider provider;
}

String rememberedOutputDirectory(AppSettings settings) =>
    settings.outputDirectoryBookmark.isEmpty ? '' : settings.outputDirectory;

Future<OperationOptions?> showOperationSheet({
  required BuildContext context,
  required int fileCount,
  required AppSettings settings,
}) {
  return showMacosSheet<OperationOptions>(
    context: context,
    builder: (context) => MacosSheet(
      child: _OperationSheetContent(fileCount: fileCount, settings: settings),
    ),
  );
}

final class _OperationSheetContent extends StatefulWidget {
  const _OperationSheetContent({
    required this.fileCount,
    required this.settings,
  });

  final int fileCount;
  final AppSettings settings;

  @override
  State<_OperationSheetContent> createState() => _OperationSheetContentState();
}

final class _OperationSheetContentState extends State<_OperationSheetContent> {
  late final TextEditingController _outputController;
  late String _targetLanguage;
  late TranslationProvider _provider;
  late bool _requiresOutputReselection;

  static const _languages = [
    'Simplified Chinese',
    'Traditional Chinese',
    'English',
    'Japanese',
    'Korean',
    'French',
    'German',
    'Spanish',
  ];

  @override
  void initState() {
    super.initState();
    _outputController = TextEditingController(
      text: rememberedOutputDirectory(widget.settings),
    );
    _requiresOutputReselection =
        widget.settings.outputDirectory.isNotEmpty &&
        widget.settings.outputDirectoryBookmark.isEmpty;
    _targetLanguage = widget.settings.targetLanguage;
    _provider = widget.settings.lastProvider;
  }

  @override
  void dispose() {
    _outputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 560,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Translate ${widget.fileCount} '
              '${widget.fileCount == 1 ? 'book' : 'books'}',
              style: MacosTheme.of(context).typography.title2,
            ),
            const SizedBox(height: 6),
            Text(
              'These options will be remembered for the next job.',
              style: MacosTheme.of(context).typography.subheadline,
            ),
            const SizedBox(height: 24),
            _LabeledControl(
              label: 'Output folder',
              child: Row(
                children: [
                  Expanded(
                    child: MacosTextField(
                      controller: _outputController,
                      readOnly: true,
                      placeholder: 'Choose a folder',
                    ),
                  ),
                  const SizedBox(width: 8),
                  PushButton(
                    controlSize: ControlSize.regular,
                    secondary: true,
                    onPressed: () async {
                      final selected = await getDirectoryPath(
                        initialDirectory: _outputController.text.trim().isEmpty
                            ? null
                            : _outputController.text,
                      );
                      if (selected != null && mounted) {
                        setState(() {
                          _outputController.text = selected;
                          _requiresOutputReselection = false;
                        });
                      }
                    },
                    child: const Text('Choose…'),
                  ),
                ],
              ),
            ),
            if (_requiresOutputReselection) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 130),
                child: Text(
                  'Choose the output folder again to restore macOS access.',
                  style: MacosTheme.of(context).typography.caption1.copyWith(
                    color: MacosColors.systemOrangeColor,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _LabeledControl(
              label: 'Target language',
              child: MacosPopupButton<String>(
                value: _targetLanguage,
                items: [
                  for (final language in _languages)
                    MacosPopupMenuItem(value: language, child: Text(language)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _targetLanguage = value);
                  }
                },
              ),
            ),
            const SizedBox(height: 14),
            _LabeledControl(
              label: 'Output format',
              child: MacosTextField(
                controller: TextEditingController(text: 'EPUB'),
                readOnly: true,
                enabled: false,
              ),
            ),
            const SizedBox(height: 14),
            _LabeledControl(
              label: 'Model',
              child: MacosPopupButton<TranslationProvider>(
                value: _provider,
                items: [
                  for (final provider in TranslationProvider.values)
                    MacosPopupMenuItem(
                      value: provider,
                      child: Text(provider.label),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _provider = value);
                  }
                },
              ),
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 10),
                PushButton(
                  controlSize: ControlSize.large,
                  color: MacosTheme.of(context).primaryColor,
                  onPressed: _outputController.text.trim().isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                          OperationOptions(
                            outputDirectory: _outputController.text,
                            targetLanguage: _targetLanguage,
                            provider: _provider,
                          ),
                        ),
                  child: const Text('Start'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _LabeledControl extends StatelessWidget {
  const _LabeledControl({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: MacosTheme.of(context).typography.body,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: child),
      ],
    );
  }
}
