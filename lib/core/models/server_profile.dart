class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.privateKey,
  });

  static const _privateKeySentinel = Object();

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String password;
  final String? privateKey;

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
    };
  }

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      username: json['username'] as String,
      password: json['password'] as String,
      privateKey: json['privateKey'] as String?,
    );
  }
}
