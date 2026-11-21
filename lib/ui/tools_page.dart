import 'package:material_ui/material_ui.dart';

import '../domain/draw.dart';
import 'common.dart';
import 'tools/draw_card.dart';
import 'tools/quick_roll_card.dart';

enum _Tool { draw, teams, roll }

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  var _selected = _Tool.draw;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final members = [
        for (final member in widget.controller.repository.members())
          if (member.active) member.name,
      ];
      return PageBody(
        storageKey: 'dorm-tools',
        children: [
          Text('寝室工具箱', style: Theme.of(context).textTheme.headlineMedium),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_Tool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Tool.draw, label: Text('抽签')),
                    ButtonSegment(value: _Tool.teams, label: Text('随机分组')),
                    ButtonSegment(value: _Tool.roll, label: Text('骰子与硬币')),
                  ],
                  selected: {_selected},
                  onSelectionChanged: (choice) =>
                      setState(() => _selected = choice.single),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Visibility(
                visible: _selected == _Tool.draw,
                maintainState: true,
                child: DrawCard(mode: DrawMode.draw, members: members),
              ),
              Visibility(
                visible: _selected == _Tool.teams,
                maintainState: true,
                child: DrawCard(mode: DrawMode.teams, members: members),
              ),
              Visibility(
                visible: _selected == _Tool.roll,
                maintainState: true,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: const QuickRollCard(showTitle: false),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}
