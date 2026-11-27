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
  if (invite.directKey case final direct?) {
    return (repository: invite.repository, key: direct);
  }
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
  final invite = await cloud.exportInvite(includeKey: true);
  final repository = invite.repository.split('/').last;
  final name = '${repository.substring(0, repository.length - 4)}.dorm';
  return saveDocument(
    XFile.fromData(invite.encode(), name: name),
    name: name,
    extension: 'dorm',
    label: 'Dorm 邀请',
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
