import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/theme/app_colors.dart';

class HelpCenterScreen extends StatelessWidget {
  const HelpCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final topics = <Map<String, String>>[
      {
        'title': 'Connecting via SSH',
        'markdown': '''
# Connecting via SSH
Hamma uses `dartssh2` to establish secure connections. To connect:
1. Tap **Add Server**.
2. Enter the **Host** (IP or Domain) and **Port** (default 22).
3. Provide your **Username**.
4. Use either a **Password** or a **Private Key** (Ed25519 or RSA).
5. Tap **Test Connection** to verify settings before saving.
'''
      },
      {
        'title': 'Managing Docker',
        'markdown': '''
# Managing Docker
Hamma provides a simplified Docker dashboard:
1. Open a server from the list.
2. Select **Docker Manager**.
3. View running containers, stats, and images.
4. Perform actions like **Restart**, **Stop**, or **View Logs** directly from buttons.
'''
      },
      {
        'title': 'Using AI Assistant',
        'markdown': '''
# Using AI Assistant
The AI Copilot helps you manage servers without writing complex commands:
1. Tap the **AI Assistant** icon in a server dashboard.
2. Ask questions like "How do I check Nginx logs?" or "Restart my Postgres container".
3. The AI suggests commands which you can **edit** and **run** after explicit confirmation.
4. If a command fails, use **Smart Error Analysis** to get a technical breakdown of the failure.
'''
      },
      {
        'title': 'Fleet Monitoring',
        'markdown': '''
# Fleet Monitoring
Monitor your entire infrastructure at once:
1. Open the **Fleet Command Center** from the main server list.
2. View CPU, RAM, and Disk metrics across all saved servers.
3. Enable **Background Health Monitoring** in Settings to receive alerts if a server goes offline or exceeds resource thresholds.
'''
      },
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Help Center')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: topics.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final topic = topics[index];
              return Card(
                child: ListTile(
                  title: Text(topic['title']!),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: Text(topic['title']!)),
                          body: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 900),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: MarkdownBody(
                                  data: topic['markdown']!,
                                  selectable: true,
                                  styleSheet: MarkdownStyleSheet(
                                    h1: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22),
                                    p: const TextStyle(color: AppColors.textPrimary, height: 1.6, fontSize: 15),
                                    listBullet: const TextStyle(color: AppColors.textPrimary),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
