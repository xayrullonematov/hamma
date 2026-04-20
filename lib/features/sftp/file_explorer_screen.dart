import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/sftp_service.dart';
import 'file_editor_screen.dart';

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({super.key, required this.server});

  final ServerProfile server;

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _primaryColor = Color(0xFF3B82F6);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _fileColor = Color(0xFF64748B);
  static const _shadowColor = Color(0x22000000);
  static const _overlayColor = Color(0xB3000000);

  final SftpService _sftpService = SftpService();

  bool _isConnecting = true;
  bool _isLoading = false;
  bool _isDownloadingFile = false;
  bool _isUploadingFile = false;
  bool _isShowingMessage = false;
  String _currentPath = '.';
  String _displayPath = '.';
  String? _loadError;
  List<SftpName> _entries = const [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    unawaited(_sftpService.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _sftpService.connect(
        host: widget.server.host,
        port: widget.server.port,
        username: widget.server.username,
        password: widget.server.password,
        privateKey: widget.server.privateKey,
        privateKeyPassword: widget.server.privateKeyPassword,
        onTrustHostKey: _confirmHostKeyTrust,
      );
      await _loadDirectory('.');
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _loadDirectory(String path) async {
    if (!_sftpService.isConnected) {
      return;
    }

    setState(() {
      _isLoading = true;
      if (_entries.isEmpty) {
        _loadError = null;
      }
    });

    try {
      final names = await _sftpService.listDirectory(path);
      final displayPath = await _resolveDisplayPath(path);
      final sortedNames =
          names
              .where((entry) => entry.filename != '.' && entry.filename != '..')
              .toList()
            ..sort(_compareEntries);

      if (!mounted) {
        return;
      }

      setState(() {
        _entries = sortedNames;
        _currentPath = path;
        _displayPath = displayPath;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      if (_entries.isEmpty) {
        setState(() {
          _loadError = error.toString();
        });
      } else {
        _showMessage(error.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<String> _resolveDisplayPath(String path) async {
    try {
      return await _sftpService.client.absolute(path);
    } catch (_) {
      return path;
    }
  }

  Future<void> _openEntry(SftpName entry) async {
    final entryPath = _buildChildPath(_currentPath, entry.filename);
    if (_isDirectory(entry)) {
      await _loadDirectory(entryPath);
      return;
    }

    setState(() {
      _isDownloadingFile = true;
    });

    try {
      final content = await _sftpService.readFile(entryPath);
      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder:
              (_) => FileEditorScreen(
                sftpService: _sftpService,
                filePath: entryPath,
                initialContent: content,
              ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      _showMessage(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingFile = false;
        });
      }
    }
  }

  Future<void> _handleDownload(SftpName entry) async {
    final remotePath = _buildChildPath(_currentPath, entry.filename);

    setState(() {
      _isDownloadingFile = true;
    });

    try {
      final dir =
          Platform.isAndroid
              ? (await getExternalStorageDirectory())?.path ??
                  (await getApplicationDocumentsDirectory()).path
              : (await getDownloadsDirectory())?.path ??
                  (await getApplicationDocumentsDirectory()).path;

      final localPath = p.join(dir, entry.filename);
      await _sftpService.downloadFile(remotePath, localPath);
      _showMessage('Downloaded to $localPath');
    } catch (error) {
      _showMessage('Download failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingFile = false;
        });
      }
    }
  }

  Future<void> _handleUpload() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.single.path == null) {
        return;
      }

      final localPath = result.files.single.path!;
      final filename = result.files.single.name;
      final remotePath = _buildChildPath(_currentPath, filename);

      setState(() {
        _isUploadingFile = true;
      });

      await _sftpService.uploadFile(localPath, remotePath);
      _showMessage('Uploaded $filename');
      await _loadDirectory(_currentPath);
    } catch (error) {
      _showMessage('Upload failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingFile = false;
        });
      }
    }
  }

  Future<bool> _confirmHostKeyTrust({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Trust SSH Host Key'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('First connection to $host:$port'),
                  const SizedBox(height: 12),
                  Text('Algorithm: $algorithm'),
                  const SizedBox(height: 8),
                  SelectableText('Fingerprint: $fingerprint'),
                  const SizedBox(height: 12),
                  const Text(
                    'Only trust this key if you have verified it with your server provider or the server itself.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Trust'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  void _showMessage(String message) {
    if (!mounted || message.trim().isEmpty || _isShowingMessage) {
      return;
    }

    _isShowingMessage = true;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message))).closed.then((_) {
      _isShowingMessage = false;
    });
  }

  bool _isDirectory(SftpName entry) {
    return entry.attr.isDirectory || entry.longname.startsWith('d');
  }

  int _compareEntries(SftpName a, SftpName b) {
    final aIsDirectory = _isDirectory(a);
    final bIsDirectory = _isDirectory(b);
    if (aIsDirectory != bIsDirectory) {
      return aIsDirectory ? -1 : 1;
    }

    return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
  }

  String _buildChildPath(String base, String child) {
    if (base == '/') {
      return '/$child';
    }
    if (base.isEmpty || base == '.') {
      return './$child';
    }
    if (base.endsWith('/')) {
      return '$base$child';
    }
    return '$base/$child';
  }

  String _parentDirectory(String path) {
    if (path.isEmpty || path == '.') {
      return '..';
    }
    if (path == '/') {
      return '/';
    }
    if (path == '..' || path.endsWith('/..')) {
      return '$path/..';
    }

    final normalized =
        path.length > 1 && path.endsWith('/')
            ? path.substring(0, path.length - 1)
            : path;
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash == -1) {
      return '.';
    }
    if (lastSlash == 0) {
      return '/';
    }
    return normalized.substring(0, lastSlash);
  }

  String _entrySubtitle(SftpName entry) {
    if (_isDirectory(entry)) {
      return 'Directory';
    }

    final size = entry.attr.size;
    if (size == null) {
      return 'File';
    }

    return 'File • ${_formatBytes(size)}';
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;

    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }

    final display =
        unitIndex == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$display ${units[unitIndex]}';
  }

  Widget _buildDirectoryList(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: _shadowColor, blurRadius: 18, offset: Offset(0, 10)),
        ],
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: _entries.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListTile(
              leading: const Icon(
                Icons.arrow_upward_rounded,
                color: _mutedColor,
              ),
              title: Text(
                '..',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                'Go up',
                style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
              ),
              onTap:
                  _isLoading
                      ? null
                      : () => _loadDirectory(_parentDirectory(_currentPath)),
            );
          }

          final entry = _entries[index - 1];
          final isDirectory = _isDirectory(entry);

          return ListTile(
            leading: Icon(
              isDirectory ? Icons.folder : Icons.description,
              color: isDirectory ? _primaryColor : _fileColor,
            ),
            title: Text(
              entry.filename,
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              _entrySubtitle(entry),
              style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor),
            ),
            trailing:
                isDirectory
                    ? const Icon(Icons.chevron_right_rounded, color: _mutedColor)
                    : PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, color: _mutedColor),
                      color: _panelColor,
                      onSelected: (value) {
                        if (value == 'edit') {
                          _openEntry(entry);
                        } else if (value == 'download') {
                          _handleDownload(entry);
                        }
                      },
                      itemBuilder:
                          (context) => [
                            const PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  Icon(Icons.edit, color: Colors.white),
                                  SizedBox(width: 12),
                                  Text(
                                    'Edit',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'download',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.download_rounded,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 12),
                                  Text(
                                    'Download',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ],
                    ),
            onTap:
                _isLoading || _isDownloadingFile || _isUploadingFile
                    ? null
                    : () => _openEntry(entry),
          );
        },
        separatorBuilder: (context, _) {
          return Divider(
            color: Colors.white.withValues(alpha: 0.06),
            height: 1,
            indent: 20,
            endIndent: 20,
          );
        },
      ),
    );
  }

  Widget _buildLoadingOverlay(String label) {
    return Positioned.fill(
      child: ColoredBox(
        color: _overlayColor,
        child: Center(
          child: Container(
            width: 180,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            decoration: BoxDecoration(
              color: _panelColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnecting) {
      return const Scaffold(
        backgroundColor: _backgroundColor,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null && _entries.isEmpty) {
      return Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(title: const Text('File Explorer')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _surfaceColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.folder_off_outlined,
                    size: 40,
                    color: _mutedColor,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Could not open file explorer',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _loadError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _mutedColor, height: 1.5),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _isConnecting = true;
                        _loadError = null;
                      });
                      _initialize();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: const Text('File Explorer'),
        actions: [
          IconButton(
            onPressed:
                _isLoading || _isDownloadingFile || _isUploadingFile
                    ? null
                    : () => _loadDirectory(_currentPath),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: _surfaceColor,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(
                        color: _shadowColor,
                        blurRadius: 18,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.server.name,
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _displayPath,
                        style: const TextStyle(
                          color: _mutedColor,
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(child: _buildDirectoryList(context)),
              ],
            ),
          ),
          if (_isLoading) _buildLoadingOverlay('Loading directory...'),
          if (_isDownloadingFile) _buildLoadingOverlay('Downloading file...'),
          if (_isUploadingFile) _buildLoadingOverlay('Uploading file...'),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed:
            _isLoading || _isDownloadingFile || _isUploadingFile
                ? null
                : _handleUpload,
        backgroundColor: _primaryColor,
        child: const Icon(Icons.upload_file_rounded, color: Colors.white),
      ),
    );
  }
}
