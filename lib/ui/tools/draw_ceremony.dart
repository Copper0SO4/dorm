import 'dart:math';

import 'package:material_ui/material_ui.dart';

class DrawCeremony extends StatelessWidget {
  const DrawCeremony({
    super.key,
    required this.progress,
    required this.resultLabel,
    required this.grouped,
  });

  final double progress;
  final String resultLabel;
  final bool grouped;

  double _between(double start, double end) =>
      ((progress - start) / (end - start)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final shuffle = _between(0, .46);
    final pick = Curves.easeOutCubic.transform(_between(.36, .67));
    final flip = Curves.easeInOut.transform(_between(.52, .81));
    final reveal = _between(.65, 1);
    final flipped = flip >= .5;
    final stage = progress < .45
        ? '洗签中'
        : !flipped
        ? (grouped ? '确定分组' : '抽出签牌')
        : '揭晓结果';
    return Semantics(
      label: grouped ? '正在分组' : '正在抽签',
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
              CustomPaint(painter: _RevealLight(reveal)),
              for (final index in [-2, -1, 1, 2])
                Center(
                  child: Opacity(
                    opacity: 1 - pick * .68,
                    child: Transform.translate(
                      offset: Offset(
                        index * (16 + sin(shuffle * 4 * pi) * 8 + pick * 8),
                        index.abs() * 4 + pick * 16 + 4,
                      ),
                      child: Transform.rotate(
                        angle: index * (.14 + sin(shuffle * 3 * pi) * .09),
                        child: const _Ticket(),
                      ),
                    ),
                  ),
                ),
              Center(
                child: Transform.translate(
                  offset: Offset(
                    sin(shuffle * 6 * pi) * 13 * (1 - pick),
                    2 - pick * 16,
                  ),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, .0022)
                      ..rotateY((flipped ? flip - 1 : flip) * pi),
                    child: _Ticket(frontLabel: flipped ? resultLabel : null),
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
      width: 83,
      height: 111,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: front ? const Color(0xffffedbd) : const Color(0xff31765e),
        border: Border.all(color: const Color(0xffd3ac61), width: 1.5),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x5110231d),
            offset: Offset(0, 4),
            blurRadius: 12,
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
          borderRadius: BorderRadius.circular(7),
        ),
        child: front
            ? Text(
                frontLabel!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xff523712),
                  fontWeight: FontWeight.w700,
                ),
              )
            : const Icon(
                Icons.auto_awesome_rounded,
                size: 27,
                color: Color(0xfff5e1a2),
              ),
      ),
    );
  }
}

class _RevealLight extends CustomPainter {
  const _RevealLight(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 14);
    final orbit = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0x4786bca5);
    for (final radius in [56.0, 72.0]) {
      canvas.drawCircle(center, radius, orbit);
    }
    if (progress == 0) return;
    final travel = Curves.easeOut.transform(progress);
    final rays = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 14; i++) {
      final angle = (i + .25) * 2 * pi / 14;
      final direction = Offset(cos(angle), sin(angle));
      final edge = center + direction * (48 + (i.isEven ? 45 : 29) * travel);
      rays.color =
          (i.isEven ? const Color(0xffffcf72) : const Color(0xffb4e2ae))
              .withValues(alpha: .85 * (1 - progress));
      canvas.drawLine(edge, edge + direction * (3 + i % 4), rays);
      if (i % 3 == 0) {
        canvas.drawCircle(edge + direction * 10, 1.8, rays);
      }
    }
  }

  @override
  bool shouldRepaint(_RevealLight oldDelegate) =>
      oldDelegate.progress != progress;
}
