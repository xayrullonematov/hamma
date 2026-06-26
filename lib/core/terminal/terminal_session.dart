import 'package:meta/meta.dart';

@immutable
class TerminalSession {
  const TerminalSession({
    required this.serverId,
    required this.sessionId,
    required this.serverName,
    required this.scrollback,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  static const maxScrollbackChars = 100000;

  final String serverId;
  final String sessionId;
  final String serverName;
  final String scrollback;
  final int createdAtMs;
  final int updatedAtMs;

  int get scrollbackChars => scrollback.length;

  TerminalSession copyWith({
    String? serverName,
    String? scrollback,
    int? createdAtMs,
    int? updatedAtMs,
  }) {
    return TerminalSession(
      serverId: serverId,
      sessionId: sessionId,
      serverName: serverName ?? this.serverName,
      scrollback: scrollback ?? this.scrollback,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  TerminalSession append(
    String chunk, {
    required int nowMs,
    int maxChars = maxScrollbackChars,
  }) {
    if (chunk.isEmpty) return copyWith(updatedAtMs: nowMs);
    return copyWith(
      scrollback: trimTerminalScrollback('$scrollback$chunk', maxChars),
      updatedAtMs: nowMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'sessionId': sessionId,
    'serverName': serverName,
    'scrollback': scrollback,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory TerminalSession.fromJson(Map<String, dynamic> json) {
    return TerminalSession(
      serverId: (json['serverId'] ?? '').toString(),
      sessionId: (json['sessionId'] ?? '').toString(),
      serverName: (json['serverName'] ?? '').toString(),
      scrollback: (json['scrollback'] ?? '').toString(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class TerminalSessionMetadata {
  const TerminalSessionMetadata({
    required this.serverId,
    required this.sessionId,
    required this.serverName,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.scrollbackChars,
  });

  final String serverId;
  final String sessionId;
  final String serverName;
  final int createdAtMs;
  final int updatedAtMs;
  final int scrollbackChars;

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'sessionId': sessionId,
    'serverName': serverName,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'scrollbackChars': scrollbackChars,
  };

  factory TerminalSessionMetadata.fromJson(Map<String, dynamic> json) {
    return TerminalSessionMetadata(
      serverId: (json['serverId'] ?? '').toString(),
      sessionId: (json['sessionId'] ?? '').toString(),
      serverName: (json['serverName'] ?? '').toString(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      scrollbackChars: (json['scrollbackChars'] as num?)?.toInt() ?? 0,
    );
  }
}

String trimTerminalScrollback(
  String input, [
  int maxChars = TerminalSession.maxScrollbackChars,
]) {
  if (maxChars <= 0) return '';
  if (input.length <= maxChars) return input;
  return input.substring(input.length - maxChars);
}
