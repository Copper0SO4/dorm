import 'package:material_ui/material_ui.dart';

class GroupBoard extends StatelessWidget {
  const GroupBoard({
    super.key,
    required this.groups,
    required this.progress,
    this.onCopy,
  });

  final List<List<String>> groups;
  final double progress;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final total = groups.fold(0, (sum, group) => sum + group.length);
    final time = progress * (total + 2);
    final assigned = time.ceil().clamp(0, total);
    final done = progress >= 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  liveRegion: done,
                  child: Text(
                    done ? '分组结果' : '正在分配成员',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Text(
                  done
                      ? '$total 人 · ${groups.length} 组'
                      : '$assigned / $total 人',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (!done)
              LinearProgressIndicator(
                value: assigned / total,
                semanticsLabel: '分组进度',
              ),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 10.0;
                final columns = constraints.maxWidth >= 540
                    ? 3
                    : constraints.maxWidth >= 276
                    ? 2
                    : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * gap) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final (groupIndex, members) in groups.indexed)
                      SizedBox(
                        width: width,
                        child: _Group(
                          index: groupIndex,
                          members: members,
                          groupCount: groups.length,
                          time: time,
                        ),
                      ),
                  ],
                );
              },
            ),
            if (onCopy case final copy?)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: copy,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('复制分组'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.index,
    required this.members,
    required this.groupCount,
    required this.time,
  });

  final int index;
  final List<String> members;
  final int groupCount;
  final double time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = [
      (colors.primaryContainer, colors.onPrimaryContainer),
      (colors.secondaryContainer, colors.onSecondaryContainer),
      (colors.tertiaryContainer, colors.onTertiaryContainer),
    ];
    final (surface, foreground) = palette[index % palette.length];
    final ready = time > index;
    return Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Text(
            '第 ${index + 1} 组',
            style: theme.textTheme.titleSmall?.copyWith(color: foreground),
          ),
          if (!ready)
            Text(
              '等待分配',
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            )
          else
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                for (final (slot, name) in members.indexed)
                  if (time > slot * groupCount + index)
                    _member(
                      name,
                      (time - slot * groupCount - index).clamp(0, 2) / 2,
                      colors,
                    ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _member(String name, double arrival, ColorScheme colors) {
    final settled = Curves.easeOutCubic.transform(arrival);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colors.surface,
      ),
      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    if (settled == 1) return chip;
    return Transform.translate(
      offset: Offset(0, -10 * (1 - settled)),
      child: Opacity(opacity: settled, child: chip),
    );
  }
}
