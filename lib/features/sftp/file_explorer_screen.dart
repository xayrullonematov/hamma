import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/server_profile.dart';
import '../../core/ssh/sftp_service.dart';
import '../../core/storage/app_prefs_storage.dart';
import 'file_editor_screen.dart';
import '../../core/theme/app_colors.dart';

enum FileSortMode { name, size, date }

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({super.key, required this.server});

  final ServerProfile server;

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _panelColor = AppColors.panel;
  static const _primaryColor = AppColors.textPrimary;
  static const _mutedColor = AppColors.textMuted;
  static const _fileColor = AppColors.textMuted;
  static const _shadowColor = Color(0x22000000);
  static const _overlayColor = Color(0xB3000000);

  final SftpService _sftpService = SftpService();
  final AppPrefsStorage _prefs = const AppPrefsStorage();
  late final TextEditingController _pathController;
  late final TextEditingController _searchController;

  bool _isConnecting = true;
  bool _isLoading = false;
  bool _isDownloadingFile = false;
  bool _isUploadingFile = false;
  bool _isShowingMessage = false;
  bool _showHiddenFiles = false;
  bool _isSearching = false;
  String _searchQuery = '';
  FileSortMode _sortMode = FileSortMode.name;
  String _currentPath = '.';
  String _displayPath = '.';
  String? _loadError;
  List<SftpName> _entries = const [];

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController();
    _searchController = TextEditingController();
    _initialize();
  }

  @override
  void dispose() {
    _pathController.dispose();
    _searchController.dispose();
    unawaited(_sftpService.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final results = await Future.wait([
        _prefs.shouldShowHiddenFiles(),
        _prefs.getFileSortMode(),
      ]);

      _showHiddenFiles = results[0] as bool;
      final savedSortMode = results[1] as String;
      _sortMode = FileSortMode.values.firstWhere(
        (m) => m.name == savedSortMode,
        orElse: () => FileSortMode.name,
      );

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
      // Reset search when navigating to a new directory
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });

    try {
      final names = await _sftpService.listDirectory(path);
      final displayPath = await _resolveDisplayPath(path);
      final filteredNames = names.where((entry) {
        final name = entry.filename;
        if (name == '.' || name == '..') return false;
        if (!_showHiddenFiles && name.startsWith('.')) return false;
        return true;
      }).toList();

      final sortedNames = filteredNames..sort(_compareEntries);

      if (!mounted) {
        return;
      }

      setState(() {
        _entries = sortedNames;
        _currentPath = path;
        _displayPath = displayPath;
        _pathController.text = displayPath;
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

  Future<void> _handlePathNavigation(String path) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final attr = await _sftpService.client.stat(trimmedPath);

      if (attr.mode?.type == SftpFileType.directory) {
        await _loadDirectory(trimmedPath);
      } else {
        final content = await _sftpService.readFile(trimmedPath);
        if (!mounted) return;

        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder:
                (_) => FileEditorScreen(
                  sftpService: _sftpService,
                  filePath: trimmedPath,
                  initialContent: content,
                ),
          ),
        );
        _pathController.text = _displayPath;
      }
    } catch (error) {
      _showMessage('Navigation failed: $error');
      _pathController.text = _displayPath;
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _toggleHiddenFiles() async {
    setState(() {
      _showHiddenFiles = !_showHiddenFiles;
    });
    await _prefs.setShowHiddenFiles(_showHiddenFiles);
    await _loadDirectory(_currentPath);
  }

  Future<void> _setSortMode(FileSortMode mode) async {
    setState(() {
      _sortMode = mode;
      _entries = List.from(_entries)..sort(_compareEntries);
    });
    await _prefs.setFileSortMode(mode.name);
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
    });
  }

  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
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

  Future<void> _handleDelete(SftpName entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Are you sure you want to delete ${entry.filename}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final path = _buildChildPath(_currentPath, entry.filename);
      if (_isDirectory(entry)) {
        await _sftpService.removeDirectory(path);
      } else {
        await _sftpService.removeFile(path);
      }
      _showMessage('Deleted ${entry.filename}');
      await _loadDirectory(_currentPath);
    } catch (error) {
      _showMessage('Delete failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleNewFolder() async {
    final name = await _showInputDialog(title: 'New Folder', hint: 'Folder name');
    if (name == null || name.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final path = _buildChildPath(_currentPath, name);
      await _sftpService.createDirectory(path);
      _showMessage('Created folder $name');
      await _loadDirectory(_currentPath);
    } catch (error) {
      _showMessage('Failed to create folder: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleNewFile() async {
    final name = await _showInputDialog(title: 'New File', hint: 'File name');
    if (name == null || name.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final path = _buildChildPath(_currentPath, name);
      await _sftpService.writeFile(path, '');
      _showMessage('Created file $name');
      await _loadDirectory(_currentPath);
    } catch (error) {
      _showMessage('Failed to create file: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _showInputDialog({required String title, required String hint}) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
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

    switch (_sortMode) {
      case FileSortMode.name:
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      case FileSortMode.size:
        final aSize = a.attr.size ?? 0;
        final bSize = b.attr.size ?? 0;
        return bSize.compareTo(aSize);
      case FileSortMode.date:
        final aTime = a.attr.modifyTime ?? 0;
        final bTime = b.attr.modifyTime ?? 0;
        return bTime.compareTo(aTime);
    }
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

    final filteredEntries =
        _searchQuery.isEmpty
            ? _entries
            : _entries
                .where(
                  (e) => e.filename.toLowerCase().contains(
                    _searchQuery.toLowerCase(),
                  ),
                )
                .toList();

    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.zero,
        boxShadow: const [
          BoxShadow(color: _shadowColor, blurRadius: 18, offset: Offset(0, 10)),
        ],
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: filteredEntries.length + 1,
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

          final entry = filteredEntries[index - 1];
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
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: _mutedColor),
              color: _panelColor,
              onSelected: (value) {
                if (value == 'edit') {
                  _openEntry(entry);
                } else if (value == 'download') {
                  _handleDownload(entry);
                } else if (value == 'delete') {
                  _handleDelete(entry);
                }
              },
              itemBuilder:
                  (context) => [
                    if (!isDirectory)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit, color: Colors.white),
                            SizedBox(width: 12),
                            Text('Edit', style: TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                    if (!isDirectory)
                      const PopupMenuItem(
                        value: 'download',
                        child: Row(
                          children: [
                            Icon(Icons.download_rounded, color: Colors.white),
                            SizedBox(width: 12),
                            Text(
                              'Download',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                          SizedBox(width: 12),
                          Text('Delete', style: TextStyle(color: AppColors.danger)),
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
              borderRadius: BorderRadius.zero,
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
        appBar: AppBar(automaticallyImplyLeading: false, title: const Text('File Explorer')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _surfaceColor,
                borderRadius: BorderRadius.zero,
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
        automaticallyImplyLeading: false,
        title:
            _isSearching
                ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search current folder...',
                    hintStyle: const TextStyle(color: _mutedColor),
                    border: InputBorder.none,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close_rounded, color: _mutedColor),
                      onPressed: () {
                        if (_searchController.text.isEmpty) {
                          _stopSearch();
                        } else {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        }
                      },
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                )
                : const Text('File Explorer'),
        actions: [
          if (!_isSearching) ...[
            IconButton(
              onPressed: _startSearch,
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search',
            ),
            IconButton(
              onPressed:
                  _isLoading || _isDownloadingFile || _isUploadingFile
                      ? null
                      : () => _loadDirectory(_currentPath),
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh',
            ),
          ],
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'hidden') {
                _toggleHiddenFiles();
              } else if (value == 'sort_name') {
                _setSortMode(FileSortMode.name);
              } else if (value == 'sort_size') {
                _setSortMode(FileSortMode.size);
              } else if (value == 'sort_date') {
                _setSortMode(FileSortMode.date);
              }
            },
            itemBuilder:
                (context) => [
                  CheckedPopupMenuItem(
                    value: 'hidden',
                    checked: _showHiddenFiles,
                    child: const Text('Show Hidden Files'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    enabled: false,
                    child: Text(
                      'Sort by',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _mutedColor,
                      ),
                    ),
                  ),
                  CheckedPopupMenuItem(
                    value: 'sort_name',
                    checked: _sortMode == FileSortMode.name,
                    child: const Text('Name'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'sort_size',
                    checked: _sortMode == FileSortMode.size,
                    child: const Text('Size'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'sort_date',
                    checked: _sortMode == FileSortMode.date,
                    child: const Text('Date'),
                  ),
                ],
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
                    borderRadius: BorderRadius.zero,
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
                      TextField(
                        controller: _pathController,
                        onSubmitted: _handlePathNavigation,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 24,
                            minHeight: 24,
                          ),
                          suffixIcon: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.arrow_forward_rounded,
                              size: 18,
                              color: _mutedColor,
                            ),
                            onPressed:
                                () => _handlePathNavigation(_pathController.text),
                          ),
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
          if (_isLoading) _buildLoadingOverlay('Processing...'),
          if (_isDownloadingFile) _buildLoadingOverlay('Downloading file...'),
          if (_isUploadingFile) _buildLoadingOverlay('Uploading file...'),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: null, // We use child as a popup anchor
        backgroundColor: AppColors.textPrimary,
        foregroundColor: AppColors.scaffoldBackground,
        child: PopupMenuButton<String>(
          icon: Icon(Icons.add, color: AppColors.scaffoldBackground, size: 28),
          offset: const Offset(0, -140),
          onSelected: (value) {
            if (value == 'folder') {
              _handleNewFolder();
            } else if (value == 'file') {
              _handleNewFile();
            } else if (value == 'upload') {
              _handleUpload();
            }
          },
          itemBuilder:
              (context) => [
                const PopupMenuItem(
                  value: 'folder',
                  child: Row(
                    children: [
                      Icon(Icons.create_new_folder_outlined),
                      SizedBox(width: 12),
                      Text('New Folder'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'file',
                  child: Row(
                    children: [
                      Icon(Icons.note_add_outlined),
                      SizedBox(width: 12),
                      Text('New File'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'upload',
                  child: Row(
                    children: [
                      Icon(Icons.upload_file_rounded),
                      SizedBox(width: 12),
                      Text('Upload File'),
                    ],
                  ),
                ),
              ],
        ),
      ),
    );
  }
}
