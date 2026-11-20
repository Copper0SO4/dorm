import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/draw.dart';
import 'common.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.controller});
  final DormController controller;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final _random = Random.secure();
  final _count = TextEditingController(text: '1');
  late final _entries = TextEditingController(text: _members());
  var _mode = DrawMode.draw;
  var _result = <List<String>>[];
  String? _prompt;
  var _quickResult = '';
  var _quickRoll = 0;

  String _members() => widget.controller.repository
      .members()
      .where((member) => member.active)
      .map((member) => member.name)
      .join('\n');

  @override
  void dispose() {
    _entries.dispose();
    _count.dispose();
    super.dispose();
  }

  void _preset(String entries) {
    setState(() {
      _entries.text = entries;
      _result = [];
      _prompt = null;
    });
  }

  void _runDraw() {
    try {
      final count = int.tryParse(_count.text.trim()) ?? 0;
      final result = makeDraw(
        drawEntries(_entries.text),
        count,
        _mode,
        _random,
      );
      setState(() {
        _result = result;
        _prompt = null;
      });
    } catch (error) {
      setState(() => _prompt = errorText(error));
    }
  }

  Future<void> _copyResult() async {
    final text = _mode == DrawMode.draw
        ? _result.single.join('、')
        : _result.indexed
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
    final group = _mode == DrawMode.teams;
    final draw = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 14,
          children: [
            Text('抽签与分组', style: theme.textTheme.titleLarge),
            SegmentedButton<DrawMode>(
              segments: const [
                ButtonSegment(
                  value: DrawMode.draw,
                  label: Text('抽签'),
                  icon: Icon(Icons.casino_outlined),
                ),
                ButtonSegment(
                  value: DrawMode.teams,
                  label: Text('随机分组'),
                  icon: Icon(Icons.groups_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selected) => setState(() {
                _mode = selected.single;
                _count.text = _mode == DrawMode.teams ? '2' : '1';
                _result = [];
                _prompt = null;
              }),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('使用寝室成员'),
                  onPressed: () => _preset(_members()),
                ),
                ActionChip(
                  label: const Text('今晚吃什么'),
                  onPressed: () => _preset('食堂\n麻辣烫\n饺子\n煲仔饭\n火锅'),
                ),
              ],
            ),
            TextField(
              controller: _entries,
              minLines: 4,
              maxLines: 7,
              maxLength: 6200,
              decoration: const InputDecoration(
                labelText: '候选名单',
                hintText: '每行写一个名字或选项',
              ),
              onChanged: (_) => setState(() {
                _result = [];
                _prompt = null;
              }),
            ),
            SizedBox(
              width: 180,
              child: TextField(
                controller: _count,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: group ? '分成几组' : '抽取几个'),
                onChanged: (_) => setState(() {
                  _result = [];
                  _prompt = null;
                }),
              ),
            ),
            if (_prompt case final message?)
              Text(message, style: TextStyle(color: theme.colorScheme.error)),
            FilledButton.icon(
              onPressed: _runDraw,
              icon: Icon(group ? Icons.shuffle : Icons.casino_outlined),
              label: Text(group ? '开始分组' : '开始抽签'),
            ),
            if (_result.isNotEmpty) ...[
              const Divider(),
              for (final (index, names) in _result.indexed)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Text(
                      group ? '第 ${index + 1} 组' : '抽签结果',
                      style: theme.textTheme.titleMedium,
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      children: [
                        for (final name in names) Chip(label: Text(name)),
                      ],
                    ),
                  ],
                ),
              OutlinedButton.icon(
                onPressed: _copyResult,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制结果'),
              ),
            ],
          ],
        ),
      ),
    );
    final quick = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text('骰子与硬币', style: theme.textTheme.titleLarge),
            if (_quickResult.isNotEmpty)
              Semantics(
                liveRegion: true,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    _quickResult,
                    key: ValueKey(_quickRoll),
                    style: theme.textTheme.headlineMedium,
                  ),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _roll('${_random.nextInt(6) + 1} 点'),
                  icon: const Icon(Icons.casino_outlined),
                  label: const Text('掷骰子'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _roll(_random.nextBool() ? '正面' : '反面'),
                  icon: const Icon(Icons.toll_outlined),
                  label: const Text('抛硬币'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return PageBody(
      storageKey: 'dorm-tools',
      children: [
        Text('寝室工具箱', style: theme.textTheme.headlineMedium),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 740
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Expanded(flex: 2, child: draw),
                    Expanded(child: quick),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [draw, quick],
                ),
        ),
      ],
    );
  }

  void _roll(String value) => setState(() {
    _quickResult = value;
    _quickRoll++;
  });
}
