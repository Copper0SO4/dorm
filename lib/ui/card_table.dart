import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/preferences.dart' show maxUiScale, minUiScale;
import '../game/bot_profile.dart'
    show botDecisionTimeout, botTimeoutLimit, formatBotRanks;
import '../game/card_rooms.dart';
import '../game/card_session.dart';
import '../game/cards.dart';
import 'card_art.dart';
import 'cards_page.dart';
import 'common.dart';

part 'card_cheats.dart';

class CardTable extends StatefulWidget {
  const CardTable({
    super.key,
    required this.session,
    required this.view,
    required this.share,
    this.onBotApi,
  });

  final CardSession session;
  final RoomJson view;
  final VoidCallback share;
  final VoidCallback? onBotApi;

  @override
  State<CardTable> createState() => _CardTableState();
}

class _CardTableState extends State<CardTable> {
  static const _finalPlayDuration = Duration(milliseconds: 1800);
  static const _audio = MethodChannel('dorm/cards/audio');
  static const _cardWindow = MethodChannel('dorm/cards/window');
  static const _gold = Color(0xfff4cf86);
  static const _ink = Color(0xff173038);
  static const _moveColors = {
    CardMove.lead: (Color(0xffa4dfc4), Color(0xff123b2c)),
    CardMove.beat: (Color(0xffffd083), Color(0xff3f270d)),
    CardMove.pass: (Color(0xffffc0cb), Color(0xff562331)),
  };

  final _selected = <int>{};
  bool _chatVisible = false;
  bool _chatReading = false;
  int _unreadChat = 0;
  final _sounds = <String, Uint8List>{};
  int _event = 0;
  int _chatEvent = 0;
  int? _splash;
  Timer? _timer;
  Timer? _finalPlayTimer;
  bool get _showFinalPlay => _finalPlayTimer?.isActive ?? false;
  bool _muted = false;
  bool _fullscreen = false;
  bool _changingFullscreen = false;
  String? _preferred;
  int? _hintTurn;
  int _hintCursor = 0;
  List<CardPlay>? _hints;
  int? _appliedAiHintId;

  RoomJson get view => widget.view;
  CardRules get rules => CardRules.fromJson(view['rules'] as RoomJson);
  CardSession get session => widget.session;
  bool get ownTurn => view['turn'] == view['you'];
  bool get apiAvailable => view['apiAvailable'] == true;
  String? get _ownAutoMode =>
      people
              .where((player) => player['id'] == view['you'])
              .firstOrNull?['botMode']
          as String?;
  bool get autoplay => people.any(
    (player) => player['id'] == view['you'] && player['autoplay'] == true,
  );
  RoomJson? get coaching => view['aiHint'] as RoomJson?;
  RoomJson? get _debug => view['debug'] as RoomJson?;
  bool get _forceOut => _debug?['forceOut'] == true;
  CardPlay? get _playLimit => _forceOut ? null : previous;
  bool get isHost => view['host'] == view['you'];
  bool get inPlay => ['playing', 'bidding'].contains(view['phase']);
  bool get online => view['scope'] == 'online';
  bool get blocked => session.working || session.awaitingGit;
  int? get _activeOpponent => !ownTurn ? view['turn'] as int? : null;
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
    _chatEvent = (_chatMessages(view).lastOrNull?['id'] as int?) ?? 0;
  }

  @override
  void didUpdateWidget(CardTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prior = oldWidget.view;
    if (prior['room'] != view['room'] || prior['you'] != view['you']) {
      _event = (events.lastOrNull?['id'] as int?) ?? 0;
      _chatEvent = (_chatMessages(view).lastOrNull?['id'] as int?) ?? 0;
      _unreadChat = 0;
    }
    if (view['phase'] != 'finished' || prior['room'] != view['room']) {
      _finalPlayTimer?.cancel();
      _finalPlayTimer = null;
    } else if (prior['phase'] != 'finished' && view['last'] is RoomJson) {
      _finalPlayTimer?.cancel();
      _finalPlayTimer = Timer(_finalPlayDuration, () {
        if (!mounted) return;
        setState(() => _finalPlayTimer = null);
        unawaited(_sound('finish'));
      });
    }
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
    final hint = coaching;
    if (view['phase'] == 'playing' &&
        ownTurn &&
        !autoplay &&
        hint != null &&
        hint['pending'] != true &&
        hint['error'] == null &&
        hint['turn'] == view['turnVersion'] &&
        hint['id'] != _appliedAiHintId) {
      _appliedAiHintId = hint['id'] as int?;
      if (hint['pass'] != true && hint['play'] is RoomJson) {
        final play = hint['play'] as RoomJson;
        final ids = (play['cards'] as List)
            .cast<RoomJson>()
            .map((card) => card['id'] as int)
            .toList();
        final owned = hand.map((card) => card.id).toSet();
        if (ids.isNotEmpty && ids.every(owned.contains)) {
          _selected
            ..clear()
            ..addAll(ids);
          _preferred = play['key'] as String?;
          _hintCursor = 0;
        }
      }
    }
    final messages = _chatMessages(view);
    final incoming = messages
        .where(
          (entry) =>
              (entry['id'] as int) > _chatEvent && entry['from'] != view['you'],
        )
        .toList();
    _chatEvent = (messages.lastOrNull?['id'] as int?) ?? 0;
    if (!_chatReading) _unreadChat += incoming.length;
    if (!_chatVisible && incoming.isNotEmpty) {
      final latest = incoming.last;
      final message = '${_chatSpeaker(latest, people)} · ${latest['text']}';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_chatVisible && _unreadChat > 0) {
          notify(context, message);
        }
      });
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
    final fallback = recent
        .where(
          (entry) =>
              const {'botFallback', 'botTurnFallback'}.contains(entry['kind']),
        )
        .lastOrNull;
    if (fallback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notify(context, fallback['text'] as String);
      });
    }
    final soundEvent = recent
        .where(
          (entry) =>
              (!_showFinalPlay || entry['kind'] != 'finish') &&
              (entry['kind'] != 'chat' || entry['from'] != view['you']),
        )
        .lastOrNull;
    if (soundEvent != null) unawaited(_sound(soundEvent['kind'] as String));
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

  Future<void> _setFullscreen(bool enabled) async {
    if (_changingFullscreen || _fullscreen == enabled) return;
    setState(() => _changingFullscreen = true);
    try {
      final active = await _cardWindow.invokeMethod<bool>(
        'fullscreen',
        enabled,
      );
      if (!mounted) {
        if (active == true) {
          await _cardWindow.invokeMethod<bool>('fullscreen', false);
        }
        return;
      }
      setState(() => _fullscreen = active == true);
    } on MissingPluginException {
      if (mounted) notify(context, '当前版本无法切换全屏');
    } on PlatformException {
      if (mounted) notify(context, '无法切换牌桌全屏');
    } finally {
      if (mounted) setState(() => _changingFullscreen = false);
    }
  }

  @override
  void dispose() {
    if (_fullscreen && !_changingFullscreen) {
      _cardWindow.invokeMethod<bool>('fullscreen', false).ignore();
    }
    _timer?.cancel();
    _finalPlayTimer?.cancel();
    super.dispose();
  }

  List<CardPlay> _hintsForTurn() {
    final turn = view['turnVersion'] as int;
    final cached = _hints;
    if (cached != null && _hintTurn == turn) return cached;
    _hintTurn = turn;
    _hintCursor = 0;
    return _hints = hintPlays(hand, wild, _playLimit, rules: rules);
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

  String _playChoiceLabel(CardPlay play) {
    final level = play.kind == PlayKind.rocket && rules.rocketBeatsChain
        ? '王炸优先'
        : '等级 ${play.bombLevel}';
    final conversions = {
      for (final card in play.cards)
        if (play.ranks[card.id] case final rank?)
          '${PlayingCard.rankLabel(card.rank)}→${PlayingCard.rankLabel(rank)}',
    };
    return [
      play.label,
      if (play.bomb) level,
      if (play.bomb) '×${play.bombMultiplier}',
      if (play.kind != PlayKind.rocket) PlayingCard.rankLabel(play.high),
      ...conversions,
    ].join(' · ');
  }

  Future<void> _play() async {
    if (!ownTurn || blocked || view['phase'] != 'playing') return;
    final cards = hand.where((card) => _selected.contains(card.id)).toList();
    final selection = inspectCardSelection(cards, wild, _playLimit, rules);
    final options = selection.options;
    if (options.isEmpty) {
      notify(context, selection.issue ?? '请先选牌');
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
                        child: Text(_playChoiceLabel(play)),
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

  Future<void> _chooseBot() => _chooseBotMode(
    title: '添加电脑玩家',
    localTitle: '本地电脑',
    localSubtitle: '按内置规则出牌，不调用模型 API',
    apiTitle: 'API 电脑',
    apiSubtitle: '由房主的模型出牌，单次最多等 ${botDecisionTimeout.inSeconds} 秒',
    unavailableSubtitle: '需先在「电脑 API」中启用并配置密钥',
    onChosen: (mode) => session.act('bot', {'mode': mode}),
  );

  Future<void> _chooseAutoplay() => _chooseBotMode(
    title: '选择托管模式',
    localTitle: '本地托管',
    localSubtitle: '按内置规则自动出牌，不调用模型 API',
    apiTitle: 'API 托管',
    apiSubtitle: '由房主的模型代打，牌桌可随时取消托管',
    unavailableSubtitle: '需房主先启用电脑 API',
    onChosen: (mode) =>
        session.act('autoplay', {'enabled': true, 'mode': mode}),
  );

  Future<void> _chooseBotMode({
    required String title,
    required String localTitle,
    required String localSubtitle,
    required String apiTitle,
    required String apiSubtitle,
    required String unavailableSubtitle,
    required Future<void> Function(String mode) onChosen,
  }) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: Text(title),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.memory),
            title: Text(localTitle),
            subtitle: Text(localSubtitle),
            onTap: () {
              Navigator.pop(dialogContext);
              unawaited(onChosen('local'));
            },
          ),
          ListTile(
            enabled: apiAvailable,
            leading: const Icon(Icons.auto_awesome),
            title: Text(apiTitle),
            subtitle: Text(apiAvailable ? apiSubtitle : unavailableSubtitle),
            onTap: !apiAvailable
                ? null
                : () {
                    Navigator.pop(dialogContext);
                    unawaited(onChosen('api'));
                  },
          ),
        ],
      ),
      actions: [
        if (!apiAvailable && isHost && widget.onBotApi != null)
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              widget.onBotApi!();
            },
            child: const Text('配置电脑 API'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
      ],
    ),
  );

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

  String _person(Object? id) =>
      people.where((person) => person['id'] == id).firstOrNull?['name']
          as String? ??
      '';

  Map<int, CardMove> _turnMoves() {
    if (people.any((person) => person.containsKey('move'))) {
      final types = CardMove.values.asNameMap();
      return {
        for (final person in people)
          if (person['id'] != _activeOpponent)
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
            event['from'] != _activeOpponent &&
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
    final playing = phase == 'playing' && ownTurn && !autoplay;
    final cards = hand;
    final chosen = [
      for (final card in cards)
        if (_selected.contains(card.id)) card,
    ];
    final roomRules = rules;
    final wildRanks = wild;
    final selection = playing
        ? inspectCardSelection(chosen, wildRanks, _playLimit, roomRules)
        : (options: const <CardPlay>[], issue: null);
    final suggested = selection.options
        .where((play) => play.key == _preferred)
        .firstOrNull;
    final pattern =
        suggested ??
        (selection.options.length == 1 ? selection.options.single : null);
    final preview =
        pattern?.label ??
        (selection.options.length > 1
            ? '${selection.options.length} 种出法'
            : null);
    final moves = _turnMoves();
    final opponents = _opponents(rules.players);
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 125);
    final error = session.error ?? (online ? session.gitError : null);
    final waitingForHint = playing && coaching?['pending'] == true;
    final aiThinking = view['botThinking'] == true;
    final progress = aiThinking ? view['botProgress'] as RoomJson? : coaching;

    final table = PopScope(
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
        child: SizedBox.expand(
          child: CardTableFrame(
            key: const ValueKey('dorm-card-table-frame'),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 450;
                final narrow = constraints.maxWidth < 600;
                final horizontalPadding = compact || narrow ? 8.0 : 25.0;
                final tableWidth = math.max(
                  120.0,
                  constraints.maxWidth - horizontalPadding * 2,
                );
                final last = _displayedPlay;
                final actor =
                    (view['leader'] ?? _previousTrick?['leader']) as int?;
                final multiRowOpponents =
                    opponents.length > 3 && tableWidth / opponents.length < 76;
                final handHeight =
                    (constraints.maxHeight *
                            (compact
                                ? .29
                                : multiRowOpponents
                                ? .27
                                : .32))
                        .clamp(
                          74.0,
                          constraints.maxHeight >= 850 ? 185.0 : 142.0,
                        );
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: compact ? 4 : 10,
                  ),
                  child: Column(
                    spacing: compact || multiRowOpponents ? 3 : 6,
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
                      if (view['counter'] case final List counts)
                        _counter(counts.cast<RoomJson>()),
                      if (opponents.isNotEmpty)
                        _opponentsStrip(
                          opponents,
                          moves,
                          tableWidth: tableWidth,
                          compact: compact,
                        ),
                      Expanded(
                        child: !_showFinalPlay && view['settlement'] is RoomJson
                            ? Align(
                                child: _settlement(
                                  view['settlement'] as RoomJson,
                                ),
                              )
                            : last == null || actor == null
                            ? const SizedBox.shrink()
                            : _trickArea(last, actor, opponents, moves, motion),
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
                          if (_showFinalPlay && view['you'] == view['landlord'])
                            _landlordBadge(),
                          if (!_showFinalPlay)
                            _actions(
                              phase: phase,
                              legal: selection.options.isNotEmpty,
                            ),
                        ],
                      ),
                      if (aiThinking || waitingForHint)
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            _AiWaitLabel(
                              key: ValueKey((
                                view['room'],
                                view['turnVersion'],
                                waitingForHint ? (coaching?['id']) : null,
                              )),
                              stage: progress?['stage'] as String?,
                              seconds:
                                  progress?['remaining'] as int? ??
                                  botDecisionTimeout.inSeconds,
                            ),
                            if (waitingForHint || (isHost || ownTurn))
                              TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: _gold,
                                  minimumSize: const Size(0, 26),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: blocked
                                    ? null
                                    : () => session.act(
                                        waitingForHint
                                            ? 'cancelAiHint'
                                            : 'skipBotWait',
                                        {'turnVersion': view['turnVersion']},
                                      ),
                                child: Text(waitingForHint ? '取消提示' : '本手用本地'),
                              ),
                          ],
                        )
                      else if (playing && coaching != null)
                        _coachingFeedback(coaching!),
                      if (cards.isNotEmpty && phase != 'finished') ...[
                        _handLine(
                          cards.length,
                          moves[view['you']],
                          chosen.length,
                          selection.issue,
                          preview,
                        ),
                        _HandStrip(
                          cards: cards,
                          selected: _selected,
                          wild: wild,
                          enabled: phase == 'playing' && !blocked && !autoplay,
                          height: handHeight,
                          motion: motion,
                          tightSpacing:
                              Theme.of(context).platform ==
                                  TargetPlatform.windows ||
                              Theme.of(context).platform ==
                                  TargetPlatform.linux,
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
    );
    final isDesktop =
        Theme.of(context).platform == TargetPlatform.windows ||
        Theme.of(context).platform == TargetPlatform.linux;
    if (!isDesktop) return table;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            _setFullscreen(!_fullscreen),
        if (_fullscreen)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _setFullscreen(false),
      },
      child: Focus(autofocus: true, child: table),
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
                    text: inPlay
                        ? ' · 第 ${view['round'] ?? 1}${rules.matchRounds > 0 ? '/${rules.matchRounds}' : ''} 局 · ${view['multiplier']} 倍'
                        : ' · ${rules.mode.label} · ${rules.decks} 副${online ? ' · 在线' : ''}',
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
            flex: _debug?['gui'] == true ? 2 : 1,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (inPlay || autoplay)
                  IconButton(
                    tooltip: autoplay ? '取消托管' : '开启托管',
                    isSelected: autoplay,
                    onPressed: blocked
                        ? null
                        : autoplay
                        ? () => session.act('autoplay', {'enabled': false})
                        : _chooseAutoplay,
                    icon: const Icon(Icons.smart_toy_outlined),
                    selectedIcon: const Icon(Icons.smart_toy, color: _gold),
                  ),
                if (Theme.of(context).platform == TargetPlatform.windows ||
                    Theme.of(context).platform == TargetPlatform.linux)
                  IconButton(
                    tooltip: _fullscreen ? '退出全屏（F11）' : '全屏（F11）',
                    onPressed: _changingFullscreen
                        ? null
                        : () => _setFullscreen(!_fullscreen),
                    icon: Icon(
                      _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                  ),
                IconButton(
                  tooltip: '牌桌消息',
                  onPressed: _showChat,
                  icon: Badge(
                    isLabelVisible: _unreadChat > 0,
                    label: Text(_unreadChat > 99 ? '99+' : '$_unreadChat'),
                    child: const Icon(Icons.chat_bubble_outline),
                  ),
                ),
                if (isHost && !online)
                  IconButton(
                    tooltip: '分享牌桌',
                    onPressed: blocked ? null : widget.share,
                    icon: const Icon(Icons.qr_code_2),
                  ),
                if (_debug?['gui'] == true)
                  TextButton(
                    onPressed: blocked ? null : () => _showCheats(),
                    style: TextButton.styleFrom(
                      foregroundColor: _gold,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                    ),
                    child: const Text('Cheats'),
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

  Widget _counter(List<RoomJson> counts) => Tooltip(
    message: '未见牌张数，含未知的底牌与弃牌',
    child: Container(
      key: const ValueKey('card-counter'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xe0163028),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff6a8c7b)),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 5,
        children: [
          const Text(
            '未见',
            style: TextStyle(fontSize: 10, color: Colors.white70),
          ),
          for (final count in counts)
            Text.rich(
              TextSpan(
                text: PlayingCard.rankLabel(count['rank'] as int),
                style: const TextStyle(
                  color: _gold,
                  fontWeight: FontWeight.w800,
                ),
                children: [
                  TextSpan(
                    text: ' ${count['count']}',
                    style: TextStyle(
                      color: count['count'] == 0
                          ? Colors.white38
                          : Colors.white,
                    ),
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 10),
            ),
        ],
      ),
    ),
  );

  Widget _coachingFeedback(RoomJson advice) {
    final explanation = advice['reason'] as String?;
    final error = advice['error'] as String?;
    final play = advice['play'] as RoomJson?;
    final action = play == null ? '不出' : '出牌 · ${play['label']}';
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: error != null ? const Color(0xffffc9aa) : _gold,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        minimumSize: const Size(0, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: explanation == null
          ? null
          : () => _showAiAdvice(advice, explanation),
      child: Text(
        error ?? 'AI 建议 · $action · $explanation',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  void _showAiAdvice(RoomJson advice, String explanation) {
    final play = advice['play'] as RoomJson?;
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('AI 出牌建议'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(play == null ? '建议动作　不出' : '建议动作　出牌 · ${play['label']}'),
                if (play != null)
                  Text(
                    '出牌牌面　${formatBotRanks((play['cards'] as List).cast<RoomJson>().map((card) => card['rank'] as int))}',
                  ),
                Text('判断理由　$explanation'),
              ],
            ),
          ),
          if (play != null)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context);
                if (!mounted ||
                    advice['turn'] != view['turnVersion'] ||
                    advice['id'] != coaching?['id'] ||
                    autoplay) {
                  return;
                }
                setState(() {
                  _selected
                    ..clear()
                    ..addAll(
                      (play['cards'] as List).cast<RoomJson>().map(
                        (card) => card['id'] as int,
                      ),
                    );
                  _preferred = play['key'] as String;
                  _hintCursor = 0;
                });
              },
              child: const Text('选中建议的牌'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _signedScore(Object? value) {
    final score = BigInt.tryParse('$value') ?? BigInt.zero;
    return score > BigInt.zero ? '+$score' : '$score';
  }

  Widget _settlement(RoomJson summary) {
    final rows = {
      for (final player in (summary['players'] as List).cast<RoomJson>())
        player['seat']: player,
    };
    final ranking = (view['standings'] as List).cast<RoomJson>();
    final spring = summary['spring'];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xec122c24),
          border: Border.all(color: const Color(0xffa69365)),
          borderRadius: BorderRadius.circular(15),
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(13),
          children: [
            Text(
              view['matchComplete'] == true ? '全场结算' : '第 ${view['round']} 局结算',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: _gold,
              ),
            ),
            Text(
              '底分 ${summary['base']} · 炸弹 ${summary['bombs']} · ${summary['multiplier']} 倍${spring == null ? '' : ' · $spring'}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            for (final rankingRow in ranking)
              if (rows[rankingRow['seat']] case final row?)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 5,
                    children: [
                      Row(
                        spacing: 10,
                        children: [
                          Expanded(
                            child: Text(
                              '${row['name']}${row['seat'] == view['you'] ? '（你）' : ''}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (row['seat'] == view['landlord']) _landlordBadge(),
                          Text(
                            '本局 ${_signedScore(row['delta'])}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          Text(
                            '总分 ${_signedScore(row['total'])}',
                            style: const TextStyle(color: _gold),
                          ),
                        ],
                      ),
                      if ((row['cards'] as List).isNotEmpty)
                        Wrap(
                          spacing: 3,
                          runSpacing: 3,
                          alignment: WrapAlignment.start,
                          children: [
                            for (final id in (row['cards'] as List).cast<int>())
                              _Face(
                                card: PlayingCard(id),
                                width: 28,
                                height: 38,
                              ),
                          ],
                        )
                      else
                        const Text(
                          '已出完',
                          style: TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                    ],
                  ),
                ),
          ],
        ),
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
            if (DormUiScaleScope.maybeOf(dialogContext) case final scaleScope?)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('界面缩放')),
                    IconButton(
                      tooltip: '缩小界面',
                      visualDensity: VisualDensity.compact,
                      onPressed: scaleScope.scale <= minUiScale + 0.001
                          ? null
                          : () => scaleScope.onAdjust(-1),
                      icon: const Icon(Icons.remove),
                    ),
                    TextButton(
                      onPressed: (scaleScope.scale - 1.0).abs() < 0.001
                          ? null
                          : scaleScope.onReset,
                      child: Text('${(scaleScope.scale * 100).round()}%'),
                    ),
                    IconButton(
                      tooltip: '放大界面',
                      visualDensity: VisualDensity.compact,
                      onPressed: scaleScope.scale >= maxUiScale - 0.001
                          ? null
                          : () => scaleScope.onAdjust(1),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
            if ((_debug?['hands'] as RoomJson?)?.containsKey(
                  '${view['you']}',
                ) ==
                true)
              SimpleDialogOption(
                onPressed: blocked
                    ? null
                    : () => run(
                        () =>
                            unawaited(_showDebugHand(view['you'] as int, '自己')),
                      ),
                child: const Text('查看自己的手牌'),
              ),
            if (_debug != null)
              SimpleDialogOption(
                onPressed: blocked ? null : () => run(_showDebug),
                child: const Text('调试'),
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

  Future<void> _showCheats({int? seat}) async {
    if (_debug?['gui'] != true || blocked) return;
    if (seat != null) {
      await session.act('debugGui', {'op': 'select', 'seat': seat});
      if (!mounted || session.error != null || _debug?['gui'] != true) return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _CheatsDialog(session: session),
    );
  }

  Future<void> _showDebug() async {
    final input = TextEditingController();
    String? feedback;
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      final route = DialogRoute<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (_, update) => ListenableBuilder(
            listenable: session,
            builder: (_, _) {
              final debug = session.view?['debug'] as RoomJson?;
              Future<void> run() async {
                final command = input.text.trim();
                if (debug == null || session.working || command.isEmpty) return;
                update(() => feedback = null);
                await session.act('debug', {
                  'command': command,
                  'deal': debug['deal'],
                });
                if (!dialogContext.mounted) return;
                update(() => feedback = session.error ?? '已执行');
                if (session.error == null) input.clear();
              }

              return AlertDialog(
                title: const Text('调试'),
                scrollable: true,
                content: SizedBox(
                  width: 440,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 10,
                    children: [
                      Semantics(
                        label: '调试输入',
                        child: TextField(
                          controller: input,
                          autofocus: true,
                          maxLength: 500,
                          decoration: const InputDecoration(
                            counterText: '',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => run(),
                        ),
                      ),
                      if (feedback != null) Text(feedback!),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                  FilledButton(
                    onPressed: debug == null || session.working ? null : run,
                    child: const Text('执行'),
                  ),
                ],
              );
            },
          ),
        ),
      );
      await navigator.push(route);
      await route.completed;
    } finally {
      input.dispose();
    }
  }

  Future<void> _showDebugHand(int seat, String name) async {
    var selected = <int>{};
    Object? selectedDeal;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, update) => ListenableBuilder(
          listenable: session,
          builder: (_, _) {
            final debug = session.view?['debug'] as RoomJson?;
            final hands = debug?['hands'] as RoomJson?;
            final cards = (hands?['$seat'] as List? ?? []).cast<int>();
            final deal = debug?['deal'];
            final marked = selectedDeal == deal
                ? selected.intersection(cards.toSet())
                : <int>{};
            final inPlay = const {
              'bidding',
              'playing',
            }.contains(session.view?['phase']);
            return AlertDialog(
              title: Text('$name 的手牌'),
              content: SizedBox(
                width: 460,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 264),
                  child: SingleChildScrollView(
                    child: cards.isEmpty
                        ? const Text('当前没有可查看的手牌')
                        : Wrap(
                            spacing: 5,
                            runSpacing: 5,
                            children: [
                              for (final id in cards)
                                _DebugHandCard(
                                  id: id,
                                  selected: marked.contains(id),
                                  onTap: inPlay && !session.working
                                      ? () => update(() {
                                          selectedDeal = deal;
                                          selected = {...marked};
                                          if (!selected.add(id)) {
                                            selected.remove(id);
                                          }
                                        })
                                      : null,
                                ),
                            ],
                          ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
                if (marked.isNotEmpty && inPlay)
                  FilledButton(
                    onPressed: session.working || marked.length >= cards.length
                        ? null
                        : () async {
                            await session.act('debugRemove', {
                              'seat': seat,
                              'cards': marked.toList(),
                              'deal': deal,
                            });
                            if (!dialogContext.mounted) return;
                            if (session.error == null) {
                              update(selected.clear);
                            } else {
                              notify(dialogContext, session.error!);
                            }
                          },
                    child: Text('删除 ${marked.length} 张牌'),
                  ),
              ],
            );
          },
        ),
      ),
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
    final thinking = view['botThinking'] == true;
    final apiTimeouts = view['apiTimeouts'] as int? ?? 0;
    final apiSuspended = inPlay && view['apiSuspended'] == true;
    final call = rules.landlordCall.label;
    final status = thinking
        ? (ownTurn ? 'AI 代打思考中' : '${_person(current)} 思考中')
        : autoplay && ownTurn && inPlay
        ? (apiSuspended || _ownAutoMode != 'api' ? '本地托管中' : 'API 托管中')
        : switch (phase) {
            'bidding' => ownTurn ? '轮到你$call' : '${_person(current)}正在$call',
            'playing' when ownTurn && previous == null => '轮到你先出',
            'playing' when ownTurn => '轮到你出牌',
            'playing' => '${_person(current)}正在出牌',
            'finished' when _showFinalPlay =>
              view['leader'] == view['you']
                  ? '你率先出完'
                  : '${_person(view['leader'])}率先出完',
            'finished' => view['result'] as String? ?? '牌局结束',
            _ => people.length == rules.players ? '座位已满，可以发牌' : '等待其他玩家入座',
          };
    final apiStatus = apiSuspended
        ? '本局本地接管'
        : inPlay && apiTimeouts > 0
        ? '超时 $apiTimeouts/${view['apiTimeoutLimit'] ?? botTimeoutLimit}'
        : null;
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
            if (thinking)
              const SizedBox.square(
                dimension: 10,
                child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
              )
            else
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
                    if (apiStatus != null)
                      TextSpan(
                        text: '  ·  $apiStatus',
                        style: const TextStyle(
                          color: Color(0xffffd59a),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
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

  Widget _trickArea(
    RoomJson last,
    int actor,
    List<RoomJson?> opponents,
    Map<int, CardMove> moves,
    Duration motion,
  ) {
    final previousTrick = view['last'] == null;
    if (actor == _activeOpponent) return const SizedBox.shrink();
    final displayed = <int, RoomJson>{
      if (!previousTrick && !_showFinalPlay)
        for (final entry
            in (view['tablePlays'] as List? ?? const []).cast<RoomJson>())
          if (entry['seat'] != actor && entry['seat'] != _activeOpponent)
            entry['seat'] as int: entry['play'] as RoomJson,
      actor: last,
    };
    final me = view['you'] as int;
    return LayoutBuilder(
      builder: (context, bounds) {
        if (bounds.maxHeight < 22) return const SizedBox.shrink();
        final retain =
            bounds.maxHeight >= 118 &&
            bounds.maxWidth >= 480 &&
            opponents.length <= 3;
        final plays = retain ? displayed : {actor: last};
        final bothRows = plays.containsKey(me) && plays.length > 1;
        final height = bothRows ? (bounds.maxHeight - 6) / 2 : bounds.maxHeight;
        return Stack(
          children: [
            for (final item in plays.entries)
              _playedCards(
                item.value,
                item.key,
                opponents,
                moves[item.key],
                motion,
                bounds.maxWidth,
                height,
                current: item.key == actor,
                previousTrick: previousTrick,
                separateOpponents:
                    plays.keys.where((id) => id != me).length > 1,
              ),
            if (!previousTrick &&
                last['bomb'] == true &&
                motion != Duration.zero)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: const Alignment(0, -.30),
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey((
                        'bomb',
                        actor,
                        (last['cards'] as List).firstOrNull?['id'],
                      )),
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 720),
                      builder: (context, phase, child) => Opacity(
                        opacity: math
                            .min(phase * 8, (1 - phase) * 3)
                            .clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: .9 + phase * .18,
                          child: child,
                        ),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xf23c3022),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _gold),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Text(
                            '${last['label']} ×${last['bombMultiplier'] ?? 2}',
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _playedCards(
    RoomJson last,
    int actor,
    List<RoomJson?> opponents,
    CardMove? move,
    Duration motion,
    double availableWidth,
    double availableHeight, {
    required bool current,
    required bool previousTrick,
    required bool separateOpponents,
  }) {
    final mine = actor == view['you'];
    final seat = opponents.indexWhere((player) => player?['id'] == actor);
    final position = mine || seat < 0 || opponents.length == 1
        ? .5
        : opponents.length == 2
        ? (seat == 0 ? .16 : .84)
        : (seat + .5) / opponents.length;
    final cards = (last['cards'] as List).cast<RoomJson>();
    final bomb = last['bomb'] == true;
    final lane = !mine && separateOpponents
        ? availableWidth / opponents.length - 6
        : availableWidth;
    final width = math.min(
      lane,
      (106 + cards.length * 19).clamp(145, 580).toDouble(),
    );
    final left = (availableWidth * position - width / 2).clamp(
      0.0,
      availableWidth - width,
    );
    final insetTop = mine || availableHeight < 190 ? 0.0 : 24.0;
    return Positioned(
      key: ValueKey(mine ? 'my-played-cards' : 'played-by-$actor'),
      left: left,
      top: mine ? null : insetTop,
      bottom: mine ? 0 : null,
      width: width,
      height: math.min(132, availableHeight - insetTop),
      child: TweenAnimationBuilder<double>(
        key: ValueKey((actor, last['key'], cards.firstOrNull?['id'])),
        tween: Tween(begin: 0, end: 1),
        duration: motion * 1.56,
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, (1 - value) * (mine ? 8 : -8)),
          child: Opacity(
            opacity: (.55 + value * .45) * (current ? 1 : .77),
            child: child,
          ),
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
                color: bomb || current
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
    );
  }

  Widget _landlordBadge() => const DecoratedBox(
    decoration: BoxDecoration(
      color: Color(0xffffd990),
      borderRadius: BorderRadius.all(Radius.circular(4)),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Text(
        '地主',
        style: TextStyle(
          color: Color(0xff49300e),
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
  );

  Widget _handLine(
    int count,
    CardMove? move,
    int chosen,
    String? issue,
    String? pattern,
  ) {
    final you = view['you'];
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        Text(
          '我 · $count 张',
          style: const TextStyle(
            color: _gold,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (you == view['landlord']) _landlordBadge(),
        if (_forceOut)
          const Text('强制出牌', style: TextStyle(color: _gold, fontSize: 12)),
        if (move != null) _moveTag(move),
        if (chosen > 0) ...[
          Text(
            issue ??
                (pattern == null ? '已选 $chosen 张' : '$pattern · $chosen 张'),
            style: TextStyle(
              color: issue != null
                  ? const Color(0xffffc9aa)
                  : pattern != null
                  ? _gold
                  : Colors.white70,
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
    if (inPlay && ownTurn && autoplay) {
      children.add(
        OutlinedButton.icon(
          style: quiet,
          onPressed: blocked
              ? null
              : () => session.act('autoplay', {'enabled': false}),
          icon: const Icon(Icons.front_hand_outlined, size: 16),
          label: const Text('接管出牌'),
        ),
      );
    }
    if (phase == 'bidding' && ownTurn && !autoplay) {
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
      for (final bid in rules.bidsAfter(view['bid'] as int).skip(1)) {
        children.add(
          FilledButton(
            style: playStyle,
            onPressed: blocked
                ? null
                : () => session.act('bid', {
                    'bid': bid,
                    'turnVersion': turnVersion,
                  }),
            child: Text(
              rules.landlordCall == LandlordCall.call ? '叫地主' : '$bid 分',
            ),
          ),
        );
      }
    }
    if (phase == 'playing' && ownTurn && !autoplay) {
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
        OutlinedButton(
          style: quiet,
          onPressed: blocked
              ? null
              : () => session.act('aiHint', {'turnVersion': turnVersion}),
          child: Text(coaching == null ? 'AI 提示' : '重新生成'),
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
          label: Text(
            phase != 'finished'
                ? '发牌开局'
                : view['matchComplete'] == true
                ? '开始新比赛'
                : '下一局',
          ),
        ),
        if (!online) ...[
          OutlinedButton(
            style: quiet,
            onPressed: blocked || people.length >= rules.players
                ? null
                : _chooseBot,
            child: const Text('添加电脑玩家'),
          ),
          if (people.any((person) => person['bot'] == true))
            OutlinedButton(
              style: quiet,
              onPressed: blocked ? null : () => session.act('removeBot'),
              child: const Text('移除电脑玩家'),
            ),
          if (widget.onBotApi != null)
            OutlinedButton(
              style: quiet,
              onPressed: blocked ? null : widget.onBotApi,
              child: const Text('电脑 API'),
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

  Widget _opponentsStrip(
    List<RoomJson?> opponents,
    Map<int, CardMove> moves, {
    required double tableWidth,
    required bool compact,
  }) {
    final maxPerRow = math.max(2, (tableWidth / 76).floor());
    final rowCount = opponents.length <= maxPerRow
        ? 1
        : (opponents.length / maxPerRow).ceil();
    final perRow = (opponents.length / rowCount).ceil();
    final rows = [
      for (var i = 0; i < opponents.length; i += perRow)
        opponents.sublist(i, math.min(i + perRow, opponents.length)),
    ];
    final multiRow = rows.length > 1;
    final gap = compact || multiRow ? 4.0 : 8.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        for (final row in rows)
          Row(
            spacing: gap,
            children: [
              for (final (index, player) in row.indexed)
                Expanded(
                  child: Align(
                    alignment: multiRow
                        ? Alignment.center
                        : row.length == 1
                        ? Alignment.center
                        : index == 0
                        ? Alignment.centerLeft
                        : index == row.length - 1
                        ? Alignment.centerRight
                        : Alignment.center,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: multiRow ? double.infinity : 172,
                      ),
                      child: _seat(
                        player,
                        moves[player?['id']],
                        compact: multiRow || compact,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _seat(RoomJson? player, CardMove? move, {bool compact = false}) {
    if (player == null) {
      return SizedBox(
        height: compact ? 33 : 37,
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
    final remoteAuto = player['autoplay'] == true;
    final botMode = player['botMode'] as String?;
    final autoLabel = botMode == 'api' && view['apiSuspended'] != true
        ? 'API 托管'
        : '本地托管';
    final called = view['phase'] == 'bidding' ? player['called'] as int? : null;
    final caption = called == null
        ? null
        : called == 0
        ? '不叫'
        : rules.landlordCall == LandlordCall.call
        ? '叫地主'
        : '$called 分';
    return Semantics(
      label:
          '$name${landlord ? '，地主' : ''} ${player['cards']} 张${remoteAuto ? '，$autoLabel中' : ''}${move == null ? '' : '，${move.label}'}',
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
            height: compact ? 37 : 43,
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
                              ? (botMode == 'api' ? 'AI' : '机')
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
                          if (landlord)
                            Row(
                              spacing: 3,
                              children: [
                                _landlordBadge(),
                                if (move != null && limits.maxWidth >= 108)
                                  Flexible(child: _moveTag(move)),
                              ],
                            )
                          else if (move != null)
                            _moveTag(move)
                          else if (caption != null)
                            Text(
                              caption,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: const TextStyle(
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
                          remoteAuto && limits.maxWidth >= 136
                              ? '$autoLabel · ${player['cards']}'
                              : '${player['cards']}',
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
    final hands = _debug?['hands'] as RoomJson?;
    final seat = player['id'] as int;
    if (_debug?['gui'] == true) {
      unawaited(_showCheats(seat: seat));
      return;
    }
    if (hands?.containsKey('$seat') == true) {
      unawaited(_showDebugHand(seat, player['name'] as String));
      return;
    }
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

  Future<void> _showChat() async {
    if (_chatVisible) return;
    setState(() {
      _chatVisible = _chatReading = true;
      _unreadChat = 0;
    });
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => _CardChatDialog(
          session: session,
          onReading: (reading) {
            if (!mounted) return;
            setState(() {
              _chatReading = reading;
              if (reading) _unreadChat = 0;
            });
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _chatVisible = _chatReading = false);
    }
  }
}

String _chatSpeaker(RoomJson message, List<RoomJson> people) {
  final speaker =
      message['sender'] as String? ??
      people
              .where((person) => person['id'] == message['from'])
              .firstOrNull?['name']
          as String? ??
      '玩家';
  return message['replyTo'] == null || message['from'] == null
      ? speaker
      : '$speaker（AI）';
}

List<RoomJson> _chatMessages(RoomJson? view) {
  final chat = view?['chat'] as RoomJson?;
  if (chat?['messages'] case final List messages) {
    return messages.cast<RoomJson>();
  }
  return (view?['events'] as List? ?? const [])
      .cast<RoomJson>()
      .where((event) => event['kind'] == 'chat')
      .toList();
}

class _CardChatDialog extends StatefulWidget {
  const _CardChatDialog({required this.session, required this.onReading});

  final CardSession session;
  final ValueChanged<bool> onReading;

  @override
  State<_CardChatDialog> createState() => _CardChatDialogState();
}

class _CardChatDialogState extends State<_CardChatDialog> {
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  bool _system = false;
  int _readThrough = 0;
  String? _error;

  CardSession get _session => widget.session;
  bool get _blocked => _session.working || _session.awaitingGit;

  Future<void> _act(String action, RoomJson data) async {
    if (_blocked) return;
    setState(() => _error = null);
    await _session.act(action, data);
    if (mounted) setState(() => _error = _session.error);
  }

  Future<void> _send() async {
    final text = _draft.text.trim();
    if (text.isEmpty || _blocked) return;
    await _act('chat', {'text': text});
    if (!mounted || _error != null) return;
    if (_draft.text.trim() == text) _draft.clear();
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final view = _session.view;
      final events = (view?['events'] as List? ?? const []).cast<RoomJson>();
      final people = (view?['people'] as List? ?? const []).cast<RoomJson>();
      final messages = _chatMessages(view);
      final history = _system
          ? events.where((event) => event['kind'] != 'chat').toList()
          : messages;
      final byId = {for (final message in messages) message['id']: message};
      if (!_system) _readThrough = messages.lastOrNull?['id'] as int? ?? 0;
      final unread = _system
          ? messages
                .where(
                  (message) =>
                      (message['id'] as int) > _readThrough &&
                      message['from'] != view?['you'],
                )
                .length
          : 0;
      final chat = view?['chat'] as RoomJson?;
      final status = chat?['status'] as RoomJson?;
      final queued = chat?['queued'] as int? ?? 0;
      final source = byId[status?['source']];
      final host = view != null && view['host'] == view['you'];
      final aiOn = chat?['enabled'] == true;
      final available = chat?['available'] == true;
      final colors = Theme.of(context).colorScheme;
      final retry =
          status?['error'] != null &&
          available &&
          aiOn &&
          (host || source?['from'] == view?['you']);
      final media = MediaQuery.of(context);
      final height = media.size.height - media.viewInsets.vertical;
      final compact = height < 310;
      final tabs = SegmentedButton<bool>(
        style: compact
            ? const ButtonStyle(visualDensity: VisualDensity.compact)
            : null,
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: false,
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(unread == 0 ? '聊天' : '聊天 · $unread'),
          ),
          const ButtonSegment(
            value: true,
            icon: Icon(Icons.notes),
            label: Text('系统'),
          ),
        ],
        selected: {_system},
        onSelectionChanged: (value) {
          setState(() => _system = value.single);
          widget.onReading(!_system);
        },
      );
      return Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: compact ? 4 : 10,
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 490,
          height: 540,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 17, right: 6),
                child: Row(
                  children: [
                    if (compact) ...[
                      tabs,
                      const Spacer(),
                    ] else
                      Expanded(
                        child: Text(
                          '牌桌消息',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (!compact)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Align(alignment: Alignment.centerLeft, child: tabs),
                ),
              const SizedBox(height: 6),
              if (!_system && chat != null && height >= 200)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  child: Row(
                    children: [
                      const Icon(Icons.smart_toy_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          !available
                              ? 'AI 回复 · 房主需启用电脑 API'
                              : aiOn
                              ? 'AI 回复已开启'
                              : 'AI 回复已关闭',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (host)
                        Semantics(
                          label: 'AI 回复',
                          child: Switch(
                            value: aiOn,
                            onChanged: _blocked
                                ? null
                                : (value) => _act('chatAi', {'enabled': value}),
                          ),
                        ),
                    ],
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: history.isEmpty
                    ? Center(
                        child: Text(
                          _system ? '暂无系统记录' : '还没有消息，打个招呼吧',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        key: ValueKey(_system),
                        controller: _system ? null : _scroll,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        itemCount: history.length,
                        itemBuilder: (context, index) {
                          final event = history[history.length - 1 - index];
                          if (_system) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                event['text'] as String,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            );
                          }
                          return _ChatBubble(
                            event: event,
                            sender: _chatSpeaker(event, people),
                            mine: event['from'] == view?['you'],
                            quoted: byId[event['replyTo']]?['text'] as String?,
                          );
                        },
                      ),
              ),
              if (!_system && status != null && height >= 155)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        if (status['pending'] == true)
                          const SizedBox.square(
                            dimension: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: colors.error,
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            status['pending'] == true
                                ? 'AI 正在回复…${queued > 0 ? ' · $queued 条排队' : ''}'
                                : status['error'] as String,
                          ),
                        ),
                        if (retry)
                          TextButton(
                            onPressed: _blocked
                                ? null
                                : () => _act('retryChatAi', {
                                    'source': status['source'],
                                  }),
                            child: const Text('重试'),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(error, style: TextStyle(color: colors.error)),
                ),
              if (!_system)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 12, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _draft,
                          onSubmitted: (_) => _send(),
                          textInputAction: TextInputAction.send,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(120),
                          ],
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '发条消息',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ListenableBuilder(
                        listenable: _draft,
                        builder: (context, _) => IconButton.filled(
                          tooltip: '发送',
                          onPressed: _blocked || _draft.text.trim().isEmpty
                              ? null
                              : _send,
                          icon: const Icon(Icons.send),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.event,
    required this.sender,
    required this.mine,
    this.quoted,
  });

  final RoomJson event;
  final String sender;
  final bool mine;
  final String? quoted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ai = event['replyTo'] != null;
    final millis = event['time'] as int?;
    final time = millis == null
        ? null
        : TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(millis))
              .format(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 345),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                [if (ai) '✦', mine ? '我' : sender, ?time].join('  '),
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 2),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: mine
                      ? colors.primaryContainer
                      : ai
                      ? colors.tertiaryContainer
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (quoted case final quote?)
                        Text(
                          '↳ $quote',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      SelectableText(event['text'] as String),
                      if (event['aiSkipped'] case final String skipped)
                        Text(skipped, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ],
          ),
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

class _AiWaitLabel extends StatefulWidget {
  const _AiWaitLabel({super.key, required this.stage, required this.seconds});

  final String? stage;
  final int seconds;

  @override
  State<_AiWaitLabel> createState() => _AiWaitLabelState();
}

class _AiWaitLabelState extends State<_AiWaitLabel> {
  Timer? _timer;
  late int _seconds = widget.seconds;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_AiWaitLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seconds != oldWidget.seconds ||
        widget.stage != oldWidget.stage) {
      _seconds = widget.seconds;
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    if (_seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _seconds--);
      if (_seconds == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = switch (widget.stage) {
      'preparing' => '正在准备牌面',
      'connecting' => '正在连接模型',
      'receiving' => '正在接收结果',
      'retrying' => '模型未给出答案，正在重试',
      _ => '模型正在分析',
    };
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xff153b32),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 9),
          child: Text.rich(
            TextSpan(
              text: phase,
              children: [
                TextSpan(
                  text: _seconds > 0 ? ' · 剩余最多 $_seconds 秒' : ' · 正在结束等待',
                ),
              ],
            ),
            style: const TextStyle(color: Color(0xfff2dbac), fontSize: 12),
          ),
        ),
      ),
    );
  }
}

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
