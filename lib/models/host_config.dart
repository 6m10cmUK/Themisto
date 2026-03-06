import 'package:uuid/uuid.dart';

class HostConfig {
  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  String? password; // stored separately in secure storage

  HostConfig({
    String? id,
    required this.label,
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
      };

  factory HostConfig.fromJson(Map<String, dynamic> json) => HostConfig(
        id: json['id'] as String,
        label: json['label'] as String,
        host: json['host'] as String,
        port: json['port'] as int? ?? 22,
        username: json['username'] as String,
      );

  HostConfig copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    String? password,
  }) =>
      HostConfig(
        id: id,
        label: label ?? this.label,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
      );
}
