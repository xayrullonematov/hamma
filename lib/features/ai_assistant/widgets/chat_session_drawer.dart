import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

class ChatSessionDrawer extends StatelessWidget {
  const ChatSessionDrawer({
    super.key,
    required this.sessions,
    required this.currentSessionId,
    required this.onCreateNewChat,
    required this.onLoadSession,
    required this.onDeleteSession,
  });

  final List<Map<String, String>> sessions;
  final String? currentSessionId;
  final VoidCallback onCreateNewChat;
  final void Function(String sessionId) onLoadSession;
  final void Function(String sessionId) onDeleteSession;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.scaffoldBackground,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: onCreateNewChat,
                icon: const Icon(Icons.add),
                label: const Text('New Chat'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  backgroundColor: AppColors.textPrimary,
                  foregroundColor: AppColors.scaffoldBackground,
                ),
              ),
            ),
            const Divider(color: Colors.white12),
            Expanded(
              child: ListView.builder(
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  final isSelected = session['id'] == currentSessionId;
                  return ListTile(
                    leading: Icon(
                      Icons.chat_bubble_outline,
                      color: isSelected
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                      size: 20,
                    ),
                    title: Text(
                      session['title'] ?? 'Untitled Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? Colors.white : AppColors.textMuted,
                        fontSize: 14,
                      ),
                    ),
                    selected: isSelected,
                    trailing: isSelected
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => onDeleteSession(session['id']!),
                          ),
                    onTap: () {
                      onLoadSession(session['id']!);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
