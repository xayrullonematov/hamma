import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/vault/vault_change_bus.dart';
import '../../core/vault/vault_group.dart';
import '../../core/vault/vault_secret.dart';
import '../../core/vault/vault_storage.dart';
import '../../core/vault/vault_search.dart';
import 'vault_group_detail_screen.dart';
import 'vault_group_edit_screen.dart';
import 'vault_export_screen.dart';

class VaultListScreen extends StatefulWidget {
  const VaultListScreen({super.key, this.storage});

  final VaultStorage? storage;

  @override
  State<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends State<VaultListScreen> {
  late StreamSubscription<void> _subscription;
  late final VaultStorage _storage;
  final _searchController = TextEditingController();
  final _searchIndex = VaultSearchIndex();
  
  List<VaultGroup> _groups = [];
  List<VaultSecret> _allSecrets = [];
  List<VaultSecret> _ungroupedSecrets = [];
  Map<String, int> _groupSecretCounts = {};
  Set<String> _groupsNeedingRotation = {};
  
  CredentialType? _selectedType;
  String? _selectedTag;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? VaultStorage();
    _loadData();
    _subscription = VaultChangeBus.instance.changes.listen((_) => _loadData());
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _subscription.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final groups = await _storage.loadAllGroups();
    final allSecrets = await _storage.loadAll();

    final counts = <String, int>{};
    final ungrouped = <VaultSecret>[];
    final needsRotation = <String>{};
    
    final now = DateTime.now();
    final threshold = now.add(const Duration(days: 7));

    for (final s in allSecrets) {
      final isNearRotation = s.rotateBy != null && s.rotateBy!.isBefore(threshold);
      
      if (s.groupId == null) {
        ungrouped.add(s);
      } else {
        counts[s.groupId!] = (counts[s.groupId!] ?? 0) + 1;
        if (isNearRotation) {
          needsRotation.add(s.groupId!);
        }
      }
    }

    _searchIndex.buildIndex(groups, allSecrets);

    if (mounted) {
      setState(() {
        _groups = groups;
        _allSecrets = allSecrets;
        _ungroupedSecrets = ungrouped;
        _groupSecretCounts = counts;
        _groupsNeedingRotation = needsRotation;
        _isLoading = false;
      });
    }
  }

  List<VaultGroup> _getRecentlyUsed() {
    final groupMaxLastUsed = <String, DateTime>{};
    for (final s in _allSecrets) {
      if (s.groupId != null && s.lastUsedAt != null) {
        final existing = groupMaxLastUsed[s.groupId!];
        if (existing == null || s.lastUsedAt!.isAfter(existing)) {
          groupMaxLastUsed[s.groupId!] = s.lastUsedAt!;
        }
      }
    }
    
    final sortedGroups = _groups
        .where((g) => groupMaxLastUsed.containsKey(g.id))
        .toList()
      ..sort((a, b) => groupMaxLastUsed[b.id]!.compareTo(groupMaxLastUsed[a.id]!));
      
    return sortedGroups.take(3).toList();
  }

  List<String> get _allTags => 
      _groups.expand((g) => g.tags).toSet().toList()..sort();

  void _showTypeSelector() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(),
      builder: (context) => _VaultTypeSelector(storage: _storage),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text;
    final searchResults = _searchIndex.search(query);
    final matchedGroupIds = searchResults.map((r) => r.groupId).whereType<String>().toSet();
    final matchedSecretIds = searchResults.map((r) => r.secretId).whereType<String>().toSet();

    var filteredGroups = _groups;
    var filteredUngrouped = _ungroupedSecrets;

    if (query.isNotEmpty) {
      filteredGroups = filteredGroups.where((g) => matchedGroupIds.contains(g.id)).toList();
      filteredUngrouped = filteredUngrouped.where((s) => matchedSecretIds.contains(s.id)).toList();
    }

    if (_selectedType != null) {
      filteredGroups = filteredGroups.where((g) => g.type == _selectedType).toList();
      filteredUngrouped = [];
    }
    
    if (_selectedTag != null) {
      filteredGroups = filteredGroups.where((g) => g.tags.contains(_selectedTag)).toList();
      filteredUngrouped = [];
    }

    final recentlyUsed = (query.isEmpty && _selectedType == null && _selectedTag == null) 
        ? _getRecentlyUsed() : <VaultGroup>[];

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text('VAULT'),
        backgroundColor: AppColors.scaffoldBackground,
        actions: [
          IconButton(
            icon: const Icon(Icons.import_export),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const VaultExportScreen()),
            ),
            tooltip: 'Export / Import',
          ),
          if (query.isNotEmpty || _selectedType != null || _selectedTag != null)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _searchController.clear();
                _selectedType = null;
                _selectedTag = null;
              }),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _SearchBar(controller: _searchController),
                _FilterRow(
                  selectedType: _selectedType,
                  selectedTag: _selectedTag,
                  allTags: _allTags,
                  onTypeSelected: (t) => setState(() => _selectedType = t),
                  onTagSelected: (t) => setState(() => _selectedTag = t),
                ),
                const Divider(color: AppColors.border, height: 1),
                Expanded(
                  child: filteredGroups.isEmpty && filteredUngrouped.isEmpty
                      ? _EmptyState(isSearch: query.isNotEmpty || _selectedType != null || _selectedTag != null)
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (recentlyUsed.isNotEmpty) ...[
                              _SectionHeader(title: 'RECENTLY USED'),
                              ...recentlyUsed.map((g) => _VaultGroupCard(
                                group: g,
                                secretCount: _groupSecretCounts[g.id] ?? 0,
                                needsRotation: _groupsNeedingRotation.contains(g.id),
                                onTap: () => _openDetail(g),
                              )),
                              const SizedBox(height: 24),
                            ],
                            if (filteredGroups.isNotEmpty) ...[
                              _SectionHeader(title: 'GROUPS'),
                              ...filteredGroups.map((g) => _VaultGroupCard(
                                    group: g,
                                    secretCount: _groupSecretCounts[g.id] ?? 0,
                                    needsRotation: _groupsNeedingRotation.contains(g.id),
                                    onTap: () => _openDetail(g),
                                  )),
                              const SizedBox(height: 24),
                            ],
                            if (filteredUngrouped.isNotEmpty) ...[
                              _SectionHeader(title: 'UNGROUPED SECRETS'),
                              ...filteredUngrouped.map((s) => _VaultSecretTile(secret: s)),
                            ],
                          ],
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showTypeSelector,
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onPrimary,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _openDetail(VaultGroup g) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VaultGroupDetailScreen(group: g, storage: _storage),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search groups, fields, tags...',
          hintStyle: const TextStyle(color: AppColors.textFaint, fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.textFaint),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selectedType,
    required this.selectedTag,
    required this.allTags,
    required this.onTypeSelected,
    required this.onTagSelected,
  });

  final CredentialType? selectedType;
  final String? selectedTag;
  final List<String> allTags;
  final void Function(CredentialType?) onTypeSelected;
  final void Function(String?) onTagSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          ...CredentialType.values.map((type) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(
                  label: Text(type.name.toUpperCase(), style: const TextStyle(fontSize: 10)),
                  selected: selectedType == type,
                  onSelected: (selected) => onTypeSelected(selected ? type : null),
                  backgroundColor: AppColors.panel,
                  selectedColor: AppColors.accent.withValues(alpha: 0.2),
                  checkmarkColor: AppColors.accent,
                  shape: const RoundedRectangleBorder(side: BorderSide(color: AppColors.border)),
                ),
              )),
          if (allTags.isNotEmpty) const VerticalDivider(color: AppColors.border, indent: 12, endIndent: 12),
          ...allTags.map((tag) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(
                  label: Text('#$tag', style: const TextStyle(fontSize: 10)),
                  selected: selectedTag == tag,
                  onSelected: (selected) => onTagSelected(selected ? tag : null),
                  backgroundColor: AppColors.panel,
                  selectedColor: AppColors.accent.withValues(alpha: 0.2),
                  checkmarkColor: AppColors.accent,
                  shape: const RoundedRectangleBorder(side: BorderSide(color: AppColors.border)),
                ),
              )),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title,
        style: TextStyle(
          fontFamily: AppColors.monoFamily,
          color: AppColors.textFaint,
          fontSize: 12,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isSearch});
  final bool isSearch;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isSearch ? Icons.search_off : Icons.lock_outline, size: 48, color: AppColors.textFaint),
            const SizedBox(height: 16),
            Text(
              isSearch ? 'No matches found.' : 'Your vault is empty.',
              style: const TextStyle(color: AppColors.textMuted),
            ),
            if (isSearch) ...[
              const SizedBox(height: 8),
              const Text(
                'Try adjusting your search or filters.',
                style: TextStyle(color: AppColors.textFaint, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VaultGroupCard extends StatelessWidget {
  const _VaultGroupCard({
    required this.group,
    required this.secretCount,
    this.needsRotation = false,
    required this.onTap,
  });

  final VaultGroup group;
  final int secretCount;
  final bool needsRotation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: AppColors.border),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_getIconData(group.icon), color: AppColors.accent, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      group.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (needsRotation)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 16),
                    ),
                  Text(
                    '$secretCount field${secretCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: AppColors.textFaint,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (group.tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: group.tags.map((t) => Chip(
                        label: Text(t, style: const TextStyle(fontSize: 10)),
                        backgroundColor: AppColors.panel,
                        side: const BorderSide(color: AppColors.border),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      )).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _getIconData(String name) {
    switch (name) {
      case 'cloud': return Icons.cloud_outlined;
      case 'cloud_queue': return Icons.cloud_queue;
      case 'storage': return Icons.storage_outlined;
      case 'dns': return Icons.dns_outlined;
      case 'payments': return Icons.payments_outlined;
      case 'code': return Icons.code;
      case 'vpn_key': return Icons.vpn_key_outlined;
      case 'api': return Icons.api_outlined;
      default: return Icons.enhanced_encryption_outlined;
    }
  }
}

class _VaultSecretTile extends StatelessWidget {
  const _VaultSecretTile({required this.secret});
  final VaultSecret secret;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(secret.name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        secret.scope ?? 'Global',
        style: const TextStyle(color: AppColors.textFaint, fontSize: 12),
      ),
      trailing: const Text('••••••••', style: TextStyle(color: AppColors.textMuted)),
      onTap: () {
        // Flat secret detail not requested in this task
      },
    );
  }
}

class _VaultTypeSelector extends StatelessWidget {
  const _VaultTypeSelector({required this.storage});

  final VaultStorage storage;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'SELECT CREDENTIAL TYPE',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
        ),
        const Divider(color: AppColors.border, height: 1),
        SizedBox(
          height: 300,
          child: GridView.count(
            crossAxisCount: 3,
            padding: const EdgeInsets.all(16),
            children: CredentialType.values.map((type) => InkWell(
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VaultGroupEditScreen(type: type, storage: storage),
                      ),
                    );
                  },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_getIconForType(type), color: AppColors.accent),
                      const SizedBox(height: 8),
                      Text(
                        _getTypeLabel(type),
                        style: const TextStyle(fontSize: 10),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )).toList(),
          ),
        ),
      ],
    );
  }

  IconData _getIconForType(CredentialType type) {
    switch (type) {
      case CredentialType.awsS3: return Icons.cloud_outlined;
      case CredentialType.awsGeneric: return Icons.cloud_queue;
      case CredentialType.postgres: return Icons.storage_outlined;
      case CredentialType.mysql: return Icons.dns_outlined;
      case CredentialType.stripe: return Icons.payments_outlined;
      case CredentialType.github: return Icons.code;
      case CredentialType.sshKey: return Icons.vpn_key_outlined;
      case CredentialType.apiKey: return Icons.api_outlined;
      case CredentialType.generic: return Icons.enhanced_encryption_outlined;
    }
  }

  String _getTypeLabel(CredentialType type) {
    switch (type) {
      case CredentialType.awsS3: return 'AWS S3';
      case CredentialType.awsGeneric: return 'AWS IAM';
      case CredentialType.postgres: return 'PostgreSQL';
      case CredentialType.mysql: return 'MySQL';
      case CredentialType.stripe: return 'Stripe';
      case CredentialType.github: return 'GitHub';
      case CredentialType.sshKey: return 'SSH Key';
      case CredentialType.apiKey: return 'API Key';
      case CredentialType.generic: return 'Generic';
    }
  }
}
