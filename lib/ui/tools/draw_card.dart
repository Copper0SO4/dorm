import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/draw.dart';
import '../../domain/ledger.dart';
import '../common.dart';
import 'draw_ceremony.dart';
import 'group_board.dart';

class DrawCard extends StatefulWidget {
  const DrawCard({
    super.key,
    required this.mode,
    required this.members,
    required this.panelWidth,
  });

  final DrawMode mode;
  final List<String> members;
  final double panelWidth;

  @override
  State<DrawCard> createState() => _DrawCardState();
}

class _DrawCardState extends State<DrawCard>
    with SingleTickerProviderStateMixin {
  final _random = Random.secure();
  late final _motion = AnimationController(vsync: this)
    ..addStatusListener(_finish);
  late var _requested = _teams ? 2 : 1;
  List<String>? _custom;
  List<List<String>>? _pending;
  List<List<String>>? _result;
  String? _error;

  bool get _teams => widget.mode == DrawMode.teams;
  List<String> get _roster => _custom ?? widget.members;

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _finish(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    setState(() {
      _result = _pending;
      _pending = null;
    });
  }

  void _setOptions({required List<String>? roster, required int count}) {
    setState(() {
      _custom = roster;
      _requested = count;
      _result = null;
      _error = null;
    });
  }

  Future<void> _edit() async {
    var draft = _roster.join('\n');
    List<String>? applied;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => EditorDialog(
        title: _teams ? '编辑分组名单' : '编辑抽签名单',
        action: '使用名单',
        fields: TextFormField(
          initialValue: draft,
          minLines: 4,
          maxLines: 8,
          maxLength: 6200,
          decoration: const InputDecoration(
            labelText: '候选名单',
            helperText: '每行一个名字或选项，重复项会合并',
          ),
          onChanged: (text) => draft = text,
        ),
        onSave: () => applied = validateDrawEntries(drawEntries(draft)),
      ),
    );
    if (save == true && mounted) {
      _setOptions(roster: applied, count: _requested);
    }
  }

  void _run(int count) {
    if (_pending != null) return;
    try {
      final result = makeDraw(_roster, count, widget.mode, _random);
      final animate = !MediaQuery.disableAnimationsOf(context);
      setState(() {
        _error = null;
        _result = animate ? null : result;
        _pending = animate ? result : null;
      });
      if (animate) {
        _motion.duration = Duration(
          milliseconds: _teams ? 680 + min(660, _roster.length * 42) : 1400,
        );
        _motion.forward(from: 0);
      }
    } on InputException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _copy(List<List<String>> result) async {
    final text = _teams
        ? result.indexed
              .map((group) => '第 ${group.$1 + 1} 组  ${group.$2.join('、')}')
              .join('\n')
        : result.single.join('、');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) notify(context, '已复制结果');
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法复制结果'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final roster = _roster;
    final busy = _pending != null;
    final minimum = _teams ? 2 : 1;
    final limit = min(100, roster.length);
    final count = _requested.clamp(minimum, max(minimum, limit)).toInt();
    final valid = roster.length >= minimum && roster.length <= 100;
    final lower = roster.length ~/ count;
    final upper = lower + (roster.length % count == 0 ? 0 : 1);
    final controls = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _custom == null
                      ? '寝室成员 · ${roster.length} 人'
                      : '自定义名单 · ${roster.length} 项',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton.icon(
                  onPressed: busy ? null : _edit,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(roster.isEmpty ? '添加名单' : '编辑名单'),
                ),
              ],
            ),
            if (roster.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (final name in roster.take(8)) _label(name, colors),
                  if (roster.length > 8)
                    _label('+ ${roster.length - 8}', colors),
                ],
              ),
            if (_custom != null || !_teams)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (_custom != null)
                    ActionChip(
                      label: const Text('恢复室友名单'),
                      onPressed: busy
                          ? null
                          : () => _setOptions(roster: null, count: count),
                    ),
                  if (!_teams)
                    ActionChip(
                      label: const Text('今晚吃什么'),
                      onPressed: busy
                          ? null
                          : () => _setOptions(
                              roster: ['食堂', '麻辣烫', '饺子', '煲仔饭', '火锅'],
                              count: 1,
                            ),
                    ),
                ],
              ),
            const Divider(height: 1),
            if (valid)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(_teams ? '组数' : '抽取数量'),
                  IconButton.outlined(
                    tooltip: _teams ? '减少组数' : '减少抽取数量',
                    onPressed: busy || count <= minimum
                        ? null
                        : () => _setOptions(roster: _custom, count: count - 1),
                    icon: const Icon(Icons.remove),
                  ),
                  Semantics(
                    label: _teams ? '$count 组' : '抽取 $count 项',
                    excludeSemantics: true,
                    child: SizedBox(
                      width: 24,
                      child: Text('$count', textAlign: TextAlign.center),
                    ),
                  ),
                  IconButton.outlined(
                    tooltip: _teams ? '增加组数' : '增加抽取数量',
                    onPressed: busy || count >= limit
                        ? null
                        : () => _setOptions(roster: _custom, count: count + 1),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            if (_teams && valid)
              Text(lower == upper ? '每组 $lower 人' : '每组 $lower 至 $upper 人'),
            if (!valid)
              Text(
                roster.length > 100
                    ? '名单最多支持 100 项'
                    : _teams
                    ? '至少需要 2 名成员，可以编辑名单添加。'
                    : '添加一份名单即可抽签。',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            FilledButton.icon(
              onPressed: busy || !valid ? null : () => _run(count),
              icon: Icon(
                _teams ? Icons.group_work_outlined : Icons.style_outlined,
              ),
              label: Text(
                busy
                    ? (_teams ? '分组中…' : '抽签中…')
                    : _result == null
                    ? (_teams ? '开始分组' : '开始抽签')
                    : (_teams ? '重新分组' : '再抽一次'),
              ),
            ),
            if (_error case final error?)
              Semantics(
                liveRegion: true,
                child: Text(error, style: TextStyle(color: colors.error)),
              ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final content = _output(context);
        final form = SizedBox(
          width: min(widget.panelWidth, constraints.maxWidth),
          child: controls,
        );
        if (content == null) {
          return Align(alignment: Alignment.topLeft, child: form);
        }
        if (constraints.maxWidth >= widget.panelWidth + panelGap + 300) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: panelGap,
            children: [
              form,
              Expanded(child: content),
            ],
          );
        }
        return Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.panelWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: panelGap,
              children: [form, content],
            ),
          ),
        );
      },
    );
  }

  Widget? _output(BuildContext context) {
    if (_pending case final pending?) {
      return AnimatedBuilder(
        animation: _motion,
        builder: (context, _) => _teams
            ? GroupBoard(groups: pending, progress: _motion.value)
            : DrawCeremony(
                progress: _motion.value,
                resultLabel: pending.single.length == 1
                    ? pending.single.single
                    : '${pending.single.length} 项入选',
              ),
      );
    }
    if (_result case final result?) {
      return _teams
          ? GroupBoard(groups: result, progress: 1, onCopy: () => _copy(result))
          : Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        '抽签结果',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final name in result.single)
                          Chip(
                            label: Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _copy(result),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制结果'),
                      ),
                    ),
                  ],
                ),
              ),
            );
    }
    return null;
  }

  Widget _label(String name, ColorScheme colors) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}
