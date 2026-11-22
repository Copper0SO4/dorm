import 'dart:math';

import 'package:material_ui/material_ui.dart';

const _padColors = [
  Color(0xff6de6cf),
  Color(0xff8eb8ff),
  Color(0xffffb27d),
  Color(0xffc9adff),
  Color(0xffddeb88),
  Color(0xffff9ac0),
  Color(0xff79dbff),
  Color(0xfff7db97),
];

typedef _Pad = ({int first, int last, int size});
typedef _Packet = ({
  int pad,
  int source,
  String label,
  int members,
  double departure,
  double arrival,
});
typedef _Point = ({double x, double y, double z});
typedef _Labels =
    Map<(String, int, Color, TextDirection, String?), TextPainter>;

/// The stage batches large rosters for display. Assignment is already decided
/// by the draw and does not depend on any visual position or timing.
class GroupScenePlan {
  factory GroupScenePlan(List<List<String>> groups, List<String> roster) {
    final sourceOrder = {
      for (final (index, name) in roster.indexed) name.trim(): index,
    };
    final count = groups.fold(0, (sum, group) => sum + group.length);
    final padCount = min(_padColors.length, groups.length);
    final pads = <_Pad>[];
    final batches = <List<List<String>>>[];
    for (var index = 0; index < padCount; index++) {
      final start = index * groups.length ~/ padCount;
      final end = (index + 1) * groups.length ~/ padCount;
      final members = groups
          .sublist(start, end)
          .expand((group) => group)
          .toList();
      final batch = count <= 18 ? 1 : (members.length + 2) ~/ 3;
      pads.add((first: start + 1, last: end, size: members.length));
      batches.add([
        for (var offset = 0; offset < members.length; offset += batch)
          members.sublist(offset, min(offset + batch, members.length)),
      ]);
    }
    final rounds = batches.fold(0, (n, group) => max(n, group.length));
    final order = [
      for (var round = 0; round < rounds; round++)
        for (final (pad, group) in batches.indexed)
          if (round < group.length) (pad: pad, members: group[round]),
    ];
    final source = List.generate(order.length, (index) => index)
      ..sort(
        (a, b) => (sourceOrder[order[a].members.first] ?? a).compareTo(
          sourceOrder[order[b].members.first] ?? b,
        ),
      );
    final slots = {for (final (slot, index) in source.indexed) index: slot};
    return GroupScenePlan._(count, pads, [
      for (final (index, packet) in order.indexed)
        (
          pad: packet.pad,
          source: slots[index]!,
          label: packet.members.length > 1
              ? '+${packet.members.length}'
              : packet.members.single,
          members: packet.members.length,
          departure: .25 + .42 * index / max(1, order.length - 1),
          arrival: .49 + .42 * index / max(1, order.length - 1),
        ),
    ]);
  }

  GroupScenePlan._(this.memberCount, List<_Pad> pads, List<_Packet> packets)
    : _pads = List.unmodifiable(pads),
      _packets = List.unmodifiable(packets);

  final int memberCount;
  final List<_Pad> _pads;
  final List<_Packet> _packets;

  int get markerCount => _pads.length;
  int get packetCount => _packets.length;

  Color colorForGroup(int index, int total) =>
      _padColors[((index + 1) * markerCount - 1) ~/ total];

  int assignedAt(double progress) => _packets.fold(
    0,
    (sum, packet) => sum + (progress >= packet.arrival ? packet.members : 0),
  );
}

class GroupScene extends StatefulWidget {
  const GroupScene({
    super.key,
    required this.plan,
    required this.animation,
    required this.settled,
  });

  final GroupScenePlan plan;
  final Animation<double> animation;
  final bool settled;

  @override
  State<GroupScene> createState() => _GroupSceneState();
}

class _GroupSceneState extends State<GroupScene> {
  final _Labels _labels = {};

  void _clearLabels() {
    for (final label in _labels.values) {
      label.dispose();
    }
    _labels.clear();
  }

  @override
  void didUpdateWidget(GroupScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plan != widget.plan) _clearLabels();
  }

  @override
  void dispose() {
    _clearLabels();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: double.infinity,
        height: widget.settled
            ? (widget.plan.markerCount <= 4 ? 134 : 164)
            : (bounds.maxWidth * .54).clamp(208.0, 292.0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ExcludeSemantics(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _GroupPainter(
                  widget.plan,
                  widget.animation,
                  Directionality.of(context),
                  Theme.of(context).textTheme.labelMedium?.fontFamily,
                  _labels,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Camera {
  _Camera(Size size, double time)
    : origin = Offset(size.width / 2, size.height * .65),
      unit = min(size.width / 8.4, size.height / 5.8) {
    final yaw = .25 - .43 * Curves.easeInOutCubic.transform(time);
    final pitch = .62 - .12 * sin(pi * time);
    _cosYaw = cos(yaw);
    _sinYaw = sin(yaw);
    _cosPitch = cos(pitch);
    _sinPitch = sin(pitch);
  }

  final Offset origin;
  final double unit;
  late final double _cosYaw, _sinYaw, _cosPitch, _sinPitch;

  (Offset, double, double) project(_Point point) {
    final x = point.x * _cosYaw - point.z * _sinYaw;
    final z = point.x * _sinYaw + point.z * _cosYaw;
    final vertical = point.y * _cosPitch - z * _sinPitch;
    final depth = point.y * _sinPitch + z * _cosPitch;
    final scale = unit * 10 / (10 - depth);
    return (origin + Offset(x, -vertical) * scale, depth, scale);
  }
}

class _GroupPainter extends CustomPainter {
  _GroupPainter(
    this.plan,
    this.animation,
    this.direction,
    this.font,
    this._labels,
  ) : super(repaint: animation);

  final GroupScenePlan plan;
  final Animation<double> animation;
  final TextDirection direction;
  final String? font;
  final _Labels _labels;

  @override
  void paint(Canvas canvas, Size size) {
    final time = animation.value;
    final camera = _Camera(size, time);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff162c46), Color(0xff0a1429), Color(0xff101b32)],
        ).createShader(Offset.zero & size),
    );
    final light = Rect.fromCenter(
      center: Offset(size.width * .5, size.height * .45),
      width: size.width * 1.16,
      height: size.height * 1.35,
    );
    canvas.drawOval(
      light,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x4a347aaf), Color(0x0023486b)],
        ).createShader(light),
    );
    _floor(canvas, camera);

    final pads = _padPositions(plan.markerCount);
    final arrived = List.filled(pads.length, 0);
    final lastLanding = List.filled(pads.length, -1.0);
    final surfaces = <({double depth, void Function() paint})>[];
    for (final packet in plan._packets) {
      final target = pads[packet.pad];
      final color = _padColors[packet.pad];
      if (time >= packet.arrival) {
        arrived[packet.pad] += packet.members;
        lastLanding[packet.pad] = packet.arrival;
        continue;
      }
      final point = _packetPosition(packet, target, time);
      final (screen, depth, scale) = camera.project(point);
      final shadow = camera.project((x: point.x, y: -.16, z: point.z)).$1;
      canvas.drawOval(
        Rect.fromCenter(
          center: shadow,
          width: scale * 1.7,
          height: scale * .25,
        ),
        Paint()..color = const Color(0x48080f22),
      );
      final flying = _phase(time, packet.departure, packet.arrival);
      if (flying > 0) {
        final trail = Path()..moveTo(screen.dx, screen.dy);
        for (var step = 1; step <= 6; step++) {
          final sample = _packetPosition(
            packet,
            target,
            max(packet.departure, time - step * .013),
          );
          final at = camera.project(sample).$1;
          trail.lineTo(at.dx, at.dy);
        }
        canvas.drawPath(
          trail,
          Paint()
            ..color = color.withValues(alpha: .50 * sin(pi * flying))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }
      final tilt = .13 * sin(time * 5 * pi + packet.source) * sin(pi * time);
      surfaces.add((
        depth: depth,
        paint: () =>
            _packet(canvas, packet, screen, scale, flying, color, tilt),
      ));
    }
    for (final (index, pad) in pads.indexed) {
      surfaces.add((
        depth: camera.project(pad).$2,
        paint: () => _destination(
          canvas,
          camera,
          pad,
          plan._pads[index],
          _padColors[index],
          arrived[index],
          lastLanding[index] < 0
              ? 0
              : 1 - _phase(time, lastLanding[index], lastLanding[index] + .09),
        ),
      ));
    }
    // Member labels face the camera. Nearer labels therefore cover farther
    // labels at every point where their images overlap.
    surfaces.sort((a, b) => a.depth.compareTo(b.depth));
    for (final surface in surfaces) {
      surface.paint();
    }
  }

  static List<_Point> _padPositions(int count) {
    final rows = count <= 4 ? 1 : 2;
    final split = count ~/ rows;
    return [
      for (var row = 0; row < rows; row++)
        for (var col = 0; col < (row == 0 ? split : count - split); col++)
          (
            x: (col - ((row == 0 ? split : count - split) - 1) / 2) * 1.78,
            y: 0,
            z: rows == 1 ? 1.05 : (row == 0 ? -.75 : 1.55),
          ),
    ];
  }

  _Point _orbit(_Packet packet, double time) {
    final scatter = Curves.easeOutCubic.transform(_phase(time, 0, .22));
    final sweep = Curves.easeInOutCubic.transform(_phase(time, 0, .66));
    final angle = 2 * pi * packet.source / plan.packetCount + 1.55 * pi * sweep;
    final lift = sin(angle * 2 + packet.source * .9);
    return (
      x: sin(angle) * (1.4 + 1.46 * scatter),
      y: 1.55 + .36 * lift + .22 * scatter,
      z: cos(angle) * (1.20 + .20 * scatter),
    );
  }

  _Point _packetPosition(_Packet packet, _Point target, double time) {
    if (time <= packet.departure) return _orbit(packet, time);
    final from = _orbit(packet, packet.departure);
    final flight = _phase(time, packet.departure, packet.arrival);
    final movement = Curves.easeInOutCubic.transform(flight);
    final arc = sin(pi * movement);
    return (
      x:
          from.x +
          (target.x - from.x) * movement +
          .30 * arc * (packet.pad.isEven ? 1 : -1),
      y: from.y + (.12 - from.y) * movement + .56 * arc,
      z: from.z + (target.z - from.z) * movement + .36 * arc,
    );
  }

  void _floor(Canvas canvas, _Camera camera) {
    final paint = Paint()
      ..color = const Color(0x2f81b7db)
      ..strokeWidth = .75;
    for (var x = -6; x <= 6; x++) {
      canvas.drawLine(
        camera.project((x: x.toDouble(), y: -.18, z: -5)).$1,
        camera.project((x: x.toDouble(), y: -.18, z: 4)).$1,
        paint,
      );
    }
    for (var z = -5; z <= 4; z++) {
      canvas.drawLine(
        camera.project((x: -6, y: -.18, z: z.toDouble())).$1,
        camera.project((x: 6, y: -.18, z: z.toDouble())).$1,
        paint,
      );
    }
  }

  void _destination(
    Canvas canvas,
    _Camera camera,
    _Point center,
    _Pad pad,
    Color color,
    int landed,
    double pulse,
  ) {
    Path ring(double radius, double height) {
      final path = Path();
      for (var segment = 0; segment <= 32; segment++) {
        final angle = segment * pi / 16;
        final at = camera.project((
          x: center.x + radius * cos(angle),
          y: height,
          z: center.z + radius * sin(angle),
        )).$1;
        if (segment == 0) {
          path.moveTo(at.dx, at.dy);
        } else {
          path.lineTo(at.dx, at.dy);
        }
      }
      return path..close();
    }

    final active = landed > 0;
    final base = Paint();
    canvas.drawPath(ring(.79, -.12), base..color = const Color(0xff111c33));
    canvas.drawPath(
      ring(.79, 0),
      base
        ..color = Color.lerp(
          const Color(0xff20314d),
          color,
          active ? .30 : .12,
        )!,
    );
    final outline = Paint()
      ..color = color.withValues(alpha: active ? .93 : .56)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 1.5 : 1;
    canvas.drawPath(ring(.79, 0), outline);
    outline.color = color.withValues(alpha: active ? .54 : .25);
    canvas.drawPath(ring(.62, .006), outline);
    if (pulse > 0) {
      outline.color = color.withValues(alpha: pulse * .68);
      canvas.drawPath(ring(.82 + (1 - pulse) * .38, .025), outline);
    }
    final at = camera.project(center).$1;
    final range = pad.first == pad.last
        ? '${pad.first}'
        : '${pad.first}–${pad.last}';
    _text(
      canvas,
      range,
      at.translate(0, -4),
      11,
      active ? const Color(0xfff8fcff) : color,
      66,
    );
    _text(
      canvas,
      '$landed/${pad.size}',
      at.translate(0, 9),
      9,
      const Color(0xffd6e5f8),
      58,
    );
  }

  void _packet(
    Canvas canvas,
    _Packet packet,
    Offset at,
    double scale,
    double flight,
    Color color,
    double tilt,
  ) {
    final landing = Curves.easeInCubic.transform(flight);
    final width = (scale * 2.12).clamp(36.0, 108.0) * (1 - landing * .56);
    final height = (scale * .68).clamp(16.0, 30.0) * (1 - landing * .56);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: width,
      height: height,
    );
    final face = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    final accent = Color.lerp(
      const Color(0xffa9cced),
      color,
      _phase(flight, 0, .65),
    )!;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(tilt);
    canvas.drawRRect(
      face.shift(const Offset(0, 3)),
      Paint()..color = const Color(0xff101b31),
    );
    canvas.drawRRect(
      face,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(const Color(0xff315270), accent, .29)!,
            Color.lerp(const Color(0xff15263c), accent, .18)!,
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      face,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent,
    );
    if (height >= 15) {
      _text(
        canvas,
        packet.label,
        Offset.zero,
        height >= 23 ? 12 : 10,
        const Color(0xfff7fbff),
        width - 8,
      );
    }
    canvas.restore();
  }

  void _text(
    Canvas canvas,
    String label,
    Offset center,
    int size,
    Color color,
    double maxWidth,
  ) {
    final text = _labels.putIfAbsent(
      (label, size, color, direction, font),
      () => TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontFamily: font,
            fontSize: size.toDouble(),
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: direction,
        maxLines: 1,
        ellipsis: '…',
      ),
    )..layout(maxWidth: maxWidth);
    text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(_GroupPainter other) =>
      plan != other.plan ||
      animation != other.animation ||
      direction != other.direction ||
      font != other.font;
}

double _phase(double value, double start, double end) =>
    ((value - start) / (end - start)).clamp(0.0, 1.0);
