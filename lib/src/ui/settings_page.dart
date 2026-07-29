import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../jobs/job_controller.dart';
import '../l10n/app_localizations.dart';
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
  late final TextEditingController _executableController;
  late final TextEditingController _promptController;
  var _saving = false;
  var _saved = false;
  bool? _codexAvailable;
  Timer? _codexCheckTimer;
  var _codexCheckGeneration = 0;

  @override
  void initState() {
    super.initState();
    _provider = widget.controller.settings.lastProvider;
    _baseUrlController = TextEditingController();
    _modelController = TextEditingController();
    _apiKeyController = TextEditingController();
    _executableController = TextEditingController();
    _promptController = TextEditingController();
    _loadProvider();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    _executableController.dispose();
    _promptController.dispose();
    _codexCheckTimer?.cancel();
    super.dispose();
  }

  void _loadProvider() {
    final model = widget.controller.settings.model(_provider);
    _baseUrlController.text = model.baseUrl;
    _modelController.text = model.model;
    _apiKeyController.text = model.apiKey;
    _executableController.text = model.executable;
    _promptController.text = model.prompt;
    _saved = false;
    if (_provider == TranslationProvider.codexCli) {
      _scheduleCodexCheck();
    }
  }

  void _scheduleCodexCheck() {
    _codexCheckTimer?.cancel();
    _codexAvailable = null;
    final generation = ++_codexCheckGeneration;
    _codexCheckTimer = Timer(const Duration(milliseconds: 250), () async {
      final executable = _executableController.text.trim();
      var available = false;
      if (executable.isNotEmpty) {
        try {
          final result = await Process.run(executable, [
            '--version',
          ]).timeout(const Duration(seconds: 3));
          available = result.exitCode == 0;
        } on Object {
          available = false;
        }
      }
      if (mounted && generation == _codexCheckGeneration) {
        setState(() => _codexAvailable = available);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MacosScaffold(
      toolBar: ToolBar(title: Text(context.l10n.t('settings'))),
      children: [
        ContentArea(
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
            children: [
              Text(
                context.l10n.t('translationModel'),
                style: MacosTheme.of(context).typography.title2,
              ),
              const SizedBox(height: 6),
              Text(
                _provider == TranslationProvider.codexCli
                    ? context.l10n.t('cliNote')
                    : context.l10n.t('secretNote'),
                style: MacosTheme.of(context).typography.subheadline,
              ),
              const SizedBox(height: 28),
              _SettingsRow(
                label: context.l10n.t('provider'),
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
              if (_provider == TranslationProvider.codexCli) ...[
                const SizedBox(height: 16),
                _SettingsRow(
                  label: context.l10n.t('executable'),
                  child: Row(
                    children: [
                      Expanded(
                        child: MacosTextField(
                          controller: _executableController,
                          placeholder: 'codex',
                          onChanged: (_) {
                            setState(() => _saved = false);
                            _scheduleCodexCheck();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (_codexAvailable == null)
                        Text(
                          context.l10n.t('codexChecking'),
                          style: MacosTheme.of(context).typography.caption1,
                        )
                      else if (!_codexAvailable!)
                        Flexible(
                          child: Text(
                            context.l10n.t('codexMissing'),
                            style: MacosTheme.of(context).typography.caption1
                                .copyWith(color: MacosColors.systemRedColor),
                          ),
                        ),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 16),
                _SettingsRow(
                  label: context.l10n.t('baseUrl'),
                  child: MacosTextField(
                    controller: _baseUrlController,
                    placeholder: 'https://api.example.com/v1',
                    onChanged: (_) => setState(() => _saved = false),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _SettingsRow(
                label: context.l10n.t('model'),
                child: MacosTextField(
                  controller: _modelController,
                  placeholder: 'Model name',
                  onChanged: (_) => setState(() => _saved = false),
                ),
              ),
              if (_provider != TranslationProvider.codexCli) ...[
                const SizedBox(height: 16),
                _SettingsRow(
                  label: context.l10n.t('apiKey'),
                  child: MacosTextField(
                    controller: _apiKeyController,
                    placeholder: context.l10n.t('apiKey'),
                    obscureText: true,
                    onChanged: (_) => setState(() => _saved = false),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _SettingsRow(
                label: context.l10n.t('guidance'),
                alignTop: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MacosTextField(
                      controller: _promptController,
                      minLines: 10,
                      maxLines: 18,
                      placeholder: 'Translation instructions',
                      onChanged: (_) => setState(() => _saved = false),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.t('plainText'),
                      style: MacosTheme.of(context).typography.caption1,
                    ),
                  ],
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
                        context.l10n.t('saved'),
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
                        : Text(context.l10n.t('save')),
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
          executable: _executableController.text.trim(),
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
