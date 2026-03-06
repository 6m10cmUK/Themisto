import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host_config.dart';
import '../providers/providers.dart';

class HostEditScreen extends ConsumerStatefulWidget {
  final HostConfig? host;
  const HostEditScreen({super.key, this.host});

  @override
  ConsumerState<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends ConsumerState<HostEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    _labelCtrl = TextEditingController(text: h?.label ?? '');
    _hostCtrl = TextEditingController(text: h?.host ?? '');
    _portCtrl = TextEditingController(text: (h?.port ?? 22).toString());
    _userCtrl = TextEditingController(text: h?.username ?? '');
    _passCtrl = TextEditingController(text: h?.password ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.host != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Host' : 'Add Host')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _labelCtrl,
                decoration: const InputDecoration(labelText: 'Label'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _hostCtrl,
                decoration: const InputDecoration(labelText: 'Host'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _portCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Required';
                  if (int.tryParse(v) == null) return 'Invalid port';
                  return null;
                },
              ),
              TextFormField(
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _passCtrl,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _save,
                child: Text(isEdit ? 'Update' : 'Add'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final config = HostConfig(
      id: widget.host?.id,
      label: _labelCtrl.text,
      host: _hostCtrl.text,
      port: int.parse(_portCtrl.text),
      username: _userCtrl.text,
      password: _passCtrl.text.isEmpty ? null : _passCtrl.text,
    );
    await ref.read(hostListProvider.notifier).addOrUpdate(config);
    if (mounted) Navigator.pop(context);
  }
}
