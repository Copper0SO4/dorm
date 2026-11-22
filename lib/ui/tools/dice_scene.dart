import 'dart:math';

import 'package:material_ui/material_ui.dart';

class DiceScene extends StatelessWidget {
  const DiceScene({
    super.key,
    required this.from,
    required this.points,
    required this.progress,
  });

  final int from;
  final int points;
  final double progress;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(204, 170),
    painter: _DicePainter(from, points, progress),
  );
}

typedef _Point = ({double x, double y, double z});

class _DicePainter extends CustomPainter {
  const _DicePainter(this.initialFace, this.finalFace, this.progress);

  final int initialFace;
  final int finalFace;
  final double progress;
  static const _camera = 7.2;

  static (double, double) _facing(int face) => switch (face) {
    2 => (0, -pi / 2),
    3 => (-pi / 2, 0),
    4 => (pi / 2, 0),
    5 => (0, pi / 2),
    6 => (0, pi),
    _ => (0, 0),
  };

  static _Point _plane(int face, double u, double v) => switch (face) {
    2 => (x: 1, y: v, z: -u),
    3 => (x: u, y: -1, z: v),
    4 => (x: u, y: 1, z: -v),
    5 => (x: -1, y: v, z: u),
    6 => (x: -u, y: v, z: -1),
    _ => (x: u, y: v, z: 1),
  };

  static List<Offset> _pips(int face) {
    const tl = Offset(-.46, -.46);
    const tr = Offset(.46, -.46);
    const ml = Offset(-.46, 0);
    const mr = Offset(.46, 0);
    const bl = Offset(-.46, .46);
    const br = Offset(.46, .46);
    return switch (face) {
      1 => const [Offset.zero],
      2 => const [tl, br],
      3 => const [tl, Offset.zero, br],
      4 => const [tl, tr, bl, br],
      5 => const [tl, tr, Offset.zero, bl, br],
      _ => const [tl, tr, ml, mr, bl, br],
    };
  }

  static _Point Function(_Point) _rotateX(double angle) {
    final c = cos(angle);
    final s = sin(angle);
    return (p) => (x: p.x, y: p.y * c - p.z * s, z: p.y * s + p.z * c);
  }

  static _Point Function(_Point) _rotateY(double angle) {
    final c = cos(angle);
    final s = sin(angle);
    return (p) => (x: p.x * c + p.z * s, y: p.y, z: p.z * c - p.x * s);
  }

  static _Point Function(_Point) _rotateZ(double angle) {
    final c = cos(angle);
    final s = sin(angle);
    return (p) => (x: p.x * c - p.y * s, y: p.x * s + p.y * c, z: p.z);
  }

  /// Multi-stage physical bounce height (0.0 at rest, peak ~0.185 at mid-air).
  static double _bounceHeight(double t) {
    if (t < 0.66) {
      return sin(pi * (t / 0.66)) * 0.185;
    }
    if (t < 0.88) {
      return sin(pi * ((t - 0.66) / 0.22)) * 0.048;
    }
    return sin(pi * ((t - 0.88) / 0.12)) * 0.012;
  }

  static List<Offset> _roundedFaceOutline(
    Offset Function(double u, double v) projectUv,
  ) {
    // 2D rounded square in (u, v) space [-1, 1]^2 with corner radius r = 0.22.
    const r = 0.22;
    const inner = 1.0 - r;
    const cornerCenters = [
      Offset(-inner, -inner),
      Offset(inner, -inner),
      Offset(inner, inner),
      Offset(-inner, inner),
    ];
    const startAngles = [pi, -pi / 2, 0.0, pi / 2];
    final points = <Offset>[];
    for (var c = 0; c < 4; c++) {
      final center = cornerCenters[c];
      final base = startAngles[c];
      for (var step = 0; step <= 4; step++) {
        final theta = base + (pi / 2) * (step / 4);
        points.add(
          projectUv(center.dx + r * cos(theta), center.dy + r * sin(theta)),
        );
      }
    }
    return points;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final turn = Curves.easeOutCubic.transform(progress);
    final (startPitch, startYaw) = _facing(initialFace);
    final (endPitch, endYaw) = _facing(finalFace);
    final settleWobble = progress > 0.66
        ? sin((progress - 0.66) * 18) * (1 - progress) * 0.24
        : 0.0;
    final pitch = _rotateX(
      startPitch + (endPitch - startPitch + 2 * pi) * turn + settleWobble,
    );
    final yaw = _rotateY(
      startYaw + (endYaw - startYaw + 4 * pi) * turn - settleWobble * 0.6,
    );
    final spin = _rotateZ(sin(pi * progress) * 0.35 * (1 - progress));
    final tilt = _rotateX(-.28);
    final view = _rotateY(-.39);
    _Point rotate(_Point p) => view(tilt(spin(yaw(pitch(p)))));

    final scale = size.shortestSide * .218;
    final heightFraction = _bounceHeight(progress);
    final lift = heightFraction * size.height;
    final drift = sin(2.4 * pi * progress) * (1 - progress) * size.width * .07;
    final center = Offset(size.width / 2 + drift, size.height * .54 - lift);
    Offset project(_Point p) =>
        center + Offset(p.x, p.y) * (scale / (1 - p.z / _camera));
    Offset facePoint(int face, double u, double v) =>
        project(rotate(_plane(face, u, v)));

    final shadowAlpha = (.27 - heightFraction * .95).clamp(0.06, 0.30);
    final shadowWidth = scale * (2.35 - heightFraction * 3.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx, size.height * .82),
        width: shadowWidth,
        height: scale * .46,
      ),
      Paint()
        ..color = const Color(0xff10261e).withValues(alpha: shadowAlpha)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          5.0 + heightFraction * 26.0,
        ),
    );

    final visible =
        [
            for (var face = 1; face <= 6; face++)
              (face: face, normal: rotate(_plane(face, 0, 0))),
          ].where((side) => side.normal.z > 1 / _camera).toList()
          ..sort((a, b) => a.normal.z.compareTo(b.normal.z));
    final fill = Paint();
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xff789c8d);
    final rimHighlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0x55ffffff);
    final darkInk = Paint()..color = const Color(0xff163b31);
    final redInk = Paint()..color = const Color(0xffc0392b);

    for (final side in visible) {
      final face = side.face;
      final normal = side.normal;
      final light = (.52 - normal.x * .18 - normal.y * .34 + normal.z * .26)
          .clamp(0.0, 1.0);
      final outline = Path()
        ..addPolygon(
          _roundedFaceOutline((u, v) => facePoint(face, u, v)),
          true,
        );
      fill.color = Color.lerp(
        const Color(0xff89b29f),
        const Color(0xfffffaf0),
        light,
      )!;
      canvas.drawPath(outline, fill);
      canvas.drawPath(outline, edge);
      if (light > 0.55) {
        canvas.drawPath(outline, rimHighlight);
      }

      final pipPaint = (face == 1 || face == 4) ? redInk : darkInk;
      final pipRadius = face == 1 ? .18 : .128;
      for (final pip in _pips(face)) {
        final dot = Path()
          ..addPolygon([
            for (var step = 0; step < 14; step++)
              facePoint(
                face,
                pip.dx + pipRadius * cos(step * 2 * pi / 14),
                pip.dy + pipRadius * sin(step * 2 * pi / 14),
              ),
          ], true);
        canvas.drawPath(dot, pipPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_DicePainter oldDelegate) =>
      initialFace != oldDelegate.initialFace ||
      finalFace != oldDelegate.finalFace ||
      progress != oldDelegate.progress;
}
