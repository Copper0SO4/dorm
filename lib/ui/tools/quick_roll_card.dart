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
      _motion.duration = Duration(
        milliseconds: kind == _Roll.dice ? 1050 : 880,
      );
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
    if (_kind == _Roll.dice) {
      return DiceScene(from: _startingFace, points: _lastFace, progress: time);
    }

    final turn = Curves.easeOutCubic.transform(time);
    // Multi-bounce vertical arc: high toss (0..0.72) then crisp landing bounce (0.72..1.0).
    final hop = time < 0.72
        ? sin(pi * (time / 0.72)) * 42
        : sin(pi * ((time - 0.72) / 0.28)) * 9;
    final target = _result ?? _next ?? 0;
    // Rotate 5 full flips + exact half-turn if target is tails (1).
    final totalAngle = (10 + target) * pi * turn;
    final facingFront = cos(totalAngle) >= 0;
    final edgeProximity = 1 - cos(totalAngle).abs();
    final shadowWidth = 64.0 - hop * 0.65;
    final shadowAlpha = (0.26 - hop * 0.004).clamp(0.06, 0.26);

    return SizedBox(
      width: 120,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: 12,
            child: Container(
              width: shadowWidth,
              height: 14,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.black.withValues(alpha: shadowAlpha),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(0, -hop + 6),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0022)
                ..rotateX(totalAngle)
                ..rotateZ(sin(2 * pi * time) * (1 - time) * 0.16),
              child: Transform(
                alignment: Alignment.center,
                transform: facingFront
                    ? Matrix4.identity()
                    : (Matrix4.identity()..rotateX(pi)),
                child: _CoinFace(
                  front: facingFront,
                  edgeGlow: edgeProximity,
                  theme: theme,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoinFace extends StatelessWidget {
  const _CoinFace({
    required this.front,
    required this.edgeGlow,
    required this.theme,
  });

  final bool front;
  final double edgeGlow;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final colors = theme.colorScheme;
    final lightFill = front
        ? const [Color(0xffffe79b), Color(0xffd79e33)]
        : const [Color(0xffe9eff3), Color(0xff96a7b3)];
    final ringColor = front ? const Color(0xffa46f19) : const Color(0xff5b6b76);
    final textColor = front ? const Color(0xff573706) : const Color(0xff23313b);

    return Container(
      width: 82,
      height: 82,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: lightFill,
        ),
        border: Border.all(
          color: Color.lerp(ringColor, colors.onSurface, edgeGlow * 0.35)!,
          width: 2.5 + edgeGlow * 1.5,
        ),
      ),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: ringColor.withValues(alpha: 0.48),
            width: 1.2,
          ),
        ),
        child: Text(
          front ? '正' : '反',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: textColor,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
