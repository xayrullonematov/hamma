import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/theme/app_colors.dart';

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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _privateKeyPasswordController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

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

    Navigator.of(context).pop(profile);
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
    showDialog(
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
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                publicKey,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
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
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Text(_isEditing ? 'Save Changes' : 'Save Server'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your saved server profile stays on this device.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ObscuredMultilineTextFormField extends StatelessWidget {
  const _ObscuredMultilineTextFormField({
    required this.controller,
    required this.decoration,
    this.validator,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle =
        theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    const contentPadding = EdgeInsets.fromLTRB(12, 16, 12, 16);

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: contentPadding,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final text = value.text;
                  final isEmpty = text.isEmpty;
                  return Text(
                    isEmpty
                        ? 'Paste or import a PEM private key.'
                        : _maskText(text),
                    style: textStyle.copyWith(
                      color:
                          isEmpty
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
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          minLines: 6,
          maxLines: 8,
          autocorrect: false,
          enableSuggestions: false,
          style: textStyle.copyWith(color: Colors.transparent, height: 1.4),
          cursorColor: theme.colorScheme.primary,
          decoration: decoration.copyWith(
            hintText: null,
            contentPadding: contentPadding,
          ),
          validator: validator,
        ),
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
        borderRadius: BorderRadius.circular(24),
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
                  borderRadius: BorderRadius.circular(14),
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
