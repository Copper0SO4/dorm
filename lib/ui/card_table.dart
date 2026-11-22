import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../game/card_rooms.dart';
import '../game/card_session.dart';
import '../game/cards.dart';
import 'card_art.dart';
import 'cards_page.dart';
import 'common.dart';

class CardTable extends StatefulWidget {
  const CardTable({
    super.key,
    required this.session,
    required this.view,
    required this.share,
  });

  final CardSession session;
  final RoomJson view;
  final VoidCallback share;

  @override
  State<CardTable> createState() => _CardTableState();
}

class _CardTableState extends State<CardTable> {
  static const _audio = MethodChannel('dorm/cards/audio');
  static const _gold = Color(0xfff4cf86);
  static const _ink = Color(0xff173038);
  static const _moveColors = {
    CardMove.lead: (Color(0xffa4dfc4), Color(0xff123b2c)),
    CardMove.beat: (Color(0xffffd083), Color(0xff3f270d)),
    CardMove.pass: (Color(0xffffc0cb), Color(0xff562331)),
  };

  final _selected = <int>{};
  final _chat = TextEditingController();
  final _sounds = <String, Uint8List>{};
  int _event = 0;
  int? _splash;
  Timer? _timer;
  bool _muted = false;
  String? _preferred;
  int? _hintTurn;
  int _hintCursor = 0;
  List<CardPlay>? _hints;

  RoomJson get view => widget.view;
  CardRules get rules => CardRules.fromJson(view['rules'] as RoomJson);
  CardSession get session => widget.session;
  bool get ownTurn => view['turn'] == view['you'];
  bool get isHost => view['host'] == view['you'];
  bool get inPlay => ['playing', 'bidding'].contains(view['phase']);
  bool get online => view['scope'] == 'online';
  bool get blocked => session.working || session.awaitingGit;
  List<RoomJson> get people => (view['people'] as List).cast<RoomJson>();
  List<RoomJson> get events => (view['events'] as List).cast<RoomJson>();
  List<PlayingCard> get hand =>
      (view['hand'] as List).cast<int>().map(PlayingCard.new).toList();
  Set<int> get wild => (view['wild'] as List).cast<int>().toSet();
  CardPlay? get previous => view['last'] is RoomJson
      ? CardPlay.fromJson(view['last'] as RoomJson)
      : null;
  RoomJson? get _previousTrick => view['previousTrick'] as RoomJson?;
  RoomJson? get _displayedPlay =>
      (view['last'] ?? _previousTrick?['play']) as RoomJson?;

  @override
  void initState() {
    super.initState();
    _event = (events.lastOrNull?['id'] as int?) ?? 0;
  }

  @override
  void didUpdateWidget(CardTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prior = oldWidget.view;
    final turnChanged = prior['turnVersion'] != view['turnVersion'];
    final sameHand = listEquals(prior['hand'] as List, view['hand'] as List);
    final sameTable =
        prior['room'] == view['room'] &&
        prior['you'] == view['you'] &&
        prior['phase'] == 'playing' &&
        view['phase'] == 'playing';
    if (!sameTable ||
        !sameHand ||
        (turnChanged && prior['turn'] == prior['you'])) {
      _selected.clear();
    }
    if (!sameTable || !sameHand || turnChanged) {
      _preferred = null;
      _hints = null;
      _hintTurn = null;
      _hintCursor = 0;
    }
    final recent = events
        .where((entry) => (entry['id'] as int) > _event)
        .toList();
    if (recent.isEmpty) return;
    _event = recent.last['id'] as int;
    final tomato = recent
        .where((entry) => entry['kind'] == 'tomato')
        .lastOrNull;
    if (tomato != null) {
      _splash = tomato['target'] as int?;
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) {
          setState(() {
            _splash = null;
          });
        }
      });
    }
    unawaited(_sound(recent.last['kind'] as String));
  }

  Future<void> _sound(String kind) async {
    if (_muted) return;
    final sample = switch (kind) {
      'deal' || 'landlord' => 'deal',
      'bomb' || 'rocket' => 'bomb',
      'finish' => 'finish',
      'tomato' => 'tomato',
      'play' || 'pass' || 'bid' || 'chat' => 'card',
      _ => null,
    };
    if (sample == null) return;
    try {
      final clip = _sounds[sample] ?? await _loadClip(sample);
      _sounds[sample] = clip;
      await _audio.invokeMethod<void>('play', clip);
    } on MissingPluginException {
      await SystemSound.play(SystemSoundType.click);
    } on PlatformException {
      // Audio is optional and must not interrupt a hand.
    }
  }

  Future<Uint8List> _loadClip(String sample) async {
    final bytes = await rootBundle.load('assets/cards_audio/$sample.wav');
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _chat.dispose();
    super.dispose();
  }

  List<CardPlay> _hintsForTurn() {
    final turn = view['turnVersion'] as int;
    final cached = _hints;
    if (cached != null && _hintTurn == turn) return cached;
    _hintTurn = turn;
    _hintCursor = 0;
    return _hints = hintPlays(hand, wild, previous, rules: rules);
  }

  void _hint() {
    if (!ownTurn || blocked) return;
    final options = _hintsForTurn();
    if (options.isEmpty) {
      notify(context, '没有可用的提示');
      return;
    }
    final play = options[_hintCursor % options.length];
    _hintCursor++;
    setState(() {
      _selected
        ..clear()
        ..addAll(play.cards.map((card) => card.id));
      _preferred = play.key;
    });
  }

  void _setSelected(Set<int> next) {
    setState(() {
      _selected
        ..clear()
        ..addAll(next);
      _preferred = null;
      _hintCursor = 0;
    });
  }

  Future<void> _play() async {
    if (!ownTurn || blocked || view['phase'] != 'playing') return;
    final cards = hand.where((card) => _selected.contains(card.id)).toList();
    final options = legalCardPlays(cards, wild, previous, rules: rules);
    if (options.isEmpty) {
      notify(context, disabledCardPlayMessage(cards, wild, rules) ?? '这组牌无法打出');
      return;
    }
    final initialTurn = view['turnVersion'];
    final preferred = options
        .where((play) => play.key == _preferred)
        .firstOrNull;
    final play =
        preferred ??
        (options.length == 1
            ? options.single
            : await showDialog<CardPlay>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('选择出牌方式'),
                  children: [
                    for (final play in options)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, play),
                        child: Text(
                          '${play.label} · ${PlayingCard.rankLabel(play.high)}'
                          '${play.ranks.isEmpty ? '' : ' · ${play.ranks.values.map(PlayingCard.rankLabel).join(' ')}'}',
                        ),
                      ),
                  ],
                ),
              ));
    if (!mounted || play == null) return;
    await session.act('play', {
      'cards': cards.map((card) => card.id).toList(),
      'pattern': play.key,
      'turnVersion': initialTurn,
    });
  }

  Future<void> _rules() async {
    final setup = await showDialog<({CardRules rules, CardLocation where})>(
      context: context,
      builder: (_) => CardRulesDialog(
        current: CardRules.fromJson(view['rules'] as RoomJson),
      ),
    );
    if (setup != null) {
      await session.act('rules', {'rules': setup.rules.toJson()});
    }
  }

  Future<void> _leave() async {
    if (inPlay) {
      final accepted = await confirm(
        context,
        '离开牌桌',
        '离开会结束这一手牌。',
        action: '离开房间',
      );
      if (!accepted) return;
    }
    await session.act('leave');
  }

  void _sendChat() {
    final text = _chat.text.trim();
    if (text.isEmpty || blocked) return;
    _chat.clear();
    unawaited(session.act('chat', {'text': text}));
  }

  String _person(Object? id) =>
      people.where((person) => person['id'] == id).firstOrNull?['name']
          as String? ??
      '';

  Map<int, CardMove> _turnMoves() {
    if (people.any((person) => person.containsKey('move'))) {
      final types = CardMove.values.asNameMap();
      return {
        for (final person in people)
          person['id'] as int: ?types[person['move']],
      };
    }

    final leader = view['leader'];
    if (view['last'] == null || leader is! int) return const {};
    final play = events
        .where(
          (event) =>
              event['from'] == leader &&
              ['play', 'bomb', 'rocket'].contains(event['kind']),
        )
        .lastOrNull;
    if (play == null) return const {};
    return {
      leader: CardMove.lead,
      for (final event in events)
        if (event['kind'] == 'pass' &&
            (event['id'] as int) > (play['id'] as int))
          event['from'] as int: CardMove.pass,
    };
  }

  Widget _moveTag(CardMove move) {
    final (background, ink) = _moveColors[move]!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          move.label,
          maxLines: 1,
          style: TextStyle(
            color: ink,
            fontSize: 12,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  List<RoomJson?> _opponents(int capacity) {
    final me = people.indexWhere((person) => person['id'] == view['you']);
    if (me < 0) return const [];
    final around = <RoomJson?>[
      for (var step = 1; step < people.length; step++)
        people[(me + step) % people.length],
    ];
    while (around.length < capacity - 1) {
      around.add(null);
    }
    return around.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final phase = view['phase'] as String;
    final playing = phase == 'playing' && ownTurn;
    final cards = hand;
    final chosen = [
      for (final card in cards)
        if (_selected.contains(card.id)) card,
    ];
    final roomRules = rules;
    final wildRanks = wild;
    final legal =
        playing &&
        chosen.isNotEmpty &&
        legalCardPlays(
          chosen,
          wildRanks,
          previous,
          rules: roomRules,
        ).isNotEmpty;
    final selectionIssue = playing && chosen.isNotEmpty && !legal
        ? disabledCardPlayMessage(chosen, wildRanks, roomRules) ?? '这手牌不能这样出'
        : null;
    final moves = _turnMoves();
    final opponents = _opponents(rules.players);
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 125);
    final error = session.error ?? (online ? session.gitError : null);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !blocked) unawaited(_leave());
      },
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -.16),
            radius: 1.12,
            colors: [Color(0xff286b52), Color(0xff0c2c32)],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400, maxHeight: 720),
            child: CardTableFrame(
              key: const ValueKey('dorm-card-table-frame'),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 450;
                  final last = _displayedPlay;
                  final actor =
                      (view['leader'] ?? _previousTrick?['leader']) as int?;
                  final handHeight = (constraints.maxHeight * .31).clamp(
                    74.0,
                    142.0,
                  );
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 8 : 25,
                      vertical: compact ? 4 : 10,
                    ),
                    child: Column(
                      spacing: compact ? 2 : 6,
                      children: [
                        _toolbar(),
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(0x549d9971),
                        ),
                        if (session.awaitingGit)
                          const LinearProgressIndicator(minHeight: 2),
                        if (error != null)
                          Text(
                            error,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xffffcab5)),
                          ),
                        if (opponents.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1040),
                            child: Row(
                              spacing: compact ? 4 : 8,
                              children: [
                                for (final player in opponents)
                                  Expanded(
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 172,
                                        ),
                                        child: _seat(
                                          player,
                                          moves[player?['id']],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: last == null || actor == null
                              ? const SizedBox.shrink()
                              : _playedCards(
                                  last,
                                  actor,
                                  opponents,
                                  moves[actor],
                                  motion,
                                  previousTrick: view['last'] == null,
                                ),
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 7,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 190),
                              child: _turnPrompt(),
                            ),
                            _actions(phase: phase, legal: legal),
                          ],
                        ),
                        if (cards.isNotEmpty) ...[
                          _handLine(
                            cards.length,
                            moves[view['you']],
                            chosen.length,
                            selectionIssue,
                          ),
                          _HandStrip(
                            cards: cards,
                            selected: _selected,
                            wild: wild,
                            enabled: phase == 'playing' && !blocked,
                            height: handHeight,
                            motion: motion,
                            tightSpacing:
                                Theme.of(context).platform ==
                                TargetPlatform.windows,
                            onChanged: _setSelected,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final bottom = (view['bottom'] as List).cast<int>();
    final bottomCount = bottom.isNotEmpty
        ? bottom.length
        : view['phase'] == 'bidding'
        ? rules.bottom
        : 0;
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(38, 38),
          iconSize: 19,
          padding: const EdgeInsets.all(8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      child: Row(
        spacing: 5,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                text: '${view['room']}',
                style: const TextStyle(
                  color: _gold,
                  fontWeight: FontWeight.w800,
                ),
                children: [
                  TextSpan(
                    text:
                        '  ${rules.mode.label} · ${rules.decks} 副 · 连炸${rules.chainBombs ? '开' : '关'}${online ? ' · 在线' : ''}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (bottomCount > 0) _bottomPreview(bottom, bottomCount),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '牌桌消息',
                  onPressed: _showChat,
                  icon: const Icon(Icons.chat_bubble_outline),
                ),
                if (isHost && !online)
                  IconButton(
                    tooltip: '分享牌桌',
                    onPressed: blocked ? null : widget.share,
                    icon: const Icon(Icons.qr_code_2),
                  ),
                IconButton(
                  tooltip: '牌桌菜单',
                  onPressed: _menu,
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomPreview(List<int> cards, int count) {
    final visible = math.min(3, count);
    return Tooltip(
      message: '地主底牌 · $count 张',
      child: Material(
        key: const ValueKey('bottom-card-preview'),
        color: const Color(0xff173b31),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xff6f9c86)),
        ),
        child: InkWell(
          onTap: _showBottom,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 3,
              children: [
                for (var index = 0; index < visible; index++)
                  if (cards.isNotEmpty)
                    _Face(
                      card: PlayingCard(cards[index]),
                      width: 20,
                      height: 27,
                    )
                  else
                    Container(
                      width: 20,
                      height: 27,
                      decoration: BoxDecoration(
                        color: const Color(0xff346352),
                        border: Border.all(color: const Color(0xff9dad85)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.diamond_outlined,
                        color: Color(0xffd3c69b),
                        size: 11,
                      ),
                    ),
                if (count > visible)
                  Text(
                    '+${count - visible}',
                    style: const TextStyle(color: _gold, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _menu() {
    final last = _displayedPlay;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        void run(VoidCallback action) {
          Navigator.pop(dialogContext);
          action();
        }

        return SimpleDialog(
          title: const Text('牌桌菜单'),
          children: [
            if (hand.isNotEmpty)
              SimpleDialogOption(
                onPressed: () => run(_showHand),
                child: const Text('展开手牌'),
              ),
            if (last != null)
              SimpleDialogOption(
                onPressed: () => run(() => _showPrevious(last)),
                child: const Text('查看上一手'),
              ),
            SimpleDialogOption(
              onPressed: () => run(() => setState(() => _muted = !_muted)),
              child: Text(_muted ? '打开音效' : '关闭音效'),
            ),
            if (isHost && inPlay)
              SimpleDialogOption(
                onPressed: blocked ? null : () => run(_abort),
                child: const Text('结束牌局'),
              ),
            SimpleDialogOption(
              onPressed: blocked ? null : () => run(_leave),
              child: const Text('离开房间'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _abort() async {
    if (await confirm(context, '结束当前牌局', '所有玩家将回到房间大厅。', action: '结束牌局')) {
      await session.act('abort');
    }
  }

  void _showBottom() {
    final cards = (view['bottom'] as List).cast<int>();
    if (cards.isNotEmpty) {
      _showCards('地主底牌', cards.map(PlayingCard.new).toList());
    } else {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('地主底牌'),
          content: Text('底牌 ${rules.bottom} 张 · 叫分后揭晓'),
        ),
      );
    }
  }

  void _showHand() => _showCards(
    '我的手牌',
    hand,
    interactive: view['phase'] == 'playing' && !blocked,
  );

  void _showPrevious(RoomJson last) {
    final cards = (last['cards'] as List).cast<RoomJson>();
    _showCards(
      last['label'] as String,
      [for (final value in cards) PlayingCard(value['id'] as int)],
      ranks: {
        for (final value in cards) value['id'] as int: value['rank'] as int,
      },
    );
  }

  void _showCards(
    String title,
    List<PlayingCard> cards, {
    Map<int, int> ranks = const {},
    bool interactive = false,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final card in cards)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: !interactive
                      ? null
                      : () {
                          if (view['phase'] != 'playing' ||
                              blocked ||
                              !hand.any((entry) => entry.id == card.id)) {
                            return;
                          }
                          final chosen = {..._selected};
                          if (!chosen.remove(card.id)) chosen.add(card.id);
                          _setSelected(chosen);
                          update(() {});
                        },
                  child: _Face(
                    card: card,
                    shown: ranks[card.id],
                    selected: interactive && _selected.contains(card.id),
                    width: 52,
                    height: 69,
                    wild: wild.contains(card.rank),
                  ),
                ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _turnPrompt() {
    final phase = view['phase'];
    final current = view['turn'];
    final status = switch (phase) {
      'bidding' => ownTurn ? '轮到你叫分' : '${_person(current)}正在叫分',
      'playing' when ownTurn && previous == null => '轮到你先出',
      'playing' when ownTurn => '轮到你出牌',
      'playing' => '${_person(current)}正在出牌',
      'finished' => view['result'] as String? ?? '牌局结束',
      _ => people.length == rules.players ? '座位已满，可以发牌' : '等待其他玩家入座',
    };
    final wildLabel = phase == 'playing' && wild.isNotEmpty
        ? '癞子 ${wild.map(PlayingCard.rankLabel).join('、')}'
        : null;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
        decoration: BoxDecoration(
          color: ownTurn ? const Color(0xff483d25) : const Color(0xff17372c),
          border: Border.all(
            color: ownTurn ? const Color(0xffcfad72) : const Color(0xff789682),
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Icon(
              Icons.circle,
              size: 6,
              color: ownTurn ? _gold : const Color(0xff98c6a6),
            ),
            Flexible(
              child: Text.rich(
                TextSpan(
                  text: status,
                  style: TextStyle(
                    color: ownTurn ? const Color(0xffffe9b8) : Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                  children: [
                    if (wildLabel != null)
                      TextSpan(
                        text: '  ·  $wildLabel',
                        style: const TextStyle(
                          color: Color(0xffffe3ac),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 1.1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playedCards(
    RoomJson last,
    int actor,
    List<RoomJson?> opponents,
    CardMove? move,
    Duration motion, {
    required bool previousTrick,
  }) {
    final mine = actor == view['you'];
    final seat = opponents.indexWhere((player) => player?['id'] == actor);
    final position = mine || seat < 0 ? .5 : (seat + .5) / opponents.length;
    final cards = (last['cards'] as List).cast<RoomJson>();
    final bomb = last['bomb'] == true;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1040),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxHeight < 22) return const SizedBox.shrink();
          final width = math.min(
            constraints.maxWidth,
            (106 + cards.length * 19).clamp(145, 580).toDouble(),
          );
          final left = (constraints.maxWidth * position - width / 2).clamp(
            0.0,
            constraints.maxWidth - width,
          );
          final insetTop = mine || constraints.maxHeight < 190 ? 0.0 : 24.0;
          return Stack(
            children: [
              Positioned(
                key: ValueKey(mine ? 'my-played-cards' : 'played-by-$actor'),
                left: left,
                top: mine ? null : insetTop,
                bottom: mine ? 0 : null,
                width: width,
                height: math.min(132, constraints.maxHeight - insetTop),
                child: TweenAnimationBuilder<double>(
                  key: ValueKey((actor, last['key'], cards.firstOrNull?['id'])),
                  tween: Tween(begin: 0, end: 1),
                  duration: motion * 1.56,
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) => Transform.translate(
                    offset: Offset(0, (1 - value) * (mine ? 8 : -8)),
                    child: Opacity(opacity: .55 + value * .45, child: child),
                  ),
                  child: GestureDetector(
                    onTap: () => _showPrevious(last),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: mine
                              ? const [Color(0xff443e29), Color(0xff2a281e)]
                              : const [Color(0xff234839), Color(0xff142c23)],
                        ),
                        border: Border.all(
                          color: bomb
                              ? const Color(0xffefc372)
                              : mine
                              ? const Color(0xffbe9b63)
                              : const Color(0xff6c9d8b),
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: bomb
                                ? const Color(0x612a210c)
                                : const Color(0x5408120e),
                            blurRadius: bomb ? 12 : 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 1),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              spacing: 4,
                              children: [
                                Flexible(
                                  child: Text(
                                    mine ? '我的出牌' : '${_person(actor)} 出牌',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: mine ? _gold : Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                if (previousTrick)
                                  const Text(
                                    '上轮',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                else if (move != null)
                                  _moveTag(move),
                                Flexible(
                                  child: Text(
                                    last['label'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, limits) {
                                  if (limits.maxHeight < 20) {
                                    return const SizedBox.shrink();
                                  }
                                  return _HandStrip(
                                    cards: [
                                      for (final card in cards)
                                        PlayingCard(card['id'] as int),
                                    ],
                                    shown: {
                                      for (final card in cards)
                                        card['id'] as int: card['rank'] as int,
                                    },
                                    selected: const {},
                                    wild: const {},
                                    enabled: false,
                                    height: limits.maxHeight,
                                    motion: motion,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _handLine(int count, CardMove? move, int chosen, String? issue) {
    final you = view['you'];
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        Text(
          '我 · $count 张${you == view['landlord'] ? ' · 地主' : ''}',
          style: const TextStyle(
            color: _gold,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (move != null) _moveTag(move),
        if (chosen > 0) ...[
          Text(
            issue ?? '已选 $chosen 张',
            style: TextStyle(
              color: issue != null ? const Color(0xffffc9aa) : Colors.white70,
              fontSize: 12,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(38, 24),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              foregroundColor: _gold,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 12),
            ),
            onPressed: blocked ? null : () => _setSelected({}),
            child: const Text('清空'),
          ),
        ],
      ],
    );
  }

  Widget _actions({required String phase, required bool legal}) {
    final quiet = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
      backgroundColor: const Color(0xff24473a),
      side: const BorderSide(color: Color(0xff6d9a85)),
      minimumSize: const Size(74, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final playStyle = FilledButton.styleFrom(
      backgroundColor: const Color(0xffffd28b),
      foregroundColor: const Color(0xff342611),
      disabledBackgroundColor: const Color(0xff6d6248),
      disabledForegroundColor: Colors.white54,
      minimumSize: const Size(90, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
    );
    final children = <Widget>[];
    final turnVersion = view['turnVersion'];
    if (phase == 'bidding' && ownTurn) {
      children.add(
        OutlinedButton(
          style: quiet,
          onPressed: blocked
              ? null
              : () =>
                    session.act('bid', {'bid': 0, 'turnVersion': turnVersion}),
          child: const Text('不叫'),
        ),
      );
      for (var bid = (view['bid'] as int) + 1; bid <= 3; bid++) {
        children.add(
          FilledButton(
            style: playStyle,
            onPressed: blocked
                ? null
                : () => session.act('bid', {
                    'bid': bid,
                    'turnVersion': turnVersion,
                  }),
            child: Text('$bid 分'),
          ),
        );
      }
    }
    if (phase == 'playing' && ownTurn) {
      children.addAll([
        OutlinedButton(
          style: quiet,
          onPressed: blocked || previous == null
              ? null
              : () => session.act('pass', {'turnVersion': turnVersion}),
          child: const Text('不出'),
        ),
        OutlinedButton(
          style: quiet,
          onPressed: blocked ? null : _hint,
          child: const Text('提示'),
        ),
        FilledButton(
          style: playStyle,
          onPressed: blocked || !legal ? null : _play,
          child: const Text('出牌'),
        ),
      ]);
    }
    if (isHost && !inPlay) {
      children.addAll([
        FilledButton.icon(
          style: playStyle,
          onPressed: !blocked && people.length == rules.players
              ? () => session.act('start')
              : null,
          icon: const Icon(Icons.play_arrow),
          label: Text(phase == 'finished' ? '再来一局' : '发牌开局'),
        ),
        if (!online) ...[
          OutlinedButton(
            style: quiet,
            onPressed: blocked || people.length >= rules.players
                ? null
                : () => session.act('bot'),
            child: const Text('添加电脑玩家'),
          ),
          if (people.any((person) => person['bot'] == true))
            OutlinedButton(
              style: quiet,
              onPressed: blocked ? null : () => session.act('removeBot'),
              child: const Text('移除电脑玩家'),
            ),
        ],
        OutlinedButton(
          style: quiet,
          onPressed: blocked ? null : _rules,
          child: const Text('调整规则'),
        ),
      ]);
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xcc0d251d),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x856e9783)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 7,
          runSpacing: 4,
          children: children,
        ),
      ),
    );
  }

  Widget _seat(RoomJson? player, CardMove? move) {
    if (player == null) {
      return const SizedBox(
        height: 37,
        child: Center(
          child: Text(
            '空座',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ),
      );
    }
    final id = player['id'];
    final name = player['name'] as String;
    final turn = id == view['turn'];
    final tomato = _splash == id;
    final landlord = id == view['landlord'];
    return Semantics(
      label:
          '$name ${player['cards']} 张${move == null ? '' : '，${move.label}'}',
      button: true,
      child: Material(
        color: tomato
            ? const Color(0xffae4031)
            : turn
            ? const Color(0xff3e5338)
            : const Color(0xff244437),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(
            color: turn
                ? _gold
                : _moveColors[move]?.$1 ?? const Color(0xff628678),
            width: turn ? 1.8 : 1,
          ),
        ),
        child: InkWell(
          onTap: blocked ? null : () => _seatMenu(player),
          borderRadius: BorderRadius.circular(13),
          child: SizedBox(
            height: 43,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: LayoutBuilder(
                builder: (context, limits) => Row(
                  children: [
                    if (limits.maxWidth > 96) ...[
                      Container(
                        width: 25,
                        height: 25,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Color(0xff4b7663),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          tomato
                              ? '🍅'
                              : player['bot'] == true
                              ? '机'
                              : String.fromCharCode(
                                  name.runes.firstOrNull ?? 0x5ba2,
                                ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              height: 1.1,
                            ),
                          ),
                          if (move != null)
                            _moveTag(move)
                          else if (landlord)
                            const Text(
                              '地主',
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: _gold,
                                fontSize: 10,
                                height: 1.1,
                              ),
                            ),
                        ],
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xffedddbb),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          '${player['cards']}',
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _seatMenu(RoomJson player) {
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(player['name'] as String),
        children: [
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(context);
              unawaited(session.act('tomato', {'target': player['id']}));
            },
            child: const Text('🍅 丢番茄'),
          ),
          if (isHost && !inPlay)
            SimpleDialogOption(
              onPressed: () async {
                Navigator.pop(context);
                if (await confirm(
                  this.context,
                  '移出房间',
                  '将${player['name']}移出牌桌。',
                  action: '移出',
                )) {
                  await session.act('kick', {'target': player['id']});
                }
              },
              child: const Text('移出房间'),
            ),
        ],
      ),
    );
  }

  void _showChat() {
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final history =
              (session.view?['events'] as List?)?.cast<RoomJson>() ?? [];
          return AlertDialog(
            scrollable: true,
            title: const Text('牌桌消息'),
            content: SizedBox(
              width: 380,
              child: Column(
                spacing: 8,
                children: [
                  SizedBox(
                    height: (MediaQuery.sizeOf(context).height * .30).clamp(
                      68.0,
                      155.0,
                    ),
                    child: ListView(
                      children: [
                        for (final event in history.reversed.take(24))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              event['kind'] == 'chat'
                                  ? '${_person(event['from'])} · ${event['text']}'
                                  : event['text'] as String,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _chat,
                          enabled: !blocked,
                          onSubmitted: (_) => _sendChat(),
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(120),
                          ],
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '发条消息',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '发送',
                        onPressed: blocked ? null : _sendChat,
                        icon: const Icon(Icons.send),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({
    required this.card,
    this.shown,
    required this.width,
    required this.height,
    this.peek,
    this.cornerHeight = double.infinity,
    this.selected = false,
    this.wild = false,
    this.onActivate,
  });

  final PlayingCard card;
  final int? shown;
  final double width;
  final double height;
  final double? peek;
  final double cornerHeight;
  final bool selected;
  final bool wild;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    final rank = shown ?? card.rank;
    final suit = card.suit;
    final mark = suit == null ? '' : ' ${['♠', '♥', '♦', '♣'][suit]}';
    return Semantics(
      selected: selected,
      button: onActivate != null,
      onTap: onActivate,
      label: '${PlayingCard.rankLabel(rank)}$mark${wild ? ' 癞子' : ''}',
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: CardArtwork(
            rank: rank,
            suit: suit,
            peek: peek ?? width,
            cornerHeight: cornerHeight,
            selected: selected,
            wild: wild,
          ),
        ),
      ),
    );
  }
}

typedef _CardSlot = ({double left, double bottom, double peek, int row});
typedef _FanMetrics = ({
  double cardWidth,
  double cardHeight,
  double rowStep,
  double lift,
  List<_CardSlot> slots,
});

class _HandStrip extends StatefulWidget {
  const _HandStrip({
    required this.cards,
    this.shown = const {},
    required this.selected,
    required this.wild,
    required this.enabled,
    required this.height,
    required this.motion,
    this.tightSpacing = false,
    this.onChanged,
  });

  final List<PlayingCard> cards;
  final Map<int, int> shown;
  final Set<int> selected;
  final Set<int> wild;
  final bool enabled;
  final double height;
  final Duration motion;
  final bool tightSpacing;
  final ValueChanged<Set<int>>? onChanged;

  @override
  State<_HandStrip> createState() => _HandStripState();
}

class _HandStripState extends State<_HandStrip> {
  static const _dragThreshold = 7.0;
  final _surface = GlobalKey();
  int? _anchor;
  int? _current;
  int? _pointer;
  bool _raising = true;
  bool _dragging = false;
  Offset _pointerStart = Offset.zero;
  _FanMetrics? _startLayout;

  @override
  void didUpdateWidget(_HandStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        oldWidget.cards.length != widget.cards.length ||
        oldWidget.cards.indexed.any(
          (entry) => entry.$2.id != widget.cards[entry.$1].id,
        )) {
      _resetGesture();
    }
  }

  _FanMetrics _metrics(double availableWidth) {
    final width = math.max(1.0, availableWidth - 8);
    final rowWidth = widget.tightSpacing ? math.min(width, 1120.0) : width;
    final height = widget.height;
    final count = widget.cards.length;
    final interactive = widget.onChanged != null;
    final singleLift = interactive ? math.min(16.0, height * .18) : 0.0;
    final natural = math.min(
      interactive ? 94.0 : 59.0,
      math.min(width, (height - singleLift - 4) / 1.34),
    );
    final wantedPeek = interactive ? (natural * .27).clamp(16.0, 22.0) : 13.0;
    final twoRows = count > 1 && (count - 1) * wantedPeek + natural > rowWidth;
    final widthRatio = widget.tightSpacing ? .38 : (interactive ? .61 : .74);
    final rowStep = twoRows
        ? math.min(interactive ? 46.0 : 30.0, height * .36)
        : 0.0;
    final lift = twoRows && interactive
        ? math.min(9.0, height * .09)
        : singleLift;
    final cardWidth = math.min(natural, (height - lift - rowStep - 4) / 1.34);
    final split = twoRows ? (count + 1) ~/ 2 : count;
    final slots = <_CardSlot>[];
    for (final (row, group) in [
      widget.cards.take(split).toList(),
      widget.cards.skip(split).toList(),
    ].indexed) {
      if (group.isEmpty) break;
      bool newRank(int index) =>
          interactive &&
          index + 1 < group.length &&
          group[index].rank != group[index + 1].rank;
      final gaps = group.indexed.where((entry) => newRank(entry.$1)).length;
      final intervals = group.length - 1 + gaps * .11;
      final step = intervals == 0
          ? cardWidth
          : math.min(
              cardWidth * widthRatio,
              (rowWidth - cardWidth) / intervals,
            );
      var left = (availableWidth - cardWidth - intervals * step) / 2;
      for (var i = 0; i < group.length; i++) {
        final pitch = newRank(i) ? step * 1.11 : step;
        slots.add((
          left: left,
          bottom: 3 + (1 - row) * rowStep,
          peek: i + 1 < group.length ? pitch : cardWidth,
          row: row,
        ));
        left += pitch;
      }
    }
    return (
      cardWidth: cardWidth,
      cardHeight: cardWidth * 1.34,
      rowStep: rowStep,
      lift: lift,
      slots: slots,
    );
  }

  bool _raised(int index) {
    final anchor = _anchor;
    final current = _current;
    if (anchor != null &&
        current != null &&
        index >= math.min(anchor, current) &&
        index <= math.max(anchor, current)) {
      return _raising;
    }
    return widget.selected.contains(widget.cards[index].id);
  }

  Offset _local(PointerEvent event) =>
      (_surface.currentContext!.findRenderObject()! as RenderBox).globalToLocal(
        event.position,
      );

  void _down(int index, _FanMetrics layout, PointerDownEvent event) {
    if (!widget.enabled ||
        _pointer != null ||
        event.buttons != kPrimaryButton) {
      return;
    }
    setState(() {
      _pointer = event.pointer;
      _anchor = _current = index;
      _pointerStart = _local(event);
      _startLayout = layout;
      _raising = !widget.selected.contains(widget.cards[index].id);
    });
  }

  int _dragIndex(PointerEvent event) {
    final position = _local(event);
    final delta = position - _pointerStart;
    final start = _anchor!;
    if (!_dragging && delta.distance < _dragThreshold) return start;
    _dragging = true;
    final layout = _startLayout!;
    final anchor = layout.slots[start];
    final row = layout.rowStep == 0
        ? 0
        : (anchor.row + (delta.dy / layout.rowStep).round()).clamp(0, 1);
    final lane = row == anchor.row
        ? anchor.left + anchor.peek / 2 + delta.dx
        : position.dx;
    final first = layout.slots.indexWhere((slot) => slot.row == row);
    for (var i = layout.slots.length - 1; i > first; i--) {
      final slot = layout.slots[i];
      if (slot.row == row && lane >= slot.left) return i;
    }
    return first;
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    final index = _dragIndex(event);
    if (_current != index) setState(() => _current = index);
  }

  void _up(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    final anchor = _anchor!;
    final index = _dragIndex(event);
    final next = {...widget.selected};
    for (var i = math.min(anchor, index); i <= math.max(anchor, index); i++) {
      final id = widget.cards[i].id;
      if (_raising) {
        next.add(id);
      } else {
        next.remove(id);
      }
    }
    setState(_resetGesture);
    widget.onChanged?.call(next);
  }

  void _cancel(PointerCancelEvent event) {
    if (_pointer == event.pointer) setState(_resetGesture);
  }

  void _resetGesture() {
    _pointer = _anchor = _current = null;
    _dragging = false;
    _startLayout = null;
  }

  void _toggle(int id) {
    if (!widget.enabled || _pointer != null) return;
    final next = {...widget.selected};
    if (!next.remove(id)) next.add(id);
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 360.0;
        final layout = _metrics(width);
        return MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: SizedBox(
            key: _surface,
            width: double.infinity,
            height: widget.height,
            child: Listener(
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _cancel,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (widget.onChanged != null)
                    Positioned(
                      top: widget.height * .30,
                      left: 12,
                      right: 12,
                      bottom: 0,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x0c051710), Color(0x8c081a13)],
                            ),
                            borderRadius: BorderRadius.circular(22),
                          ),
                        ),
                      ),
                    ),
                  for (var i = 0; i < widget.cards.length; i++)
                    AnimatedPositioned(
                      key: ValueKey(widget.cards[i].id),
                      duration: widget.motion,
                      curve: Curves.easeOut,
                      left: layout.slots[i].left,
                      bottom:
                          layout.slots[i].bottom +
                          (_raised(i) ? layout.lift : 0),
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) => _down(i, layout, event),
                        child: _Face(
                          card: widget.cards[i],
                          shown: widget.shown[widget.cards[i].id],
                          wild: widget.wild.contains(widget.cards[i].rank),
                          selected: _raised(i),
                          onActivate: widget.enabled
                              ? () => _toggle(widget.cards[i].id)
                              : null,
                          width: layout.cardWidth,
                          height: layout.cardHeight,
                          peek: layout.slots[i].peek,
                          cornerHeight:
                              layout.rowStep > 0 && layout.slots[i].row == 0
                              ? layout.rowStep - layout.lift - 4
                              : double.infinity,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
