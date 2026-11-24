part of 'card_table.dart';

class _DebugHandCard extends StatelessWidget {
  const _DebugHandCard({
    super.key,
    required this.id,
    required this.selected,
    this.onTap,
  });

  final int id;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: onTap != null,
    child: Tooltip(
      message: PlayingCard.rankLabel(PlayingCard(id).rank),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: selected ? const Color(0xffffbd4a) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              width: 2,
              color: selected ? const Color(0xff704103) : Colors.transparent,
            ),
          ),
          child: Stack(
            children: [
              _Face(
                card: PlayingCard(id),
                width: 36,
                height: 48,
                selected: selected,
              ),
              if (selected)
                const Positioned(
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xff603900),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.check, size: 11, color: Colors.white),
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

class _CheatsDialog extends StatefulWidget {
  const _CheatsDialog({required this.session});

  final CardSession session;

  @override
  State<_CheatsDialog> createState() => _CheatsDialogState();
}

class _CheatsDialogState extends State<_CheatsDialog> {
  static const _codes = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
  static const _palette = [
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '10',
    'J',
    'Q',
    'K',
    'A',
    '2',
    'B',
    'R',
  ];
  final _input = TextEditingController();
  ({int seat, Object? deal, Set<int> cards})? _selection;
  String? _feedback;

  CardSession get _session => widget.session;

  Future<bool> _send(String action, RoomJson data) async {
    if (_session.working || _session.awaitingGit) return false;
    final debug = _session.view?['debug'] as RoomJson?;
    if (debug?['gui'] != true) return false;
    setState(() => _feedback = null);
    await _session.act(action, {'deal': debug?['deal'], ...data});
    if (!mounted) return false;
    setState(() => _feedback = _session.error);
    return _feedback == null;
  }

  Future<void> _selectSeat(int seat) async {
    if (await _send('debugGui', {'op': 'select', 'seat': seat}) && mounted) {
      setState(() => _selection = null);
      _input.clear();
    }
  }

  Future<void> _submit(int seat, String operation) async {
    final sequence = _input.text.trim();
    if (sequence.isEmpty) return;
    if (await _send('debugGui', {
          'op': operation,
          'seat': seat,
          'cards': sequence,
        }) &&
        mounted) {
      _input.clear();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final view = _session.view;
      final debug = view?['debug'] as RoomJson?;
      final seats = debug?['seats'] as RoomJson? ?? {};
      final editor = debug?['editor'] as RoomJson?;
      final seat = editor?['seat'] as int?;
      final cards = (editor?['cards'] as List? ?? const []).cast<int>();
      final names = {
        for (final player
            in (view?['people'] as List? ?? const []).cast<RoomJson>())
          player['id'] as int: player['name'] as String,
      };
      final hands = debug?['hands'] as RoomJson?;
      final busy = _session.working || _session.awaitingGit;
      final active = const {'bidding', 'playing'}.contains(view?['phase']);
      final selection = _selection;
      final selected =
          selection?.seat == seat && selection?.deal == debug?['deal']
          ? (selection?.cards ?? {}).intersection(cards.toSet())
          : <int>{};
      final own = seat != null && seat == view?['you'];
      final canPlay =
          own &&
          view?['phase'] == 'playing' &&
          seat == view?['turn'] &&
          !(view?['people'] as List? ?? const []).cast<RoomJson>().any(
            (player) => player['id'] == seat && player['autoplay'] == true,
          );
      final available = debug?['gui'] == true;
      return AlertDialog(
        title: const Text('Cheats'),
        scrollable: true,
        content: SizedBox(
          width: 520,
          child: Column(
            spacing: 10,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (available)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final code in _codes)
                      if (seats[code] case final int id)
                        ChoiceChip(
                          key: ValueKey(('cheats-seat', id)),
                          label: Text(
                            '$code · ${id == view?['you'] ? '自己' : names[id] ?? ''}',
                          ),
                          selected: id == seat,
                          onSelected: busy ? null : (_) => _selectSeat(id),
                        ),
                  ],
                ),
              if (available && seat != null) ...[
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('保留座位查看权限'),
                  value: hands?.containsKey('$seat') ?? false,
                  onChanged: busy
                      ? null
                      : (enabled) => _send('debugGui', {
                          'op': 'inspect',
                          'seat': seat,
                          'enabled': enabled,
                        }),
                ),
                if (own)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('强制出牌'),
                    value: debug?['forceOut'] == true,
                    onChanged: busy
                        ? null
                        : (enabled) => _send('debugGui', {
                            'op': 'force',
                            'seat': seat,
                            'enabled': enabled,
                          }),
                  ),
                Text('${names[seat] ?? '手牌'} · ${cards.length} 张'),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 168),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final id in cards)
                          _DebugHandCard(
                            key: ValueKey(('cheats-card', id)),
                            id: id,
                            selected: selected.contains(id),
                            onTap: active && !busy
                                ? () => setState(() {
                                    final next = {...selected};
                                    if (!next.add(id)) next.remove(id);
                                    _selection = (
                                      seat: seat,
                                      deal: debug?['deal'],
                                      cards: next,
                                    );
                                  })
                                : null,
                          ),
                      ],
                    ),
                  ),
                ),
                if (active && selected.isNotEmpty)
                  OutlinedButton(
                    onPressed: busy || cards.length <= selected.length
                        ? null
                        : () async {
                            if (await _send('debugRemove', {
                                  'seat': seat,
                                  'cards': selected.toList(),
                                }) &&
                                mounted) {
                              setState(() => _selection = null);
                            }
                          },
                    child: Text('删除 ${selected.length} 张牌'),
                  ),
                if (active) ...[
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final rank in _palette)
                        ActionChip(
                          label: Text(
                            rank == 'B'
                                ? '小王'
                                : rank == 'R'
                                ? '大王'
                                : rank,
                          ),
                          onPressed: busy
                              ? null
                              : () => _send('debugGui', {
                                  'op': 'add',
                                  'seat': seat,
                                  'cards': rank,
                                }),
                        ),
                    ],
                  ),
                  TextField(
                    key: const ValueKey('cheats-ranks'),
                    controller: _input,
                    enabled: !busy,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: '牌面',
                      hintText: '45245234',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(seat, 'add'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: busy ? null : () => _submit(seat, 'add'),
                        child: const Text('添加牌'),
                      ),
                      if (canPlay)
                        OutlinedButton(
                          onPressed: busy ? null : () => _submit(seat, 'play'),
                          child: const Text('指定出牌'),
                        ),
                      if (!own)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => _send('tomato', {'target': seat}),
                          child: const Text('丢番茄'),
                        ),
                    ],
                  ),
                ],
              ],
              if (_feedback != null) Text(_feedback!),
            ],
          ),
        ),
        actions: [
          if (available)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (await _send('debugGui', {'op': 'hide'}) &&
                          context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
              child: const Text('隐藏 Cheats'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
