import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/ledger.dart';
import '../../domain/party_tools.dart';
import '../common.dart';

class DecisionWheelCard extends StatefulWidget {
  const DecisionWheelCard({
    super.key,
    required this.members,
    required this.panelWidth,
  });

  final List<String> members;
  final double panelWidth;

  @override
  State<DecisionWheelCard> createState() => _DecisionWheelCardState();
}

class _DecisionWheelCardState extends State<DecisionWheelCard> {
  final _random = Random.secure();
  final _customOptions = <String, List<String>>{};
  var _preset = decisionPresets.first;
  Timer? _spinTimer;
  var _spinning = false;
  int? _highlightIndex;
  String? _result;
  String? _error;

  List<String> get _options {
    final override = _customOptions[_preset.id];
    if (override != null) return override;
    if (_preset.usesMembers) {
      return widget.members.isNotEmpty
          ? widget.members
          : const ['室友甲', '室友乙', '室友丙'];
    }
    return _preset.options;
  }

  @override
  void dispose() {
    _spinTimer?.cancel();
    super.dispose();
  }

  void _selectPreset(DecisionPreset preset) {
    _spinTimer?.cancel();
    setState(() {
      _preset = preset;
      _spinning = false;
      _highlightIndex = null;
      _result = null;
      _error = null;
    });
  }

  void _spin() {
    if (_spinning) return;
    final options = _options;
    final String chosen;
    try {
      chosen = pickRandomOption(options, _random);
    } on InputException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    final targetIndex = options.indexOf(chosen);
    final animate = !MediaQuery.disableAnimationsOf(context);
    if (!animate || options.length == 1) {
      setState(() {
        _error = null;
        _highlightIndex = targetIndex;
        _result = chosen;
      });
      return;
    }
    _spinTimer?.cancel();
    var step = 0;
    const totalSteps = 12;
    setState(() {
      _error = null;
      _spinning = true;
      _result = null;
      _highlightIndex = _random.nextInt(options.length);
    });
    _spinTimer = Timer.periodic(const Duration(milliseconds: 85), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      step++;
      if (step >= totalSteps) {
        timer.cancel();
        setState(() {
          _spinning = false;
          _highlightIndex = targetIndex;
          _result = chosen;
        });
      } else {
        setState(() {
          _highlightIndex = (_highlightIndex! + 1) % options.length;
        });
      }
    });
  }

  Future<void> _editOptions() async {
    var text = _options.join('\n');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('编辑「${_preset.title}」选项'),
        content: SizedBox(
          width: 400,
          child: TextFormField(
            initialValue: text,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '每行一个候选选项',
              alignLabelWithHint: true,
            ),
            onChanged: (value) => text = value,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _customOptions.remove(_preset.id);
                _result = null;
                _highlightIndex = null;
              });
              Navigator.pop(context, false);
            },
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final parsed = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (parsed.isEmpty) {
      setState(() => _error = '请至少保留 1 个有效选项');
      return;
    }
    setState(() {
      _customOptions[_preset.id] = parsed;
      _result = null;
      _highlightIndex = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final options = _options;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.panelWidth + 120),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Text(
                  '寝室决策盲盒',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _preset.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in decisionPresets)
                      ChoiceChip(
                        label: Text(preset.title),
                        selected: preset.id == _preset.id,
                        onSelected: _spinning
                            ? null
                            : (_) => _selectPreset(preset),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (index, item) in options.indexed)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 90),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _highlightIndex == index
                              ? colors.primary
                              : colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          item,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: _highlightIndex == index
                                ? colors.onPrimary
                                : colors.onSurface,
                            fontWeight: _highlightIndex == index
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
                if (_result case final result?)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_preset.title} · 抽中结果',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                result,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '复制结果',
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: '${_preset.title}：$result'),
                            );
                            if (context.mounted) notify(context, '已复制决策结果');
                          },
                          icon: const Icon(Icons.copy_outlined),
                        ),
                      ],
                    ),
                  ),
                if (_error case final error?)
                  Text(error, style: TextStyle(color: colors.error)),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _spinning ? null : _spin,
                      icon: const Icon(Icons.casino_outlined),
                      label: Text(_spinning ? '抽取中…' : '帮我们决定'),
                    ),
                    TextButton.icon(
                      onPressed: _spinning ? null : _editOptions,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('编辑选项'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
