import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/plaintext.dart';

import '../../core/ssh/sftp_service.dart';
import '../../core/theme/app_colors.dart';

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
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _overlayColor = Color(0xB3000000);

  late final CodeLineEditingController _controller;
  late final CodeScrollController _scrollController;
  late String _savedContent;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _savedContent = widget.initialContent;
    _controller = CodeLineEditingController(codeLines: CodeLines.fromText(widget.initialContent));
    _scrollController = CodeScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isDirty => _controller.text != _savedContent;

  Mode _getLanguageMode(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'dart':
        return langDart;
      case 'py':
        return langPython;
      case 'sh':
        return langBash;
      case 'json':
        return langJson;
      case 'js':
        return langJavascript;
      case 'yaml':
      case 'yml':
        return langYaml;
      case 'xml':
        return langXml;
      case 'md':
        return langMarkdown;
      case 'css':
        return langCss;
      case 'html':
        return langXml;
      default:
        return langPlaintext;
    }
  }

  Future<void> _saveFile() async {
    if (_isSaving) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    final contentToSave = _controller.text;
    var usedSudoFallback = false;

    try {
      await widget.sftpService.writeFileWithSudoFallback(
        widget.filePath,
        contentToSave,
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

      _savedContent = contentToSave;
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

  Future<bool> _onWillPop() async {
    if (!_isDirty) {
      return true;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved Changes'),
        content: const Text(
          'You have unsaved changes. Are you sure you want to discard them?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Discard'),
          ),
        ],
      ),
    );

    return result ?? false;
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
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
            CodeEditor(
              controller: _controller,
              scrollController: _scrollController,
              wordWrap: false,
              indicatorBuilder: (context, controller, chunkController, notifier) {
                return DefaultCodeLineNumber(
                  controller: controller,
                  notifier: notifier,
                );
              },
              style: CodeEditorStyle(
                fontSize: 14,
                fontFamily: 'monospace',
                backgroundColor: _backgroundColor,
                codeTheme: CodeHighlightTheme(
                  languages: {
                    'lang': CodeHighlightThemeMode(mode: _getLanguageMode(widget.filePath)),
                  },
                  theme: atomOneDarkTheme,
                ),
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
      ),
    );
  }
}
