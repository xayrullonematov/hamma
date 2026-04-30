import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/theme/app_colors.dart';

class PackageManagerScreen extends StatefulWidget {
  const PackageManagerScreen({
    super.key,
    required this.sshService,
    required this.serverName,
  });

  final SshService sshService;
  final String serverName;

  @override
  State<PackageManagerScreen> createState() => _PackageManagerScreenState();
}

class _PackageManagerScreenState extends State<PackageManagerScreen> {
  static const _backgroundColor = AppColors.scaffoldBackground;
  static const _surfaceColor = AppColors.surface;
  static const _mutedColor = AppColors.textMuted;
  static const _primaryColor = AppColors.textPrimary;
  static const _dangerColor = AppColors.danger;

  List<UpgradablePackage> _upgradablePackages = [];
  List<SearchResultPackage> _searchResults = [];
  bool _isLoading = true;
  String _packageManager = 'apt'; // Default to apt
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _detectPackageManager();
    await _fetchUpgradable();
  }

  Future<void> _detectPackageManager() async {
    try {
      final output = await widget.sshService.execute('command -v apt || command -v dnf || command -v yum');
      if (output.contains('apt')) {
        _packageManager = 'apt';
      } else if (output.contains('dnf')) {
        _packageManager = 'dnf';
      } else if (output.contains('yum')) {
        _packageManager = 'yum';
      }
    } catch (_) {}
  }

  Future<void> _fetchUpgradable() async {
    setState(() => _isLoading = true);
    try {
      String command = '';
      if (_packageManager == 'apt') {
        command = 'apt list --upgradable 2>/dev/null';
      } else {
        command = 'sudo -S $_packageManager check-update --quiet';
      }

      final output = await widget.sshService.execute(command);
      final packages = _parseUpgradable(output);
      if (mounted) {
        setState(() {
          _upgradablePackages = packages;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError('Failed to fetch updates: $e');
      }
    }
  }

  List<UpgradablePackage> _parseUpgradable(String output) {
    final lines = output.trim().split('\n');
    final packages = <UpgradablePackage>[];

    if (_packageManager == 'apt') {
      for (var line in lines) {
        if (line.contains('/') && line.contains('[')) {
          // Example: google-chrome-stable/stable 124.0.6367.60-1 amd64 [upgradable from: 123.0.6312.122-1]
          final parts = line.split(' ');
          final name = parts[0].split('/')[0];
          final newVersion = parts[1];
          final currentVersionMatch = RegExp(r'upgradable from: (.*)\]').firstMatch(line);
          final currentVersion = currentVersionMatch?.group(1) ?? 'Unknown';
          packages.add(UpgradablePackage(name: name, currentVersion: currentVersion, newVersion: newVersion));
        }
      }
    } else {
      for (var line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 3 && !line.startsWith('Loaded') && !line.startsWith('Last')) {
          packages.add(UpgradablePackage(name: parts[0], currentVersion: 'Unknown', newVersion: parts[1]));
        }
      }
    }
    return packages;
  }

  Future<void> _updateLists() async {
    _showStreamConsole('Updating package lists...', 'sudo -S $_packageManager update -y');
  }

  Future<void> _upgradeAll() async {
    final cmd = 'sudo -S $_packageManager upgrade -y';
    _showStreamConsole('Upgrading all packages...', cmd, onDone: _fetchUpgradable);
  }

  Future<void> _searchPackages(String query) async {
    if (query.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final command = _packageManager == 'apt' ? 'apt search $query' : '$_packageManager search $query';
      final output = await widget.sshService.execute(command);
      _parseSearchResults(output);
      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Search failed: $e');
    }
  }

  void _parseSearchResults(String output) {
    final lines = output.trim().split('\n');
    final results = <SearchResultPackage>[];
    for (var i = 0; i < lines.length; i++) {
       if (_packageManager == 'apt' && lines[i].contains('/') && i + 1 < lines.length) {
         results.add(SearchResultPackage(name: lines[i].split('/')[0], description: lines[i+1].trim()));
         i++;
       }
    }
    setState(() => _searchResults = results);
  }

  void _showStreamConsole(String title, String command, {VoidCallback? onDone}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => _StreamConsole(
        sshService: widget.sshService,
        title: title,
        command: command,
        onDone: onDone,
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: _dangerColor));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: const Text('Package Manager'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchUpgradable),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Column(
            children: [
              _buildHeader(),
              _buildSearchBar(),
              Expanded(
                child: _isLoading 
                  ? const Center(child: CircularProgressIndicator())
                  : _searchResults.isNotEmpty 
                    ? _buildSearchResults()
                    : _buildUpgradableList(),
              ),
              _buildActionButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      color: _surfaceColor,
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_upgradablePackages.length} Updates Available',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text('Using $_packageManager', style: const TextStyle(color: _mutedColor, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search packages to install...',
          hintStyle: const TextStyle(color: _mutedColor),
          prefixIcon: const Icon(Icons.search, color: _mutedColor),
          filled: true,
          fillColor: _surfaceColor,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _searchController.clear();
              setState(() => _searchResults = []);
            },
          ),
        ),
        onSubmitted: _searchPackages,
      ),
    );
  }

  Widget _buildUpgradableList() {
    if (_upgradablePackages.isEmpty) {
      return Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 48, color: AppColors.textPrimary),
          const SizedBox(height: 12),
          const Text('System is up to date', style: TextStyle(color: Colors.white70)),
        ],
      ));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 450,
        mainAxisExtent: 80,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _upgradablePackages.length,
      itemBuilder: (context, index) {
        final pkg = _upgradablePackages[index];
        return Card(
          color: _surfaceColor,
          child: Center(
            child: ListTile(
              title: Text(pkg.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: Text('${pkg.currentVersion} → ${pkg.newVersion}', style: const TextStyle(color: _mutedColor)),
              trailing: const Icon(Icons.arrow_upward, color: AppColors.textPrimary, size: 16),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchResults() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 450,
        mainAxisExtent: 80,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final pkg = _searchResults[index];
        return Card(
          color: _surfaceColor,
          child: Center(
            child: ListTile(
              title: Text(pkg.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
              subtitle: Text(pkg.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _mutedColor)),
              trailing: IconButton(
                icon: const Icon(Icons.download, color: _primaryColor),
                onPressed: () => _showStreamConsole('Installing ${pkg.name}...', 'sudo -S $_packageManager install -y ${pkg.name}', onDone: _fetchUpgradable),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButtons() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _surfaceColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(onPressed: _updateLists, child: const Text('Update Lists')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(onPressed: _upgradablePackages.isEmpty ? null : _upgradeAll, child: const Text('Upgrade All')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StreamConsole extends StatefulWidget {
  const _StreamConsole({
    required this.sshService,
    required this.title,
    required this.command,
    this.onDone,
  });

  final SshService sshService;
  final String title;
  final String command;
  final VoidCallback? onDone;

  @override
  State<_StreamConsole> createState() => _StreamConsoleState();
}

class _StreamConsoleState extends State<_StreamConsole> {
  final List<_ConsoleLine> _output = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  bool _isDone = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final session = await widget.sshService.streamCommand(widget.command);
      
      // sudo requires passwordless sudo or SSH key auth on the server

      _stdoutSub = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (mounted) {
              setState(() => _output.add(_ConsoleLine(line, isError: false)));
              _scrollToBottom();
            }
          });

      _stderrSub = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (mounted) {
              setState(() => _output.add(_ConsoleLine(line, isError: true)));
              _scrollToBottom();
            }
          });
      
      await session.done;
      if (mounted) {
        setState(() => _isDone = true);
        widget.onDone?.call();
      }
    } catch (e) {
      if (mounted) setState(() => _output.add(_ConsoleLine('Error: $e', isError: true)));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Container(
          padding: const EdgeInsets.all(24),
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _output.length,
                    itemBuilder: (context, index) {
                      final line = _output[index];
                      return Text(
                        line.text, 
                        style: TextStyle(
                          color: line.isError ? AppColors.danger : AppColors.textPrimary, 
                          fontFamily: 'monospace', 
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_isDone)
                SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsoleLine {
  final String text;
  final bool isError;
  _ConsoleLine(this.text, {required this.isError});
}

class UpgradablePackage {
  final String name;
  final String currentVersion;
  final String newVersion;
  UpgradablePackage({required this.name, required this.currentVersion, required this.newVersion});
}

class SearchResultPackage {
  final String name;
  final String description;
  SearchResultPackage({required this.name, required this.description});
}
