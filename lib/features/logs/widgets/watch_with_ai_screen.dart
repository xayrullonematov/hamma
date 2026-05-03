import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/ai/ai_command_service.dart';
import '../../../core/ai/ai_provider.dart';
import '../../../core/ai/log_triage/log_batcher.dart';
import '../../../core/ai/log_triage/log_triage_models.dart';
import '../../../core/ai/log_triage/log_triage_service.dart';
import '../../../core/ssh/ssh_service.dart';
import '../../../core/storage/api_key_storage.dart';
import '../../../core/storage/custom_actions_storage.dart';
import '../../../core/storage/log_triage_prefs.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/responsive/breakpoints.dart';
import '../../ai_assistant/ai_copilot_sheet.dart';
import '../../ai_assistant/copilot_dock.dart';
import '../../quick_actions/quick_actions.dart';

/// Brutalist split-pane "Watch with AI" view.
///
/// Left pane: raw log tail (xterm-ish). Right pane: live AI insights —
/// severity badge, summary, suggested-command card (gated by the risk
/// assessor), quick actions row.
///
/// Local AI only — when [aiSettings].provider != local the screen
/// renders a "Local AI required" banner and never starts the triage
/// pipeline, preserving the zero-trust guarantee that log lines never
/// leave loopback.
class WatchWithAiScreen extends StatefulWidget {
  const WatchWithAiScreen({
    super.key,
    required this.sshService,
    required this.command,
    required this.title,
    required this.aiSettings,
    this.prefs = const LogTriagePrefs(),
    this.actionsStorage = const CustomActionsStorage(),
  });

  final SshService sshService;

  /// Tailing command — must produce continuous lines on stdout (e.g.
  /// `journalctl -f`, `docker logs -f --tail 50 web`, `tail -f /var/log/syslog`).
  final String command;

  /// Human-readable title for the AppBar, e.g. `journalctl -f`.
  final String title;

  final AiSettings aiSettings;
  final LogTriagePrefs prefs;
  final CustomActionsStorage actionsStorage;

  @override
  State<WatchWithAiScreen> createState() => _WatchWithAiScreenState();
}

class _WatchWithAiScreenState extends State<WatchWithAiScreen> {
  static const _maxRawLines = 1000;

  final List<_RawLine> _rawLines = [];
  final ScrollController _rawScroll = ScrollController();
  bool _autoScroll = true;

  SSHSession? _session;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  StreamSubscription<InsightUpdate>? _insightSub;
  StreamController<String>? _lineBus;

  AiCommandService? _aiService;
  LogTriageService? _triage;
  LogBatcher? _batcher;

  int _batchSize = LogTriagePrefs.defaultBatchSize;
  bool _starting = true;
  String? _bootError;

  InsightUpdate? _latest;
  bool _analyzing = false;
  int _batchesSeen = 0;
  DateTime? _lastUpdateAt;

  @override
  void initState() {
    super.initState();
    _rawScroll.addListener(() {
      if (!_rawScroll.hasClients) return;
      final pos = _rawScroll.position;
      final atBottom = (pos.maxScrollExtent - pos.pixels) < 40;
      if (atBottom != _autoScroll) {
        setState(() => _autoScroll = atBottom);
      }
    });
    unawaited(_boot());
  }

  Future<void> _boot() async {
    if (widget.aiSettings.provider != AiProvider.local) {
      setState(() {
        _starting = false;
        _bootError = null; // banner handles this case
      });
      return;
    }
    try {
      _batchSize = await widget.prefs.loadBatchSize();
      _aiService = AiCommandService.forProvider(
        provider: AiProvider.local,
        apiKey: '',
        localEndpoint: widget.aiSettings.localEndpoint,
        localModel: widget.aiSettings.localModel,
      );
      _triage = await LogTriageService.create(
        aiService: _aiService!,
        prefs: widget.prefs,
      );
      await _startStreaming();
      if (mounted) setState(() => _starting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _bootError = e.toString();
        });
      }
    }
  }

  Future<void> _startStreaming() async {
    await _stopStreaming();
    _lineBus = StreamController<String>.broadcast();

    final session = await widget.sshService.streamCommand(widget.command);
    _session = session;

    _stdout = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine);
    _stderr = session.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) => _onLine(l, isError: true));

    _batcher = LogBatcher(maxLines: _batchSize);
    _insightSub = _triage!
        .watch(_batcher!.batch(_lineBus!.stream))
        .listen(_onInsight, onError: (Object e, _) {
      if (!mounted) return;
      setState(() => _analyzing = false);
      _toast('AI triage error: $e');
    });
  }

  Future<void> _stopStreaming() async {
    await _insightSub?.cancel();
    await _stdout?.cancel();
    await _stderr?.cancel();
    _session?.close();
    await _lineBus?.close();
    _insightSub = null;
    _stdout = null;
    _stderr = null;
    _session = null;
    _lineBus = null;
    _batcher = null;
  }

  void _onLine(String line, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _rawLines.add(_RawLine(line, isError: isError));
      while (_rawLines.length > _maxRawLines) {
        _rawLines.removeAt(0);
      }
      // We only mark "analyzing" when we know a batch is forming.
      _analyzing = true;
    });
    _lineBus?.add(line);
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_rawScroll.hasClients && _autoScroll) {
          _rawScroll.jumpTo(_rawScroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _onInsight(InsightUpdate update) {
    if (!mounted) return;
    setState(() {
      // Muted insights still tick the counter / clear the spinner so
      // the UI stays lively for recurring acknowledged patterns, but
      // we DO NOT replace _latest — the previously-surfaced insight
      // stays put so the user isn't shown the muted summary again.
      // This honours the mute-suppression contract while avoiding the
      // "stuck spinner / frozen count" UX issue.
      if (!update.muted) {
        _latest = update;
      }
      _batchesSeen++;
      _lastUpdateAt = DateTime.now();
      _analyzing = false;
    });
  }

  Future<void> _muteCurrent() async {
    final fp = _latest?.insight.fingerprint;
    if (fp == null || fp.isEmpty) return;
    await _triage?.mute(fp);
    if (!mounted) return;
    setState(() {
      _latest = InsightUpdate(
        insight: _latest!.insight,
        batch: _latest!.batch,
        muted: true,
        suggestedCommandRisk: _latest!.suggestedCommandRisk,
      );
    });
    _toast('Muted: ${_latest!.insight.severity.label}');
  }

  Future<void> _saveSnippet() async {
    final cmd = _latest?.insight.suggestedCommand?.trim();
    if (cmd == null || cmd.isEmpty) return;
    // Refuse to persist a critical-risk suggestion as a one-tap
    // snippet — the snippet pad doesn't show the risk badge, so a
    // future tap could execute it without the warning the triage
    // screen surfaces here.
    if (_latest!.suggestedCommandIsCritical) {
      _toast('Refused: critical-risk command cannot be saved as a snippet.');
      return;
    }
    try {
      final existing = await widget.actionsStorage.loadActions();
      final label = _shortLabel(_latest!.insight.summary);
      final id =
          'custom-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      final next = [
        ...existing,
        QuickAction(id: id, label: label, command: cmd, isCustom: true),
      ];
      await widget.actionsStorage.saveActions(next);
      _toast('Saved snippet: $label');
    } catch (e) {
      _toast('Save failed: $e');
    }
  }

  /// Hands the current insight + the recent log tail to the AI Copilot
  /// for a deeper, conversational follow-up. Only the local-AI bullet
  /// of the copilot is allowed in the same zero-trust spirit as the
  /// triage screen — the copilot itself enforces this when the user
  /// switches providers, but we seed it with the current local
  /// settings so the round-trip stays loopback.
  Future<void> _openInCopilot() async {
    final latest = _latest;
    if (latest == null) return;
    final settings = widget.aiSettings;
    if (settings.provider != AiProvider.local) {
      _toast('Local AI required.');
      return;
    }
    final cmd = latest.insight.suggestedCommand?.trim();
    final critical = latest.suggestedCommandIsCritical;
    final tail = _rawLines
        .skip(_rawLines.length > 40 ? _rawLines.length - 40 : 0)
        .map((l) => l.text)
        .join('\n');
    final prompt = StringBuffer()
      ..writeln('Help me triage this live log stream from ${widget.title}.')
      ..writeln('')
      ..writeln('AI summary so far (severity ${latest.insight.severity.label}):')
      ..writeln(latest.insight.summary)
      ..writeln('');
    if (cmd != null && cmd.isNotEmpty) {
      prompt
        ..writeln(critical
            ? 'Suggested command (BLOCKED by risk assessor — do NOT run as-is):'
            : 'Suggested command:')
        ..writeln('  $cmd')
        ..writeln('');
    }
    prompt
      ..writeln('Recent log lines (most recent last):')
      ..writeln('---')
      ..writeln(tail)
      ..writeln('---')
      ..writeln('What is the root cause and how should I investigate next?');

    Widget buildBody(BuildContext _) => AiCopilotSheet(
          serverId: widget.title,
          provider: settings.provider,
          apiKeyStorage: const ApiKeyStorage(),
          openRouterModel: settings.openRouterModel,
          localEndpoint: settings.localEndpoint,
          localModel: settings.localModel,
          initialPrompt: prompt.toString(),
          executionTarget: AiCopilotExecutionTarget.dashboard,
          // Triage screen has no shell of its own — execution is always
          // refused; the copilot will surface the message instead.
          canRunCommands: () => false,
          getContext: () => tail,
          onRunCommand: (_) async => null,
          executionUnavailableMessage:
              'Open the terminal to run commands; this view only inspects logs.',
        );

    // When a CopilotDock is installed (desktop dashboard ≥1100px),
    // dock the triage copilot in the right-hand pane instead of the
    // modal sheet so the log stream stays visible while the user
    // chats with the AI. Mobile/tablet still get the bottom sheet.
    final dock = CopilotDock.maybeOf(context);
    if (dock != null && Breakpoints.isDesktop(context)) {
      dock.open(
        CopilotDockRequest(
          title: 'AI TRIAGE — ${widget.title.toUpperCase()}',
          builder: buildBody,
        ),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: buildBody(context),
      ),
    );
  }

  Future<void> _copySuggested() async {
    final cmd = _latest?.insight.suggestedCommand?.trim();
    if (cmd == null || cmd.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: cmd));
    _toast('Copied to clipboard');
  }

  String _shortLabel(String summary) {
    final cleaned = summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return 'AI suggestion';
    if (cleaned.length <= 48) return cleaned;
    return '${cleaned.substring(0, 45)}…';
  }

  Future<void> _changeCadence(int newSize) async {
    final clamped = LogTriagePrefs.clampBatchSize(newSize);
    if (clamped == _batchSize) return;
    setState(() => _batchSize = clamped);
    await widget.prefs.saveBatchSize(clamped);
    // Restart the pipeline so the new cadence takes effect immediately.
    if (_aiService != null && _triage != null) {
      await _startStreaming();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_stopStreaming());
    _rawScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.aiSettings.provider == AiProvider.local;
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'WATCH WITH AI',
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                color: AppColors.accent,
              ),
            ),
            Text(
              widget.title,
              style: const TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          if (isLocal)
            PopupMenuButton<int>(
              tooltip: 'Cadence (lines per batch)',
              icon: const Icon(Icons.tune, color: AppColors.textMuted),
              onSelected: _changeCadence,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 25, child: Text('Every 25 lines')),
                PopupMenuItem(value: 50, child: Text('Every 50 lines (default)')),
                PopupMenuItem(value: 100, child: Text('Every 100 lines')),
                PopupMenuItem(value: 250, child: Text('Every 250 lines')),
                PopupMenuItem(value: 500, child: Text('Every 500 lines (max)')),
              ],
            ),
        ],
      ),
      body: !isLocal
          ? _buildLocalRequiredBanner()
          : _starting
              ? const Center(child: CircularProgressIndicator())
              : _bootError != null
                  ? _buildBootError(_bootError!)
                  : _buildSplitPane(),
    );
  }

  Widget _buildLocalRequiredBanner() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.accent),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined,
                color: AppColors.accent, size: 36),
            const SizedBox(height: 12),
            const Text(
              'LOCAL AI REQUIRED',
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                color: AppColors.accent,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Live log triage runs only against the local AI engine '
              '(Ollama / LM Studio / llama.cpp / Jan) so log lines '
              'never leave loopback. Switch the AI provider to '
              '"Local AI" in Settings to enable Watch with AI.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBootError(String err) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: AppColors.danger, size: 32),
            const SizedBox(height: 8),
            Text(
              err,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitPane() {
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 800;
      final raw = _buildRawPane();
      final insights = _buildInsightsPane();
      if (wide) {
        return Row(
          children: [
            Expanded(flex: 6, child: raw),
            Container(width: 1, color: AppColors.border),
            Expanded(flex: 5, child: insights),
          ],
        );
      }
      return Column(
        children: [
          Expanded(flex: 3, child: raw),
          Container(height: 1, color: AppColors.border),
          Expanded(flex: 2, child: insights),
        ],
      );
    });
  }

  Widget _buildRawPane() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(8),
      child: ListView.builder(
        controller: _rawScroll,
        itemCount: _rawLines.length,
        itemBuilder: (_, i) {
          final line = _rawLines[i];
          return Text(
            line.text,
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              fontSize: 11,
              color: line.isError
                  ? AppColors.danger
                  : AppColors.textPrimary,
            ),
          );
        },
      ),
    );
  }

  Widget _buildInsightsPane() {
    final update = _latest;
    final severity = update?.insight.severity ?? TriageSeverity.normal;
    final color = _severityColor(severity);
    return Container(
      color: AppColors.scaffoldBackground,
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: color, width: 2),
        ),
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(severity, color, update),
              const SizedBox(height: 14),
              _buildSummary(update),
              const SizedBox(height: 16),
              _buildSuggestion(update),
              const SizedBox(height: 16),
              _buildActionsRow(update),
              const SizedBox(height: 12),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
      TriageSeverity severity, Color color, InsightUpdate? update) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: color, width: 1),
          ),
          child: Text(
            severity.label,
            style: TextStyle(
              fontFamily: AppColors.monoFamily,
              color: color,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(width: 10),
        if (update?.muted == true)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(Icons.notifications_off,
                size: 14, color: AppColors.textMuted),
          ),
        const Spacer(),
        if (_analyzing)
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.accent,
            ),
          ),
      ],
    );
  }

  Widget _buildSummary(InsightUpdate? update) {
    if (update == null) {
      return Text(
        _analyzing
            ? 'Buffering log lines… first insight after $_batchSize lines.'
            : 'Waiting for log activity.',
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }
    return Text(
      update.insight.summary.isEmpty
          ? '(no summary returned)'
          : update.insight.summary,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 14,
        height: 1.4,
      ),
    );
  }

  Widget _buildSuggestion(InsightUpdate? update) {
    if (update == null || !update.hasSuggestedCommand) {
      return const SizedBox.shrink();
    }
    final cmd = update.insight.suggestedCommand!;
    final critical = update.suggestedCommandIsCritical;
    final hints = update.insight.riskHints;
    final color = critical ? AppColors.danger : AppColors.accent;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: color, width: 1),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                critical ? 'BLOCKED · CRITICAL' : 'SUGGESTED COMMAND',
                style: TextStyle(
                  fontFamily: AppColors.monoFamily,
                  color: color,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  fontSize: 10,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 14, color: AppColors.textMuted),
                onPressed: _copySuggested,
                tooltip: 'Copy command',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            cmd,
            style: const TextStyle(
              fontFamily: AppColors.monoFamily,
              color: AppColors.textPrimary,
              fontSize: 12,
            ),
          ),
          if (hints.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final h in hints)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• $h',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
          if (critical) ...[
            const SizedBox(height: 6),
            const Text(
              'Run blocked by the local risk assessor. Review manually before executing.',
              style: TextStyle(color: AppColors.danger, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionsRow(InsightUpdate? update) {
    final canMute = update != null && !update.muted;
    final hasCmd = update != null && update.hasSuggestedCommand;
    // SAVE SNIPPET is gated on the risk assessor — see _saveSnippet
    // for the rationale. COPY is always permitted because the user is
    // explicitly choosing to inspect the command, not arming it.
    final canSave = hasCmd && !update.suggestedCommandIsCritical;
    final canCopy = hasCmd;
    final canCopilot = update != null &&
        widget.aiSettings.provider == AiProvider.local;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _ActionChip(
          label: canMute ? 'MUTE PATTERN' : 'MUTED',
          icon: Icons.notifications_off_outlined,
          enabled: canMute,
          onTap: _muteCurrent,
        ),
        _ActionChip(
          label: 'SAVE SNIPPET',
          icon: Icons.bookmark_add_outlined,
          enabled: canSave,
          onTap: _saveSnippet,
        ),
        _ActionChip(
          label: 'COPY',
          icon: Icons.copy_all_outlined,
          enabled: canCopy,
          onTap: _copySuggested,
        ),
        _ActionChip(
          label: 'OPEN IN COPILOT',
          icon: Icons.smart_toy_outlined,
          enabled: canCopilot,
          onTap: _openInCopilot,
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Text(
      'Cadence: every $_batchSize lines · '
      'Batches analysed: $_batchesSeen'
      '${_lastUpdateAt == null ? '' : ' · Last: ${_relativeTime(_lastUpdateAt!)}'}',
      style: const TextStyle(
        fontFamily: AppColors.monoFamily,
        color: AppColors.textFaint,
        fontSize: 10,
        letterSpacing: 1.2,
      ),
    );
  }

  String _relativeTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inSeconds < 5) return 'just now';
    if (delta.inMinutes < 1) return '${delta.inSeconds}s ago';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    return '${delta.inHours}h ago';
  }

  Color _severityColor(TriageSeverity s) {
    switch (s) {
      case TriageSeverity.normal:
        return AppColors.accent;
      case TriageSeverity.watch:
        return AppColors.textMuted;
      case TriageSeverity.warn:
        return const Color(0xFFFFB000); // amber
      case TriageSeverity.critical:
        return AppColors.danger;
    }
  }
}

class _RawLine {
  const _RawLine(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.accent : AppColors.textFaint;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppColors.monoFamily,
                fontSize: 10,
                color: color,
                letterSpacing: 1.4,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
