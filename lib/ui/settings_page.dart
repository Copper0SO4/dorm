import 'package:material_ui/material_ui.dart';

import '../app_identity.dart';
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

  Future<void> _confirmReset() async {
    final cloudSettings = widget.controller.cloud?.settings;
    var keepRepository = false;
    var clearRemote = false;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: const Text('清空数据与恢复出厂设置'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 10,
                  children: [
                    const Text(
                      '将永久清空本机所有成员、账单、转账、排班、物资、事务、认领及本地偏好设置，使 Dorm 恢复为初始空白状态。',
                    ),
                    if (cloudSettings != null) ...[
                      Text(
                        '当前已连接 GitHub 仓库：${cloudSettings.repository}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: keepRepository,
                        onChanged: (value) =>
                            update(() => keepRepository = value ?? false),
                        title: const Text('保留 GitHub 仓库地址与密钥配置'),
                        subtitle: const Text('恢复出厂后无需重新填写仓库和导入私钥'),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: clearRemote,
                        onChanged: (value) =>
                            update(() => clearRemote = value ?? false),
                        title: const Text('同时清空 GitHub 远程仓库内容'),
                        subtitle: const Text(
                          '清空远端 dormos-data 与在线牌桌分支内容；未勾选则不影响远端数据',
                        ),
                      ),
                    ],
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
                  child: const Text('确认清空'),
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
        notify(
          context,
          clearRemote ? '已清空本机数据并清空 GitHub 远程仓库' : '已清空本机数据并恢复出厂设置',
        );
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
            subtitle: const Text('清空本机所有数据与偏好，可选保留仓库地址并清空远程仓库'),
            trailing: Icon(Icons.warning_amber_rounded, color: errorColor),
            onTap: _saving ? null : _confirmReset,
          ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
