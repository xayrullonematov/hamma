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
    final rawPort = json['port'];
    final port = rawPort is int
        ? rawPort
        : int.tryParse(rawPort?.toString() ?? '') ?? 22;

    return ServerProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      host: json['host']?.toString() ?? '',
      port: port,
      username: json['username']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      privateKey: json['privateKey']?.toString(),
      privateKeyPassword: json['privateKeyPassword']?.toString(),
    );
  }
}
