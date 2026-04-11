import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/models/server_profile.dart';

class ServerFormScreen extends StatefulWidget {
  const ServerFormScreen({
    super.key,
    this.initialServer,
  });

  final ServerProfile? initialServer;

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final port = int.parse(_portController.text.trim());
    final profile = ServerProfile(
      id: widget.initialServer?.id ?? _generateServerId(),
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: port,
      username: _usernameController.text.trim(),
      password: _passwordController.text.trim(),
    );

    Navigator.of(context).pop(profile);
  }

  String _generateServerId() {
    final random = Random.secure().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}-$random';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Server' : 'Add Server'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a server name.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Host / IP',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a host or IP.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final port = int.tryParse(value?.trim() ?? '');
                  if (port == null || port <= 0 || port > 65535) {
                    return 'Enter a port between 1 and 65535.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a username.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a password.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _save,
                child: Text(_isEditing ? 'Save Changes' : 'Save Server'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
