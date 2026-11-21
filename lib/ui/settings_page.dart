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
  data('本机数据', '账单 CSV 与数据库备份', Icons.storage_outlined),
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
        subtitle: const Text('编辑姓名和头像、启用或停用成员'),
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

  @override
  Widget build(BuildContext context) => Card(
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
        if (_saving) const LinearProgressIndicator(),
      ],
    ),
  );
}
