import 'package:material_ui/material_ui.dart';

import '../domain/matters.dart';
import '../domain/schedule.dart';
import 'common.dart';

class MattersPage extends StatefulWidget {
  const MattersPage({super.key, required this.controller});
  final DormController controller;

  @override
  State<MattersPage> createState() => _MattersPageState();
}

class _MattersPageState extends State<MattersPage> {
  var _selected = MatterStatus.open;
  var _archived = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final matters = widget.controller.repository.matters();
      final active = matters.where((matter) => !matter.archived);
      final archive = matters.where((matter) => matter.archived).toList();
      final lanes = {
        for (final status in MatterStatus.values)
          status: active.where((matter) => matter.status == status).toList(),
      };
      return PageBody(
        storageKey: 'matters',
        children: [
          PageHeading(
            '寝室事务',
            '记录报修、活动准备和其他需要跟进的事。',
            actions: [
              FilledButton.icon(
                onPressed: () => _editMatter(context, widget.controller),
                icon: const Icon(Icons.add),
                label: const Text('新建事务'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: Text('归档（${archive.length}）'),
                avatar: const Icon(Icons.archive_outlined, size: 18),
                selected: _archived,
                onSelected: (value) => setState(() => _archived = value),
              ),
            ),
          ),
          if (_archived)
            _lane(archive, '还没有归档的事务')
          else
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 790) {
                  return Row(
                    spacing: 12,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final status in MatterStatus.values)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 8,
                            children: [
                              Text(
                                '${status.label} · ${lanes[status]!.length}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              _lane(lanes[status]!, '暂无${status.label}事务'),
                            ],
                          ),
                        ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final status in MatterStatus.values)
                          ChoiceChip(
                            label: Text(
                              '${status.label} · ${lanes[status]!.length}',
                            ),
                            selected: _selected == status,
                            onSelected: (_) =>
                                setState(() => _selected = status),
                          ),
                      ],
                    ),
                    _lane(lanes[_selected]!, '暂无${_selected.label}事务'),
                  ],
                );
              },
            ),
        ],
      );
    },
  );

  Widget _lane(List<Matter> matters, String empty) => matters.isEmpty
      ? Card(
          child: Padding(padding: const EdgeInsets.all(14), child: Text(empty)),
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            for (final matter in matters)
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  title: Text(
                    matter.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: _MatterMeta(matter),
                  trailing: matter.urgent
                      ? const Tooltip(
                          message: '优先处理',
                          child: Icon(Icons.priority_high),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () =>
                      _showMatter(context, widget.controller, matter.id),
                ),
              ),
          ],
        );
}

class _MatterMeta extends StatelessWidget {
  const _MatterMeta(this.matter);
  final Matter matter;

  @override
  Widget build(BuildContext context) {
    final due = matter.dueDay;
    final overdue =
        due != null &&
        !matter.archived &&
        matter.status != MatterStatus.done &&
        due.compareTo(dayKey(today())) < 0;
    return Wrap(
      spacing: 10,
      children: [
        Text(matter.owner ?? '未指派'),
        if (due != null)
          Text(
            overdue ? '已逾期 $due' : '截止 $due',
            style: overdue
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
      ],
    );
  }
}

Future<void> _editMatter(
  BuildContext context,
  DormController controller, [
  Matter? matter,
]) async {
  final choices = controller.repository
      .members()
      .where((member) => member.active || member.id == matter?.ownerId)
      .toList();
  var title = matter?.title ?? '';
  var note = matter?.note ?? '';
  var owner = matter?.ownerId ?? 0;
  var urgent = matter?.urgent ?? false;
  var due = DateTime.tryParse(matter?.dueDay ?? '');
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: matter == null ? '新建事务' : '编辑事务',
      fields: StatefulBuilder(
        builder: (context, update) => fieldColumn([
          textField('事务标题', title, (value) => title = value, autofocus: true),
          textField(
            '说明',
            note,
            (value) => note = value,
            required: false,
            limit: 600,
            maxLines: 3,
          ),
          DropdownButtonFormField<int>(
            initialValue: owner,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '负责人'),
            items: [
              const DropdownMenuItem(value: 0, child: Text('未指派')),
              for (final member in choices)
                DropdownMenuItem(
                  value: member.id,
                  child: Text(member.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => update(() => owner = value ?? 0),
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined),
                label: Text(due == null ? '设置截止日期' : '截止 ${dayKey(due!)}'),
                onPressed: () async {
                  final selected = await showDatePicker(
                    context: context,
                    initialDate: due ?? DateTime.now(),
                    firstDate: DateTime(1900),
                    lastDate: DateTime(9999, 12, 31),
                  );
                  if (selected != null && context.mounted) {
                    update(() => due = selected);
                  }
                },
              ),
              if (due != null)
                TextButton(
                  onPressed: () => update(() => due = null),
                  child: const Text('清除日期'),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('优先处理'),
            value: urgent,
            onChanged: (value) => update(() => urgent = value),
          ),
        ]),
      ),
      onSave: () => controller.write(
        () => controller.repository.saveMatter((
          title: title,
          note: note,
          ownerId: owner == 0 ? null : owner,
          due: due,
          urgent: urgent,
        ), id: matter?.id),
      ),
    ),
  );
  if (saved == true && context.mounted) notify(context, '事务已保存');
}

Future<void> _showMatter(
  BuildContext context,
  DormController controller,
  int id,
) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final matter = controller.repository
          .matters()
          .where((m) => m.id == id)
          .firstOrNull;
      if (matter == null) {
        return AlertDialog(
          title: const Text('事务已不存在'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      }
      final completed = matter.completedAt;
      return AlertDialog(
        scrollable: true,
        title: Text(matter.title),
        content: SizedBox(
          width: 490,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              Text(
                matter.archived
                    ? '${matter.status.label} · 已归档'
                    : matter.status.label,
              ),
              _MatterMeta(matter),
              if (matter.urgent) const Text('优先处理'),
              if (matter.note.isNotEmpty) SelectableText(matter.note),
              if (completed != null)
                Text('完成于 ${localTime(context, completed)}'),
              if (!matter.archived)
                DropdownButtonFormField<MatterStatus>(
                  key: ValueKey(matter.status),
                  initialValue: matter.status,
                  decoration: const InputDecoration(labelText: '更新状态'),
                  items: [
                    for (final status in MatterStatus.values)
                      DropdownMenuItem(
                        value: status,
                        child: Text(status.label),
                      ),
                  ],
                  onChanged: (status) {
                    if (status == null || status == matter.status) return;
                    perform(
                      context,
                      controller,
                      () => controller.repository.setMatterStatus(id, status),
                      '状态已更新',
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => perform(
              context,
              controller,
              () => controller.repository.archiveMatter(id, !matter.archived),
              matter.archived ? '已恢复事务' : '已归档事务',
            ),
            child: Text(matter.archived ? '恢复' : '归档'),
          ),
          if (!matter.archived)
            TextButton(
              onPressed: () => _editMatter(context, controller, matter),
              child: const Text('编辑'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  ),
);
