import 'package:material_ui/material_ui.dart';

import '../data/cloud_proxy.dart';
import '../data/cloud_sync.dart';
import 'common.dart';

Future<void> editCloudProxy(BuildContext context, CloudSync cloud) async {
  CloudProxy? saved;
  try {
    saved = await cloud.readProxy();
  } catch (_) {
    if (!context.mounted) return;
    notify(context, '无法读取现有代理配置，可以重新填写');
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _CloudProxyDialog(cloud: cloud, saved: saved),
  );
}

class _CloudProxyDialog extends StatefulWidget {
  const _CloudProxyDialog({required this.cloud, this.saved});

  final CloudSync cloud;
  final CloudProxy? saved;

  @override
  State<_CloudProxyDialog> createState() => _CloudProxyDialogState();
}

class _CloudProxyDialogState extends State<_CloudProxyDialog> {
  late bool _enabled = widget.saved != null;
  late CloudProxyKind _kind = widget.saved?.kind ?? CloudProxyKind.http;
  late final _host = TextEditingController(text: widget.saved?.host);
  late final _port = TextEditingController(text: widget.saved?.port.toString());
  late final _username = TextEditingController(text: widget.saved?.username);
  late final _password = TextEditingController(text: widget.saved?.password);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final proxy = _enabled
          ? CloudProxy(
              kind: _kind,
              host: _host.text,
              port: int.tryParse(_port.text.trim()) ?? 0,
              username: _username.text,
              password: _password.text,
            )
          : null;
      await widget.cloud.saveProxy(proxy);
      if (mounted) {
        Navigator.pop(context);
        notify(context, proxy == null ? '已恢复直连' : '代理已保存，下次同步生效');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = errorText(error, fallback: '无法保存代理设置，请重试');
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('云同步代理'),
    content: SizedBox(
      width: 440,
      child: fieldColumn([
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用代理'),
          subtitle: const Text('此设置仅用于本机的 GitHub 云同步。'),
          value: _enabled,
          onChanged: _saving
              ? null
              : (enabled) => setState(() {
                  _enabled = enabled;
                  _error = null;
                }),
        ),
        if (_enabled) ...[
          DropdownButtonFormField<CloudProxyKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: '代理类型'),
            items: [
              for (final kind in CloudProxyKind.values)
                DropdownMenuItem(value: kind, child: Text(kind.label)),
            ],
            onChanged: _saving ? null : (kind) => setState(() => _kind = kind!),
          ),
          TextField(
            controller: _host,
            enabled: !_saving,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '代理主机',
              hintText: '127.0.0.1',
            ),
          ),
          TextField(
            controller: _port,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '代理端口'),
          ),
          TextField(
            controller: _username,
            enabled: !_saving,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '代理用户名（可留空）'),
          ),
          TextField(
            controller: _password,
            enabled: !_saving,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '代理密码（可留空）'),
          ),
        ],
        if (_error case final error?)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ]),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
    ],
  );
}
