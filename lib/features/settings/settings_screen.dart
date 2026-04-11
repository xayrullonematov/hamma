import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialApiKey,
    required this.onSaveApiKey,
  });

  final String initialApiKey;
  final Future<void> Function(String apiKey) onSaveApiKey;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _apiKeyController;
  bool _isSaving = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
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
      _status = apiKey.isEmpty ? 'Clearing API key' : 'Saving API key';
    });

    try {
      await widget.onSaveApiKey(apiKey);
      if (!mounted) {
        return;
      }

      setState(() {
        _status = apiKey.isEmpty ? 'API key cleared.' : 'API key saved.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to save API key: $error';
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
