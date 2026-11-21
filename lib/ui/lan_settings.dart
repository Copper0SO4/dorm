import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/qr_image.dart';
import '../domain/lan_link.dart';
import 'camera_qr.dart';
import 'common.dart';
import 'save_document.dart';

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

  Future<void> _join() async {
    final link = await scanWithCamera<Uri>(
      context,
      title: '扫描局域网二维码',
      instruction: '把室友访问地址的二维码放在取景框内。',
      read: readLanQrLink,
    );
    if (link == null || !mounted) return;
    try {
      final opened = await launchUrl(
        link,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) notify(context, '无法打开浏览器，请检查浏览器是否可用');
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法打开局域网工作台'));
    }
  }

  Future<void> _showQr(String address) async {
    try {
      final image = await makeQrPng(address);
      if (!mounted || !widget.controller.lan.addresses.contains(address)) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('扫码打开局域网工作台'),
          scrollable: true,
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                const Text('让室友连接同一局域网，再用手机相机扫码。'),
                Image.memory(
                  image,
                  width: 264,
                  filterQuality: FilterQuality.none,
                  semanticLabel: '局域网工作台地址二维码',
                ),
                SelectableText(address),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _saveQr(image),
              icon: const Icon(Icons.download_outlined),
              label: const Text('保存二维码'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法生成二维码'));
    }
  }

  Future<void> _saveQr(Uint8List image) async {
    const name = 'Dorm-LAN.png';
    try {
      final saved = await saveDocument(
        XFile.fromData(image, name: name, mimeType: 'image/png'),
        name: name,
        extension: 'png',
        label: '二维码图片',
        mimeType: 'image/png',
      );
      if (saved && mounted) notify(context, '已保存二维码');
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法保存二维码'));
    }
  }

  Widget _addressTile(String address) {
    final loopback = Uri.parse(address).host == '127.0.0.1';
    return ListTile(
      leading: const Icon(Icons.link),
      title: SelectableText(address),
      subtitle: Text(loopback ? '本机测试' : '室友访问地址'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!loopback)
            IconButton(
              tooltip: '显示二维码',
              icon: const Icon(Icons.qr_code_2_outlined),
              onPressed: () => _showQr(address),
            ),
          IconButton(
            tooltip: '复制地址',
            onPressed: () => _copy(address, '地址'),
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
    );
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
          if (Platform.isAndroid)
            Card(
              child: ListTile(
                leading: const Icon(Icons.qr_code_scanner_rounded),
                title: const Text('扫码加入工作台'),
                subtitle: const Text('扫描室友的局域网二维码，在浏览器打开。'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _join,
              ),
            ),
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
          if (server.running)
            Card(
              child: Column(
                children: [
                  const ListTile(
                    title: Text('分享工作台'),
                    subtitle: Text('打开链接或扫描二维码即可进入。'),
                  ),
                  for (final address in server.addresses) _addressTile(address),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('服务使用 HTTP。启动后，能访问该地址的人都可以读写寝室数据。'),
          ),
        ],
      ),
    );
  }
}
