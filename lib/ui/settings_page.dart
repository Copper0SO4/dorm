import 'package:material_ui/material_ui.dart';

import 'chores_page.dart';
import 'cloud_page.dart';
import 'common.dart';
import 'members_dialog.dart';

class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.controller,
    required this.themeMode,
  });

  final DormController controller;
  final ValueNotifier<ThemeMode> themeMode;

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

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.controller, required this.themeMode});

  final DormController controller;
  final ValueNotifier<ThemeMode> themeMode;

  @override
  Widget build(BuildContext context) {
    final local = Column(
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
                Text('外观', style: Theme.of(context).textTheme.titleMedium),
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: themeMode,
                  builder: (context, mode, _) =>
                      DropdownButtonFormField<ThemeMode>(
                        initialValue: mode,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '主题'),
                        items: const [
                          DropdownMenuItem(
                            value: ThemeMode.system,
                            child: Text('跟随系统'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.light,
                            child: Text('浅色'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.dark,
                            child: Text('深色'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) themeMode.value = value;
                        },
                      ),
                ),
              ],
            ),
          ),
        ),
        Card(
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
        ),
      ],
    );
    final cloud = controller.cloud;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: PageBody(
          storageKey: 'settings',
          children: [
            if (cloud == null)
              local
            else
              LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 790
                    ? Row(
                        spacing: 24,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 300, child: local),
                          Expanded(child: CloudSettingsPanel(cloud: cloud)),
                        ],
                      )
                    : Column(
                        spacing: 24,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          local,
                          CloudSettingsPanel(cloud: cloud),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
