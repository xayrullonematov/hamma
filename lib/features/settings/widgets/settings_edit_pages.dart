import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Pushes a brutalist radio-list edit page and returns the selected
/// value, or null if the user backed out without choosing.
Future<T?> pushSettingsChoiceEdit<T>({
  required BuildContext context,
  required String title,
  required T currentValue,
  required List<SettingsChoice<T>> choices,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      settings: RouteSettings(name: 'settings_edit/$title'),
      builder: (_) => _SettingsChoiceEditPage<T>(
        title: title,
        currentValue: currentValue,
        choices: choices,
      ),
    ),
  );
}

/// Pushes a brutalist single-line text edit page and returns the
/// trimmed value, or null if the user backed out.
Future<String?> pushSettingsTextEdit({
  required BuildContext context,
  required String title,
  required String currentValue,
  String? helperText,
  String? hintText,
  bool obscure = false,
  bool monospace = false,
  TextInputType keyboardType = TextInputType.text,
  String? Function(String value)? validator,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      settings: RouteSettings(name: 'settings_edit/$title'),
      builder: (_) => _SettingsTextEditPage(
        title: title,
        currentValue: currentValue,
        helperText: helperText,
        hintText: hintText,
        obscure: obscure,
        monospace: monospace,
        keyboardType: keyboardType,
        validator: validator,
      ),
    ),
  );
}

/// Pushes a brutalist slider edit page and returns the chosen integer.
Future<int?> pushSettingsSliderEdit({
  required BuildContext context,
  required String title,
  required int currentValue,
  required int min,
  required int max,
  int? divisions,
  String Function(int value)? labelBuilder,
  String? helperText,
}) {
  return Navigator.of(context).push<int>(
    MaterialPageRoute<int>(
      settings: RouteSettings(name: 'settings_edit/$title'),
      builder: (_) => _SettingsSliderEditPage(
        title: title,
        currentValue: currentValue,
        min: min,
        max: max,
        divisions: divisions,
        labelBuilder: labelBuilder,
        helperText: helperText,
      ),
    ),
  );
}

class SettingsChoice<T> {
  const SettingsChoice({
    required this.value,
    required this.label,
    this.subtitle,
  });

  final T value;
  final String label;
  final String? subtitle;
}

class _SettingsChoiceEditPage<T> extends StatefulWidget {
  const _SettingsChoiceEditPage({
    required this.title,
    required this.currentValue,
    required this.choices,
  });

  final String title;
  final T currentValue;
  final List<SettingsChoice<T>> choices;

  @override
  State<_SettingsChoiceEditPage<T>> createState() =>
      _SettingsChoiceEditPageState<T>();
}

class _SettingsChoiceEditPageState<T>
    extends State<_SettingsChoiceEditPage<T>> {
  late T _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentValue;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: ValueKey('settings_edit_page_${widget.title}'),
      appBar: AppBar(title: Text(widget.title.toUpperCase())),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: widget.choices.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: AppColors.border),
          itemBuilder: (context, i) {
            final choice = widget.choices[i];
            final isSelected = choice.value == _selected;
            return Material(
              color: AppColors.panel,
              child: InkWell(
                key: ValueKey('settings_edit_choice_${choice.label}'),
                onTap: () {
                  setState(() => _selected = choice.value);
                  Navigator.of(context).pop<T>(choice.value);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: isSelected
                            ? AppColors.accent
                            : AppColors.textMuted,
                        size: 18,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              choice.label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (choice.subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                choice.subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.textMuted,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsTextEditPage extends StatefulWidget {
  const _SettingsTextEditPage({
    required this.title,
    required this.currentValue,
    required this.helperText,
    required this.hintText,
    required this.obscure,
    required this.monospace,
    required this.keyboardType,
    required this.validator,
  });

  final String title;
  final String currentValue;
  final String? helperText;
  final String? hintText;
  final bool obscure;
  final bool monospace;
  final TextInputType keyboardType;
  final String? Function(String value)? validator;

  @override
  State<_SettingsTextEditPage> createState() => _SettingsTextEditPageState();
}

class _SettingsTextEditPageState extends State<_SettingsTextEditPage> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    final err = widget.validator?.call(value.trim());
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop<String>(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: ValueKey('settings_edit_page_${widget.title}'),
      appBar: AppBar(
        title: Text(widget.title.toUpperCase()),
        actions: [
          TextButton(
            key: const ValueKey('settings_edit_save'),
            onPressed: _submit,
            child: const Text('SAVE'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: TextField(
            key: const ValueKey('settings_edit_text_field'),
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscure,
            keyboardType: widget.keyboardType,
            onSubmitted: (_) => _submit(),
            style: widget.monospace
                ? const TextStyle(
                    fontFamily: AppColors.monoFamily,
                    fontSize: 13,
                  )
                : null,
            decoration: InputDecoration(
              labelText: widget.title,
              hintText: widget.hintText,
              helperText: widget.helperText,
              errorText: _error,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSliderEditPage extends StatefulWidget {
  const _SettingsSliderEditPage({
    required this.title,
    required this.currentValue,
    required this.min,
    required this.max,
    required this.divisions,
    required this.labelBuilder,
    required this.helperText,
  });

  final String title;
  final int currentValue;
  final int min;
  final int max;
  final int? divisions;
  final String Function(int value)? labelBuilder;
  final String? helperText;

  @override
  State<_SettingsSliderEditPage> createState() =>
      _SettingsSliderEditPageState();
}

class _SettingsSliderEditPageState extends State<_SettingsSliderEditPage> {
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.currentValue.clamp(widget.min, widget.max);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = widget.labelBuilder?.call(_value) ?? '$_value';
    return Scaffold(
      key: ValueKey('settings_edit_page_${widget.title}'),
      appBar: AppBar(
        title: Text(widget.title.toUpperCase()),
        actions: [
          TextButton(
            key: const ValueKey('settings_edit_save'),
            onPressed: () => Navigator.of(context).pop<int>(_value),
            child: const Text('SAVE'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: AppColors.monoFamily,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Slider(
                key: const ValueKey('settings_edit_slider'),
                min: widget.min.toDouble(),
                max: widget.max.toDouble(),
                divisions: widget.divisions,
                value: _value.toDouble(),
                label: label,
                onChanged: (v) => setState(() => _value = v.round()),
              ),
              if (widget.helperText != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.helperText!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
