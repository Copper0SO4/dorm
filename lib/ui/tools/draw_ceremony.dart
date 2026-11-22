import 'dart:math';

import 'package:material_ui/material_ui.dart';

class DrawCeremony extends StatelessWidget {
  const DrawCeremony({
    super.key,
    required this.progress,
    required this.resultLabel,
  });

  final double progress;
  final String resultLabel;

  double _between(double start, double end) =>
      ((progress - start) / (end - start)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final shuffle = _between(0, .46);
    final pick = Curves.easeOutCubic.transform(_between(.36, .67));
    final flip = Curves.easeInOutCubic.transform(_between(.52, .81));
    final reveal = _between(.68, 1);
    final popScale = reveal > 0
        ? 1.0 + sin(pi * reveal) * 0.14
        : 1.0 + pick * 0.12;
    final flipped = flip >= .5;
    final stage = progress < .45
        ? '洗签中'
        : !flipped
        ? '抽出签牌'
        : '揭晓结果';
    return Semantics(
      label: '正在抽签',
      excludeSemantics: true,
      liveRegion: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: 196,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff275647), Color(0xff112b25)],
                  ),
                ),
              ),
              CustomPaint(painter: _RevealLight(reveal, progress)),
              for (final index in [-2, -1, 1, 2])
                Center(
                  child: Opacity(
                    opacity: (1 - pick * .76).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(
                        index * 19 +
                            sin(shuffle * 4 * pi + index * 0.9) *
                                24 *
                                (1 - pick),
                        index.abs() * 4 +
                            cos(shuffle * 3 * pi + index) * 8 * (1 - pick) +
                            pick * 20 +
                            4,
                      ),
                      child: Transform.rotate(
                        angle:
                            index * .15 +
                            sin(shuffle * 5 * pi + index) * .16 * (1 - pick),
                        child: const _Ticket(),
                      ),
                    ),
                  ),
                ),
              Center(
                child: Transform.translate(
                  offset: Offset(
                    sin(shuffle * 6 * pi) * 18 * (1 - pick),
                    4 - pick * 18,
                  ),
                  child: Transform.scale(
                    scale: popScale,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, .0024)
                        ..rotateY((flipped ? flip - 1 : flip) * pi),
                      child: _Ticket(frontLabel: flipped ? resultLabel : null),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 11,
                child: Text(
                  stage,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: const Color(0xfff5e8bb)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ticket extends StatelessWidget {
  const _Ticket({this.frontLabel});

  final String? frontLabel;

  @override
  Widget build(BuildContext context) {
    final front = frontLabel != null;
    return Container(
      width: 86,
      height: 114,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: front
              ? const [Color(0xfffff6d6), Color(0xfffbe09c)]
              : const [Color(0xff38876c), Color(0xff235946)],
        ),
        border: Border.all(color: const Color(0xffdfb768), width: 1.6),
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: front ? const Color(0x66ffcf72) : const Color(0x5510231d),
            offset: const Offset(0, 4),
            blurRadius: front ? 16 : 12,
          ),
        ],
      ),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(
            color: front ? const Color(0xffc59143) : const Color(0xff9bc2a4),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: front
            ? Text(
                frontLabel!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xff523712),
                  fontWeight: FontWeight.w800,
                ),
              )
            : const Icon(
                Icons.auto_awesome_rounded,
                size: 28,
                color: Color(0xfff5e1a2),
              ),
      ),
    );
  }
}

class _RevealLight extends CustomPainter {
  const _RevealLight(this.reveal, this.total);
  final double reveal;
  final double total;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 14);
    final orbit = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0x4786bca5);
    for (final radius in [56.0, 74.0]) {
      canvas.drawCircle(center, radius + sin(total * 2 * pi) * 2.5, orbit);
    }
    if (reveal == 0) return;
    final travel = Curves.easeOut.transform(reveal);
    final pulse = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = const Color(0xffffd984).withValues(alpha: (1 - travel) * 0.55);
    canvas.drawCircle(center, 46 + travel * 54, pulse);

    final rays = Paint()
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 16; i++) {
      final angle = (i + .25) * 2 * pi / 16 + travel * 0.15;
      final direction = Offset(cos(angle), sin(angle));
      final edge = center + direction * (46 + (i.isEven ? 50 : 32) * travel);
      rays.color =
          (i.isEven ? const Color(0xffffcf72) : const Color(0xffb4e2ae))
              .withValues(alpha: .90 * (1 - reveal));
      canvas.drawLine(edge, edge + direction * (4 + i % 4), rays);
      if (i % 2 == 0) {
        canvas.drawCircle(edge + direction * 11, 2.0, rays);
      }
    }
  }

  @override
  bool shouldRepaint(_RevealLight oldDelegate) =>
      oldDelegate.reveal != reveal || oldDelegate.total != total;
}
