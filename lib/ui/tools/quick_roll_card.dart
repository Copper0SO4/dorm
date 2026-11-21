import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'dice_scene.dart';

enum _Roll { dice, coin }

class QuickRollCard extends StatefulWidget {
  const QuickRollCard({super.key, required this.showTitle});

  final bool showTitle;

  @override
  State<QuickRollCard> createState() => _QuickRollCardState();
}

class _QuickRollCardState extends State<QuickRollCard>
    with SingleTickerProviderStateMixin {
  final _random = Random.secure();
  late final _motion = AnimationController(vsync: this)
    ..addStatusListener(_finish);
  var _kind = _Roll.dice;
  int? _next;
  int? _result;
  var _startingFace = 5;
  var _lastFace = 5;

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _finish(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    setState(() {
      _result = _next;
      _next = null;
    });
  }

  void _roll(_Roll kind) {
    if (_next != null) return;
    final outcome = kind == _Roll.dice
        ? _random.nextInt(6) + 1
        : _random.nextInt(2);
    final animate = !MediaQuery.disableAnimationsOf(context);
    setState(() {
      _kind = kind;
      if (kind == _Roll.dice) {
        _startingFace = _lastFace;
        _lastFace = outcome;
      }
      _result = animate ? null : outcome;
      _next = animate ? outcome : null;
    });
    if (animate) {
      _motion.duration = Duration(milliseconds: kind == _Roll.dice ? 970 : 620);
      _motion.forward(from: 0);
    }
  }

  String get _caption {
    if (_next != null) {
      return _kind == _Roll.dice ? '骰子滚动中…' : '硬币翻转中…';
    }
    if (_result == null) return '掷骰子或抛硬币';
    if (_kind == _Roll.dice) return '$_result 点';
    return _result == 0 ? '正面' : '反面';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rolling = _next != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            if (widget.showTitle)
              Text('骰子与硬币', style: theme.textTheme.titleLarge),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 170,
                    child: Center(
                      child: ExcludeSemantics(
                        child: AnimatedBuilder(
                          animation: _motion,
                          builder: (context, _) => _figure(theme, rolling),
                        ),
                      ),
                    ),
                  ),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _caption,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: rolling ? null : () => _roll(_Roll.dice),
                  icon: const Icon(Icons.casino_outlined),
                  label: const Text('掷骰子'),
                ),
                FilledButton.tonalIcon(
                  onPressed: rolling ? null : () => _roll(_Roll.coin),
                  icon: const Icon(Icons.toll_outlined),
                  label: const Text('抛硬币'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _figure(ThemeData theme, bool rolling) {
    final time = rolling ? _motion.value : 1.0;
    final turn = Curves.easeOutCubic.transform(time);
    final hop = sin(time * pi) * 23;
    final colors = theme.colorScheme;
    final steps = (turn * 13).floor();
    if (_kind == _Roll.dice) {
      return DiceScene(from: _startingFace, points: _lastFace, progress: time);
    }

    final face = rolling ? steps % 2 : _result ?? 0;
    return Transform.translate(
      offset: Offset(0, -hop),
      child: Transform.scale(
        scaleX: rolling ? max(.14, cos(turn * 6 * pi).abs()) : 1,
        child: Container(
          width: 76,
          height: 76,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.tertiaryContainer,
            border: Border.all(color: colors.tertiary, width: 2),
          ),
          child: Text(
            face == 0 ? '正' : '反',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: colors.onTertiaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
