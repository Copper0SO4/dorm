import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../game/card_rooms.dart';
import '../game/card_session.dart';
import '../game/cards.dart';
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
  final _selected = <int>{};
  final _chat = TextEditingController();
  final _sounds = <String, Uint8List>{};
  int _event = 0;
  int? _splash;
  String? _impact;
  Timer? _timer;
  bool _muted = false;
  bool _log = false;
  String? _preferred;

  RoomJson get view => widget.view;
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

  @override
  void initState() {
    super.initState();
    _event = (events.lastOrNull?['id'] as int?) ?? 0;
  }

  @override
  void didUpdateWidget(CardTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view['turnVersion'] != view['turnVersion']) {
      _selected.clear();
      _preferred = null;
    }
    final recent = events
        .where((entry) => (entry['id'] as int) > _event)
        .toList();
    if (recent.isEmpty) return;
    _event = recent.last['id'] as int;
    final impact = recent
        .where((entry) => ['bomb', 'rocket', 'finish'].contains(entry['kind']))
        .lastOrNull;
    if (impact != null) {
      _impact = impact['kind'] == 'finish'
          ? '牌局结束'
          : impact['kind'] == 'rocket'
          ? '王炸！'
          : '炸弹！';
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) {
          setState(() {
            _impact = null;
            _splash = null;
          });
        }
      });
    }
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
            _impact = null;
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

  void _hint() {
    final suggestion = suggestCards(hand, wild, previous);
    if (suggestion == null) {
      notify(context, '暂无推荐出法，可以选择不要');
      return;
    }
    setState(() {
      _selected
        ..clear()
        ..addAll(suggestion.cards.map((card) => card.id));
      _preferred = suggestion.key;
    });
  }

  Future<void> _play() async {
    final cards = hand.where((card) => _selected.contains(card.id)).toList();
    final options = cardPlays(
      cards,
      wild,
    ).where((play) => play.beats(previous)).toList();
    if (options.isEmpty) {
      notify(context, '这组牌无法打出');
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
                  title: const Text('选择癞子替代方式'),
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
    if (!mounted || play == null || initialTurn != view['turnVersion']) return;
    await session.act('play', {
      'cards': cards.map((card) => card.id).toList(),
      'pattern': play.key,
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

  @override
  Widget build(BuildContext context) {
    final rules = CardRules.fromJson(view['rules'] as RoomJson);
    final phase = view['phase'];
    final current = view['turn'];
    return PageBody(
      storageKey: 'cards-${view['room']}',
      children: [
        PageHeading(
          '房间 ${view['room']}',
          '${rules.mode.label} · ${rules.players} 人 · ${rules.decks} 副牌${online ? ' · GitHub 在线' : ''}',
          actions: [
            if (isHost && !online)
              OutlinedButton.icon(
                onPressed: blocked ? null : widget.share,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('分享牌桌'),
              ),
            IconButton(
              tooltip: _muted ? '开启音效' : '关闭音效',
              onPressed: () => setState(() => _muted = !_muted),
              icon: Icon(
                _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
              ),
            ),
            OutlinedButton(
              onPressed: blocked ? null : _leave,
              child: const Text('离开房间'),
            ),
          ],
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xff124a40), Color(0xff0b2d35)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 15,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final player in people) _seat(player),
                    for (var i = people.length; i < rules.players; i++)
                      const Chip(
                        avatar: Icon(Icons.add, size: 15),
                        label: Text('空座'),
                      ),
                  ],
                ),
                Text(
                  switch (phase) {
                    'bidding' => ownTurn ? '轮到你叫分' : '${_person(current)}正在叫分',
                    'playing' => ownTurn ? '轮到你出牌' : '${_person(current)}正在出牌',
                    'finished' => view['result'] as String? ?? '牌局结束',
                    _ =>
                      people.length == rules.players ? '座位已满，可以发牌' : '等待其他玩家入座',
                  },
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 21,
                  ),
                ),
                AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 230),
                  child: _impact == null
                      ? const SizedBox.shrink()
                      : Text(
                          _impact!,
                          key: ValueKey(_impact),
                          style: const TextStyle(
                            color: Color(0xffffcc72),
                            fontSize: 23,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
                if (inPlay && wild.isNotEmpty)
                  Text(
                    '癞子 · ${wild.map(PlayingCard.rankLabel).join('、')}',
                    style: const TextStyle(color: Color(0xfffde4a0)),
                  ),
                if ((view['bottom'] as List).isNotEmpty)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      const Text('底牌', style: TextStyle(color: Colors.white)),
                      for (final id in (view['bottom'] as List).cast<int>())
                        _Face(card: PlayingCard(id), width: 32, height: 42),
                    ],
                  ),
                if (view['last'] case final RoomJson last)
                  Wrap(
                    spacing: 4,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${_person(view['leader'])} · ${last['label']}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      for (final value
                          in (last['cards'] as List).cast<RoomJson>())
                        _Face(
                          card: PlayingCard(value['id'] as int),
                          shown: value['rank'] as int,
                          width: 34,
                          height: 45,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        if (session.error case final error?) ...[
          const SizedBox(height: 8),
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (session.awaitingGit) const LinearProgressIndicator(),
        if (online && session.gitError != null)
          Text('GitHub · ${session.gitError}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (phase == 'bidding' && ownTurn) ...[
              OutlinedButton(
                onPressed: blocked
                    ? null
                    : () => session.act('bid', {'bid': 0}),
                child: const Text('不叫'),
              ),
              for (var bid = (view['bid'] as int) + 1; bid <= 3; bid++)
                FilledButton(
                  onPressed: blocked
                      ? null
                      : () => session.act('bid', {'bid': bid}),
                  child: Text('叫 $bid 分'),
                ),
            ],
            if (phase == 'playing' && ownTurn) ...[
              FilledButton.icon(
                onPressed: blocked || _selected.isEmpty ? null : _play,
                icon: const Icon(Icons.arrow_upward),
                label: Text('出牌 · ${_selected.length}'),
              ),
              OutlinedButton(
                onPressed: blocked || previous == null
                    ? null
                    : () => session.act('pass'),
                child: const Text('不要'),
              ),
              TextButton(
                onPressed: blocked ? null : _hint,
                child: const Text('提示'),
              ),
            ],
            if (isHost && !inPlay) ...[
              FilledButton.icon(
                onPressed: !blocked && people.length == rules.players
                    ? () => session.act('start')
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(phase == 'finished' ? '再来一局' : '发牌开局'),
              ),
              if (!online) ...[
                TextButton(
                  onPressed: blocked || people.length >= rules.players
                      ? null
                      : () => session.act('bot'),
                  child: const Text('添加电脑玩家'),
                ),
                if (people.any((person) => person['bot'] == true))
                  TextButton(
                    onPressed: blocked ? null : () => session.act('removeBot'),
                    child: const Text('移除电脑玩家'),
                  ),
              ],
              TextButton(
                onPressed: blocked ? null : _rules,
                child: const Text('调整规则'),
              ),
            ],
            if (isHost && inPlay)
              TextButton(
                onPressed: blocked
                    ? null
                    : () async {
                        if (await confirm(
                          context,
                          '结束当前牌局',
                          '所有玩家将回到房间大厅。',
                          action: '结束牌局',
                        )) {
                          await session.act('abort');
                        }
                      },
                child: const Text('结束牌局'),
              ),
          ],
        ),
        if (hand.isNotEmpty) ...[
          SectionHeading('我的手牌 · ${hand.length} 张'),
          Wrap(
            spacing: 4,
            runSpacing: 8,
            children: [
              for (final card in hand)
                _Face(
                  card: card,
                  wild: wild.contains(card.rank),
                  selected: _selected.contains(card.id),
                  width: 44,
                  height: 60,
                  tap: phase != 'playing'
                      ? null
                      : () => setState(() {
                          if (!_selected.add(card.id)) {
                            _selected.remove(card.id);
                          }
                          _preferred = null;
                        }),
                ),
            ],
          ),
        ],
        SectionHeading(
          '牌桌聊天',
          trailing: TextButton(
            onPressed: () => setState(() => _log = !_log),
            child: Text(_log ? '收起记录' : '查看记录'),
          ),
        ),
        if (_log)
          for (final event in events.reversed.take(24))
            Text(
              event['kind'] == 'chat'
                  ? '${_person(event['from'])} · ${event['text']}'
                  : event['text'] as String,
            )
        else if (events.lastOrNull case final event?)
          Text(
            event['kind'] == 'chat'
                ? '${_person(event['from'])} · ${event['text']}'
                : event['text'] as String,
          ),
        const SizedBox(height: 8),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                controller: _chat,
                enabled: !blocked,
                onSubmitted: (_) => _sendChat(),
                inputFormatters: [LengthLimitingTextInputFormatter(120)],
                decoration: const InputDecoration(hintText: '发条消息'),
              ),
            ),
            IconButton.filled(
              tooltip: '发送',
              icon: const Icon(Icons.send),
              onPressed: blocked ? null : _sendChat,
            ),
          ],
        ),
      ],
    );
  }

  Widget _seat(RoomJson player) {
    final id = player['id'];
    final turn = id == view['turn'];
    final tomato = _splash == id;
    return Semantics(
      label: '${player['name']} ${player['cards']} 张',
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 260),
        padding: const EdgeInsets.fromLTRB(9, 5, 4, 5),
        decoration: BoxDecoration(
          color: tomato
              ? const Color(0xffb93d31)
              : turn
              ? const Color(0xff2f7660)
              : const Color(0xff235357),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 5,
          children: [
            if (tomato) const Text('🍅', style: TextStyle(fontSize: 21)),
            Text(
              '${player['name']}${id == view['you'] ? ' · 我' : ''}'
              '${id == view['landlord'] ? ' · 地主' : ''}',
              style: const TextStyle(color: Colors.white),
            ),
            Text(
              '${player['cards']} 张',
              style: const TextStyle(color: Color(0xffc9e5df)),
            ),
            if (id != view['you'] && isHost && !inPlay)
              IconButton(
                tooltip: '移出${player['name']}',
                color: Colors.white,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.person_remove_outlined, size: 16),
                onPressed: blocked
                    ? null
                    : () async {
                        final accepted = await confirm(
                          context,
                          '移出房间',
                          '将${player['name']}移出牌桌。',
                          action: '移出',
                        );
                        if (accepted) await session.act('kick', {'target': id});
                      },
              ),
            if (id != view['you'])
              IconButton(
                tooltip: '向${player['name']}丢番茄',
                color: const Color(0xfff9c5a8),
                visualDensity: VisualDensity.compact,
                icon: const Text('🍅'),
                onPressed: blocked
                    ? null
                    : () => session.act('tomato', {'target': id}),
              ),
          ],
        ),
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
    this.selected = false,
    this.wild = false,
    this.tap,
  });

  final PlayingCard card;
  final int? shown;
  final double width;
  final double height;
  final bool selected;
  final bool wild;
  final VoidCallback? tap;

  @override
  Widget build(BuildContext context) {
    final rank = shown ?? card.rank;
    final suit = card.suit;
    final ink = suit == 1 || suit == 2 || rank == 17
        ? const Color(0xffaf312e)
        : const Color(0xff153138);
    final mark = suit == null ? '★' : ['♠', '♥', '♦', '♣'][suit];
    final label = PlayingCard.rankLabel(rank);
    return Semantics(
      button: tap != null,
      selected: selected,
      label: '$label $mark${wild ? ' 癞子' : ''}',
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 140),
          width: width,
          height: height,
          transform: Matrix4.translationValues(0, selected ? -5 : 0, 0),
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? const Color(0xffffdfa3) : const Color(0xfffbf7ed),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected || wild
                  ? const Color(0xffd79848)
                  : const Color(0xffd8d2bb),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    color: ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ),
              Text(
                wild ? '癞' : mark,
                style: TextStyle(color: ink, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
