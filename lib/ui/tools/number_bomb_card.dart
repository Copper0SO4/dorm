import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../domain/ledger.dart';
import '../../domain/party_tools.dart';

class NumberBombCard extends StatefulWidget {
  const NumberBombCard({super.key, required this.panelWidth});

  final double panelWidth;

  @override
  State<NumberBombCard> createState() => _NumberBombCardState();
}

class _NumberBombCardState extends State<NumberBombCard> {
  final _random = Random.secure();
  final _input = TextEditingController();
  late final NumberBombGame _game = NumberBombGame(max: 100, random: _random);
  var _maxLimit = 100;
  String? _status;
  String? _penalty;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _newGame(int maxLimit) {
    setState(() {
      _maxLimit = maxLimit;
      _game.reset(min: 1, max: maxLimit);
      _input.clear();
      _status = null;
      _penalty = null;
      _error = null;
    });
  }

  void _submit() {
    final parsed = int.tryParse(_input.text.trim());
    if (parsed == null) {
      setState(() => _error = '请输入有效的整数');
      return;
    }
    try {
      final outcome = _game.guess(parsed);
      setState(() {
        _error = null;
        _input.clear();
        _status = switch (outcome) {
          BombOutcome.tooLow =>
            '$parsed 太小了！安全范围缩窄为 ${_game.low} ~ ${_game.high}',
          BombOutcome.tooHigh =>
            '$parsed 太大了！安全范围缩窄为 ${_game.low} ~ ${_game.high}',
          BombOutcome.exploded => '💥 踩中炸弹 $parsed！共经历 ${_game.attempts} 轮',
        };
      });
    } on InputException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _drawPenalty() {
    setState(() {
      _penalty = pickRandomOption(penaltyPresets, _random);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final exploded = _game.exploded;
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
                  '数字炸弹',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '室友轮流报数，每次缩小安全范围，踩中隐藏数字的人抽一个小惩罚！',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final limit in const [50, 100, 200])
                      ChoiceChip(
                        label: Text('1 ~ $limit'),
                        selected: _maxLimit == limit,
                        onSelected: (_) => _newGame(limit),
                      ),
                  ],
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: exploded
                        ? colors.errorContainer
                        : colors.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        exploded ? '炸弹已引爆' : '当前安全区间',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: exploded
                              ? colors.onErrorContainer
                              : colors.onPrimaryContainer,
                        ),
                      ),
                      Text(
                        exploded
                            ? '炸弹数字：${_game.secret}'
                            : '${_game.low}  ~  ${_game.high}',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: exploded
                              ? colors.onErrorContainer
                              : colors.onPrimaryContainer,
                        ),
                      ),
                      if (_status case final status?)
                        Text(
                          status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: exploded
                                ? colors.onErrorContainer
                                : colors.onPrimaryContainer,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!exploded)
                  Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: '输入 ${_game.low} ~ ${_game.high} 之间的数字',
                            errorText: _error,
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      FilledButton(onPressed: _submit, child: const Text('报数')),
                    ],
                  ),
                if (exploded)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _drawPenalty,
                        icon: const Icon(Icons.card_giftcard_outlined),
                        label: const Text('抽个轻惩罚'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _newGame(_maxLimit),
                        icon: const Icon(Icons.refresh),
                        label: const Text('再来一局'),
                      ),
                    ],
                  ),
                if (_penalty case final penalty?)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '本局惩罚：$penalty',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                if (_game.history.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final item in _game.history.reversed.take(10))
                        Chip(
                          label: Text(switch (item.outcome) {
                            BombOutcome.tooLow => '${item.guess} ↑',
                            BombOutcome.tooHigh => '${item.guess} ↓',
                            BombOutcome.exploded => '${item.guess} 💥',
                          }),
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
