import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialProvider,
    required this.initialApiKey,
    required this.onSaveAiSettings,
  });

  final AiProvider initialProvider;
  final String initialApiKey;
  final Future<void> Function(AiProvider provider, String apiKey)
      onSaveAiSettings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _shadowColor = Color(0x22000000);

  late final TextEditingController _apiKeyController;
  late AiProvider _selectedProvider;
  bool _isSaving = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialProvider;
    _apiKeyController = TextEditingController(text: widget.initialApiKey);
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final apiKey = _apiKeyController.text.trim();

    setState(() {
      _isSaving = true;
      _status = apiKey.isEmpty ? 'Clearing API key' : 'Saving AI settings';
    });

    try {
      await widget.onSaveAiSettings(_selectedProvider, apiKey);
      if (!mounted) {
        return;
      }

      setState(() {
        _status = apiKey.isEmpty ? 'API key cleared.' : 'AI settings saved.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to save AI settings: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 24),
          children: [
            Container(
              decoration: BoxDecoration(
                color: _surfaceColor,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: _shadowColor,
                    blurRadius: 20,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.smart_toy_outlined,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'AI Configuration',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Choose your AI provider and manage the API key used by the copilot.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _mutedColor,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Theme(
                    data: theme.copyWith(
                      canvasColor: _panelColor,
                    ),
                    child: DropdownButtonFormField<AiProvider>(
                      // ignore: deprecated_member_use
                      value: _selectedProvider,
                      decoration: const InputDecoration(
                        labelText: 'AI Provider',
                      ),
                      items: AiProvider.values.map((provider) {
                        return DropdownMenuItem<AiProvider>(
                          value: provider,
                          child: Text(provider.label),
                        );
                      }).toList(),
                      onChanged: _isSaving
                          ? null
                          : (provider) {
                              if (provider == null) {
                                return;
                              }

                              setState(() {
                                _selectedProvider = provider;
                              });
                            },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _panelColor,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      _selectedProvider.helperText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _mutedColor,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Enter API Key',
                      helperText: 'Leave blank to clear the saved API key.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _mutedColor,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
