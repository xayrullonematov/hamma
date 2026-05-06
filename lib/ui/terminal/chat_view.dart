import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// A brutalist, streaming terminal view for AI interactions.
///
/// Implements a strict geometric aesthetic:
/// - Zero-radius corners (sharp edges).
/// - High-contrast monochrome palette.
/// - Monospace typography (JetBrains Mono).
/// - Real-time token streaming with a typing effect.
/// - ASCII-based progress tracking for model downloads.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.tokenStream,
    required this.downloadProgressStream,
  });

  /// The stream of incoming AI tokens.
  final Stream<String> tokenStream;

  /// The stream of download progress (0.0 to 100.0).
  final Stream<double> downloadProgressStream;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final StringBuffer _buffer = StringBuffer();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _tokenSub;

  @override
  void initState() {
    super.initState();
    _tokenSub = widget.tokenStream.listen((token) {
      if (mounted) {
        setState(() {
          _buffer.write(token);
        });
        _scrollToBottom();
      }
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _tokenSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Text(
                _buffer.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: AppColors.monoFamily,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
          ),
          _buildDownloadSection(),
        ],
      ),
    );
  }

  Widget _buildDownloadSection() {
    return StreamBuilder<double>(
      stream: widget.downloadProgressStream,
      initialData: 0.0,
      builder: (context, snapshot) {
        final progress = snapshot.data ?? 0.0;
        if (progress >= 100.0) return const SizedBox.shrink();
        
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _renderAsciiBar(progress),
            style: const TextStyle(
              color: Colors.white,
              fontFamily: AppColors.monoFamily,
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
        );
      },
    );
  }

  String _renderAsciiBar(double progress) {
    const int width = 20;
    final int filledCount = (progress / 100 * width).round();
    final String filled = '=' * (filledCount > 0 ? filledCount - 1 : 0);
    final String head = filledCount > 0 ? '>' : '';
    final String empty = ' ' * (width - filledCount);
    return '[$filled$head$empty]';
  }
}
