import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/cloud_proxy.dart';
import '../data/cloud_sync.dart';
import '../data/ssh_vault.dart';
import '../domain/cloud.dart';
import 'cloud_proxy_dialog.dart';
import 'common.dart';
import 'dorm_invite_dialog.dart';

class CloudSettingsPanel extends StatefulWidget {
  const CloudSettingsPanel({super.key, required this.cloud});

  final CloudSync cloud;

  @override
  State<CloudSettingsPanel> createState() => _CloudSettingsPanelState();
}

class _CloudSettingsPanelState extends State<CloudSettingsPanel> {
  CloudSync get cloud => widget.cloud;
  late Future<String?> _deviceKey = cloud.devicePublicKey();
  late Future<CloudProxy?> _proxy = cloud.readProxy();
  bool _openingInvite = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cloud,
    builder: (context, _) {
      final settings = cloud.settings;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text('GitHub 云同步', style: Theme.of(context).textTheme.titleLarge),
          _connectionCard(context, settings),
          _deviceKeyCard(context),
          _networkAndInvitesCard(settings != null),
        ],
      );
    },
  );

  Widget _connectionCard(BuildContext context, CloudSettings? settings) {
    final lastSync = cloud.lastSynced;
    final status = settings == null
        ? '尚未连接仓库'
        : cloud.busy
        ? '正在同步'
        : cloud.conflict != null
        ? '等待解决冲突'
        : cloud.error ?? '已配置自动同步';
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(cloud.busy ? Icons.sync : Icons.cloud_outlined),
            title: Text(status),
            subtitle: Text(
              lastSync == null
                  ? '同步到私有仓库的 $cloudBranch 分支'
                  : '最近成功 · ${MaterialLocalizations.of(context).formatCompactDate(lastSync)} '
                        '${TimeOfDay.fromDateTime(lastSync).format(context)}',
            ),
          ),
          if (settings != null) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link_outlined),
              title: const Text('仓库'),
              subtitle: SelectableText(settings.repository),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline),
              title: Text(settings.operator),
              subtitle: Text(
                [
                  if (settings.email.isNotEmpty) settings.email,
                  settings.useDeviceKey ? '设备 SSH 密钥' : '导入的 SSH 密钥',
                ].join(' · '),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (settings == null)
                  FilledButton.icon(
                    onPressed: () => _edit(context),
                    icon: const Icon(Icons.add_link),
                    label: const Text('配置仓库'),
                  )
                else ...[
                  if (cloud.conflict != null)
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => CloudConflictPage(cloud: cloud),
                        ),
                      ),
                      icon: const Icon(Icons.merge_type),
                      label: const Text('解决冲突'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: cloud.busy ? null : cloud.sync,
                      icon: const Icon(Icons.sync),
                      label: const Text('立即同步'),
                    ),
                  OutlinedButton(
                    onPressed: cloud.busy ? null : () => _edit(context),
                    child: const Text('编辑配置'),
                  ),
                  TextButton(
                    onPressed: cloud.busy ? null : () => _disconnect(context),
                    child: const Text('断开连接'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _networkAndInvitesCard(bool hasRepository) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<CloudProxy?>(
          future: _proxy,
          builder: (context, snapshot) => ListTile(
            leading: const Icon(Icons.settings_ethernet_outlined),
            title: const Text('代理设置'),
            subtitle: Text(
              snapshot.hasError
                  ? '无法读取代理设置'
                  : snapshot.connectionState != ConnectionState.done
                  ? '正在读取设置'
                  : snapshot.data?.kind.label ?? '直连',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await editCloudProxy(context, cloud);
              if (!mounted) return;
              setState(() {
                _proxy = cloud.readProxy();
              });
            },
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('仓库邀请', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _openingInvite || cloud.busy
                        ? null
                        : () => _importInvite(context),
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('导入 .dorm'),
                  ),
                  if (hasRepository)
                    OutlinedButton.icon(
                      onPressed: _openingInvite
                          ? null
                          : () => _exportInvite(context),
                      icon: const Icon(Icons.ios_share_outlined),
                      label: const Text('导出 .dorm'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _deviceKeyCard(BuildContext context) => FutureBuilder<String?>(
    future: _deviceKey,
    builder: (context, snapshot) {
      final publicKey = snapshot.data;
      final loading = snapshot.connectionState != ConnectionState.done;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设备 SSH 密钥', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (loading)
                const LinearProgressIndicator()
              else if (snapshot.hasError)
                Text(errorText(snapshot.error!, fallback: '无法读取或生成设备密钥'))
              else if (publicKey == null)
                const Text('在本机生成 Ed25519 密钥。生成后可复制公钥，私钥由 Dorm 保存。')
              else ...[
                const Text(
                  '将公钥添加到 GitHub 仓库的 Deploy keys，并勾选 Allow write access。',
                ),
                const SizedBox(height: 8),
                Text(
                  _maskedPublicKey(publicKey),
                  key: const ValueKey('masked-ssh-key'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
              if (!loading) ...[
                const SizedBox(height: 8),
                if (publicKey == null)
                  FilledButton.tonalIcon(
                    onPressed: () => setState(() {
                      _deviceKey = cloud.generateDevicePublicKey();
                    }),
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('生成 SSH 密钥'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () => _copyPublicKey(context, publicKey),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('复制公钥'),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );

  String _maskedPublicKey(String key) {
    const mask = '********';
    final parts = key.split(' ');
    if (parts.length < 2) return mask;
    final data = parts[1];
    if (data.length <= 12) return '${parts.first} $mask';
    final prefix = data.substring(0, 6);
    final suffix = data.substring(data.length - 6);
    return '${parts.first} $prefix$mask$suffix';
  }

  Future<void> _copyPublicKey(BuildContext context, String publicKey) async {
    try {
      await Clipboard.setData(ClipboardData(text: publicKey));
      if (context.mounted) notify(context, '已复制 SSH 公钥');
    } catch (_) {
      if (context.mounted) notify(context, '无法复制完整公钥，请重试');
    }
  }

  Future<void> _importInvite(BuildContext context) async {
    setState(() => _openingInvite = true);
    try {
      final invite = await chooseDormInvite(context);
      if (invite != null && context.mounted) {
        await _edit(context, invite: invite);
      }
    } catch (error) {
      if (context.mounted) {
        notify(context, errorText(error, fallback: '无法读取 .dorm 邀请'));
      }
    } finally {
      if (mounted) setState(() => _openingInvite = false);
    }
  }

  Future<void> _exportInvite(BuildContext context) async {
    setState(() => _openingInvite = true);
    try {
      final saved = await writeDormInvite(context, cloud);
      if (saved && context.mounted) notify(context, '已保存 .dorm 邀请');
    } catch (error) {
      if (context.mounted) {
        notify(context, errorText(error, fallback: '无法保存 .dorm 邀请'));
      }
    } finally {
      if (mounted) setState(() => _openingInvite = false);
    }
  }

  Future<void> _edit(BuildContext context, {ImportedDormInvite? invite}) async {
    final publicKey = await _deviceKey.then(
      (key) => key,
      onError: (Object _) => null,
    );
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _CloudEditor(
        cloud: cloud,
        hasDeviceKey: publicKey != null,
        invite: invite,
      ),
    );
  }

  Future<void> _disconnect(BuildContext context) async {
    if (!await confirm(
      context,
      '断开云同步',
      '本机数据、设备密钥和 GitHub 分支会保留。导入到此仓库的私钥会从这台设备移除。',
      action: '断开连接',
    )) {
      return;
    }
    try {
      await cloud.disconnect();
    } catch (error) {
      if (context.mounted) notify(context, errorText(error));
    }
  }
}

class _CloudEditor extends StatefulWidget {
  const _CloudEditor({
    required this.cloud,
    required this.hasDeviceKey,
    this.invite,
  });

  final CloudSync cloud;
  final bool hasDeviceKey;
  final ImportedDormInvite? invite;

  @override
  State<_CloudEditor> createState() => _CloudEditorState();
}

class _CloudEditorState extends State<_CloudEditor> {
  late final _address = TextEditingController(
    text: widget.invite?.repository ?? widget.cloud.settings?.repository,
  );
  late final _operator = TextEditingController(
    text: widget.cloud.settings?.operator,
  );
  late final _email = TextEditingController(text: widget.cloud.settings?.email);
  final _passphrase = TextEditingController();
  late bool _useDeviceKey = widget.invite == null
      ? widget.cloud.settings?.useDeviceKey ?? widget.hasDeviceKey
      : widget.invite?.key == null && widget.hasDeviceKey;
  String? _key;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _address.dispose();
    _operator.dispose();
    _email.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    if (text == null ||
        text.length > 24 * 1024 ||
        !text.trimLeft().startsWith('-----BEGIN OPENSSH PRIVATE KEY-----')) {
      setState(() => _error = '请先复制完整的 OpenSSH 私钥');
    } else {
      setState(() {
        _key = text;
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final settings = CloudSettings(
        repository: _address.text,
        operator: _operator.text,
        email: _email.text,
        useDeviceKey: _useDeviceKey,
      );
      final key = _useDeviceKey
          ? null
          : widget.invite?.key ??
                (_key == null ? null : CloudKey(_key!, _passphrase.text));
      if (!_useDeviceKey && key == null && _passphrase.text.isNotEmpty) {
        setState(() => _error = '更改口令时请同时粘贴私钥');
        return;
      }
      final currentRepository = widget.cloud.settings?.repository;
      if (currentRepository != null &&
          currentRepository != settings.repository) {
        final accepted = await confirm(
          context,
          '切换同步仓库',
          '当前本机数据将用于与新仓库同步。若新仓库为空，Dorm 会上传当前账本、排班和物资。',
          action: '切换并同步',
        );
        if (!mounted || !accepted) return;
      }
      await widget.cloud.configure(settings, key);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _error = errorText(error, fallback: '未能保存云同步配置'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _normalized(String input) {
    try {
      return githubSshAddress(input);
    } on Exception {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('配置 GitHub 云同步'),
    scrollable: true,
    content: SizedBox(
      width: 540,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _address,
            enabled: !_saving,
            readOnly: widget.invite != null,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'GitHub 仓库地址',
              hintText: 'https://github.com/账号/仓库',
            ),
          ),
          if (_normalized(_address.text) case final ssh?)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(ssh)),
          const SizedBox(height: 12),
          TextField(
            controller: _operator,
            enabled: !_saving,
            decoration: const InputDecoration(labelText: '操作者名称'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            enabled: !_saving,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Git 提交邮箱（可留空）'),
          ),
          const SizedBox(height: 12),
          if (widget.hasDeviceKey || _useDeviceKey)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用设备 SSH 密钥'),
              value: _useDeviceKey,
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _useDeviceKey = value!;
                      _error = null;
                    }),
            ),
          if (!_useDeviceKey && widget.invite?.key != null)
            const Text('已解锁邀请中的 SSH 私钥')
          else if (!_useDeviceKey) ...[
            OutlinedButton.icon(
              onPressed: _saving ? null : _paste,
              icon: const Icon(Icons.key_outlined),
              label: Text(_key == null ? '粘贴 SSH 私钥' : '已粘贴私钥 · 重新粘贴'),
            ),
            if (_key == null &&
                widget.cloud.settings?.repository ==
                    _normalized(_address.text) &&
                widget.cloud.settings?.useDeviceKey == false)
              const Text('留空会保留现有私钥。'),
            const SizedBox(height: 8),
            TextField(
              controller: _passphrase,
              enabled: !_saving,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'SSH 私钥口令（可留空）'),
            ),
          ],
          const SizedBox(height: 10),
          if (widget.invite != null &&
              widget.invite?.key == null &&
              !widget.hasDeviceKey)
            const Text('此邀请仅提供仓库地址。你可以粘贴私钥，也可以返回生成设备密钥。')
          else
            const Text('操作者名称及邮箱将写入提交记录。'),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? '连接中…' : '保存并同步'),
      ),
    ],
  );
}

class CloudConflictPage extends StatefulWidget {
  const CloudConflictPage({super.key, required this.cloud});

  final CloudSync cloud;

  @override
  State<CloudConflictPage> createState() => _CloudConflictPageState();
}

class _CloudConflictPageState extends State<CloudConflictPage> {
  final _choices = <int, CloudSide>{};
  CloudConflict? _shown;
  String? _error;

  Future<void> _resolve(CloudSide? entire) async {
    if (entire != null &&
        !await confirm(
          context,
          '确认保留整份版本',
          entire == CloudSide.local
              ? '本机版本将提交到 GitHub，云端历史可在 Git 中查看。'
              : '本机未上传的改动将被云端版本覆盖。',
          action: '确认保留',
        )) {
      return;
    }
    if (!mounted) return;
    try {
      await widget.cloud.resolve(choices: _choices, entire: entire);
      if (mounted && widget.cloud.conflict == null) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _error = errorText(error, fallback: '无法应用该版本，请重新选择'));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('解决同步冲突')),
    body: ListenableBuilder(
      listenable: widget.cloud,
      builder: (context, _) {
        final conflict = widget.cloud.conflict;
        if (conflict == null) return const Center(child: Text('当前没有待处理的冲突'));
        if (!identical(_shown, conflict)) {
          _shown = conflict;
          _choices.clear();
          _error = null;
        }
        final rows = conflict.merge?.conflicts ?? [];
        final author = conflict.remote?.author;
        final busy = widget.cloud.busy;
        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: rows.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return PageHeading(
                '同步冲突',
                author == null
                    ? conflict.message
                    : '${conflict.message}。最近云端提交者：$author',
              );
            }
            if (index == rows.length + 1) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_error case final error?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (rows.isNotEmpty)
                          FilledButton(
                            onPressed: busy || _choices.length != rows.length
                                ? null
                                : () => _resolve(null),
                            child: const Text('应用逐条选择'),
                          ),
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => _resolve(CloudSide.local),
                          child: const Text('保留整份本机版本'),
                        ),
                        if (conflict.remote != null)
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => _resolve(CloudSide.remote),
                            child: const Text('保留整份云端版本'),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }
            final row = rows[index - 1];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row.table.label} · ${row.local?['title'] ?? row.local?['name'] ?? row.remote?['title'] ?? row.remote?['name'] ?? row.local?['day'] ?? row.remote?['day'] ?? row.key.split('/').first.substring(0, 8)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        '本机：${_summary(row, row.local, conflict.local)}',
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        '云端：${_summary(row, row.remote, conflict.remote!.data)}',
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final side in CloudSide.values)
                            ChoiceChip(
                              label: Text(
                                side == CloudSide.local ? '保留本机' : '保留云端',
                              ),
                              selected: _choices[index - 1] == side,
                              onSelected: busy
                                  ? null
                                  : (_) => setState(
                                      () => _choices[index - 1] = side,
                                    ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );

  String _summary(
    CloudRowConflict conflict,
    CloudRow? row,
    CloudSnapshot snapshot,
  ) {
    if (row == null) return '已删除';
    const fields = {
      'name': '名称',
      'title': '标题',
      'active': '启用',
      'category': '分类',
      'quantity': '数量',
      'location': '位置',
      'note': '备注',
      'status': '状态',
      'deleted': '删除',
      'total': '总额（分）',
      'payer_id': '付款人',
      'created_at': '创建时间',
      'supply_id': '关联物资',
      'supply_name': '物资名称',
      'bill_id': '账单',
      'member_id': '成员',
      'amount': '金额（分）',
      'personal_amount': '个人费用（分）',
      'owner_id': '负责人',
      'due_day': '截止日期',
      'urgent': '优先处理',
      'archived': '已归档',
      'batch_id': '批量结算',
      'cadence': '频率',
      'next_day': '下次排班',
      'last_member_id': '上次指派',
      'task_id': '任务',
      'day': '日期',
      'completed_at': '完成时间',
    };
    return row.entries
        .map((entry) {
          final value = entry.value;
          final target = conflict.table.references[entry.key];
          final reference = target == null
              ? null
              : snapshot.tables[target]![value];
          final display =
              reference?['name'] ?? reference?['title'] ?? value ?? '—';
          return '${fields[entry.key] ?? entry.key} $display';
        })
        .join(' · ');
  }
}
