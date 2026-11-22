import 'package:material_ui/material_ui.dart';

import 'group_scene.dart';

class GroupBoard extends StatelessWidget {
  const GroupBoard({
    super.key,
    required this.groups,
    required this.animation,
    this.scene,
    this.onSkip,
    this.onCopy,
  });

  final List<List<String>> groups;
  final Animation<double> animation;
  final GroupScenePlan? scene;
  final VoidCallback? onSkip;
  final VoidCallback? onCopy;

  double get progress => onSkip == null ? 1 : animation.value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final total = groups.fold(0, (sum, group) => sum + group.length);
    final done = onSkip == null;
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
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    done ? '分组结果' : '正在分配成员',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (onSkip case final skip?)
                  TextButton(onPressed: skip, child: const Text('跳过动画'))
                else
                  Text(
                    '$total 人 · ${groups.length} 组',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (scene case final plan?)
              GroupScene(plan: plan, animation: animation, settled: done),
            if (scene case final plan? when !done)
              AnimatedBuilder(
                animation: animation,
                builder: (context, _) => _GroupProgress(
                  assigned: plan.assignedAt(animation.value),
                  total: total,
                ),
              ),
            if (done) _GroupResults(groups: groups, scene: scene),
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

class _GroupProgress extends StatelessWidget {
  const _GroupProgress({required this.assigned, required this.total});

  final int assigned;
  final int total;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 6,
    children: [
      LinearProgressIndicator(value: assigned / total, semanticsLabel: '分组进度'),
      Text(
        '已入组 $assigned / $total 人',
        style: Theme.of(context).textTheme.labelMedium,
      ),
    ],
  );
}

class _GroupResults extends StatelessWidget {
  const _GroupResults({required this.groups, required this.scene});

  final List<List<String>> groups;
  final GroupScenePlan? scene;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0;
      final maxColumns = constraints.maxWidth >= 540
          ? 3
          : constraints.maxWidth >= 276
          ? 2
          : 1;
      final columns = groups.length.clamp(1, maxColumns);
      final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final (index, members) in groups.indexed)
            SizedBox(
              width: width,
              child: _Group(
                index: index,
                members: members,
                accent: scene?.colorForGroup(index, groups.length),
              ),
            ),
        ],
      );
    },
  );
}

class _Group extends StatelessWidget {
  const _Group({
    required this.index,
    required this.members,
    required this.accent,
  });

  final int index;
  final List<String> members;
  final Color? accent;

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
    return Container(
      constraints: const BoxConstraints(minHeight: 84),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent == null
            ? surface
            : Color.alphaBlend(
                accent!.withValues(alpha: .15),
                colors.surfaceContainerHighest,
              ),
        border: accent == null
            ? null
            : Border.all(color: accent!.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            '第 ${index + 1} 组',
            style: theme.textTheme.titleSmall?.copyWith(
              color: accent == null ? foreground : colors.onSurface,
            ),
          ),
          Wrap(
            spacing: 5,
            runSpacing: 4,
            children: [
              for (final name in members)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: colors.surface,
                  ),
                  child: Text(name),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
