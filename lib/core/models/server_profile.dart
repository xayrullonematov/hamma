class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.privateKey,
    this.privateKeyPassword,
  });

  static const _privateKeySentinel = Object();
  static const _privateKeyPasswordSentinel = Object();

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String password;
  final String? privateKey;
  final String? privateKeyPassword;

  bool get isValid {
    return name.trim().isNotEmpty &&
        host.trim().isNotEmpty &&
        port > 0 &&
        port <= 65535 &&
        username.trim().isNotEmpty &&
        (password.trim().isNotEmpty ||
            (privateKey?.trim().isNotEmpty ?? false));
  }

  ServerProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    Object? privateKey = _privateKeySentinel,
    Object? privateKeyPassword = _privateKeyPasswordSentinel,
  }) {
    return ServerProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      privateKey:
          identical(privateKey, _privateKeySentinel)
              ? this.privateKey
              : privateKey as String?,
      privateKeyPassword:
          identical(privateKeyPassword, _privateKeyPasswordSentinel)
              ? this.privateKeyPassword
              : privateKeyPassword as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'privateKey': privateKey,
      'privateKeyPassword': privateKeyPassword,
    };
  }

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    // Type-checked accessors that don't crash on missing/wrong-type fields,
    // but also don't silently coerce maps/lists/bools into strings (which
    // would make a corrupted profile look superficially valid).
    String str(String key) {
      final v = json[key];
      return v is String ? v : '';
    }

    String? strOrNull(String key) {
      final v = json[key];
      return v is String ? v : null;
    }

    // Port: accept int or string-encoded int (legitimate JSON variation).
    // Default to 22 only when the field is absent or null. For malformed
    // values, return 0 so `isValid` flags the profile rather than silently
    // connecting to the SSH default port.
    final rawPort = json['port'];
    final int port;
    if (rawPort == null) {
      port = 22;
    } else if (rawPort is int) {
      port = rawPort;
    } else if (rawPort is String) {
      port = int.tryParse(rawPort) ?? 0;
    } else {
      port = 0;
    }

    return ServerProfile(
      id: str('id'),
      name: str('name'),
      host: str('host'),
      port: port,
      username: str('username'),
      password: str('password'),
      privateKey: strOrNull('privateKey'),
      privateKeyPassword: strOrNull('privateKeyPassword'),
    );
  }
}
