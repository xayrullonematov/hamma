import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/ollama_client.dart';
import '../../core/theme/app_colors.dart';

/// Brutalist in-app model manager for the local AI engine.
///
/// Lists models installed on the local Ollama daemon, lets the user
/// delete them, and lets them pull a new one (either from a curated
/// catalog or by typing a tag). Pulling shows live byte-by-byte progress
/// streamed straight from the daemon.
///
/// Returns the chosen "default model" tag (or `null` if unchanged) when
/// popped, so the caller (Settings) can persist it.
class LocalModelsScreen extends StatefulWidget {
  const LocalModelsScreen({
    super.key,
    required this.endpoint,
    this.currentDefault,
  });

  /// Base URL of the local engine, e.g. `http://localhost:11434`.
  final String endpoint;

  /// The currently-saved default model tag, used to highlight it in the
  /// list and to pre-select the radio button.
  final String? currentDefault;

  @override
  State<LocalModelsScreen> createState() => _LocalModelsScreenState();
}

class _CatalogEntry {
  const _CatalogEntry({
    required this.tag,
    required this.label,
    required this.summary,
    required this.approxSize,
  });
  final String tag;
  final String label;
  final String summary;
  final String approxSize;
}

class _LocalModelsScreenState extends State<LocalModelsScreen> {
  static const Color _zeroTrustGreen = Color(0xFF00FF88);

  // Hand-picked OpenAI-style starter set; everything here works with
  // `ollama pull <tag>` on a stock daemon.
  static const List<_CatalogEntry> _catalog = [
    _CatalogEntry(
      tag: 'gemma3',
      label: 'Gemma 3',
      summary: 'Google general-purpose chat model. Good default.',
      approxSize: '~5 GB',
    ),
    _CatalogEntry(
      tag: 'llama3.2',
      label: 'Llama 3.2',
      summary: 'Meta small/fast. Runs on modest hardware.',
      approxSize: '~2 GB',
    ),
    _CatalogEntry(
      tag: 'llama3',
      label: 'Llama 3',
      summary: 'Meta general-purpose chat. Strong reasoning.',
      approxSize: '~4.7 GB',
    ),
    _CatalogEntry(
      tag: 'mistral',
      label: 'Mistral 7B',
      summary: 'Compact, fast, OSS. Solid all-rounder.',
      approxSize: '~4.1 GB',
    ),
    _CatalogEntry(
      tag: 'phi3',
      label: 'Phi-3',
      summary: 'Microsoft small model. Decent on CPU only.',
      approxSize: '~2.3 GB',
    ),
    _CatalogEntry(
      tag: 'qwen2.5-coder',
      label: 'Qwen 2.5 Coder',
      summary: 'Alibaba code-specialised model.',
      approxSize: '~4.7 GB',
    ),
    _CatalogEntry(
      tag: 'deepseek-coder',
      label: 'DeepSeek Coder',
      summary: 'Strong code completion / explanation.',
      approxSize: '~3.8 GB',
    ),
    _CatalogEntry(
      tag: 'tinyllama',
      label: 'TinyLlama',
      summary: 'Ultra-small. For quick tests on weak hardware.',
      approxSize: '~640 MB',
    ),
  ];

  late OllamaClient _client;
  String? _selectedDefault;
  bool _isLoading = true;
  String? _loadError;
  List<OllamaModel> _models = const [];
  List<OllamaLoadedModel> _loaded = const [];

  /// Render an Ollama `modified_at` ISO-8601 timestamp as a compact
  /// relative string ("3d ago", "5h ago", "just now"). Returns `null`
  /// when the input is missing or unparseable so callers can skip it.
  static String? _formatRelativeTime(String iso) {
    if (iso.isEmpty) return null;
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return null;
    final delta = DateTime.now().toUtc().difference(parsed.toUtc());
    if (delta.isNegative) return 'just now';
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inDays < 1) return '${delta.inHours}h ago';
    if (delta.inDays < 30) return '${delta.inDays}d ago';
    final months = delta.inDays ~/ 30;
    if (months < 12) return '${months}mo ago';
    return '${delta.inDays ~/ 365}y ago';
  }

  @override
  void initState() {
    super.initState();
    _client = OllamaClient(endpoint: widget.endpoint);
    _selectedDefault = widget.currentDefault;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final models = await _client.listModels();
      List<OllamaLoadedModel> loaded = const [];
      try {
        loaded = await _client.listLoadedModels();
      } catch (_) {
        // Some compat engines do not implement /api/ps.
      }
      if (!mounted) return;
      setState(() {
        _models = models;
        _loaded = loaded;
        _isLoading = false;
      });
    } on OllamaUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError =
            'Cannot reach engine at ${widget.endpoint}. ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = e.toString();
      });
    }
  }

  Future<void> _delete(OllamaModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          'Remove "${model.name}" (${model.humanSize}) from disk? '
          'This cannot be undone — you can re-pull it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _client.deleteModel(model.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
      return;
    }
    if (_selectedDefault == model.name) {
      setState(() => _selectedDefault = null);
    }
    await _refresh();
  }

  Future<void> _openPullSheet({String? prefilledTag}) async {
    final tagController = TextEditingController(text: prefilledTag ?? '');
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // Barrier-tap dismissal (`isDismissible`) routes through
      // `Navigator.maybePop`, which honours the sheet's `PopScope` and
      // therefore prompts when a pull is in progress and closes
      // immediately otherwise.
      //
      // The built-in drag-to-dismiss, however, calls `Navigator.pop`
      // directly (see Flutter's bottom_sheet.dart) and would bypass
      // `PopScope`, silently cancelling an in-progress download. We
      // disable it here and provide our own drag handle inside the
      // sheet that funnels swipe-down gestures through the same
      // confirmation flow as the close button.
      isDismissible: true,
      enableDrag: false,
      backgroundColor: AppColors.scaffoldBackground,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: _PullSheet(
          client: _client,
          tagController: tagController,
        ),
      ),
    );
    if (result == true) {
      await _refresh();
    }
  }

  Color _statusColor() {
    if (_loadError != null) return AppColors.danger;
    if (_isLoading) return AppColors.textMuted;
    return _zeroTrustGreen;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text('Local Models'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isLoading ? null : _refresh,
          ),
          IconButton(
            tooltip: 'Pull a model',
            icon: const Icon(Icons.cloud_download_rounded),
            onPressed: _isLoading ? null : () => _openPullSheet(),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _buildInstalledSection(),
            const SizedBox(height: 24),
            _buildCatalogSection(),
          ],
        ),
      ),
      bottomNavigationBar: _selectedDefault == widget.currentDefault
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: AppColors.surface,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _zeroTrustGreen,
                    foregroundColor: Colors.black,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () =>
                      Navigator.of(context).pop<String?>(_selectedDefault),
                  child: Text(
                    _selectedDefault == null
                        ? 'CLEAR DEFAULT MODEL'
                        : 'USE "${_selectedDefault!}" AS DEFAULT',
                    style: TextStyle(
                      fontFamily: AppColors.monoFamily,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildHeader() {
    final color = _statusColor();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.endpoint,
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              fontSize: 12,
              color: color,
              letterSpacing: 1,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _isLoading
                ? 'Querying engine…'
                : _loadError ??
                    '${_models.length} installed · ${_loaded.length} loaded in RAM',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstalledSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('INSTALLED'),
        const SizedBox(height: 8),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loadError != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.danger, width: 3),
              ),
              color: AppColors.surface,
            ),
            child: Text(
              _loadError!,
              style: const TextStyle(
                color: AppColors.danger,
                fontFamily: AppColors.monoFamily,
                fontSize: 12,
              ),
            ),
          )
        else if (_models.isEmpty)
          const _EmptyState(
            message:
                'No models installed yet. Pull one from the catalog below.',
          )
        else
          RadioGroup<String>(
            groupValue: _selectedDefault,
            onChanged: (v) => setState(() => _selectedDefault = v),
            child: Column(
              children: _models.map(_buildModelTile).toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildModelTile(OllamaModel m) {
    final isLoaded = _loaded.any((l) => l.name == m.name);
    final isSelected = _selectedDefault == m.name;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: isSelected ? _zeroTrustGreen : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Radio<String>(
            value: m.name,
            activeColor: _zeroTrustGreen,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  style: const TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 13,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    m.humanSize,
                    if (m.parameterSize.isNotEmpty) m.parameterSize,
                    if (m.quantization.isNotEmpty) m.quantization,
                    if (isLoaded) 'in RAM',
                    if (_formatRelativeTime(m.modifiedAt) != null)
                      'updated ${_formatRelativeTime(m.modifiedAt)}',
                  ].join(' · '),
                  style: const TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded,
                color: AppColors.danger),
            onPressed: () => _delete(m),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogSection() {
    final installedTags = _models.map((m) => m.name).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('CURATED CATALOG'),
        const SizedBox(height: 8),
        ..._catalog.map((entry) {
          final installed = installedTags
              .any((t) => t == entry.tag || t.startsWith('${entry.tag}:'));
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            entry.label,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.tag,
                            style: TextStyle(
                              fontFamily: AppColors.monoFamily,
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.approxSize,
                            style: TextStyle(
                              fontFamily: AppColors.monoFamily,
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.summary,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (installed)
                  Text(
                    'INSTALLED',
                    style: TextStyle(
                      fontFamily: AppColors.monoFamily,
                      fontSize: 10,
                      color: _zeroTrustGreen,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                else
                  OutlinedButton(
                    onPressed: () => _openPullSheet(prefilledTag: entry.tag),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _zeroTrustGreen),
                      foregroundColor: _zeroTrustGreen,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    child: Text(
                      'PULL',
                      style: TextStyle(
                        fontFamily: AppColors.monoFamily,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: AppColors.monoFamily,
        fontSize: 11,
        color: AppColors.textMuted,
        letterSpacing: 2,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
    );
  }
}

class _PullSheet extends StatefulWidget {
  const _PullSheet({required this.client, required this.tagController});
  final OllamaClient client;
  final TextEditingController tagController;

  @override
  State<_PullSheet> createState() => _PullSheetState();
}

class _PullSheetState extends State<_PullSheet> {
  StreamSubscription<OllamaPullProgress>? _sub;
  String _status = '';
  double? _fraction;
  int _completed = 0;
  int _total = 0;
  bool _isPulling = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final tag = widget.tagController.text.trim();
    if (tag.isEmpty) {
      setState(() => _error = 'Enter a model tag, e.g. "gemma3".');
      return;
    }
    setState(() {
      _isPulling = true;
      _error = null;
      _status = 'connecting';
      _fraction = null;
      _completed = 0;
      _total = 0;
      _done = false;
    });

    _sub?.cancel();
    _sub = widget.client.pullModel(tag).listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _status = event.status;
          _completed = event.completedBytes;
          _total = event.totalBytes;
          _fraction = event.fraction;
          if (event.isTerminal) {
            _done = true;
            _isPulling = false;
          }
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _error = e.toString();
          _isPulling = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isPulling = false;
          _done = true;
        });
      },
    );
  }

  Future<void> _cancel() async {
    await _sub?.cancel();
    _sub = null;
    if (!mounted) return;
    setState(() {
      _isPulling = false;
      _status = 'cancelled';
    });
  }

  /// Asks the user whether to abort an in-progress download.
  /// Returns true if the user confirms cancellation.
  Future<bool> _confirmCancelDownload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel download?'),
        content: const Text(
          'The model is still downloading. Progress will be lost if you '
          'cancel now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep downloading'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel download'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _handleClosePressed() async {
    if (_isPulling) {
      final shouldCancel = await _confirmCancelDownload();
      if (!shouldCancel) return;
      await _cancel();
    }
    if (!mounted) return;
    Navigator.of(context).pop(_done);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_isPulling,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldCancel = await _confirmCancelDownload();
        if (!shouldCancel) return;
        await _cancel();
        if (!context.mounted) return;
        Navigator.of(context).pop(_done);
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Custom drag handle. Built-in modal drag-to-dismiss is
          // disabled (it would bypass PopScope). A downward fling
          // here routes through `_handleClosePressed`, so dragging
          // shows the confirmation while pulling and dismisses the
          // sheet immediately when no pull is active.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 200) {
                _handleClosePressed();
              }
            },
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                color: AppColors.border,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'PULL MODEL',
                  style: TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 14,
                    letterSpacing: 2,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: _handleClosePressed,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.tagController,
            enabled: !_isPulling,
            decoration: const InputDecoration(
              labelText: 'Model tag',
              hintText: 'gemma3',
            ),
            style: TextStyle(fontFamily: AppColors.monoFamily, fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (_isPulling || _status.isNotEmpty || _error != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _error ?? _status,
                    style: TextStyle(
                      fontFamily: AppColors.monoFamily,
                      fontSize: 12,
                      color: _error != null
                          ? AppColors.danger
                          : AppColors.textPrimary,
                    ),
                  ),
                  if (_total > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _fraction,
                      backgroundColor: AppColors.border,
                      color: const Color(0xFF00FF88),
                      minHeight: 4,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatBytes(_completed)} / ${formatBytes(_total)}'
                      '${_fraction != null ? ' · ${(100 * _fraction!).toStringAsFixed(0)}%' : ''}',
                      style: const TextStyle(
                        fontFamily: AppColors.monoFamily,
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00FF88),
                    foregroundColor: Colors.black,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _isPulling
                      ? null
                      : (_done
                          ? () => Navigator.of(context).pop(true)
                          : _start),
                  child: Text(
                    _done
                        ? 'DONE'
                        : (_isPulling ? 'PULLING…' : 'START PULL'),
                    style: TextStyle(
                      fontFamily: AppColors.monoFamily,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (_isPulling) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    side: const BorderSide(color: AppColors.danger),
                    foregroundColor: AppColors.danger,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14),
                  ),
                  onPressed: _cancel,
                  child: Text(
                    'CANCEL',
                    style: TextStyle(
                      fontFamily: AppColors.monoFamily,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        ),
      ),
    );
  }
}
