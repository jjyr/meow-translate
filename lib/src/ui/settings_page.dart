import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../jobs/job_controller.dart';
import '../settings/app_settings.dart';

final class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.controller, super.key});

  final JobController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  late TranslationProvider _provider;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _promptController;
  var _saving = false;
  var _saved = false;

  @override
  void initState() {
    super.initState();
    _provider = widget.controller.settings.lastProvider;
    _baseUrlController = TextEditingController();
    _modelController = TextEditingController();
    _apiKeyController = TextEditingController();
    _promptController = TextEditingController();
    _loadProvider();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  void _loadProvider() {
    final model = widget.controller.settings.model(_provider);
    _baseUrlController.text = model.baseUrl;
    _modelController.text = model.model;
    _apiKeyController.text = model.apiKey;
    _promptController.text = model.prompt;
    _saved = false;
  }

  @override
  Widget build(BuildContext context) {
    return MacosScaffold(
      toolBar: const ToolBar(title: Text('Settings')),
      children: [
        ContentArea(
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
            children: [
              Text(
                'Translation model',
                style: MacosTheme.of(context).typography.title2,
              ),
              const SizedBox(height: 6),
              Text(
                'API keys are stored as plain text in Meow’s configuration '
                'file with owner-only permissions.',
                style: MacosTheme.of(context).typography.subheadline,
              ),
              const SizedBox(height: 28),
              _SettingsRow(
                label: 'Provider',
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
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _provider = value;
                      _loadProvider();
                    });
                  },
                ),
              ),
              const SizedBox(height: 16),
              _SettingsRow(
                label: 'Base URL',
                child: MacosTextField(
                  controller: _baseUrlController,
                  placeholder: 'https://api.example.com/v1',
                  onChanged: (_) => setState(() => _saved = false),
                ),
              ),
              const SizedBox(height: 16),
              _SettingsRow(
                label: 'Model',
                child: MacosTextField(
                  controller: _modelController,
                  placeholder: 'Model name',
                  onChanged: (_) => setState(() => _saved = false),
                ),
              ),
              const SizedBox(height: 16),
              _SettingsRow(
                label: 'API key',
                child: MacosTextField(
                  controller: _apiKeyController,
                  placeholder: 'API key',
                  obscureText: true,
                  onChanged: (_) => setState(() => _saved = false),
                ),
              ),
              const SizedBox(height: 16),
              _SettingsRow(
                label: 'Prompt',
                alignTop: true,
                child: MacosTextField(
                  controller: _promptController,
                  minLines: 10,
                  maxLines: 18,
                  placeholder: 'Translation instructions',
                  onChanged: (_) => setState(() => _saved = false),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_saved)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        'Saved',
                        style: MacosTheme.of(context).typography.subheadline
                            .copyWith(color: MacosColors.systemGreenColor),
                      ),
                    ),
                  PushButton(
                    controlSize: ControlSize.large,
                    color: MacosTheme.of(context).primaryColor,
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const ProgressCircle(radius: 7)
                        : const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = false;
    });
    final updatedModel = widget.controller.settings
        .model(_provider)
        .copyWith(
          baseUrl: _baseUrlController.text.trim(),
          model: _modelController.text.trim(),
          apiKey: _apiKeyController.text.trim(),
          prompt: _promptController.text,
        );
    final settings = widget.controller.settings
        .withModel(updatedModel)
        .copyWith(lastProvider: _provider);
    await widget.controller.updateSettings(settings);
    if (mounted) {
      setState(() {
        _saving = false;
        _saved = true;
      });
    }
  }
}

final class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.label,
    required this.child,
    this.alignTop = false,
  });

  final String label;
  final Widget child;
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: alignTop
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 92,
          child: Padding(
            padding: EdgeInsets.only(top: alignTop ? 5 : 0),
            child: Text(label, textAlign: TextAlign.right),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: child),
      ],
    );
  }
}
