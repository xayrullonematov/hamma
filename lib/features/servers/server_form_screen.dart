import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/vault/vault_change_bus.dart';
import '../../core/vault/vault_secret.dart';
import '../../core/vault/vault_storage.dart';

enum AuthMethod { password, sshKey }

class ServerFormScreen extends StatefulWidget {
  const ServerFormScreen({super.key, this.initialServer});

  final ServerProfile? initialServer;

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  static const _surfaceColor = AppColors.surface;
  static const _mutedColor = AppColors.textMuted;
  static const _shadowColor = Color(0x22000000);

  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _privateKeyController;
  late final TextEditingController _privateKeyPasswordController;
  late AuthMethod _authMethod;

  // ── Sticky save-bar state ────────────────────────────────────────
  // Mirrors the dirty-tracking pattern Task #44 introduced in the
  // settings screen so the brand-new form save bar feels identical
  // (appears only when there are unsaved changes, double-tap is
  // de-duped, surface failures via snackbar).
  bool _dirty = false;
  bool _isBusy = false;

  // Snapshot of the controllers' values at mount so we can decide
  // whether the form is genuinely dirty after each keystroke. If the
  // user types and then types back the original value, we hide the
  // save bar again — same UX guarantee the settings screen makes.
  late String _initialName;
  late String _initialHost;
  late String _initialPort;
  late String _initialUsername;
  late String _initialPassword;
  late String _initialPrivateKey;
  late String _initialPrivateKeyPassword;
  late AuthMethod _initialAuthMethod;

  bool get _isEditing => widget.initialServer != null;

  @override
  void initState() {
    super.initState();
    final server = widget.initialServer;
    _nameController = TextEditingController(text: server?.name ?? '');
    _hostController = TextEditingController(text: server?.host ?? '');
    _portController = TextEditingController(
      text: (server?.port ?? 22).toString(),
    );
    _usernameController = TextEditingController(text: server?.username ?? '');
    _passwordController = TextEditingController(text: server?.password ?? '');
    _privateKeyController = TextEditingController(
      text: server?.privateKey ?? '',
    );
    _privateKeyPasswordController = TextEditingController(
      text: server?.privateKeyPassword ?? '',
    );
    _authMethod =
        server?.privateKey?.trim().isNotEmpty ?? false
            ? AuthMethod.sshKey
            : AuthMethod.password;

    _initialName = _nameController.text;
    _initialHost = _hostController.text;
    _initialPort = _portController.text;
    _initialUsername = _usernameController.text;
    _initialPassword = _passwordController.text;
    _initialPrivateKey = _privateKeyController.text;
    _initialPrivateKeyPassword = _privateKeyPasswordController.text;
    _initialAuthMethod = _authMethod;

    for (final c in [
      _nameController,
      _hostController,
      _portController,
      _usernameController,
      _passwordController,
      _privateKeyController,
      _privateKeyPasswordController,
    ]) {
      c.addListener(_recomputeDirty);
    }
  }

  void _recomputeDirty() {
    final next = _nameController.text != _initialName ||
        _hostController.text != _initialHost ||
        _portController.text != _initialPort ||
        _usernameController.text != _initialUsername ||
        _passwordController.text != _initialPassword ||
        _privateKeyController.text != _initialPrivateKey ||
        _privateKeyPasswordController.text != _initialPrivateKeyPassword ||
        _authMethod != _initialAuthMethod;
    if (next != _dirty) {
      setState(() => _dirty = next);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _hostController,
      _portController,
      _usernameController,
      _passwordController,
      _privateKeyController,
      _privateKeyPasswordController,
    ]) {
      c.removeListener(_recomputeDirty);
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    // Re-entry guard — the sticky save bar's tap target is large enough
    // that a fast double-tap on touch devices reliably fires twice. We
    // never want to enqueue two saves of the same form.
    if (_isBusy) return;

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isBusy = true);
    try {
      final port = int.parse(_portController.text.trim());
      final privateKey = _privateKeyController.text;
      final privateKeyPassword = _privateKeyPasswordController.text.trim();
      final isPasswordAuth = _authMethod == AuthMethod.password;
      final profile = ServerProfile(
        id: widget.initialServer?.id ?? _generateServerId(),
        name: _nameController.text.trim(),
        host: _hostController.text.trim(),
        port: port,
        username: _usernameController.text.trim(),
        password: isPasswordAuth ? _passwordController.text.trim() : '',
        privateKey: isPasswordAuth || privateKey.isEmpty ? null : privateKey,
        privateKeyPassword:
            isPasswordAuth || privateKeyPassword.isEmpty
                ? null
                : privateKeyPassword,
      );

      if (!mounted) return;
      Navigator.of(context).pop(profile);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      _showSnackBar('Could not save server: $e');
    }
  }

  String _generateServerId() {
    final random = Random.secure().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}-$random';
  }

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(labelText: label);
  }

  Future<void> _importPrivateKey() async {
    try {
      final pickedFile = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (pickedFile == null || pickedFile.files.isEmpty) {
        return;
      }

      final file = pickedFile.files.single;
      final fileBytes =
          file.bytes ??
          (file.path == null || file.path!.trim().isEmpty
              ? null
              : await File(file.path!).readAsBytes());
      if (fileBytes == null) {
        _showSnackBar('Selected key file could not be opened.');
        return;
      }

      final privateKey = utf8.decode(fileBytes);
      _privateKeyController.value = TextEditingValue(
        text: privateKey,
        selection: TextSelection.collapsed(offset: privateKey.length),
      );
    } catch (error) {
      _showSnackBar('Could not import private key: $error');
    }
  }

  Future<void> _showKeyGenerator() async {
    final type = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Generate SSH Key Pair'),
        content: const Text(
          'Choose the type of key to generate. Ed25519 is modern and secure. RSA is widely supported.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'RSA'),
            child: const Text('RSA (4096-bit)'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'ED25519'),
            child: const Text('Ed25519'),
          ),
        ],
      ),
    );

    if (type == null) return;

    try {
      final ({String privateKey, String publicKey}) result;
      if (type == 'RSA') {
        result = SshService.generateRsa();
      } else {
        result = SshService.generateEd25519();
      }

      if (!mounted) return;

      setState(() {
        _privateKeyController.text = result.privateKey;
      });

      _showPublicKeyDialog(result.publicKey);
    } catch (e) {
      _showSnackBar('Key generation failed: $e');
    }
  }

  void _showPublicKeyDialog(String publicKey) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Key Pair Generated'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your private key has been filled in. Copy the public key below to your server\'s ~/.ssh/authorized_keys file.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: publicKey));
                _showSnackBar('Public key copied to clipboard.');
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.zero,
                ),
                child: SelectableText(
                  publicKey,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'TAP TO COPY',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.4,
                color: AppColors.textMuted,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: publicKey));
              Navigator.pop(context);
              _showSnackBar('Public key copied to clipboard.');
            },
            child: const Text('Copy & Close'),
          ),
        ],
      ),
    );
  }

  void _copyExistingPublicKey() {
    final pem = _privateKeyController.text.trim();
    if (pem.isEmpty) return;

    try {
      final publicKey = SshService.extractPublicKey(
        pem,
        _privateKeyPasswordController.text.trim().isEmpty
            ? null
            : _privateKeyPasswordController.text.trim(),
      );
      Clipboard.setData(ClipboardData(text: publicKey));
      _showSnackBar('Public key copied to clipboard.');
    } catch (e) {
      _showSnackBar('Could not extract public key. Check passphrase or format.');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Server' : 'Add Server')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 24),
                children: [
                  _FormSectionCard(
                    title: 'Server Details',
                    subtitle: 'Basic connection information for this host.',
                    icon: Icons.dns_outlined,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _nameController,
                          decoration: _fieldDecoration('Name'),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter a server name.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _hostController,
                          decoration: _fieldDecoration('Host / IP'),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter a host or IP.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          decoration: _fieldDecoration('Port'),
                          validator: (value) {
                            final port = int.tryParse(value?.trim() ?? '');
                            if (port == null || port <= 0 || port > 65535) {
                              return 'Enter a port between 1 and 65535.';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _FormSectionCard(
                    title: 'Authentication',
                    subtitle: 'Credentials used for direct SSH access.',
                    icon: Icons.lock_outline,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _usernameController,
                          decoration: _fieldDecoration('Username'),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter a username.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<AuthMethod>(
                            segments: const [
                              ButtonSegment<AuthMethod>(
                                value: AuthMethod.password,
                                label: Text('Password'),
                              ),
                              ButtonSegment<AuthMethod>(
                                value: AuthMethod.sshKey,
                                label: Text('SSH Key'),
                              ),
                            ],
                            selected: <AuthMethod>{_authMethod},
                            showSelectedIcon: false,
                            onSelectionChanged: (selection) {
                              setState(() {
                                _authMethod = selection.first;
                              });
                              _recomputeDirty();
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_authMethod == AuthMethod.password)
                          TextFormField(
                            controller: _passwordController,
                            obscureText: true,
                            decoration: _fieldDecoration('Password'),
                            validator: (value) {
                              final password = value?.trim() ?? '';
                              if (_authMethod == AuthMethod.password &&
                                  password.isEmpty) {
                                return 'Enter a password.';
                              }
                              return null;
                            },
                          ),
                        if (_authMethod == AuthMethod.sshKey) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  'Private Key (Optional)',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _showKeyGenerator,
                                icon: const Icon(Icons.key, size: 18),
                                label: const Text('Generate'),
                              ),
                              TextButton.icon(
                                onPressed: _importPrivateKey,
                                icon: const Icon(Icons.file_upload, size: 18),
                                label: const Text('Import'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _privateKeyController,
                            builder: (context, value, _) {
                              final n = value.text.length;
                              if (n == 0) return const SizedBox.shrink();
                              return Padding(
                                key: const ValueKey(
                                    'private_key_chars_indicator'),
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  '$n character${n == 1 ? '' : 's'} pasted',
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                    letterSpacing: 1.2,
                                    fontFamily: AppColors.monoFamily,
                                    fontFamilyFallback: AppColors.monoFallback,
                                  ),
                                ),
                              );
                            },
                          ),
                          _ObscuredMultilineTextFormField(
                            controller: _privateKeyController,
                            decoration: InputDecoration(
                              hintText: 'Paste or import a PEM private key.',
                              alignLabelWithHint: true,
                              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                                valueListenable: _privateKeyController,
                                builder: (context, value, _) {
                                  if (value.text.isEmpty) return const SizedBox();
                                  return IconButton(
                                    icon: const Icon(Icons.copy_all),
                                    tooltip: 'Copy Public Key',
                                    onPressed: _copyExistingPublicKey,
                                  );
                                },
                              ),
                              contentPadding: const EdgeInsets.fromLTRB(
                                12,
                                16,
                                12,
                                16,
                              ),
                            ),
                            validator: (value) {
                              final privateKey = value?.trim() ?? '';
                              if (_authMethod == AuthMethod.sshKey &&
                                  privateKey.isEmpty) {
                                return 'Add a private key.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _privateKeyPasswordController,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: _fieldDecoration(
                              'Private Key Passphrase (Optional)',
                            ).copyWith(hintText: 'Leave empty if none'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_isEditing) ...[
                    const SizedBox(height: 16),
                    _LinkedSecretsSection(
                      serverId: widget.initialServer!.id,
                      serverName: widget.initialServer!.name,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Your saved server profile stays on this device.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
                  ),
                  // Reserve room so the sticky save bar never covers
                  // the last form field on short viewports.
                  const SizedBox(height: 96),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _dirty
          ? _ServerFormStickySaveBar(
              key: const ValueKey('server_form_sticky_save_bar'),
              isEditing: _isEditing,
              isBusy: _isBusy,
              onSave: _save,
            )
          : null,
    );
  }
}

/// Sticky save bar shown only when [_dirty] is true. Mirrors the
/// settings screen's bar so the two surfaces feel like one product.
class _ServerFormStickySaveBar extends StatelessWidget {
  const _ServerFormStickySaveBar({
    super.key,
    required this.isEditing,
    required this.isBusy,
    required this.onSave,
  });

  final bool isEditing;
  final bool isBusy;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.panel,
          border: Border(
            top: BorderSide(color: AppColors.borderStrong, width: 1),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Unsaved changes',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                ),
              ),
            ),
            FilledButton(
              onPressed: isBusy ? null : onSave,
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              child: isBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.onPrimary,
                      ),
                    )
                  : Text(isEditing ? 'SAVE CHANGES' : 'SAVE'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObscuredMultilineTextFormField extends StatefulWidget {
  const _ObscuredMultilineTextFormField({
    required this.controller,
    required this.decoration,
    this.validator,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final FormFieldValidator<String>? validator;

  @override
  State<_ObscuredMultilineTextFormField> createState() =>
      _ObscuredMultilineTextFormFieldState();
}

class _ObscuredMultilineTextFormFieldState
    extends State<_ObscuredMultilineTextFormField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle =
        theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    const contentPadding = EdgeInsets.fromLTRB(12, 16, 44, 16);

    final field = TextFormField(
      controller: widget.controller,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      minLines: 6,
      maxLines: 8,
      autocorrect: false,
      enableSuggestions: false,
      style: textStyle.copyWith(
        color: _revealed ? textStyle.color : Colors.transparent,
        height: 1.4,
        fontFamily: AppColors.monoFamily,
        fontFamilyFallback: AppColors.monoFallback,
      ),
      cursorColor: theme.colorScheme.primary,
      decoration: widget.decoration.copyWith(
        hintText: null,
        contentPadding: contentPadding,
      ),
      validator: widget.validator,
    );

    final toggle = Positioned(
      top: 6,
      right: 4,
      child: IconButton(
        key: const ValueKey('private_key_visibility_toggle'),
        tooltip: _revealed ? 'Hide private key' : 'Show private key',
        icon: Icon(
          _revealed
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
          size: 18,
          color: AppColors.textMuted,
        ),
        onPressed: () => setState(() => _revealed = !_revealed),
      ),
    );

    if (_revealed) {
      return Stack(children: [field, toggle]);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: contentPadding,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (context, value, _) {
                  final text = value.text;
                  final isEmpty = text.isEmpty;
                  return Text(
                    isEmpty
                        ? 'Paste or import a PEM private key.'
                        : _maskText(text),
                    style: textStyle.copyWith(
                      color: isEmpty
                          ? theme.inputDecorationTheme.hintStyle?.color ??
                              theme.hintColor
                          : textStyle.color,
                      height: 1.4,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        field,
        toggle,
      ],
    );
  }

  static String _maskText(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (character == '\n' || character == '\r') {
        buffer.write(character);
      } else {
        buffer.write('•');
      }
    }
    return buffer.toString();
  }
}

/// Lists every vault secret this server can see and lets the user
/// move a secret between **global** scope (visible to all servers)
/// and **scoped to this server only**. The secret value is never
/// shown here — that lives behind the PIN-gated reveal in the main
/// Vault settings screen. This card only edits the (scope, name)
/// binding, which the inject layer uses to resolve `${vault:NAME}`.
class _LinkedSecretsSection extends StatefulWidget {
  const _LinkedSecretsSection({
    required this.serverId,
    required this.serverName,
  });

  final String serverId;
  final String serverName;

  @override
  State<_LinkedSecretsSection> createState() => _LinkedSecretsSectionState();
}

class _LinkedSecretsSectionState extends State<_LinkedSecretsSection> {
  late final VaultStorage _storage;
  StreamSubscription<void>? _sub;
  List<VaultSecret> _visible = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _storage = VaultStorage();
    _sub = VaultChangeBus.instance.changes.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final loaded = await _storage.loadVisibleTo(widget.serverId);
      if (!mounted) return;
      setState(() {
        _visible = loaded;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load vault: $e';
      });
    }
  }

  Future<void> _setScope(VaultSecret secret, String? newScope) async {
    try {
      await _storage.upsert(secret.copyWith(scope: newScope));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update scope: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _FormSectionCard(
      title: 'Linked Secrets',
      subtitle:
          'Bind vault secrets to this server. Reference them in commands as '
          '\${vault:NAME}. Values stay hidden — manage them in Settings → Vault.',
      icon: Icons.shield_outlined,
      child: Builder(
        builder: (context) {
          if (_loading) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            );
          }
          if (_error != null) {
            return Text(
              _error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            );
          }
          if (_visible.isEmpty) {
            return Text(
              'No secrets yet. Open Settings → Vault to add one, then come '
              'back here to bind it to this server.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: _ServerFormScreenState._mutedColor),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final secret in _visible)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '\${vault:${secret.name}}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              secret.isGlobal
                                  ? 'Global — visible to every server'
                                  : 'Scoped to ${widget.serverName}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _ServerFormScreenState._mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (secret.isGlobal)
                        OutlinedButton(
                          onPressed: () =>
                              _setScope(secret, widget.serverId),
                          child: const Text('Restrict here'),
                        )
                      else
                        OutlinedButton(
                          onPressed: () => _setScope(secret, null),
                          child: const Text('Make global'),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FormSectionCard extends StatelessWidget {
  const _FormSectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _ServerFormScreenState._surfaceColor,
        borderRadius: BorderRadius.zero,
        boxShadow: const [
          BoxShadow(
            color: _ServerFormScreenState._shadowColor,
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
                  borderRadius: BorderRadius.zero,
                ),
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _ServerFormScreenState._mutedColor,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}
