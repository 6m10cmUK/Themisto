class TmuxWindow {
  final String sessionName;
  final int index;
  final String name;
  final bool isActive;

  const TmuxWindow({
    required this.sessionName,
    required this.index,
    required this.name,
    required this.isActive,
  });

  String get displayName => name.isEmpty ? '[No name]' : name;
}
