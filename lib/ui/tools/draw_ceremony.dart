import 'dart:math';

import 'package:material_ui/material_ui.dart';

class DrawCeremony extends StatelessWidget {
  const DrawCeremony({
    super.key,
    required this.progress,
    required this.results,
    required this.pickedSlots,
  }) : assert(results.length > 0),
       assert(
         pickedSlots.length > 0 &&
             pickedSlots.length <= maxDisplayedTickets &&
             pickedSlots.length <= results.length,
       );

  static const ticketCount = 8;
  static const maxDisplayedTickets = 4;
  static const _pickAt = .45;

  final double progress;
  final List<String> results;
  final List<int> pickedSlots;

  List<List<String>> get ticketGroups {
    final slots = pickedSlots.length;
    final base = results.length ~/ slots;
    final extra = results.length % slots;
    int boundary(int index) => index * base + min(index, extra);
    return [
      for (var index = 0; index < slots; index++)
        results.sublist(boundary(index), boundary(index + 1)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final complete = progress >= 1;
    final count = results.length;
    final visibleCount = pickedSlots.length;
    final completedLabel = count == 1
        ? '已揭晓'
        : count > visibleCount
        ? '已揭晓 $count 项 · 分在 $visibleCount 张签上'
        : '已揭晓 $count 项';
    final stage = complete
        ? completedLabel
        : progress < _pickAt
        ? '洗签中'
        : progress < .74
        ? '抽出签牌'
        : '揭晓结果';
    final type = Theme.of(context).textTheme;
    return Semantics(
      label: complete && count == 1 ? '已揭晓 ${results.single}' : stage,
      excludeSemantics: true,
      liveRegion: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: LayoutBuilder(
          builder: (context, bounds) => SizedBox(
            width: double.infinity,
            height: (bounds.maxWidth * .66).clamp(214.0, 296.0),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _DrawScene(
                      progress,
                      ticketGroups,
                      pickedSlots,
                      Directionality.of(context),
                      type.titleMedium ?? const TextStyle(),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 11),
                    child: Text(
                      stage,
                      textAlign: TextAlign.center,
                      style: type.labelLarge?.copyWith(
                        color: const Color(0xfff5e8bb),
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(color: Color(0xff081410), blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

double _ramp(double value, double start, double end, Curve curve) =>
    curve.transform(((value - start) / (end - start)).clamp(0.0, 1.0));

typedef _Point = ({double x, double y, double z});

_Point _plus(_Point a, _Point b) => (x: a.x + b.x, y: a.y + b.y, z: a.z + b.z);

class _Rotation {
  _Rotation(this.pitch, this.yaw, this.roll)
    : _cx = cos(pitch),
      _sx = sin(pitch),
      _cy = cos(yaw),
      _sy = sin(yaw),
      _cz = cos(roll),
      _sz = sin(roll);

  final double pitch, yaw, roll;
  final double _cx, _sx, _cy, _sy, _cz, _sz;

  _Point apply(_Point point) {
    final x = point.x * _cy + point.z * _sy;
    final depth = point.z * _cy - point.x * _sy;
    final y = point.y * _cx - depth * _sx;
    return (
      x: x * _cz - y * _sz,
      y: x * _sz + y * _cz,
      z: point.y * _sx + depth * _cx,
    );
  }
}

class _Camera {
  _Camera({
    required this.origin,
    required this.focus,
    required this.distance,
    required this.focalLength,
    required this.view,
  });

  final Offset origin;
  final _Point focus;
  final double distance, focalLength;
  final _Rotation view;

  double get scale => focalLength / distance;

  _Point toView(_Point point) => view.apply((
    x: point.x - focus.x,
    y: point.y - focus.y,
    z: point.z - focus.z,
  ));

  double magnification(_Point point) => focalLength / (distance - point.z);

  Offset project(_Point point) =>
      origin + Offset(point.x, point.y) * magnification(point);

  // Homography of the ticket texture, with the same depth terms as the mesh.
  Matrix4 plane(_Point center, _Point right, _Point down) => Matrix4.identity()
    ..setEntry(0, 0, right.x * scale)
    ..setEntry(0, 1, down.x * scale)
    ..setEntry(0, 3, center.x * scale)
    ..setEntry(1, 0, right.y * scale)
    ..setEntry(1, 1, down.y * scale)
    ..setEntry(1, 3, center.y * scale)
    ..setEntry(3, 0, -right.z / distance)
    ..setEntry(3, 1, -down.z / distance)
    ..setEntry(3, 3, 1 - center.z / distance);
}

typedef _Pose = ({
  _Point position,
  _Rotation rotation,
  double scale,
  List<String>? result,
});

typedef _Vertex = ({Offset point, double inverseDepth});

class _Surface {
  _Surface(this.owner, this.vertices, this.paint)
    : outline = Path()
        ..addPolygon([for (final vertex in vertices) vertex.point], true) {
    bounds = outline.getBounds();
    final a = vertices.first;
    final b = vertices[vertices.length ~/ 3];
    final c = vertices[vertices.length * 2 ~/ 3];
    final ab = b.point - a.point;
    final ac = c.point - a.point;
    final determinant = ab.dx * ac.dy - ab.dy * ac.dx;
    if (determinant.abs() < .001) return;
    final db = b.inverseDepth - a.inverseDepth;
    final dc = c.inverseDepth - a.inverseDepth;
    _gradient = Offset(
      (db * ac.dy - dc * ab.dy) / determinant,
      (ab.dx * dc - ac.dx * db) / determinant,
    );
    _constant = a.inverseDepth - _dot(_gradient, a.point);
    var low = a.inverseDepth;
    var high = low;
    for (final vertex in vertices) {
      low = min(low, vertex.inverseDepth);
      high = max(high, vertex.inverseDepth);
    }
    minDepth = low;
    maxDepth = high;
  }

  final int owner;
  final List<_Vertex> vertices;
  final void Function(Canvas) paint;
  final Path outline;
  late final Rect bounds;
  late final Offset _gradient;
  late final double _constant;
  double? minDepth;
  late final double maxDepth;

  static double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  double get depth => (minDepth! + maxDepth) / 2;

  // Inverse camera-space distance is affine across a projected plane.
  Path? portionInFrontOf(_Surface other) {
    const tolerance = 1e-7;
    if (maxDepth <= other.minDepth! + tolerance) return null;
    if (minDepth! > other.maxDepth + tolerance) return outline;

    final gradient = _gradient - other._gradient;
    final constant = _constant - other._constant - tolerance;
    double difference(Offset point) => _dot(gradient, point) + constant;
    final clipped = <Offset>[];
    var previous = vertices.last.point;
    var previousDifference = difference(previous);
    for (final vertex in vertices) {
      final current = vertex.point;
      final currentDifference = difference(current);
      if ((previousDifference > 0) != (currentDifference > 0)) {
        final intersection =
            previousDifference / (previousDifference - currentDifference);
        clipped.add(Offset.lerp(previous, current, intersection)!);
      }
      if (currentDifference > 0) clipped.add(current);
      previous = current;
      previousDifference = currentDifference;
    }
    if (clipped.length < 3) return null;
    return Path()..addPolygon(clipped, true);
  }
}

const _gold = Color(0xffffd58d);
const _mint = Color(0xffa8eac9);
const _paper = Color(0xfff1cf84);

class _DrawScene extends CustomPainter {
  const _DrawScene(
    this.time,
    this.ticketGroups,
    this.pickedSlots,
    this.direction,
    this.label,
  );

  final double time;
  final List<List<String>> ticketGroups;
  final List<int> pickedSlots;
  final TextDirection direction;
  final TextStyle label;

  static const _tau = 2 * pi;
  static const _textureUnit = .0088;
  static const _thickness = .035;
  static const _floor = .96;
  static const _face = Size(104, 148);
  static final _faceRect = Rect.fromCenter(
    center: Offset.zero,
    width: _face.width,
    height: _face.height,
  );
  static final _silhouette = [
    for (var corner = 0; corner < 4; corner++)
      for (var step = 0; step <= 4; step++)
        Offset.fromDirection((-1 + corner + step / 4) * pi / 2, 11) +
            [
              const Offset(41, -63),
              const Offset(41, 63),
              const Offset(-41, 63),
              const Offset(-41, -63),
            ][corner],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final orbit = _ramp(time, .27, .48, Curves.easeInOutSine);
    const pickAt = DrawCeremony._pickAt;
    final push = _ramp(time, .54, .73, Curves.easeInOutCubic);
    final settle = _ramp(time, .78, .98, Curves.easeOutCubic);
    final spread = _ramp(time, .53, .73, Curves.easeInOutCubic);
    final reveal = _ramp(time, .74, .99, Curves.easeOutCubic);
    final impact = sin(reveal * pi);

    final firstSlot = pickedSlots.first;
    final exitAngle = firstSlot.isEven ? .42 : pi + .42;
    final slotAngle = firstSlot * _tau / DrawCeremony.ticketCount;
    final extractionSpin = exitAngle - slotAngle;
    final fan = _ramp(time, .30, pickAt, Curves.easeInOutSine);
    final spin = extractionSpin - .36 * (1 - fan);
    final sources = {
      for (final slot in pickedSlots)
        slot: _fannedCard(slot, extractionSpin, 0),
    };
    final slots = pickedSlots.toList()
      ..sort((a, b) => _screenX(sources[a]!).compareTo(_screenX(sources[b]!)));
    final count = slots.length;
    final picks = {
      for (final (index, slot) in slots.indexed)
        if (time >= pickAt + index * .018)
          slot: _extractedCard(sources[slot]!, index, count, settle),
    };
    var focus = (x: 0.0, y: 0.0, z: 0.0);
    for (final slot in slots) {
      focus = _plus(focus, (picks[slot] ?? sources[slot]!).position);
    }
    final follow = push / count;
    final camera = _Camera(
      origin: Offset(size.width / 2, size.height * .46),
      focus: (x: focus.x * follow, y: focus.y * follow, z: focus.z * follow),
      distance:
          4.50 + .10 * orbit - (count == 1 ? 1.88 : 1.18) * push + .66 * settle,
      focalLength: size.shortestSide * 1.49,
      view: _Rotation(
        -.42 + .06 * orbit + .48 * push - .12 * settle,
        -.22 + 1.18 * orbit - 1.23 * push + .27 * settle,
        -.08 + .25 * orbit - .29 * push + .12 * settle,
      ),
    );

    final center = (x: focus.x / count, y: focus.y / count, z: focus.z / count);
    final prizeCenter = camera.project(camera.toView(center));
    _paintLight(
      canvas,
      size,
      Offset.lerp(camera.origin, prizeCenter, push)!,
      reveal,
      impact,
    );
    _paintFloor(canvas, camera, reveal);

    _paintSparks(canvas, camera, reveal);
    final surfaces = <_Surface>[];
    for (var slot = 0; slot < DrawCeremony.ticketCount; slot++) {
      if (picks[slot] case final picked?) {
        _projectTicket(surfaces, camera, picked, slot);
      } else if (spread < 1) {
        final card = _fannedCard(slot, spin + .32 * spread, spread);
        _projectTicket(
          surfaces,
          camera,
          time < pickAt ? _shuffleCard(slot, card) : card,
          slot,
        );
      }
    }
    _paintSurfaces(canvas, surfaces);

    final footer = Rect.fromLTRB(0, size.height - 55, size.width, size.height);
    canvas.drawRect(
      footer,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x000a1616), Color(0xea0a1616)],
        ).createShader(footer),
    );
  }

  // Match the left-to-right ordering of the fan as the camera completes its orbit.
  double _screenX(_Pose card) => card.position.x * .57 + card.position.z * .82;

  _Pose _extractedCard(_Pose source, int index, int count, double settle) {
    final offset = index * .018;
    final raise = _ramp(
      time,
      DrawCeremony._pickAt + offset,
      .56 + offset,
      Curves.easeOutCubic,
    );
    final extract = _ramp(
      time,
      .54 + offset,
      .71 + offset,
      Curves.easeInOutCubic,
    );
    final flip = _ramp(
      time,
      .64 + offset * 1.6,
      .84 + offset * 1.6,
      Curves.easeInOutCubic,
    );
    final lift = sin(pi * extract);
    final side = _screenX(source).isNegative ? -1 : 1;
    final lane = (index - (count - 1) / 2) * (count == 4 ? .76 : .93);
    final scale = count == 4 ? .78 : (count == 3 ? .90 : 1.0);
    double blend(double start, double end) => start + (end - start) * extract;
    return (
      position: (
        x: blend(source.position.x + side * .19 * raise, lane),
        y:
            blend(source.position.y - .61 * raise, -.27 + .13 * settle) -
            .11 * lift,
        z:
            blend(source.position.z + .33 * raise, .78 - .19 * settle) +
            .10 * lift,
      ),
      rotation: _Rotation(
        blend(source.rotation.pitch + .12 * raise, 0) + .19 * lift,
        blend(source.rotation.yaw, pi) + pi * flip,
        blend(source.rotation.roll - side * .12 * raise, 0) - side * .20 * lift,
      ),
      scale: blend(source.scale + .08 * raise, scale),
      result: flip >= .5 ? ticketGroups[index] : null,
    );
  }

  _Pose _shuffleCard(int slot, _Pose fanned) {
    const packetSize = DrawCeremony.ticketCount ~/ 2;
    final left = slot < packetSize;
    final side = left ? -1 : 1;
    final layer = slot % packetSize;
    final order = layer * 2 + (left ? 0 : 1);
    final split = _ramp(time, 0, .105, Curves.easeOutCubic);
    final releaseAt = .107 + order * .018;
    final riffle = _ramp(
      time,
      releaseAt,
      releaseAt + .083,
      Curves.easeInOutSine,
    );
    final spring = sin(pi * riffle);
    final packet = split * (1 - riffle);
    final fan = _ramp(
      time,
      .310 + order * .006,
      DrawCeremony._pickAt,
      Curves.easeInOutCubic,
    );
    double openIntoFan(double start, double end) => start + (end - start) * fan;

    // Alternating release order interleaves the two packets at the same stack.
    return (
      position: (
        x: openIntoFan(
          side * (.02 * (1 - riffle) + .96 * packet),
          fanned.position.x,
        ),
        y: openIntoFan(.10 - order * .049 - .32 * spring, fanned.position.y),
        z: openIntoFan(
          -.10 + order * .055 + side * .14 * packet + .12 * spring,
          fanned.position.z,
        ),
      ),
      rotation: _Rotation(
        openIntoFan(-.38 - .29 * packet + .37 * spring, fanned.rotation.pitch),
        openIntoFan(
          pi + side * (.24 * packet + .23 * spring),
          fanned.rotation.yaw,
        ),
        openIntoFan(side * (.24 * packet + .34 * spring), fanned.rotation.roll),
      ),
      scale: fanned.scale,
      result: null,
    );
  }

  _Pose _fannedCard(int index, double spin, double spread) {
    final offset = index * _tau / DrawCeremony.ticketCount;
    final angle = offset + spin;
    final ripple = sin(offset + spin * 1.28);
    final radius = 1.24;
    return (
      position: (
        x: cos(angle) * (radius + spread * .70),
        y: ripple * .15 + spread * .17,
        z: sin(angle) * radius * .54 - spread * 1.11,
      ),
      rotation: _Rotation(
        -.38 + .26 * ripple,
        pi + cos(angle + .7) * .90,
        .37 * sin(angle + .6) + spread * sin(offset) * .34,
      ),
      scale: .72 * (1 - _ramp(spread, .15, 1, Curves.easeIn)),
      result: null,
    );
  }

  void _paintLight(
    Canvas canvas,
    Size size,
    Offset focus,
    double reveal,
    double impact,
  ) {
    final rect = Offset.zero & size;
    final fill = Paint()
      ..shader =
          RadialGradient(
            colors: [
              Color.lerp(
                const Color(0xff275949),
                const Color(0xff735538),
                reveal,
              )!,
              const Color(0xff132e2b),
              const Color(0xff071213),
            ],
            stops: const [0, .47, 1],
          ).createShader(
            Rect.fromCircle(center: focus, radius: size.longestSide * .64),
          );
    canvas.drawRect(rect, fill);
    final glow = Rect.fromCircle(
      center: focus,
      radius: size.shortestSide * .49,
    );
    fill.shader = RadialGradient(
      colors: [
        _gold.withValues(alpha: .22 * impact),
        _gold.withValues(alpha: 0),
      ],
    ).createShader(glow);
    canvas.drawRect(glow, fill);
  }

  void _paintFloor(Canvas canvas, _Camera camera, double reveal) {
    final accent = Color.lerp(_mint, _gold, reveal)!;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    Offset floor(double angle, double radius) => camera.project(
      camera.toView((
        x: cos(angle) * radius,
        y: _floor,
        z: sin(angle) * radius,
      )),
    );
    for (final radius in [0.58, .86, 1.20, 1.78]) {
      line.color = accent.withValues(alpha: radius == .86 ? .40 : .19);
      canvas.drawPath(
        Path()..addPolygon([
          for (var i = 0; i < 52; i++) floor(i * _tau / 52, radius),
        ], true),
        line,
      );
    }
    for (var i = 0; i < 32; i++) {
      final angle = i * _tau / 32;
      line.color = accent.withValues(alpha: i % 4 == 0 ? .50 : .23);
      canvas.drawLine(
        floor(angle, 1.23),
        floor(angle, i % 4 == 0 ? 1.37 : 1.29),
        line,
      );
    }
    if (reveal > 0 && reveal < 1) {
      line
        ..color = _gold.withValues(alpha: (1 - reveal) * .66)
        ..strokeWidth = 2;
      final ring = 0.57 + reveal * 1.05;
      canvas.drawPath(
        Path()..addPolygon([
          for (var i = 0; i < 52; i++) floor(i * _tau / 52, ring),
        ], true),
        line,
      );
    }
  }

  void _paintSparks(Canvas canvas, _Camera camera, double reveal) {
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var index = 0; index < 27; index++) {
      final angle = index * 2.39996 + time * 2;
      final spread = .60 + (index % 7) * .105 + reveal * .38;
      final point = camera.toView((
        x: cos(angle) * spread,
        y: sin(angle) * spread * .62,
        z: cos(index * 2.19) * (.92 + reveal * .36),
      ));
      final at = camera.project(point);
      final radio = camera.magnification(point) / camera.scale;
      final flicker = .66 + sin(index + time * 12) * .28;
      paint.color = (index.isEven ? _gold : _mint).withValues(
        alpha: (.22 + (1 - reveal) * reveal * .92) * flicker,
      );
      canvas.drawCircle(at, (index % 4 == 0 ? 1.55 : .9) * radio, paint);
      if (index % 4 == 0 && reveal > 0 && reveal < 1) {
        paint.strokeWidth = 1.1;
        final tail =
            Offset(cos(angle), sin(angle) * .62) * (8 * reveal * radio);
        canvas.drawLine(at, at - tail, paint);
      }
    }
  }

  void _paintSurfaces(Canvas canvas, List<_Surface> surfaces) {
    surfaces.sort((a, b) => a.depth.compareTo(b.depth));
    for (var index = 0; index < surfaces.length; index++) {
      final surface = surfaces[index];
      Path? visible;
      for (var earlier = 0; earlier < index; earlier++) {
        final other = surfaces[earlier];
        if (other.owner == surface.owner ||
            !surface.bounds.overlaps(other.bounds)) {
          continue;
        }
        final occlusion = other.portionInFrontOf(surface);
        if (occlusion == null) continue;
        visible = Path.combine(
          PathOperation.difference,
          visible ?? surface.outline,
          occlusion,
        );
        if (visible.getBounds().isEmpty) break;
      }
      if (visible != null) {
        if (visible.getBounds().isEmpty) continue;
        canvas.save();
        canvas.clipPath(visible);
      }
      surface.paint(canvas);
      if (visible != null) canvas.restore();
    }
  }

  void _projectTicket(
    List<_Surface> surfaces,
    _Camera camera,
    _Pose card,
    int owner,
  ) {
    if (card.scale < .02) return;
    final center = camera.toView(card.position);
    _Point axis(_Point vector) =>
        camera.view.apply(card.rotation.apply(vector));
    final unit = _textureUnit * card.scale;
    final thickness = _thickness * card.scale;
    final textureRight = axis((x: unit, y: 0, z: 0));
    final textureDown = axis((x: 0, y: unit, z: 0));
    _Vertex mesh(Offset corner, double depth) {
      final point = _plus(
        center,
        axis((x: corner.dx * unit, y: corner.dy * unit, z: depth)),
      );
      return (
        point: camera.project(point),
        inverseDepth: 1 / (camera.distance - point.z),
      );
    }

    void add(List<_Vertex> polygon, void Function(Canvas) paint) {
      final surface = _Surface(owner, polygon, paint);
      if (surface.minDepth != null) surfaces.add(surface);
    }

    final near = [for (final corner in _silhouette) mesh(corner, thickness)];
    final far = [for (final corner in _silhouette) mesh(corner, -thickness)];
    for (var i = 0; i < near.length; i++) {
      final next = (i + 1) % near.length;
      if (_orientation(near[next].point, near[i].point, far[i].point) <= 0) {
        continue;
      }
      final color = Color.lerp(
        const Color(0xff886032),
        const Color(0xfff5cf83),
        .45 + (_silhouette[i].dx / _face.width) * .55,
      )!;
      final vertices = [near[next], near[i], far[i], far[next]];
      final side = Path()
        ..addPolygon([for (final vertex in vertices) vertex.point], true);
      add(vertices, (canvas) => canvas.drawPath(side, Paint()..color = color));
    }

    final front =
        _orientation(near[0].point, near[5].point, near[10].point) > 0;
    final depth = front ? thickness : -thickness;
    final panelCenter = _plus(center, axis((x: 0, y: 0, z: depth)));
    final texture = camera.plane(panelCenter, textureRight, textureDown);
    add(front ? near : far, (canvas) {
      canvas
        ..save()
        ..translate(camera.origin.dx, camera.origin.dy)
        ..transform(texture.storage);
      _paintFace(canvas, front ? card.result : null);
      canvas.restore();
    });
  }

  static double _orientation(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

  void _paintFace(Canvas canvas, List<String>? result) {
    final resultSide = result != null;
    final body = RRect.fromRectAndRadius(_faceRect, const Radius.circular(11));
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: resultSide
            ? const [Color(0xfffff2cb), _paper]
            : const [Color(0xff41826d), Color(0xff133c35)],
      ).createShader(_faceRect);
    canvas.drawRRect(body, paint);
    paint
      ..shader = null
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..color = _gold;
    canvas.drawRRect(body.deflate(.75), paint);
    paint
      ..strokeWidth = .85
      ..color = resultSide ? const Color(0xffa56e32) : const Color(0xaac6e9ce);
    canvas.drawRRect(body.deflate(7), paint);
    canvas.drawRRect(body.deflate(10), paint);
    paint.style = PaintingStyle.fill;
    for (final sign in [-1, 1]) {
      _star(canvas, Offset(0, sign * 55.0), 5, paint);
    }
    if (resultSide) {
      if (result.length > 1) {
        _paintTicketGroup(canvas, result);
        return;
      }
      final nameStyle = label.copyWith(
        color: const Color(0xff4f3320),
        fontSize: 17,
        fontWeight: FontWeight.w800,
        height: 1.13,
      );
      final name = TextPainter(
        text: TextSpan(text: result.single, style: nameStyle),
        textAlign: TextAlign.center,
        textDirection: direction,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: 79);
      final unwrappedWidth = name.maxIntrinsicWidth;
      if (unwrappedWidth > 79 && unwrappedWidth <= 102) {
        name.text = TextSpan(
          text: result.single,
          style: nameStyle.copyWith(fontSize: 17 * 78 / unwrappedWidth),
        );
        name.layout(maxWidth: 79);
      }
      name.paint(canvas, Offset(-name.width / 2, -name.height / 2));
      name.dispose();
    } else {
      paint
        ..style = PaintingStyle.stroke
        ..color = const Color(0x8dd1efc9);
      for (final radius in [15.0, 29.0]) {
        canvas.drawCircle(Offset.zero, radius, paint);
      }
      paint
        ..style = PaintingStyle.fill
        ..color = _gold;
      _star(canvas, Offset.zero, 23, paint);
    }
  }

  void _paintTicketGroup(Canvas canvas, List<String> names) {
    final remaining = names.length > 4 ? names.length - 3 : 0;
    final shown = remaining > 0 ? names.take(3) : names;
    final lines = [...shown, if (remaining > 0) '另有 $remaining 项'];
    final step = lines.length <= 2 ? 26.0 : 20.0;
    for (final (index, entry) in lines.indexed) {
      final overflow = remaining > 0 && index == lines.length - 1;
      final painter = TextPainter(
        text: TextSpan(
          text: entry,
          style: label.copyWith(
            color: overflow ? const Color(0xff795122) : const Color(0xff4f3320),
            fontSize: overflow ? 13 : (lines.length <= 2 ? 17 : 15),
            fontWeight: overflow ? FontWeight.w600 : FontWeight.w800,
          ),
        ),
        textDirection: direction,
        textAlign: TextAlign.center,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 80);
      final y = (index - (lines.length - 1) / 2) * step;
      painter.paint(canvas, Offset(-painter.width / 2, y - painter.height / 2));
      painter.dispose();
    }
  }

  void _star(Canvas canvas, Offset center, double radius, Paint paint) {
    canvas.drawPath(
      Path()..addPolygon([
        for (var i = 0; i < 8; i++)
          center +
              Offset.fromDirection(i * pi / 4, radius * (i.isEven ? 1 : .26)),
      ], true),
      paint,
    );
  }

  @override
  bool shouldRepaint(_DrawScene oldDelegate) =>
      oldDelegate.time != time ||
      oldDelegate.ticketGroups != ticketGroups ||
      oldDelegate.pickedSlots != pickedSlots ||
      oldDelegate.direction != direction ||
      oldDelegate.label != label;
}
