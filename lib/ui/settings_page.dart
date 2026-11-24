import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../app_identity.dart';
import '../data/data_location.dart';
import '../domain/ledger.dart';
import '../domain/models.dart';
import '../domain/preferences.dart';
import 'chores_page.dart';
import 'cloud_page.dart';
import 'common.dart';
import 'data_exports.dart';
import 'lan_settings.dart';
import 'members_dialog.dart';
import 'member_identity.dart';

enum _Category {
  appearance('外观', '主题与启动页面', Icons.palette_outlined),
  ledger('账本偏好', '月度预算、筛选和均摊方式', Icons.receipt_long_outlined),
  supplies('物资偏好', '库存提醒和补货阈值', Icons.inventory_2_outlined),
  dorm('寝室管理', '成员与卫生任务', Icons.groups_outlined),
  sync('云同步', 'GitHub、SSH 密钥、代理与邀请', Icons.cloud_sync_outlined),
  lan('局域网服务器', '浏览器访问与多人操作', Icons.lan_outlined),
  data('本机数据', '账单 CSV、数据库备份与清空重置', Icons.storage_outlined),
  about('关于 Dorm', '应用名称与用途', Icons.info_outline);

  const _Category(this.label, this.description, this.icon);
  final String label;
  final String description;
  final IconData icon;
}

class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.controller,
    required this.themeMode,
  });

  final DormController controller;
  final ValueNotifier<AppearanceMode> themeMode;

  @override
  Widget build(BuildContext context) {
    final cloud = controller.cloud;
    return ListenableBuilder(
      listenable: cloud ?? controller,
      builder: (context, _) => IconButton(
        tooltip: '设置',
        icon: Badge(
          isLabelVisible: cloud?.conflict != null || cloud?.error != null,
          child: const Icon(Icons.settings_outlined),
        ),
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                _SettingsPage(controller: controller, themeMode: themeMode),
          ),
        ),
      ),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.controller, required this.themeMode});
  final DormController controller;
  final ValueNotifier<AppearanceMode> themeMode;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  _Category _selected = _Category.appearance;
  DormController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final cloud = controller.cloud;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 830;
            return ListenableBuilder(
              listenable: cloud ?? controller,
              builder: (context, _) {
                final categories = [
                  for (final category in _Category.values)
                    if (category != _Category.sync || cloud != null) category,
                ];
                final attention =
                    cloud?.conflict != null || cloud?.error != null;
                if (!wide) {
                  return PageBody(
                    storageKey: 'settings-categories',
                    children: [
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (final category in categories) ...[
                              if (category != categories.first)
                                const Divider(
                                  height: 1,
                                  indent: 16,
                                  endIndent: 16,
                                ),
                              ListTile(
                                leading: _icon(category, attention),
                                title: Text(category.label),
                                subtitle: Text(category.description),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (context) => Scaffold(
                                      appBar: AppBar(
                                        title: Text(category.label),
                                      ),
                                      body: SafeArea(
                                        top: false,
                                        child: _detail(category),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    SizedBox(
                      width: 232,
                      child: Material(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                          children: [
                            for (final category in categories)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: ListTile(
                                  leading: _icon(category, attention),
                                  title: Text(category.label),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  selected: _selected == category,
                                  selectedTileColor: Theme.of(context)
                                      .colorScheme
                                      .secondaryContainer,
                                  onTap: () =>
                                      setState(() => _selected = category),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _detail(_selected, showHeading: true)),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _icon(_Category category, bool attention) => Badge(
    isLabelVisible: category == _Category.sync && attention,
    child: Icon(category.icon),
  );

  Widget _detail(_Category category, {bool showHeading = false}) => PageBody(
    storageKey: 'settings-${category.name}',
    children: [
      if (showHeading) PageHeading(category.label, category.description),
      switch (category) {
        _Category.appearance => _appearance(),
        _Category.ledger => _ledgerPreferences(),
        _Category.supplies => _supplyPreferences(),
        _Category.dorm => _dorm(),
        _Category.sync => CloudSettingsPanel(cloud: controller.cloud!),
        _Category.lan => LanSettings(controller: controller),
        _Category.data => _DataSettings(controller: controller),
        _Category.about => const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text(dormFullName),
            subtitle: Text('寝室账本、卫生排班与公共物资管理'),
          ),
        ),
      },
    ],
  );

  Widget _withPreferences(List<Widget> Function(DormPreferences) fields) =>
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: fieldColumn(fields(controller.repository.preferences)),
          ),
        ),
      );

  void _updatePreferences(DormPreferences Function(DormPreferences) update) {
    try {
      controller.updatePreferences(update);
    } catch (error) {
      notify(context, errorText(error, fallback: '无法保存设置'));
    }
  }

  Widget _choice<T extends Enum>(
    String label,
    T selected,
    List<T> values,
    String Function(T) text,
    ValueChanged<T> changed,
  ) => DropdownButtonFormField<T>(
    initialValue: selected,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final option in values)
        DropdownMenuItem(value: option, child: Text(text(option))),
    ],
    onChanged: (value) {
      if (value != null) changed(value);
    },
  );

  Widget _appearance() => _withPreferences(
    (preferences) => [
      ValueListenableBuilder<AppearanceMode>(
        valueListenable: widget.themeMode,
        builder: (context, mode, _) => DropdownButtonFormField<AppearanceMode>(
          key: ValueKey(mode),
          initialValue: mode,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '主题'),
          items: const [
            DropdownMenuItem(value: AppearanceMode.system, child: Text('跟随系统')),
            DropdownMenuItem(value: AppearanceMode.light, child: Text('浅色')),
            DropdownMenuItem(value: AppearanceMode.dark, child: Text('深色')),
          ],
          onChanged: (value) {
            if (value == null) return;
            try {
              controller.repository.saveAppearanceMode(value);
              widget.themeMode.value = value;
            } catch (error) {
              notify(context, errorText(error, fallback: '无法保存主题'));
            }
          },
        ),
      ),
      _choice(
        '默认启动页面',
        preferences.startupPage,
        StartupPage.values,
        (page) => page.label,
        (page) =>
            _updatePreferences((value) => value.copyWith(startupPage: page)),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            preferences.einkMode ? '主题调色板（墨水屏模式下已切换为纯黑白）' : '主题调色板',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final palette in ThemePalette.values)
                ChoiceChip(
                  avatar: CircleAvatar(
                    backgroundColor: Color(palette.seedColor),
                    radius: 10,
                  ),
                  label: Text(palette.label),
                  selected: preferences.themePalette == palette,
                  onSelected: (_) => _updatePreferences(
                    (value) => value.copyWith(themePalette: palette),
                  ),
                ),
            ],
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('墨水屏模式'),
        subtitle: const Text('高对比度纯黑白、锐利边框并禁用过渡动画以减少残影'),
        value: preferences.einkMode,
        onChanged: (enabled) =>
            _updatePreferences((value) => value.copyWith(einkMode: enabled)),
      ),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('界面缩放', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '75% - 150%，PC 端支持 Ctrl +/- 与 Ctrl 0',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '缩小界面',
            onPressed: preferences.uiScale <= minUiScale + 0.001
                ? null
                : () => controller.adjustUiScale(-1),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Tooltip(
            message: '重置为 100%',
            child: TextButton(
              onPressed: (preferences.uiScale - 1.0).abs() < 0.001
                  ? null
                  : controller.resetUiScale,
              child: Text('${(preferences.uiScale * 100).round()}%'),
            ),
          ),
          IconButton(
            tooltip: '放大界面',
            onPressed: preferences.uiScale >= maxUiScale - 0.001
                ? null
                : () => controller.adjustUiScale(1),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    ],
  );

  Widget _ledgerPreferences() => _withPreferences(
    (preferences) => [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('月度公共预算'),
        subtitle: Text(
          preferences.monthlyBudget == 0
              ? '未设置 · 仅统计公共支出'
              : '${formatCents(preferences.monthlyBudget)} · 按自然月统计',
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _editNumber(
          label: '月度公共预算（元）',
          initial: preferences.monthlyBudget == 0
              ? ''
              : formatCents(preferences.monthlyBudget).substring(1),
          hint: '留空可清除预算',
          parse: (text) => text.isEmpty ? 0 : parseCents(text),
          update: (p, amount) => p.copyWith(monthlyBudget: amount),
        ),
      ),
      _choice(
        '进入账本时的筛选',
        preferences.ledgerFilter,
        LedgerFilter.values,
        (filter) => filter.label,
        (filter) =>
            _updatePreferences((value) => value.copyWith(ledgerFilter: filter)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('新建账单时默认全选均摊成员'),
        value: preferences.selectAllParticipants,
        onChanged: (enabled) => _updatePreferences(
          (value) => value.copyWith(selectAllParticipants: enabled),
        ),
      ),
    ],
  );

  Widget _supplyPreferences() => _withPreferences(
    (preferences) => [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('低库存提醒'),
        subtitle: const Text('达到阈值时在采购清单中显示物资'),
        value: preferences.stockAlerts,
        onChanged: (enabled) =>
            _updatePreferences((value) => value.copyWith(stockAlerts: enabled)),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('低库存阈值'),
        subtitle: Text('库存小于或等于 ${preferences.stockThreshold} 件时提醒'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _editNumber(
          label: '低库存阈值',
          initial: preferences.stockThreshold.toString(),
          hint: '0 至 999999 的整数',
          parse: (text) {
            final value = int.tryParse(text);
            return value != null && value >= 0 && value <= maxStockQuantity
                ? value
                : null;
          },
          update: (p, quantity) => p.copyWith(stockThreshold: quantity),
        ),
      ),
    ],
  );

  Future<void> _editNumber({
    required String label,
    required String initial,
    required String hint,
    required int? Function(String) parse,
    required DormPreferences Function(DormPreferences, int) update,
  }) => showDialog<void>(
    context: context,
    builder: (context) {
      var text = initial;
      return EditorDialog(
        title: label,
        fields: TextFormField(
          autofocus: true,
          initialValue: initial,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, helperText: hint),
          onChanged: (value) => text = value.trim(),
          validator: (value) =>
              parse((value ?? '').trim()) == null ? '请输入有效数字' : null,
        ),
        onSave: () =>
            controller.updatePreferences((p) => update(p, parse(text)!)),
      );
    },
  );

  Widget _dorm() => _withPreferences(
    (preferences) => [
      ListTile(
        leading: const Icon(Icons.group_outlined),
        title: const Text('寝室成员'),
        subtitle: const Text('编辑姓名和头像、启用、停用或删除成员'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showMembers(context, controller),
      ),
      for (final member in controller.repository.members())
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: MemberAvatar(name: member.name, avatar: member.avatar),
          title: Text(member.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              const Text('成员身份码'),
              SelectableText(
                member.identityCode,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
              if (member.deviceCode case final code?) ...[
                const Text('认领设备码'),
                DeviceCode(code),
              ] else
                Text(member.active ? '待认领' : '已停用'),
            ],
          ),
          trailing: IconButton(
            tooltip: '修改日志',
            onPressed: () => showMemberActivity(context, controller, member),
            icon: const Icon(Icons.history),
          ),
          onTap: () => editMember(context, controller, member),
        ),
      const Divider(height: 1),
      Text('本机设备码', style: Theme.of(context).textTheme.titleSmall),
      DeviceCode(controller.repository.identity.deviceCode),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.event_repeat_outlined),
        title: const Text('卫生任务'),
        subtitle: const Text('定义任务与轮换频率'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showChoreTasks(context, controller),
      ),
      _choice(
        '进入事务时的视图',
        preferences.matterView,
        MatterView.values,
        (view) => view.label,
        (view) =>
            _updatePreferences((value) => value.copyWith(matterView: view)),
      ),
    ],
  );
}

class _DataSettings extends StatefulWidget {
  const _DataSettings({required this.controller});
  final DormController controller;

  @override
  State<_DataSettings> createState() => _DataSettingsState();
}

class _DataSettingsState extends State<_DataSettings> {
  bool _saving = false;

  Future<void> _save(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseDirectory(DormDataLocation location) => _save(() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: location.directory.parent.path,
        confirmButtonText: '在此创建 Dorm 目录',
        canCreateDirectories: true,
      );
      if (path == null || !mounted) return;
      await location.schedule(Directory(path));
      if (mounted) notify(context, '已保存。关闭所有 Dorm 窗口后重新打开即可迁移。');
    } catch (error) {
      if (mounted) {
        notify(context, errorText(error, fallback: '无法保存新目录，请检查访问权限。'));
      }
    }
  });

  Future<void> _cancelMigration(DormDataLocation location) => _save(() async {
    try {
      await location.cancel();
    } catch (error) {
      if (mounted) {
        notify(context, errorText(error, fallback: '无法取消迁移，请检查目录访问权限。'));
      }
    }
  });

  Future<void> _confirmReset() async {
    final cloudSettings = widget.controller.cloud?.settings;
    final hasRepository = cloudSettings != null;
    var keepRepository = false;
    var clearRemote = false;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: const Text('清空数据与恢复出厂设置'),
              scrollable: true,
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    const Text('本机的寝室数据、成员认领和偏好设置将被清空。'),
                    Text(
                      hasRepository
                          ? '当前 GitHub 仓库\n${cloudSettings.repository}'
                          : '尚未配置 GitHub 仓库。在「云同步」连接仓库后可使用以下选项。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: keepRepository,
                      onChanged: hasRepository
                          ? (value) =>
                                update(() => keepRepository = value ?? false)
                          : null,
                      title: const Text('保留仓库配置'),
                      subtitle: const Text('保留仓库地址和当前使用的 SSH 密钥。'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: clearRemote,
                      onChanged: hasRepository
                          ? (value) =>
                                update(() => clearRemote = value ?? false)
                          : null,
                      title: const Text('清空远程仓库的 Dorm 数据'),
                      subtitle: const Text('清空共享寝室数据和在线牌桌，影响该仓库的所有同步成员。'),
                    ),
                    if (keepRepository && !clearRemote)
                      const Text('下次同步时，仓库中已有的寝室数据会重新下载到本机。'),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(clearRemote ? '清空本机与远程' : '确认清空'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _save(() async {
      try {
        await widget.controller.resetFactory(
          keepRepository: keepRepository,
          clearRemote: clearRemote,
        );
        if (!mounted) return;
        notify(context, clearRemote ? '已清空本机和远程 Dorm 数据' : '已清空本机数据并恢复出厂设置');
      } catch (error) {
        if (!mounted) return;
        notify(
          context,
          errorText(error, fallback: '清空失败，请检查网络连接或 GitHub 仓库权限'),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (widget.controller.dataLocation case final location?) ...[
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('更换配置目录'),
              subtitle: Text(location.directory.path),
              trailing: const Icon(Icons.chevron_right),
              onTap: _saving ? null : () => _chooseDirectory(location),
            ),
            if (location.pending case final pending?)
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: Text(location.migrationError ?? '下次启动时迁移'),
                subtitle: Text(pending),
                trailing: TextButton(
                  onPressed: _saving ? null : () => _cancelMigration(location),
                  child: const Text('取消迁移'),
                ),
              ),
            const Divider(height: 1),
          ],
          ListTile(
            leading: const Icon(Icons.table_view_outlined),
            title: const Text('导出全部账单'),
            subtitle: const Text('CSV 包含付款人、金额、结算状态和关联物资'),
            trailing: const Icon(Icons.download_outlined),
            onTap: _saving
                ? null
                : () => _save(
                    () => exportBills(
                      context,
                      widget.controller.repository.bills(),
                    ),
                  ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.save_outlined),
            title: const Text('创建本地备份'),
            subtitle: const Text('备份成员、账单、寝室事务、排班及物资'),
            trailing: const Icon(Icons.download_outlined),
            onTap: _saving
                ? null
                : () => _save(
                    () => exportBackup(context, widget.controller.repository),
                  ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: errorColor),
            title: Text('清空数据与恢复出厂设置', style: TextStyle(color: errorColor)),
            subtitle: const Text('清空本机数据，并选择如何处理 GitHub 仓库'),
            trailing: Icon(Icons.warning_amber_rounded, color: errorColor),
            onTap: _saving ? null : _confirmReset,
          ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
