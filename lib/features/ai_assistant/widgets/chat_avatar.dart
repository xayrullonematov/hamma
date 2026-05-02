import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.isUser});

  final bool isUser;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isUser
            ? AppColors.surface
            : AppColors.textPrimary.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isUser ? Icons.person_outline : Icons.smart_toy_outlined,
        color: isUser ? AppColors.textMuted : AppColors.textPrimary,
        size: 18,
      ),
    );
  }
}
