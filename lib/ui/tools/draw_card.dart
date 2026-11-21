import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/draw.dart';
import '../../domain/ledger.dart';
import '../common.dart';
import 'draw_ceremony.dart';

class DrawCard extends StatefulWidget {
  const DrawCard({
    super.key,
    required this.memberEntries,
    required this.showTitle,
  });

  final String Function() memberEntries;
  final bool showTitle;

  @override
  State<DrawCard> createState() => _DrawCardState();
}

class _DrawCardState extends State<DrawCard>
    with SingleTickerProviderStateMixin {
  final _random = Random.secure();
  final _count = TextEditingController(text: '1');
  late final _entries = TextEditingController(text: widget.memberEntries());
  late final _motion = AnimationController(vsync: this)
    ..addStatusListener(_finish);
  var _mode = DrawMode.draw;
  List<List<String>>? _pending;
  List<List<String>>? _result;
  String? _error;

  @override
  void dispose() {
    _motion.dispose();
    _entries.dispose();
    _count.dispose();
    super.dispose();
  }

  void _finish(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    setState(() {
      _result = _pending;
      _pending = null;
    });
  }

  void _forgetResult() {
    _result = null;
    _error = null;
  }

  void _preset(String entries) => setState(() {
    _entries.text = entries;
    _forgetResult();
  });

  void _draw() {
    if (_pending != null) return;
    try {
      final candidates = drawEntries(_entries.text);
      final result = makeDraw(
        candidates,
        int.tryParse(_count.text) ?? 0,
        _mode,
        _random,
      );
      FocusScope.of(context).unfocus();
      if (MediaQuery.disableAnimationsOf(context)) {
        setState(() {
          _error = null;
          _result = result;
        });
        return;
      }
      setState(() {
        _error = null;
        _result = null;
        _pending = result;
      });
      _motion.duration = Duration(
        milliseconds: _mode == DrawMode.draw ? 1400 : 1120,
      );
      _motion.forward(from: 0);
    } on InputException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _copyResult(List<List<String>> result) async {
    final text = _mode == DrawMode.draw
        ? result.single.join('、')
        : result.indexed
              .map((group) => '第 ${group.$1 + 1} 组  ${group.$2.join('、')}')
              .join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) notify(context, '已复制结果');
    } catch (error) {
      if (mounted) notify(context, errorText(error, fallback: '无法复制结果'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = _mode == DrawMode.teams;
    final busy = _pending != null;
    final candidates = drawEntries(_entries.text);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            if (widget.showTitle)
              Text('抽签与分组', style: theme.textTheme.titleLarge),
            SegmentedButton<DrawMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: DrawMode.draw, label: Text('抽签')),
                ButtonSegment(value: DrawMode.teams, label: Text('随机分组')),
              ],
              selected: {_mode},
              onSelectionChanged: busy
                  ? null
                  : (selected) => setState(() {
                      _mode = selected.single;
                      _count.text = _mode == DrawMode.teams ? '2' : '1';
                      _forgetResult();
                    }),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ActionChip(
                  label: const Text('使用寝室成员'),
                  onPressed: busy
                      ? null
                      : () => _preset(widget.memberEntries()),
                ),
                ActionChip(
                  label: const Text('今晚吃什么'),
                  onPressed: busy
                      ? null
                      : () => _preset('食堂\n麻辣烫\n饺子\n煲仔饭\n火锅'),
                ),
              ],
            ),
            TextField(
              controller: _entries,
              enabled: !busy,
              minLines: 3,
              maxLines: 6,
              maxLength: 6200,
              decoration: InputDecoration(
                labelText: '候选名单',
                hintText: '每行写一个名字或选项',
                helperText: '${candidates.length} 个不同的候选项',
                counterText: '',
              ),
              onChanged: (_) => setState(_forgetResult),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 122,
                  child: TextField(
                    controller: _count,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    decoration: InputDecoration(
                      labelText: grouped ? '分成几组' : '抽取几个',
                    ),
                    onChanged: (_) => setState(_forgetResult),
                  ),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : _draw,
                  icon: Icon(
                    grouped ? Icons.shuffle_rounded : Icons.style_outlined,
                  ),
                  label: Text(
                    busy
                        ? (grouped ? '分组中…' : '抽签中…')
                        : (grouped ? '开始分组' : '开始抽签'),
                  ),
                ),
              ],
            ),
            if (_error case final error?)
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_pending case final pending?)
              AnimatedBuilder(
                animation: _motion,
                builder: (context, _) => DrawCeremony(
                  progress: _motion.value,
                  grouped: grouped,
                  resultLabel: grouped
                      ? '${pending.length} 组'
                      : pending.single.length == 1
                      ? pending.single.single
                      : '${pending.single.length} 项入选',
                ),
              ),
            if (_result case final result?) _results(context, grouped, result),
          ],
        ),
      ),
    );
  }

  Widget _results(
    BuildContext context,
    bool grouped,
    List<List<String>> result,
  ) {
    final theme = Theme.of(context);
    final panel = _panel(
      theme,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              grouped ? '分组结果' : '抽签结果',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final (index, names) in result.indexed)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                if (grouped) Text('第 ${index + 1} 组'),
                Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  children: [
                    for (final name in names)
                      Chip(
                        label: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          TextButton.icon(
            onPressed: () => _copyResult(result),
            icon: const Icon(Icons.copy_outlined),
            label: const Text('复制结果'),
          ),
        ],
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) return panel;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, progress, child) => Transform.translate(
        offset: Offset(0, 8 * (1 - progress)),
        child: Opacity(opacity: progress, child: child),
      ),
      child: panel,
    );
  }

  Widget _panel(ThemeData theme, Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}
