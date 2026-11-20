import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../data/cloud_sync.dart';
import '../data/dorm_invite.dart';
import '../data/ssh_vault.dart';
import '../domain/ledger.dart';
import 'common.dart';
import 'save_document.dart';

typedef ImportedDormInvite = ({String repository, CloudKey? key});

const _dormType = XTypeGroup(label: 'Dorm 邀请', extensions: ['dorm']);

Future<ImportedDormInvite?> chooseDormInvite(BuildContext context) async {
  final file = await openFile(
    acceptedTypeGroups: Platform.isAndroid ? const [] : const [_dormType],
  );
  if (file == null || !context.mounted) return null;
  if (!file.name.toLowerCase().endsWith('.dorm')) {
    throw const InputException('请选择 .dorm 文件');
  }
  final contents = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (contents.length + chunk.length > maxDormInviteBytes) {
      throw const InputException('.dorm 文件超过 64 KB');
    }
    contents.add(chunk);
  }
  if (!context.mounted) return null;
  return unlockDormInvite(context, DormInvite.read(contents.takeBytes()));
}

Future<ImportedDormInvite?> unlockDormInvite(
  BuildContext context,
  DormInvite invite,
) async {
  if (!invite.requiresPassword) {
    return (repository: invite.repository, key: null);
  }
  if (!context.mounted) return null;
  final key = await showDialog<CloudKey>(
    context: context,
    builder: (_) => _UnlockInviteDialog(invite),
  );
  return key == null ? null : (repository: invite.repository, key: key);
}

Future<bool> writeDormInvite(BuildContext context, CloudSync cloud) async {
  final invite = await showDialog<DormInvite>(
    context: context,
    builder: (_) => _ExportInviteDialog(cloud),
  );
  if (invite == null || !context.mounted) return false;
  final repository = invite.repository.split('/').last;
  final name = '${repository.substring(0, repository.length - 4)}.dorm';
  return saveDocument(
    XFile.fromData(invite.encode(), name: name),
    name: name,
    extension: 'dorm',
    label: 'Dorm 邀请',
  );
}

class _ExportInviteDialog extends StatefulWidget {
  const _ExportInviteDialog(this.cloud);

  final CloudSync cloud;

  @override
  State<_ExportInviteDialog> createState() => _ExportInviteDialogState();
}

class _ExportInviteDialogState extends State<_ExportInviteDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _includeKey = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_includeKey && _password.text != _confirmation.text) {
      setState(() => _error = '两次输入的口令不一致');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final invite = await widget.cloud.exportInvite(
        password: _includeKey ? _password.text : null,
      );
      if (mounted) Navigator.pop(context, invite);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = errorText(error, fallback: '无法导出邀请');
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导出 .dorm 邀请'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('邀请会带上仓库地址。接收方可使用自己的设备密钥。'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('用口令加密后共享当前 SSH 私钥'),
            value: _includeKey,
            onChanged: _saving
                ? null
                : (value) => setState(() {
                    _includeKey = value!;
                    _error = null;
                  }),
          ),
          if (_includeKey) ...[
            const Text('解锁后可使用此密钥访问仓库。请通过不同渠道发送文件和口令。'),
            const SizedBox(height: 12),
            _passwordField(_password, '邀请口令（至少 12 个字符）', !_saving),
            const SizedBox(height: 12),
            _passwordField(_confirmation, '确认邀请口令', !_saving),
          ],
          if (_error case final error?) _message(context, error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving ? null : _export,
        child: Text(_saving ? '加密中…' : '选择保存位置'),
      ),
    ],
  );
}

class _UnlockInviteDialog extends StatefulWidget {
  const _UnlockInviteDialog(this.invite);

  final DormInvite invite;

  @override
  State<_UnlockInviteDialog> createState() => _UnlockInviteDialogState();
}

class _UnlockInviteDialogState extends State<_UnlockInviteDialog> {
  final _password = TextEditingController();
  bool _unlocking = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _unlocking = true;
      _error = null;
    });
    try {
      final key = await widget.invite.unlock(_password.text);
      if (mounted) Navigator.pop(context, key);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = errorText(error, fallback: '无法解锁邀请');
          _unlocking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('解锁 .dorm 邀请'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.invite.repository),
          const SizedBox(height: 12),
          _passwordField(_password, '邀请口令', !_unlocking),
          if (_error case final error?) _message(context, error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _unlocking ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _unlocking ? null : _unlock,
        child: Text(_unlocking ? '解锁中…' : '解锁'),
      ),
    ],
  );
}

Widget _passwordField(
  TextEditingController password,
  String label,
  bool enabled,
) => TextField(
  controller: password,
  enabled: enabled,
  obscureText: true,
  autocorrect: false,
  enableSuggestions: false,
  decoration: InputDecoration(labelText: label),
);

Widget _message(BuildContext context, String error) => Padding(
  padding: const EdgeInsets.only(top: 12),
  child: Text(
    error,
    style: TextStyle(color: Theme.of(context).colorScheme.error),
  ),
);
