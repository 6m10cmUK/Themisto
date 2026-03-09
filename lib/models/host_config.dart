import 'package:uuid/uuid.dart';

enum AuthType { password, key }

class HostConfig {
  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthType authType;
  String? password; // stored separately in secure storage
  String? privateKey; // stored separately in secure storage

  HostConfig({
    String? id,
    required this.label,
    required this.host,
    this.port = 22,
    required this.username,
    this.authType = AuthType.password,
    this.password,
    this.privateKey,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType.name,
      };

  factory HostConfig.fromJson(Map<String, dynamic> json) => HostConfig(
        id: json['id'] as String,
        label: json['label'] as String,
        host: json['host'] as String,
        port: json['port'] as int? ?? 22,
        username: json['username'] as String,
        authType: AuthType.values.firstWhere(
          (e) => e.name == json['authType'],
          orElse: () => AuthType.password,
        ),
      );

  HostConfig copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    AuthType? authType,
    String? password,
    String? privateKey,
  }) =>
      HostConfig(
        id: id,
        label: label ?? this.label,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        authType: authType ?? this.authType,
        password: password ?? this.password,
        privateKey: privateKey ?? this.privateKey,
      );
}
