import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import 'error_scrubber.dart';

/// Standalone full-screen "fatal error" UI shown when the app fails to
/// initialize (or any other unrecoverable error makes the main app
/// unusable).
///
/// Designed to be self-contained so it works even when the main app's
/// theme, providers, or state are the failure cause:
///  - Builds its own minimal `MaterialApp` + theme inline.
///  - Doesn't read from any provider, secure-storage, or service.
///  - Uses only `package:flutter/material.dart` and `package:flutter/services.dart`.
///
/// User actions:
///  - **COPY DETAILS** — copies the scrubbed message + stack trace to
///    the clipboard so the user can paste into a bug report or email.
///  - **TRY RESTART** — re-runs the supplied [onRestart] callback (the
///    caller wires this to whatever rebuilds the main app).
///  - **QUIT** (desktop only) — calls `exit(0)`. Hidden on iOS/Android
///    where Apple/Google guidelines forbid programmatic exit.
class CrashApp extends StatelessWidget {
  const CrashApp({
    super.key,
    required this.error,
    this.stackTrace,
    this.onRestart,
    this.hint,
  });

  final Object error;
  final StackTrace? stackTrace;
  final String? hint;

  /// If non-null, the **TRY RESTART** button is shown and invokes this
  /// callback. If null, the button is hidden.
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hamma — Fatal Error',
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.scaffoldBackground,
        brightness: Brightness.dark,
        fontFamily: AppColors.sansFamily,
        fontFamilyFallback: AppColors.sansFallback,
      ),
      home: _CrashScreen(
        error: error,
        stackTrace: stackTrace,
        onRestart: onRestart,
        hint: hint,
      ),
    );
  }
}

class _CrashScreen extends StatefulWidget {
  const _CrashScreen({
    required this.error,
    required this.stackTrace,
    required this.onRestart,
    required this.hint,
  });

  final Object error;
  final StackTrace? stackTrace;
  final VoidCallback? onRestart;
  final String? hint;

  @override
  State<_CrashScreen> createState() => _CrashScreenState();
}

class _CrashScreenState extends State<_CrashScreen> {
  // Always expanded in debug; collapsed by default in release so the
  // user sees the friendly summary first.
  late bool _detailsExpanded = kDebugMode;
  bool _justCopied = false;

  late final String _scrubbedMessage =
      ErrorScrubber.scrub(widget.error.toString());

  String get _detailsForClipboard {
    final buf = StringBuffer()
      ..writeln('Hamma fatal error report')
      ..writeln('Captured at: ${DateTime.now().toIso8601String()}')
      ..writeln('Platform: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Build mode: ${kReleaseMode ? "release" : "debug"}');
    if (widget.hint != null) buf.writeln('Hint: ${widget.hint}');
    buf
      ..writeln()
      ..writeln('Error:')
      ..writeln(_scrubbedMessage);
    if (widget.stackTrace != null) {
      buf
        ..writeln()
        ..writeln('Stack trace:')
        ..writeln(ErrorScrubber.scrub(widget.stackTrace.toString()));
    }
    return buf.toString();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _detailsForClipboard));
    if (!mounted) return;
    setState(() => _justCopied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _justCopied = false);
    });
  }

  bool get _canQuit => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(),
                  const SizedBox(height: 16),
                  _summaryPanel(),
                  const SizedBox(height: 16),
                  _detailsToggle(),
                  if (_detailsExpanded) ...[
                    const SizedBox(height: 8),
                    _detailsPanel(),
                  ],
                  const SizedBox(height: 24),
                  _actions(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          color: AppColors.danger,
          child: const Text(
            'FATAL ERROR',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppColors.monoFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'HAMMA',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppColors.monoFamily,
              fontWeight: FontWeight.w700,
              fontSize: 18,
              letterSpacing: 4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Hamma stopped working unexpectedly.',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.hint ?? 'An unrecoverable error occurred during startup '
                'or while running. No data has been lost; your servers '
                'and settings are safe in encrypted storage.',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsToggle() {
    return InkWell(
      onTap: () => setState(() => _detailsExpanded = !_detailsExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              _detailsExpanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              _detailsExpanded ? 'HIDE DETAILS' : 'SHOW DETAILS',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontFamily: AppColors.monoFamily,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailsPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
      ),
      constraints: const BoxConstraints(maxHeight: 280),
      child: SingleChildScrollView(
        child: SelectableText(
          _detailsForClipboard,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontFamily: AppColors.monoFamily,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _actions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _BrutalistButton(
          label: _justCopied ? 'COPIED ✓' : 'COPY DETAILS',
          onPressed: _copy,
          filled: false,
        ),
        if (widget.onRestart != null)
          _BrutalistButton(
            label: 'TRY RESTART',
            onPressed: widget.onRestart!,
            filled: true,
          ),
        if (_canQuit)
          _BrutalistButton(
            label: 'QUIT',
            onPressed: () => exit(0),
            filled: false,
            danger: true,
          ),
      ],
    );
  }
}

class _BrutalistButton extends StatelessWidget {
  const _BrutalistButton({
    required this.label,
    required this.onPressed,
    required this.filled,
    this.danger = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final fg = filled
        ? AppColors.onPrimary
        : (danger ? AppColors.danger : AppColors.textPrimary);
    final bg = filled ? AppColors.primary : AppColors.scaffoldBackground;
    final borderColor = danger ? AppColors.danger : AppColors.border;

    return Material(
      color: bg,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontFamily: AppColors.monoFamily,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
