import 'package:flutter/material.dart';

import '../../core/ai/command_risk_assessor.dart';
import '../../core/audit/execution_audit_entry.dart';
import '../../core/audit/execution_audit_service.dart';
import '../../core/theme/app_colors.dart';
import 'widgets/audit_log_entry_card.dart';

/// Browsable, searchable audit log screen following Geometric Brutalism.
///
/// Displays all execution audit entries with search and filter capabilities.
/// Loads entries from [ExecutionAuditService] internally.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  final ExecutionAuditService _auditService = ExecutionAuditService();
  final TextEditingController _searchController = TextEditingController();

  List<ExecutionAuditEntry> _allEntries = [];
  List<ExecutionAuditEntry> _filteredEntries = [];
  bool _isLoading = true;

  // Filter state
  final Set<CommandRiskLevel> _activeRiskFilters = {};
  final Set<ExecutionStatus> _activeStatusFilters = {};

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    setState(() => _isLoading = true);
    final entries = await _auditService.loadAll();
    if (mounted) {
      setState(() {
        _allEntries = entries;
        _isLoading = false;
        _applyFilters();
      });
    }
  }

  void _applyFilters() {
    final query = _searchController.text.toLowerCase();
    _filteredEntries = _allEntries.where((entry) {
      // Search filter
      if (query.isNotEmpty) {
        final matchesSearch =
            entry.proposedCommand.toLowerCase().contains(query) ||
            entry.naturalLanguageIntent.toLowerCase().contains(query);
        if (!matchesSearch) return false;
      }

      // Risk level filter
      if (_activeRiskFilters.isNotEmpty &&
          !_activeRiskFilters.contains(entry.riskLevel)) {
        return false;
      }

      // Status filter
      if (_activeStatusFilters.isNotEmpty &&
          !_activeStatusFilters.contains(entry.status)) {
        return false;
      }

      return true;
    }).toList();
  }

  void _onSearchChanged(String _) {
    setState(_applyFilters);
  }

  void _toggleRiskFilter(CommandRiskLevel level) {
    setState(() {
      if (_activeRiskFilters.contains(level)) {
        _activeRiskFilters.remove(level);
      } else {
        _activeRiskFilters.add(level);
      }
      _applyFilters();
    });
  }

  void _toggleStatusFilter(ExecutionStatus status) {
    setState(() {
      if (_activeStatusFilters.contains(status)) {
        _activeStatusFilters.remove(status);
      } else {
        _activeStatusFilters.add(status);
      }
      _applyFilters();
    });
  }

  String _riskLabel(CommandRiskLevel level) {
    switch (level) {
      case CommandRiskLevel.low:
        return 'LOW';
      case CommandRiskLevel.moderate:
        return 'MODERATE';
      case CommandRiskLevel.high:
        return 'HIGH';
      case CommandRiskLevel.critical:
        return 'CRITICAL';
    }
  }

  String _statusLabel(ExecutionStatus status) {
    switch (status) {
      case ExecutionStatus.approved:
        return 'APPROVED';
      case ExecutionStatus.executed:
        return 'EXECUTED';
      case ExecutionStatus.failed:
        return 'FAILED';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        elevation: 0,
        title: const Text(
          'AUDIT LOG',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 14,
            letterSpacing: 2.0,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          IconButton(
            onPressed: _loadEntries,
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Search bar
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 1),
              ),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
              ),
              decoration: const InputDecoration(
                hintText: 'SEARCH COMMANDS...',
                hintStyle: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  letterSpacing: 1.0,
                ),
                prefixIcon: Icon(
                  Icons.search,
                  color: AppColors.textMuted,
                  size: 18,
                ),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: AppColors.border, width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: AppColors.border, width: 1),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(
                    color: AppColors.textPrimary,
                    width: 1,
                  ),
                ),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
            ),
          ),

          // Filter chips row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 1),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // Risk level filters
                  ...CommandRiskLevel.values.map((level) {
                    final isActive = _activeRiskFilters.contains(level);
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _buildFilterChip(
                        label: _riskLabel(level),
                        isActive: isActive,
                        onTap: () => _toggleRiskFilter(level),
                      ),
                    );
                  }),
                  // Separator
                  Container(
                    width: 1,
                    height: 20,
                    color: AppColors.border,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  // Status filters
                  ...ExecutionStatus.values.map((status) {
                    final isActive = _activeStatusFilters.contains(status);
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _buildFilterChip(
                        label: _statusLabel(status),
                        isActive: isActive,
                        onTap: () => _toggleStatusFilter(status),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),

          // Entry list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.textPrimary,
                      strokeWidth: 2,
                    ),
                  )
                : _filteredEntries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.history,
                              color: AppColors.textMuted,
                              size: 48,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _allEntries.isEmpty
                                  ? 'NO EXECUTIONS RECORDED'
                                  : 'NO MATCHING ENTRIES',
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                                fontFamily: AppColors.monoFamily,
                                fontFamilyFallback: AppColors.monoFallback,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _filteredEntries.length,
                        itemBuilder: (context, index) {
                          return AuditLogEntryCard(
                            entry: _filteredEntries[index],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.zero,
          border: Border.all(
            color: isActive ? AppColors.textPrimary : AppColors.border,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? AppColors.onPrimary : AppColors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
          ),
        ),
      ),
    );
  }
}
