import 'package:material_ui/material_ui.dart';

import '../domain/draw.dart';
import 'common.dart';
import 'cards_page.dart';
import 'tools/decision_wheel_card.dart';
import 'tools/draw_card.dart';
import 'tools/number_bomb_card.dart';
import 'tools/quick_roll_card.dart';

enum _Tool {
  draw('抽签'),
  teams('随机分组'),
  roll('骰子与硬币'),
  decide('决策盲盒'),
  bomb('数字炸弹');

  const _Tool(this.label);
  final String label;
}

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  static const _panelWidth = 416.0;
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
          Text(
            '寝室工具箱',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: panelGap),
          Card(
            child: ListTile(
              leading: const Icon(Icons.style_outlined),
              title: const Text('斗地主'),
              subtitle: const Text('本机、局域网与 GitHub 在线房间'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => CardsPage(controller: widget.controller),
                ),
              ),
            ),
          ),
          const SizedBox(height: panelGap),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _panelWidth),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<_Tool>(
                    showSelectedIcon: false,
                    emptySelectionAllowed: true,
                    segments: const [
                      ButtonSegment(value: _Tool.draw, label: Text('抽签')),
                      ButtonSegment(value: _Tool.teams, label: Text('随机分组')),
                      ButtonSegment(value: _Tool.roll, label: Text('骰子与硬币')),
                    ],
                    selected: switch (_selected) {
                      _Tool.draw || _Tool.teams || _Tool.roll => {_selected},
                      _Tool.decide || _Tool.bomb => const {},
                    },
                    onSelectionChanged: (choice) {
                      if (choice.isNotEmpty) {
                        setState(() => _selected = choice.single);
                      }
                    },
                  ),
                ),
              ),
              for (final tool in const [_Tool.decide, _Tool.bomb])
                ChoiceChip(
                  label: Text(tool.label),
                  selected: _selected == tool,
                  onSelected: (_) => setState(() => _selected = tool),
                ),
            ],
          ),
          const SizedBox(height: panelGap),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Visibility(
                visible: _selected == _Tool.draw,
                maintainState: true,
                child: DrawCard(
                  mode: DrawMode.draw,
                  members: members,
                  panelWidth: _panelWidth,
                ),
              ),
              Visibility(
                visible: _selected == _Tool.teams,
                maintainState: true,
                child: DrawCard(
                  mode: DrawMode.teams,
                  members: members,
                  panelWidth: _panelWidth,
                ),
              ),
              Visibility(
                visible: _selected == _Tool.roll,
                maintainState: true,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _panelWidth),
                    child: const QuickRollCard(showTitle: false),
                  ),
                ),
              ),
              Visibility(
                visible: _selected == _Tool.decide,
                maintainState: true,
                child: DecisionWheelCard(
                  members: members,
                  panelWidth: _panelWidth,
                ),
              ),
              Visibility(
                visible: _selected == _Tool.bomb,
                maintainState: true,
                child: NumberBombCard(panelWidth: _panelWidth),
              ),
            ],
          ),
        ],
      );
    },
  );
}
