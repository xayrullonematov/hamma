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
  final Future<void> Function(AiProvider provider, String apiKey) onSaveAiSettings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<AiProvider>(
              // ignore: deprecated_member_use
              value: _selectedProvider,
              decoration: const InputDecoration(
                labelText: 'AI Provider',
                border: OutlineInputBorder(),
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
            const SizedBox(height: 8),
            Text(_selectedProvider.helperText),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Enter API Key',
                helperText: 'Leave blank to clear the saved API key.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _isSaving ? null : _save,
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
              Text(_status),
            ],
          ],
        ),
      ),
    );
  }
}
