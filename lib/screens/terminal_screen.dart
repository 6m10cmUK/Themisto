import 'package:flutter/material.dart';

// Placeholder for Step 2
class TerminalScreen extends StatelessWidget {
  final String sessionName;
  const TerminalScreen({super.key, required this.sessionName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Terminal - $sessionName')),
      body: const Center(child: Text('Terminal will be implemented in Step 2')),
    );
  }
}
