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
  static const _camera = 7.0;
  static const _corners = [
    Offset(-1, -1),
    Offset(1, -1),
    Offset(1, 1),
    Offset(-1, 1),
  ];

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

  @override
  void paint(Canvas canvas, Size size) {
    final turn = Curves.easeOutCubic.transform(progress);
    final (startPitch, startYaw) = _facing(initialFace);
    final (endPitch, endYaw) = _facing(finalFace);
    final pitch = _rotateX(
      startPitch + (endPitch - startPitch + 2 * pi) * turn,
    );
    final yaw = _rotateY(startYaw + (endYaw - startYaw + 4 * pi) * turn);
    final tilt = _rotateX(-.28);
    final view = _rotateY(-.39);
    _Point rotate(_Point p) => view(tilt(yaw(pitch(p))));

    final scale = size.shortestSide * .215;
    final lift = sin(pi * progress) * size.height * .135;
    final drift = sin(2 * pi * progress) * (1 - progress) * size.width * .06;
    final center = Offset(size.width / 2 + drift, size.height * .51 - lift);
    Offset project(_Point p) =>
        center + Offset(p.x, p.y) * (scale / (1 - p.z / _camera));
    Offset facePoint(int face, double u, double v) =>
        project(rotate(_plane(face, u, v)));

    final shadowAlpha = .24 - lift / size.height * .78;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx, size.height * .81),
        width: scale * (2.25 - lift / size.height * 2),
        height: scale * .46,
      ),
      Paint()
        ..color = const Color(0xff122f25).withValues(alpha: shadowAlpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
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
      ..strokeWidth = .9
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xff6e9485);
    final ink = Paint()..color = const Color(0xff163b31);
    for (final side in visible) {
      final face = side.face;
      final normal = side.normal;
      final light = (.50 - normal.x * .18 - normal.y * .32 + normal.z * .26)
          .clamp(0.0, 1.0);
      final outline = Path()
        ..addPolygon([
          for (final point in _corners) facePoint(face, point.dx, point.dy),
        ], true);
      fill.color = Color.lerp(
        const Color(0xff82ac98),
        const Color(0xfffff8e8),
        light,
      )!;
      canvas.drawPath(outline, fill);
      canvas.drawPath(outline, edge);
      for (final pip in _pips(face)) {
        final dot = Path()
          ..addPolygon([
            for (var step = 0; step < 14; step++)
              facePoint(
                face,
                pip.dx + .125 * cos(step * 2 * pi / 14),
                pip.dy + .125 * sin(step * 2 * pi / 14),
              ),
          ], true);
        canvas.drawPath(dot, ink);
      }
    }
  }

  @override
  bool shouldRepaint(_DicePainter oldDelegate) =>
      initialFace != oldDelegate.initialFace ||
      finalFace != oldDelegate.finalFace ||
      progress != oldDelegate.progress;
}
