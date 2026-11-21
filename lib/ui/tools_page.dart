import 'package:material_ui/material_ui.dart';

import 'common.dart';
import 'tools/draw_card.dart';
import 'tools/quick_roll_card.dart';

enum _Tool { draw, roll }

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final _drawKey = GlobalKey();
  final _rollKey = GlobalKey();
  var _selected = _Tool.draw;

  String _memberEntries() => widget.controller.repository
      .members()
      .where((member) => member.active)
      .map((member) => member.name)
      .join('\n');

  @override
  Widget build(BuildContext context) => PageBody(
    storageKey: 'dorm-tools',
    children: [
      Text('寝室工具箱', style: Theme.of(context).textTheme.headlineMedium),
      LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 700;
          final draw = DrawCard(
            key: _drawKey,
            memberEntries: _memberEntries,
            showTitle: wide,
          );
          final quick = QuickRollCard(key: _rollKey, showTitle: wide);
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 14,
              children: [
                Expanded(flex: 3, child: draw),
                Expanded(flex: 2, child: quick),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              SegmentedButton<_Tool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Tool.draw, label: Text('抽签与分组')),
                  ButtonSegment(value: _Tool.roll, label: Text('骰子与硬币')),
                ],
                selected: {_selected},
                onSelectionChanged: (choice) =>
                    setState(() => _selected = choice.single),
              ),
              Visibility(
                visible: _selected == _Tool.draw,
                maintainState: true,
                child: draw,
              ),
              Visibility(
                visible: _selected == _Tool.roll,
                maintainState: true,
                child: quick,
              ),
            ],
          );
        },
      ),
    ],
  );
}
