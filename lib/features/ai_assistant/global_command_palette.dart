import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ai/ai_command_service.dart';
import '../../core/ai/command_risk_assessor.dart';
import '../../core/palette/palette_index.dart';
import '../../core/palette/palette_source.dart';
import '../../core/theme/app_colors.dart';

class GlobalCommandPalette extends StatefulWidget {
  const GlobalCommandPalette({
    super.key,
    required this.aiCommandService,
    required this.availableServers,
    required this.onExecute,
    this.paletteIndex,
  });

  final AiCommandService aiCommandService;
  final List<String> availableServers;
  final void Function(CommandIntent intent) onExecute;
  final PaletteIndex? paletteIndex;

  @override
  State<GlobalCommandPalette> createState() => _GlobalCommandPaletteState();
}

class _MovePaletteSelectionIntent extends Intent {
  const _MovePaletteSelectionIntent(this.delta);
  final int delta;
}

class _InvokePaletteSelectionIntent extends Intent {
  const _InvokePaletteSelectionIntent();
}

class _CyclePaletteScopeIntent extends Intent {
  const _CyclePaletteScopeIntent();
}

class _DismissPaletteIntent extends Intent {
  const _DismissPaletteIntent();
}

class _GlobalCommandPaletteState extends State<GlobalCommandPalette> {
  final TextEditingController _controller = TextEditingController();
  final CommandRiskAssessor _riskAssessor = const CommandRiskAssessor();

  bool _isParsing = false;
  bool _isQuerying = false;
  CommandIntent? _intent;
  List<PaletteResult> _results = const <PaletteResult>[];
  int _selectedIndex = 0;
  int _queryGeneration = 0;
  String? _scopedSourceId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleQueryChanged);
    unawaited(_refreshResults());
  }

  @override
  void dispose() {
    _controller.removeListener(_handleQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  PaletteIndex? get _paletteIndex => widget.paletteIndex;

  String get _scopeLabel {
    final index = _paletteIndex;
    if (index == null || _scopedSourceId == null) return 'All';
    for (final source in index.sources) {
      if (source.id == _scopedSourceId) return source.displayName;
    }
    return 'All';
  }

  void _handleQueryChanged() {
    if (_intent != null || _error != null) {
      setState(() {
        _intent = null;
        _error = null;
      });
    }
    unawaited(_refreshResults());
  }

  Future<void> _refreshResults() async {
    final index = _paletteIndex;
    if (index == null) return;

    final generation = ++_queryGeneration;
    final input = _controller.text.trim();

    setState(() {
      _isQuerying = true;
    });

    try {
      final results =
          _scopedSourceId == null
              ? await index.query(input)
              : await index.queryScoped(_scopedSourceId!, input);
      if (!mounted || generation != _queryGeneration) return;

      var nextSelected = _selectedIndex;
      if (results.isEmpty) {
        nextSelected = 0;
      } else if (nextSelected >= results.length) {
        nextSelected = results.length - 1;
      }

      setState(() {
        _results = results;
        _selectedIndex = nextSelected;
        _isQuerying = false;
      });
    } catch (error) {
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        _results = const <PaletteResult>[];
        _error = error.toString();
        _isQuerying = false;
      });
    }
  }

  Future<void> _handleSubmitted(String value) async {
    if (value.trim().isEmpty || _isParsing) return;

    setState(() {
      _isParsing = true;
      _intent = null;
      _error = null;
    });

    try {
      final intent = await widget.aiCommandService.parseIntent(
        value,
        widget.availableServers,
      );
      if (mounted) {
        setState(() {
          _intent = intent;
          _isParsing = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _isParsing = false;
        });
      }
    }
  }

  void _moveSelection(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + delta) % _results.length;
      if (_selectedIndex < 0) _selectedIndex += _results.length;
    });
  }

  Future<void> _invokeSelectedOrParse() async {
    if (_intent != null) {
      widget.onExecute(_intent!);
      Navigator.of(context).pop();
      return;
    }

    if (_results.isEmpty) {
      await _handleSubmitted(_controller.text);
      return;
    }

    final index = _paletteIndex;
    final result = _results[_selectedIndex];
    final navigator = Navigator.of(context);
    final invokeContext = navigator.context;

    if (index != null) {
      unawaited(index.recordInvocation(result));
    }

    navigator.pop();
    await result.onInvoke(invokeContext);
  }

  void _cycleScope() {
    final index = _paletteIndex;
    if (index == null || index.sources.isEmpty) return;

    final sourceIds = <String?>[
      null,
      ...index.sources.map((source) => source.id),
    ];
    final current = sourceIds.indexOf(_scopedSourceId);
    final next = sourceIds[(current + 1) % sourceIds.length];
    setState(() {
      _scopedSourceId = next;
      _selectedIndex = 0;
    });
    unawaited(_refreshResults());
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(
          LogicalKeyboardKey.arrowDown,
        ): _MovePaletteSelectionIntent(1),
        SingleActivator(
          LogicalKeyboardKey.arrowUp,
        ): _MovePaletteSelectionIntent(-1),
        SingleActivator(LogicalKeyboardKey.enter):
            _InvokePaletteSelectionIntent(),
        SingleActivator(LogicalKeyboardKey.tab): _CyclePaletteScopeIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _DismissPaletteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MovePaletteSelectionIntent:
              CallbackAction<_MovePaletteSelectionIntent>(
                onInvoke: (intent) {
                  _moveSelection(intent.delta);
                  return null;
                },
              ),
          _InvokePaletteSelectionIntent:
              CallbackAction<_InvokePaletteSelectionIntent>(
                onInvoke: (_) => _invokeSelectedOrParse(),
              ),
          _CyclePaletteScopeIntent: CallbackAction<_CyclePaletteScopeIntent>(
            onInvoke: (_) {
              _cycleScope();
              return null;
            },
          ),
          _DismissPaletteIntent: CallbackAction<_DismissPaletteIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: Center(
              child: Container(
                width: 640,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.zero,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          if (_paletteIndex != null) ...[
                            _ScopeChip(label: _scopeLabel),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              autofocus: true,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                              ),
                              decoration: const InputDecoration(
                                hintText:
                                    'What do you want to do? (e.g. Restart nginx on production-db)',
                                hintStyle: TextStyle(
                                  color: AppColors.textMuted,
                                ),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) {
                                unawaited(_invokeSelectedOrParse());
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: AppColors.border, height: 1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 120,
                        maxHeight: 420,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: _buildContent(),
                      ),
                    ),
                    if (_intent != null) _buildIntentActions(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIntentActions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(color: AppColors.border, height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () {
                  widget.onExecute(_intent!);
                  Navigator.of(context).pop();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.textPrimary,
                  foregroundColor: AppColors.scaffoldBackground,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                ),
                child: const Text('Execute'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isParsing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: AppColors.textPrimary,
              strokeWidth: 3,
            ),
            SizedBox(height: 20),
            Text(
              'Parsing intent...',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    if (_intent != null) {
      return _buildIntentPreview();
    }

    if (_error != null) {
      return Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.danger,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.danger, fontSize: 14),
            ),
          ),
        ],
      );
    }

    if (_paletteIndex != null) {
      if (_isQuerying && _results.isEmpty) {
        return const Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              color: AppColors.textPrimary,
              strokeWidth: 2,
            ),
          ),
        );
      }

      if (_results.isNotEmpty) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _results.length; i++)
              _PaletteResultRow(
                result: _results[i],
                selected: i == _selectedIndex,
                onTap: () {
                  setState(() {
                    _selectedIndex = i;
                  });
                  unawaited(_invokeSelectedOrParse());
                },
              ),
          ],
        );
      }

      return const Center(
        child: Text(
          'No direct matches. Press Enter for an AI suggestion.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 14),
        ),
      );
    }

    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.keyboard_command_key_rounded,
            color: Color(0xFF475569),
            size: 32,
          ),
          SizedBox(height: 12),
          Text(
            'Type your request and press Enter',
            style: TextStyle(color: AppColors.textMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildIntentPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.15),
                borderRadius: BorderRadius.zero,
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: AppColors.danger,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _intent!.action,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        if (_intent!.targetServer != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.textPrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.zero,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.dns_rounded,
                  color: AppColors.textPrimary,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Target: ${_intent!.targetServer}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            borderRadius: BorderRadius.zero,
            border: Border.all(color: AppColors.border),
          ),
          width: double.infinity,
          child: SelectableText(
            _intent!.command,
            style: const TextStyle(
              fontFamily: 'monospace',
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _RiskAssessmentBadge(analysis: _riskAssessor.assess(_intent!.command)),
        const SizedBox(height: 12),
        Text(
          _intent!.explanation,
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 14,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _RiskAssessmentBadge extends StatelessWidget {
  const _RiskAssessmentBadge({required this.analysis});

  final CommandAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final color = switch (analysis.riskLevel) {
      CommandRiskLevel.low => Colors.green,
      CommandRiskLevel.moderate => Colors.orange,
      CommandRiskLevel.high => Colors.red,
      CommandRiskLevel.critical => Colors.purple,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.zero,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'RISK: ${analysis.riskLevel.name.toUpperCase()}',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            analysis.explanation,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.zero,
      ),
      child: Text(
        '$label >',
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PaletteResultRow extends StatelessWidget {
  const _PaletteResultRow({
    required this.result,
    required this.selected,
    required this.onTap,
  });

  final PaletteResult result;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color:
              selected
                  ? AppColors.textPrimary.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.18),
          border: Border.all(
            color: selected ? AppColors.textPrimary : AppColors.border,
          ),
          borderRadius: BorderRadius.zero,
        ),
        child: Row(
          children: [
            Icon(
              result.icon,
              color: selected ? AppColors.textPrimary : AppColors.textMuted,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    result.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (result.subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      result.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              result.sourceId,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
