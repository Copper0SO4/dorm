import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../game/cards.dart';

class CardTableFrame extends StatelessWidget {
  const CardTableFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      const Positioned.fill(
        child: RepaintBoundary(
          child: CustomPaint(painter: _TableFramePainter()),
        ),
      ),
      child,
    ],
  );
}

class _TableFramePainter extends CustomPainter {
  const _TableFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final compact = size.height < 440;
    final inset = compact ? 4.0 : 13.0;
    final base = Rect.fromLTRB(
      inset,
      size.height * .14,
      size.width - inset,
      size.height - (compact ? 38 : 66),
    );
    if (base.isEmpty) return;
    final rim = RRect.fromRectAndCorners(
      base,
      topLeft: Radius.elliptical(base.width * .30, base.height * .34),
      topRight: Radius.elliptical(base.width * .30, base.height * .34),
      bottomLeft: Radius.elliptical(base.width * .23, base.height * .20),
      bottomRight: Radius.elliptical(base.width * .23, base.height * .20),
    );
    canvas.drawRRect(
      rim,
      Paint()
        ..color = const Color(0x548caf84)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
    canvas.drawRRect(
      rim.deflate(compact ? 4 : 6),
      Paint()
        ..color = const Color(0x248caf84)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _TableFramePainter oldDelegate) => false;
}

class CardArtwork extends CustomPainter {
  const CardArtwork({
    required this.rank,
    required this.suit,
    required this.peek,
    required this.cornerHeight,
    required this.selected,
    required this.wild,
  });

  final int rank;
  final int? suit;
  final double peek;
  final double cornerHeight;
  final bool selected;
  final bool wild;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;
    final radius = Radius.circular(math.min(10, size.width * .16));
    final card = RRect.fromRectAndRadius(rect, radius);
    final red = suit == 1 || suit == 2 || rank == 17;
    final ink = red ? const Color(0xffa31e2d) : const Color(0xff152e2b);
    final shape = suit == null ? _diamond : _suits[suit!];
    canvas.drawRRect(
      card.shift(const Offset(0, 2)),
      Paint()..color = const Color(0x70081109),
    );
    canvas.drawRRect(
      card,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: selected
              ? const [Color(0xfffff6d3), Color(0xfff0cea0)]
              : const [Color(0xfffffff9), Color(0xffeee3cc)],
        ).createShader(rect),
    );
    canvas.drawRRect(
      card.deflate(.4),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = selected
            ? const Color(0xffffbf51)
            : wild
            ? const Color(0xffc6813d)
            : const Color(0xff9aab97)
        ..strokeWidth = selected ? 1.8 : 1,
    );

    if (peek >= size.width * .58 && size.width >= 29) {
      canvas.drawRRect(
        card.deflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = ink.withValues(alpha: .15)
          ..strokeWidth = .65,
      );
      _drawFace(canvas, size, ink, shape);
      if (size.width > 52 && rank < 16) {
        canvas.save();
        canvas.translate(size.width, size.height);
        canvas.rotate(math.pi);
        _drawCorner(canvas, size, size.width, ink, shape);
        canvas.restore();
      }
    }
    _drawCorner(canvas, size, peek, ink, shape);
    if (wild && size.width > 25) {
      _drawSuit(
        canvas,
        _diamond,
        Offset(size.width - 7, 7),
        2.7,
        const Color(0xffb36f16),
      );
    }
  }

  void _drawFace(Canvas canvas, Size size, Color ink, Path shape) {
    final center = Offset(size.width * .55, size.height * .57);
    if (suit == null || (rank >= 11 && rank <= 13)) {
      final crest = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center,
          width: size.width * .48,
          height: size.height * .43,
        ),
        const Radius.circular(7),
      );
      canvas.drawRRect(crest, Paint()..color = ink.withValues(alpha: .095));
      canvas.drawRRect(
        crest,
        Paint()
          ..color = ink.withValues(alpha: .40)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
      _drawSuit(
        canvas,
        shape,
        center.translate(0, -size.height * .045),
        size.width * .133,
        ink.withValues(alpha: .82),
      );
      _print(
        canvas,
        suit == null ? '王' : PlayingCard.rankLabel(rank),
        center.translate(-size.width * .18, size.height * .06),
        size.width * .16,
        size.width * .36,
        ink.withValues(alpha: .78),
        centered: true,
      );
      return;
    }
    final spots = rank == 14
        ? 1
        : rank == 15
        ? 2
        : rank;
    if (spots == 1) {
      _drawSuit(canvas, shape, center, size.width * .24, ink);
      return;
    }
    final rows = spots <= 3
        ? spots
        : spots <= 5
        ? 2
        : spots <= 8
        ? 3
        : 4;
    for (var row = 0; row < rows; row++) {
      final y = size.height * (.33 + .45 * row / (rows - 1));
      for (final side in spots <= 3 ? [0] : [-1, 1]) {
        _drawSuit(
          canvas,
          shape,
          Offset(center.dx + side * size.width * .16, y),
          size.width * .082,
          ink.withValues(alpha: .83),
        );
      }
    }
    final fill = switch (spots) {
      5 => [.55],
      7 => [.44],
      8 || 10 => [.43, .67],
      9 => [.55],
      _ => <double>[],
    };
    for (final y in fill) {
      _drawSuit(
        canvas,
        shape,
        Offset(center.dx, size.height * y),
        size.width * .075,
        ink.withValues(alpha: .83),
      );
    }
  }

  void _drawCorner(
    Canvas canvas,
    Size size,
    double visibleWidth,
    Color ink,
    Path shape,
  ) {
    final left = (visibleWidth * .15).clamp(1.0, 6.0);
    final width = math.max(2.0, visibleWidth - left - 2);
    final font = math.max(
      6.0,
      math.min(
        cornerHeight / 1.90,
        math.min(size.width * .32, visibleWidth * .90),
      ),
    );
    final name = PlayingCard.rankLabel(rank);
    final top = rank >= 16 ? name.substring(0, 1) : name;
    final textWidth = _print(canvas, top, Offset(left, 3), font, width, ink);
    if (suit == null) {
      _print(canvas, '王', Offset(left, 3 + font), font * .83, width, ink);
    } else {
      final pip = math.min(font * .35, width / 2);
      _drawSuit(
        canvas,
        shape,
        Offset(left + math.max(pip, textWidth / 2), 4 + font + pip),
        pip,
        ink,
      );
    }
  }

  double _print(
    Canvas canvas,
    String text,
    Offset point,
    double font,
    double width,
    Color color, {
    bool centered = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: font,
          height: 1,
          fontWeight: FontWeight.w900,
          color: color,
          fontFamilyFallback: const ['NotoSansSC'],
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final usedWidth = math.min(width, painter.width);
    if (painter.width > 0) {
      canvas.save();
      canvas.translate(
        point.dx + (centered ? (width - usedWidth) / 2 : 0),
        point.dy,
      );
      canvas.scale(usedWidth / painter.width, 1);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }
    painter.dispose();
    return usedWidth;
  }

  @override
  bool shouldRepaint(covariant CardArtwork oldDelegate) =>
      rank != oldDelegate.rank ||
      suit != oldDelegate.suit ||
      peek != oldDelegate.peek ||
      cornerHeight != oldDelegate.cornerHeight ||
      selected != oldDelegate.selected ||
      wild != oldDelegate.wild;
}

void _drawSuit(
  Canvas canvas,
  Path shape,
  Offset center,
  double radius,
  Color color,
) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.scale(radius);
  canvas.drawPath(shape, Paint()..color = color);
  canvas.restore();
}

final Path _diamond = Path()
  ..moveTo(0, -1)
  ..lineTo(.73, 0)
  ..lineTo(0, 1)
  ..lineTo(-.73, 0)
  ..close();

final List<Path> _suits = [
  Path()
    ..moveTo(0, -1)
    ..cubicTo(.18, -.72, .94, -.28, .94, .22)
    ..cubicTo(.94, .68, .40, .79, .16, .44)
    ..quadraticBezierTo(.14, .72, .44, .96)
    ..lineTo(-.44, .96)
    ..quadraticBezierTo(-.14, .72, -.16, .44)
    ..cubicTo(-.40, .79, -.94, .68, -.94, .22)
    ..cubicTo(-.94, -.28, -.18, -.72, 0, -1)
    ..close(),
  Path()
    ..moveTo(0, .95)
    ..cubicTo(-.30, .60, -.95, .11, -.95, -.40)
    ..cubicTo(-.95, -.95, -.25, -1.06, 0, -.51)
    ..cubicTo(.25, -1.06, .95, -.95, .95, -.40)
    ..cubicTo(.95, .11, .30, .60, 0, .95)
    ..close(),
  _diamond,
  Path()
    ..addOval(Rect.fromCircle(center: Offset(0, -.47), radius: .52))
    ..addOval(Rect.fromCircle(center: Offset(-.45, .21), radius: .49))
    ..addOval(Rect.fromCircle(center: Offset(.45, .21), radius: .49))
    ..moveTo(-.17, .22)
    ..lineTo(.17, .22)
    ..quadraticBezierTo(.12, .66, .42, .95)
    ..lineTo(-.42, .95)
    ..quadraticBezierTo(-.12, .66, -.17, .22)
    ..close(),
];
