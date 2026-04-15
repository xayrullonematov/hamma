import 'package:flutter/material.dart';

import '../../core/ssh/sftp_service.dart';

class FileEditorScreen extends StatefulWidget {
  const FileEditorScreen({
    super.key,
    required this.sftpService,
    required this.filePath,
    required this.initialContent,
  });

  final SftpService sftpService;
  final String filePath;
  final String initialContent;

  @override
  State<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends State<FileEditorScreen> {
  static const _backgroundColor = Color(0xFF020617);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _overlayColor = Color(0xB3000000);

  late final TextEditingController _controller;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveFile() async {
    if (_isSaving) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    var usedSudoFallback = false;

    try {
      await widget.sftpService.writeFileWithSudoFallback(
        widget.filePath,
        _controller.text,
        onSudoFallbackPrompt: () async {
          final confirmed = await _confirmSudoSave();
          if (confirmed) {
            usedSudoFallback = true;
          }
          return confirmed;
        },
      );
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            usedSudoFallback ? 'File saved with sudo' : 'File saved',
          ),
        ),
      );
    } on SftpSudoFallbackCancelledException {
      // The user explicitly cancelled the sudo escalation prompt.
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<bool> _confirmSudoSave() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Permission Denied'),
              content: const Text(
                'Permission Denied. This file requires root privileges. Attempt to save with sudo?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Use sudo'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  String _fileName(String path) {
    final normalized =
        path.length > 1 && path.endsWith('/')
            ? path.substring(0, path.length - 1)
            : path;
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty);
    if (segments.isEmpty) {
      return normalized;
    }

    return segments.last;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: Text(_fileName(widget.filePath)),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveFile,
            child:
                _isSaving
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Save'),
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: TextField(
              controller: _controller,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
                height: 1.5,
              ),
              decoration: const InputDecoration.collapsed(
                hintText: 'File contents',
                hintStyle: TextStyle(color: _mutedColor),
              ),
              cursorColor: Colors.white,
            ),
          ),
          if (_isSaving)
            const Positioned.fill(
              child: ColoredBox(
                color: _overlayColor,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
