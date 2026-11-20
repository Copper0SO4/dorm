import 'package:material_ui/material_ui.dart';

import '../domain/models.dart';
import '../domain/schedule.dart';
import 'common.dart';
import 'members_dialog.dart';

class ChoresPage extends StatefulWidget {
  const ChoresPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<ChoresPage> createState() => _ChoresPageState();
}

class _ChoresPageState extends State<ChoresPage> {
  late DateTime _month = today();
  DateTime? _selected = today();
  String? _error;
  List<Shift> _shifts = [];

  DateTime get _start => DateTime.utc(_month.year, _month.month);
  DateTime get _end => DateTime.utc(_month.year, _month.month + 1, 0);

  @override
  void initState() {
    super.initState();
    _read();
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(_read);

  void _read() {
    final repository = widget.controller.repository;
    try {
      repository.generateShiftsThrough(_end);
      widget.controller.cloud?.changed();
      _shifts = repository.shifts(_start, _end);
      _error = null;
    } catch (error) {
      _shifts = [];
      _error = errorText(error, fallback: '暂时无法读取排班。');
    }
  }

  void _selectMonth(DateTime month) => setState(() {
    _month = month;
    final now = today();
    _selected = month.year == now.year && month.month == now.month ? now : null;
    _read();
  });

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final material = MaterialLocalizations.of(context);
    final now = today();
    final canGoForward = _start.isBefore(
      DateTime.utc(now.year, now.month + 12),
    );
    final visible = _selected == null
        ? _shifts
        : _shifts.where((shift) => shift.day == dayKey(_selected!)).toList();
    final counts = <String, int>{};
    final done = <String, int>{};
    for (final shift in _shifts) {
      counts.update(shift.day, (count) => count + 1, ifAbsent: () => 1);
      if (shift.completedAt != null) {
        done.update(shift.day, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final displayDay = _selected;
    final calendar = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '上个月',
                  onPressed: () =>
                      _selectMonth(DateTime.utc(_month.year, _month.month - 1)),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    material.formatMonthYear(_month),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '下个月',
                  onPressed: canGoForward
                      ? () => _selectMonth(
                          DateTime.utc(_month.year, _month.month + 1),
                        )
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _CalendarGrid(
              month: _start,
              selected: _selected,
              counts: counts,
              done: done,
              onSelect: (day) => setState(() => _selected = day),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                TextButton(
                  onPressed: () => _selectMonth(today()),
                  child: const Text('回到今天'),
                ),
                TextButton(
                  onPressed: _selected == null
                      ? null
                      : () => setState(() => _selected = null),
                  child: const Text('查看整月'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final timeline = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            displayDay == null
                ? '本月班次'
                : '${material.formatShortDate(displayDay)}的班次',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (_error != null)
          EmptyPanel(
            icon: Icons.error_outline,
            title: _error!,
            detail: '请重试。',
            action: TextButton(onPressed: _refresh, child: const Text('重试')),
          )
        else if (visible.isEmpty)
          const EmptyPanel(
            icon: Icons.event_available_outlined,
            title: '这段时间没有排班',
            detail: '可以选择其他日期，或在任务设置中添加轮换任务。',
          )
        else
          Column(
            spacing: 8,
            children: [
              for (final shift in visible)
                _ShiftCard(shift: shift, controller: controller),
            ],
          ),
      ],
    );
    return PageBody(
      storageKey: 'chores',
      children: [
        PageHeading(
          '卫生排班',
          '按日或按周轮换，查看负责成员和完成记录。',
          actions: [
            OutlinedButton.icon(
              onPressed: () => showMembers(context, controller),
              icon: const Icon(Icons.group_outlined),
              label: const Text('寝室成员'),
            ),
            FilledButton.icon(
              onPressed: () => showChoreTasks(context, controller),
              icon: const Icon(Icons.tune_outlined),
              label: const Text('任务设置'),
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 825
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 18,
                  children: [
                    Expanded(child: calendar),
                    Expanded(child: timeline),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 22,
                  children: [calendar, timeline],
                ),
        ),
      ],
    );
  }
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({
    required this.month,
    required this.selected,
    required this.counts,
    required this.done,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime? selected;
  final Map<String, int> counts;
  final Map<String, int> done;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final offset = month.weekday - 1;
    final length = DateTime.utc(month.year, month.month + 1, 0).day;
    final colors = Theme.of(context).colorScheme;
    return Table(
      children: [
        TableRow(
          children: [
            for (final label in ['一', '二', '三', '四', '五', '六', '日'])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        for (var row = 0; row < (offset + length + 6) ~/ 7; row++)
          TableRow(
            children: [
              for (var column = 0; column < 7; column++)
                _day(context, row * 7 + column - offset + 1, length),
            ],
          ),
      ],
    );
  }

  Widget _day(BuildContext context, int number, int length) {
    if (number < 1 || number > length) return const SizedBox(height: 49);
    final day = DateTime.utc(month.year, month.month, number);
    final colors = Theme.of(context).colorScheme;
    final key = dayKey(day);
    final count = counts[key] ?? 0;
    final completed = done[key] ?? 0;
    final isSelected = selected == day;
    final isToday = today() == day;
    final label =
        '${MaterialLocalizations.of(context).formatFullDate(day)}，$count 个班次，$completed 个已完成';
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        selected: isSelected,
        excludeSemantics: false,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSelect(day),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 48,
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: isSelected ? colors.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: isToday ? Border.all(color: colors.primary) : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 3,
              children: [
                Text(
                  '$number',
                  maxLines: 1,
                  style: TextStyle(
                    fontWeight: isSelected || isToday
                        ? FontWeight.w800
                        : FontWeight.w500,
                  ),
                ),
                SizedBox(
                  height: 7,
                  child: count == 0
                      ? null
                      : Icon(
                          completed == count
                              ? Icons.check_rounded
                              : Icons.circle,
                          size: 7,
                          color: colors.primary,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.shift, required this.controller});

  final Shift shift;
  final DormController controller;

  @override
  Widget build(BuildContext context) {
    final done = shift.completedAt != null;
    final canComplete = !done && shift.day.compareTo(dayKey(today())) <= 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 12,
              children: [
                IconTile(
                  done ? Icons.task_alt : Icons.cleaning_services_outlined,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        shift.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${shift.day} · ${shift.member}${shift.memberActive ? '' : '（已停用）'}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (done)
              Text('完成于 ${localTime(context, shift.completedAt!)}')
            else
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (canComplete)
                    FilledButton.tonalIcon(
                      onPressed: () => perform(
                        context,
                        controller,
                        () => controller.repository.completeShift(shift.id),
                        '打卡成功',
                      ),
                      icon: const Icon(Icons.check),
                      label: const Text('完成打卡'),
                    ),
                  OutlinedButton(
                    onPressed: () =>
                        _changeAssignment(context, controller, shift),
                    child: const Text('改派'),
                  ),
                  if (shift.memberActive)
                    TextButton(
                      onPressed: () => _swap(context, controller, shift),
                      child: const Text('交换班次'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _changeAssignment(
  BuildContext context,
  DormController controller,
  Shift shift,
) async {
  final candidates = controller.repository
      .members()
      .where((member) => member.active && member.id != shift.memberId)
      .toList();
  await _chooseAssignment(
    context,
    title: '改派班次',
    empty: '没有其他在用成员。',
    options: [
      for (final member in candidates) (id: member.id, label: member.name),
    ],
    onSave: (id) => controller.write(
      () => controller.repository.reassignShift(shift.id, id),
    ),
  );
}

Future<void> _swap(
  BuildContext context,
  DormController controller,
  Shift shift,
) async {
  final day = DateTime.parse('${shift.day}T00:00:00Z');
  final now = today();
  final through = (day.isAfter(now) ? day : now).add(const Duration(days: 35));
  final repository = controller.repository;
  try {
    repository.generateShiftsThrough(through);
    controller.cloud?.changed();
    final options = repository
        .shifts(day.subtract(const Duration(days: 35)), through)
        .where(
          (item) =>
              item.taskId == shift.taskId &&
              item.memberId != shift.memberId &&
              item.memberActive &&
              item.completedAt == null,
        );
    await _chooseAssignment(
      context,
      title: '交换班次',
      empty: '附近没有符合条件的待完成班次。',
      options: [
        for (final other in options)
          (id: other.id, label: '${other.day} · ${other.member}'),
      ],
      onSave: (id) =>
          controller.write(() => repository.swapShifts(shift.id, id)),
    );
  } catch (error) {
    if (context.mounted) notify(context, errorText(error));
  }
}

Future<void> _chooseAssignment(
  BuildContext context, {
  required String title,
  required String empty,
  required List<({int id, String label})> options,
  required ValueChanged<int> onSave,
}) async {
  if (options.isEmpty) {
    notify(context, empty);
    return;
  }
  var selected = options.first.id;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: title,
      fields: DropdownButtonFormField<int>(
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '更换为'),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option.id,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) => selected = value!,
      ),
      onSave: () => onSave(selected),
    ),
  );
  if (saved == true && context.mounted) notify(context, '班次已更新');
}

Future<void> showChoreTasks(BuildContext context, DormController controller) =>
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final tasks = controller.repository.chores();
          return AlertDialog(
            scrollable: true,
            title: const Text('卫生任务'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tasks.isEmpty) const Text('添加卫生任务后，Dorm 会按设定频率轮换。'),
                  for (final task in tasks)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(task.title),
                      subtitle: Text(
                        '${task.cadence.label}${task.active ? '' : ' · 已归档'}',
                      ),
                      trailing: task.active
                          ? PopupMenuButton<String>(
                              tooltip: '任务操作',
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('修改名称'),
                                ),
                                PopupMenuItem(
                                  value: 'archive',
                                  child: Text('归档任务'),
                                ),
                              ],
                              onSelected: (action) async {
                                if (action == 'edit') {
                                  await _editTask(context, controller, task);
                                } else if (await confirm(
                                      context,
                                      '归档任务',
                                      '归档后将取消今天起尚未完成的班次，已打卡及过去的班次仍可查询。',
                                      action: '归档',
                                    ) &&
                                    context.mounted) {
                                  perform(
                                    context,
                                    controller,
                                    () => controller.repository.archiveChore(
                                      task.id,
                                      today(),
                                    ),
                                    '任务已归档',
                                  );
                                }
                              },
                            )
                          : null,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
              FilledButton.icon(
                onPressed: () => _editTask(context, controller, null),
                icon: const Icon(Icons.add),
                label: const Text('添加任务'),
              ),
            ],
          );
        },
      ),
    );

Future<void> _editTask(
  BuildContext context,
  DormController controller,
  Chore? task,
) async {
  var title = task?.title ?? '';
  var cadence = task?.cadence ?? Cadence.weekly;
  var start = today();
  await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: task == null ? '添加卫生任务' : '修改任务名称',
      fields: StatefulBuilder(
        builder: (context, update) => fieldColumn([
          textField('任务名称', title, (value) => title = value, autofocus: true),
          if (task == null) ...[
            DropdownButtonFormField<Cadence>(
              decoration: const InputDecoration(labelText: '轮换频率'),
              initialValue: cadence,
              items: [
                for (final option in Cadence.values)
                  DropdownMenuItem(value: option, child: Text(option.label)),
              ],
              onChanged: (value) => cadence = value!,
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final first = today();
                final result = await showDatePicker(
                  context: context,
                  initialDate: start,
                  firstDate: first,
                  lastDate: first.add(const Duration(days: 365)),
                );
                if (result != null && context.mounted) {
                  update(() => start = civilDay(result));
                }
              },
              icon: const Icon(Icons.event_outlined),
              label: Text('开始日期 ${dayKey(start)}'),
            ),
          ],
        ]),
      ),
      onSave: () => controller.write(() {
        if (task == null) {
          controller.repository.addChore(title, cadence, start);
        } else {
          controller.repository.renameChore(task.id, title);
        }
      }),
    ),
  );
}
