import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/cloud_sync.dart';
import '../data/dorm_invite.dart';
import '../data/invite_qr.dart';
import '../data/qr_image.dart';
import '../domain/ledger.dart';
import 'camera_qr.dart';
import 'common.dart';
import 'dorm_invite_dialog.dart';
import 'save_document.dart';

enum _ImportMethod { camera, image, clipboard }

Future<ImportedDormInvite?> importInviteQr(BuildContext context) async {
  final method = await showDialog<_ImportMethod>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('导入邀请二维码'),
      content: Text(
        Platform.isAndroid
            ? '可以用摄像头扫码，也可以导入二维码截图。含密钥的邀请需要输入邀请码。'
            : '选择二维码截图，或粘贴扫码工具读出的文本。含密钥的邀请需要输入邀请码。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _ImportMethod.clipboard),
          child: const Text('粘贴扫码文本'),
        ),
        if (Platform.isAndroid) ...[
          TextButton(
            onPressed: () => Navigator.pop(context, _ImportMethod.image),
            child: const Text('选择二维码图片'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _ImportMethod.camera),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('摄像头扫码'),
          ),
        ] else
          FilledButton(
            onPressed: () => Navigator.pop(context, _ImportMethod.image),
            child: const Text('选择二维码图片'),
          ),
      ],
    ),
  );
  if (method == null || !context.mounted) return null;
  final invite = switch (method) {
    _ImportMethod.camera => await scanWithCamera<DormInvite>(
      context,
      title: '扫描仓库邀请',
      instruction: '把 Dorm 仓库邀请二维码放在取景框内。',
      read: readInviteQrText,
    ),
    _ImportMethod.clipboard => readInviteQrText(
      (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '',
    ),
    _ImportMethod.image => await _chooseImage(),
  };
  if (invite == null || !context.mounted) return null;
  return unlockDormInvite(context, invite);
}

Future<DormInvite?> _chooseImage() async {
  const images = XTypeGroup(
    label: '二维码图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp'],
  );
  final file = await openFile(
    acceptedTypeGroups: Platform.isAndroid ? const [] : const [images],
  );
  if (file == null) return null;
  const maxBytes = 16 * 1024 * 1024;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const InputException('二维码图片不得超过 16 MB');
    }
    bytes.add(chunk);
  }
  return readInviteQrImage(bytes.takeBytes());
}

Future<void> showInviteQr(BuildContext context, CloudSync cloud) =>
    showDialog<void>(
      context: context,
      builder: (_) => _InviteQrDialog(cloud: cloud),
    );

class _InviteQrDialog extends StatefulWidget {
  const _InviteQrDialog({required this.cloud});
  final CloudSync cloud;

  @override
  State<_InviteQrDialog> createState() => _InviteQrDialogState();
}

class _InviteQrDialogState extends State<_InviteQrDialog> {
  late final _code = newInviteCode();
  late final _invite = _generate();
  bool _saving = false;

  Future<({String text, Uint8List png})> _generate() async {
    final invite = await widget.cloud.exportInvite(password: _code);
    final text = inviteQrText(invite);
    return (text: text, png: await makeQrPng(text));
  }

  Future<void> _copy(String value, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) notify(context, '已复制$label');
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法复制$label'));
    }
  }

  Future<void> _save(Uint8List png) async {
    setState(() => _saving = true);
    try {
      const name = 'Dorm-repository-invite.png';
      if (await saveDocument(
            XFile.fromData(png, name: name, mimeType: 'image/png'),
            name: name,
            extension: 'png',
            label: '二维码图片',
            mimeType: 'image/png',
          ) &&
          mounted) {
        notify(context, '已保存二维码');
      }
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法保存二维码'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _invite,
    builder: (context, snapshot) {
      final data = snapshot.data;
      return AlertDialog(
        title: const Text('仓库邀请二维码'),
        scrollable: true,
        content: SizedBox(
          width: 430,
          child: snapshot.hasError
              ? Text(errorText(snapshot.error!, fallback: '无法生成仓库邀请'))
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    const Text('室友导入二维码并输入邀请码后，会使用同一把 SSH 私钥。'),
                    Center(
                      child: Image.memory(
                        data.png,
                        width: 360,
                        filterQuality: FilterQuality.none,
                        semanticLabel: 'Dorm 仓库邀请二维码',
                      ),
                    ),
                    const Text('邀请码'),
                    SelectableText(
                      _code,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () => _copy(_code, '邀请码'),
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('复制邀请码'),
                        ),
                        TextButton(
                          onPressed: () => _copy(data.text, '邀请文本'),
                          child: const Text('复制邀请文本'),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: data == null || _saving ? null : () => _save(data.png),
            child: const Text('保存二维码'),
          ),
        ],
      );
    },
  );
}
