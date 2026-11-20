import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'common.dart';

class LanSettings extends StatefulWidget {
  const LanSettings({super.key, required this.controller});
  final DormController controller;

  @override
  State<LanSettings> createState() => _LanSettingsState();
}

class _LanSettingsState extends State<LanSettings> {
  late final _port = TextEditingController(
    text: widget.controller.repository.preferences.lanPort.toString(),
  );

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final value = int.tryParse(_port.text.trim());
    if (value == null || value < 1 || value > 65535) {
      notify(context, '请输入 1 至 65535 之间的端口');
      return;
    }
    try {
      widget.controller.updatePreferences(
        (preferences) => preferences.copyWith(lanPort: value),
      );
      await widget.controller.lan.start(value);
      if (mounted) notify(context, '局域网服务器已启动');
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法启动局域网服务器'));
    }
  }

  Future<void> _copy(String value, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) notify(context, '已复制$label');
    } catch (_) {
      if (mounted) notify(context, '无法复制$label');
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.controller.lan;
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                spacing: 12,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.running ? '服务器正在运行' : '服务器未启动',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (server.running)
                    Text('监听 0.0.0.0:${server.port}')
                  else
                    const Text('室友连接同一局域网后，可用浏览器访问并操作当前寝室数据。'),
                  if (!server.running)
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _port,
                        enabled: !server.starting,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '监听端口'),
                      ),
                    ),
                  if (server.running)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('停止服务器'),
                      onPressed: server.stop,
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(server.starting ? '正在启动…' : '启动服务器'),
                      onPressed: server.starting ? null : _start,
                    ),
                ],
              ),
            ),
          ),
          if (server.running) ...[
            Card(
              child: Column(
                children: [
                  for (final address in server.addresses)
                    ListTile(
                      leading: const Icon(Icons.link),
                      title: SelectableText(address),
                      subtitle: Text(
                        address.contains('127.0.0.1') ? '本机测试' : '室友访问地址',
                      ),
                      trailing: IconButton(
                        tooltip: '复制地址',
                        onPressed: () => _copy(address, '地址'),
                        icon: const Icon(Icons.copy_outlined),
                      ),
                    ),
                ],
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 9,
                  children: [
                    Text('访问码', style: Theme.of(context).textTheme.titleMedium),
                    SelectableText(
                      server.pairingCode!,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Text('访问者拥有数据读写权限。重置访问码会让现有会话失效。'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('复制访问码'),
                          onPressed: () => _copy(server.pairingCode!, '访问码'),
                        ),
                        TextButton(
                          onPressed: server.rotateCode,
                          child: const Text('重置访问码'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('服务使用 HTTP。请在可信局域网内分享地址和访问码。'),
          ),
        ],
      ),
    );
  }
}
