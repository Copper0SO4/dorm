import 'dart:math';

import 'package:material_ui/material_ui.dart';

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
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..addStatusListener(_finish);
  var _kind = _Roll.dice;
  int? _next;
  int? _result;

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
      _result = animate ? null : outcome;
      _next = animate ? outcome : null;
    });
    if (animate) _motion.forward(from: 0);
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
                    height: 130,
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
      final points = rolling ? steps % 6 + 1 : _result ?? 5;
      return Transform.translate(
        offset: Offset(0, -hop),
        child: Transform.rotate(
          angle: rolling ? turn * 4 * pi : 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: colors.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: .17),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: SizedBox.square(
              dimension: 76,
              child: CustomPaint(painter: _DicePips(points, colors.primary)),
            ),
          ),
        ),
      );
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

class _DicePips extends CustomPainter {
  const _DicePips(this.points, this.color);

  final int points;
  final Color color;

  static const _topLeft = Offset(.27, .27);
  static const _topRight = Offset(.73, .27);
  static const _middleLeft = Offset(.27, .50);
  static const _center = Offset(.50, .50);
  static const _middleRight = Offset(.73, .50);
  static const _bottomLeft = Offset(.27, .73);
  static const _bottomRight = Offset(.73, .73);

  @override
  void paint(Canvas canvas, Size size) {
    final pips = switch (points) {
      1 => [_center],
      2 => [_topLeft, _bottomRight],
      3 => [_topLeft, _center, _bottomRight],
      4 => [_topLeft, _topRight, _bottomLeft, _bottomRight],
      5 => [_topLeft, _topRight, _center, _bottomLeft, _bottomRight],
      _ => [
        _topLeft,
        _topRight,
        _middleLeft,
        _middleRight,
        _bottomLeft,
        _bottomRight,
      ],
    };
    final ink = Paint()..color = color;
    for (final pip in pips) {
      canvas.drawCircle(
        Offset(pip.dx * size.width, pip.dy * size.height),
        5,
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(_DicePips oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}
