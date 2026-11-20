import 'package:material_ui/material_ui.dart';

import '../app_identity.dart';
import '../domain/models.dart';
import 'chores_page.dart';
import 'cloud_page.dart';
import 'common.dart';
import 'data_exports.dart';
import 'members_dialog.dart';

enum _Category {
  appearance('外观', '主题与本机偏好', Icons.palette_outlined),
  dorm('寝室管理', '成员与卫生任务', Icons.groups_outlined),
  sync('云同步', 'GitHub、SSH 密钥、代理与邀请', Icons.cloud_sync_outlined),
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
        _Category.dorm => _dorm(),
        _Category.sync => CloudSettingsPanel(cloud: controller.cloud!),
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

  Widget _appearance() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: ValueListenableBuilder<AppearanceMode>(
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
    ),
  );

  Widget _dorm() => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        ListTile(
          leading: const Icon(Icons.group_outlined),
          title: const Text('寝室成员'),
          subtitle: const Text('添加、改名或停用成员'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showMembers(context, controller),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.event_repeat_outlined),
          title: const Text('卫生任务'),
          subtitle: const Text('定义任务与轮换频率'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showChoreTasks(context, controller),
        ),
      ],
    ),
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
