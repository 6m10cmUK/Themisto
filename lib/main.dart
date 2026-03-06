import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/host_list_screen.dart';

void main() {
  runApp(const ProviderScope(child: ThemistoApp()));
}

class ThemistoApp extends StatelessWidget {
  const ThemistoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Themisto',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HostListScreen(),
    );
  }
}
