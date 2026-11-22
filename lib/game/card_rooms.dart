import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/identity.dart';
import '../domain/ledger.dart';
import 'bot_profile.dart';
import 'cards.dart';

const _alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
final roomCodePattern = RegExp(r'^[2-9A-HJ-NP-Z]{7}$');
typedef RoomJson = Map<String, dynamic>;
typedef CardSeat = ({String room, String token});

class CardRooms extends ChangeNotifier {
  CardRooms({
    Random? random,
    this.botDelay = const Duration(milliseconds: 650),
    this.advisor,
    this.coach,
    this.apiEnabled,
  }) : _random = random ?? Random.secure();

  final Random _random;
  final Duration botDelay;
  final BotAdvisor? advisor;
  final BotCoach? coach;
  final bool Function()? apiEnabled;
  final _rooms = <String, _CardRoom>{};
  final _bots = <String, ({int revision, Timer timer})>{};

  List<RoomJson> publicRooms({String scope = 'lan'}) {
    _prune();
    return [
      for (final room in _rooms.values)
        if (room.scope == scope && room.canJoin) room.summary,
    ];
  }

  void requireScope(String code, String scope) {
    if (_room(code).scope != scope) throw const InputException('房间未通过这个入口分享');
  }

  void share(String code, String token) {
    final room = _room(code);
    room.requireHost(room.player(token));
    if (room.scope == 'online') throw const InputException('在线房间通过 Git 同步');
    if (room.scope != 'lan') {
      room.scope = 'lan';
      _changed(room);
    }
  }

  CardSeat create(CardRules rules, {String? name, String scope = 'local'}) {
    _prune();
    if (_rooms.length >= 24) throw const InputException('房间已满，请先关闭不使用的房间');
    var code = _code();
    while (_rooms.containsKey(code)) {
      code = _code();
    }
    final room = _CardRoom(code, rules, scope);
    final player = room.join(name);
    _rooms[code] = room;
    _changed(room);
    return (room: code, token: player.token);
  }

  CardSeat join(String code, {String? name, String scope = 'local'}) {
    final room = _room(code);
    if (scope != 'local' && room.scope != scope) {
      throw const InputException('房间未通过这个入口分享');
    }
    final player = room.join(name);
    _changed(room);
    return (room: code, token: player.token);
  }

  RoomJson state(CardSeat seat, {int? since}) {
    final room = _room(seat.room);
    final player = room.player(seat.token);
    if (since == room.version) return {'version': room.version};
    return room.view(player);
  }

  List<RoomJson> options(CardSeat seat, RoomJson data) {
    final room = _room(seat.room);
    final player = room.player(seat.token);
    room._requireTurn(player, data, _Phase.playing);
    return room._options(player, data).map((play) => play.toJson()).toList();
  }

  List<RoomJson> hints(CardSeat seat, RoomJson data) {
    final room = _room(seat.room);
    final player = room.player(seat.token);
    room._requireTurn(player, data, _Phase.playing);
    return [
      for (final play in hintPlays(
        player.cards,
        room.wild,
        room.last,
        rules: room.rules,
      ))
        play.toJson(),
    ];
  }

  RoomJson action(CardSeat seat, String action, RoomJson data) {
    final room = _room(seat.room);
    final player = room.player(seat.token);
    if (action == 'leave') {
      if (room.inProgress) room.abort('${player.name}离开了牌桌');
      room.people.remove(player);
      if (room.people.every((entry) => entry.bot)) {
        _bots.remove(room.code)?.timer.cancel();
        _rooms.remove(room.code);
        notifyListeners();
      } else {
        room.people.sort((a, b) => (a.bot ? 1 : 0).compareTo(b.bot ? 1 : 0));
        room.event('leave', '${player.name}离开了房间');
        _changed(room);
      }
      return {'left': true};
    }
    if (action == 'aiHint') {
      room._requireTurn(player, data, _Phase.playing);
      final hint = coach;
      if (hint == null || !(apiEnabled?.call() ?? true)) {
        throw const InputException('请房主先启用电脑 API');
      }
      if (room._hintFor(player)?['pending'] != true) {
        unawaited(_advise(room, player, hint));
      }
      return room.view(player);
    }
    room.act(player, action, data, _random);
    _changed(room);
    return room.view(player);
  }

  Future<void> _advise(_CardRoom room, _Person player, BotCoach coach) async {
    final revision = room.turnVersion;
    final turn = room._botTurn(player);
    final request = <String, dynamic>{
      'id': ++room._hintSequence,
      'turn': revision,
      'pending': true,
    };
    room._hints[player.id] = request;
    _publish(room);
    BotAdvice advice;
    try {
      advice = await coach(
        turn,
        List.unmodifiable(room._coachingHistory[player.id] ?? const []),
      );
    } catch (_) {
      advice = const BotAdvice.failed('AI 提示暂不可用');
    }
    if (_rooms[room.code] != room ||
        room.current != player ||
        room.turnVersion != revision ||
        room._hints[player.id] != request) {
      return;
    }
    request['pending'] = false;
    final explanation = advice.explanation;
    if (!advice.ready || explanation == null) {
      request['error'] = advice.failure ?? 'AI 没有返回可用提示';
    } else {
      request['reason'] = explanation;
      request['pass'] = advice.pass;
      if (advice.play case final play?) {
        request['play'] = play.toJson();
      }
      final history = room._coachingHistory.putIfAbsent(player.id, () => []);
      if (history.length == 4) history.removeAt(0);
      history.add(
        '${advice.pass ? '不出' : advice.play?.label ?? ''}：$explanation',
      );
    }
    _publish(room);
  }

  void _changed(_CardRoom room) {
    final pending = _bots[room.code];
    if (pending != null &&
        (pending.revision != room.turnVersion ||
            room.current?.automatic != true)) {
      _bots.remove(room.code);
      pending.timer.cancel();
      room.thinking = false;
    }
    _publish(room);
    final bot = room.current;
    if (bot == null || !bot.automatic || _bots.containsKey(room.code)) return;
    final revision = room.turnVersion;
    late final Timer timer;
    bool current() =>
        _rooms[room.code] == room &&
        _bots[room.code]?.timer == timer &&
        room.turnVersion == revision &&
        bot.automatic;

    timer = Timer(botDelay, () async {
      if (!current()) return;
      final remote = advisor;
      var applied = false;
      if (remote != null && !room.apiFailed && (apiEnabled?.call() ?? true)) {
        final turn = room._botTurn(bot);
        room.thinking = true;
        _publish(room);
        if (!current()) return;
        BotAdvice advice;
        try {
          advice = await remote(turn);
        } catch (_) {
          advice = const BotAdvice.failed('电脑 API 暂时不可用');
        }
        if (!current()) return;
        room.thinking = false;
        if (advice.failure case final failure?) room._noteApi(failure);
        if (advice.ready) {
          applied = room._applyAdvice(bot, advice, _random);
          if (!applied) room._noteApi('电脑 API 返回了不可用的动作');
        }
      }
      if (!applied) room._localBot(bot, _random);
      _bots.remove(room.code);
      _changed(room);
    });
    _bots[room.code] = (revision: revision, timer: timer);
  }

  void _publish(_CardRoom room) {
    room.version++;
    room.updated = DateTime.now();
    notifyListeners();
  }

  _CardRoom _room(String code) {
    _prune();
    return _rooms[code.toUpperCase()] ??
        (throw const InputException('房间不存在或房主已关闭房间'));
  }

  void _prune() {
    final now = DateTime.now();
    _rooms.removeWhere((code, room) {
      if (now.difference(room.updated) < const Duration(hours: 4)) return false;
      _bots.remove(code)?.timer.cancel();
      return true;
    });
  }

  String _code() => List.generate(
    7,
    (_) => _alphabet[_random.nextInt(_alphabet.length)],
  ).join();

  @override
  void dispose() {
    for (final pending in _bots.values) {
      pending.timer.cancel();
    }
    _bots.clear();
    _rooms.clear();
    super.dispose();
  }
}

enum _Phase { lobby, bidding, playing, finished }

enum CardMove {
  lead('先出'),
  beat('管上'),
  pass('不要');

  const CardMove(this.label);
  final String label;
}

class _Person {
  _Person(this.id, this.name, {this.bot = false}) : token = newIdentityCode();
  final int id;
  final String name;
  final String token;
  final bool bot;
  List<PlayingCard> cards = [];
  DateTime? lastTomato;
  DateTime? lastChat;
  BigInt points = BigInt.zero;
  bool autoplay = false;
  int? called;
  bool get automatic => bot || autoplay;
  int wins = 0;
  int moves = 0;
  CardMove? lastMove;

  RoomJson publicView() => {
    'id': id,
    'name': name,
    'cards': cards.length,
    'bot': bot,
    'points': _scoreValue(points),
    'autoplay': autoplay,
    'called': called,
    'wins': wins,
    'move': lastMove?.name,
  };
}

Object _scoreValue(BigInt value) => value.abs() <= BigInt.from(9007199254740991)
    ? value.toInt()
    : value.toString();

class _CardRoom {
  _CardRoom(this.code, this.rules, this.scope);

  final String code;
  String scope;
  CardRules rules;
  final people = <_Person>[];
  final events = <RoomJson>[];
  var updated = DateTime.now();
  int version = 0;
  int turnVersion = 0;
  int deal = 0;
  bool thinking = false;
  bool apiFailed = false;
  final _botLog = <String>[];
  final _coachingHistory = <int, List<String>>{};
  final _hints = <int, RoomJson>{};
  int _hintSequence = 0;

  RoomJson? _hintFor(_Person person) {
    final hint = _hints[person.id];
    return hint?['turn'] == turnVersion ? hint : null;
  }

  int _nextPerson = 0;
  int _eventId = 0;
  var phase = _Phase.lobby;
  List<PlayingCard> bottom = [];
  Set<int> wild = {};
  List<int> winners = [];
  int? extraSeat;
  int? turn;
  int? landlord;
  int? leader;
  int? bidder;
  int topBid = 0;
  int bids = 0;
  int passes = 0;
  int multiplier = 1;
  int bombCount = 0;
  int completedRounds = 0;
  int redeals = 0;
  int? firstCaller;
  int? previousWinner;
  List<int> seriesSeats = const [];
  RoomJson? settlement;
  final _playedCards = <int, List<PlayingCard>>{};

  bool get matchComplete =>
      rules.matchRounds > 0 && completedRounds >= rules.matchRounds;

  Map<int, int> _cardCounter(_Person person) {
    // Known bottom cards are public once assigned, even before being played.
    final seen = {
      for (final card in person.cards) card.id,
      for (final card in _playedCards.values.expand((cards) => cards)) card.id,
      if (landlord != null)
        for (final card in bottom) card.id,
    };
    final counts = {
      for (var rank = 3; rank <= 17; rank++)
        rank: PlayingCard.copiesPerDeck(rank) * rules.decks,
    };
    for (final id in seen) {
      final rank = PlayingCard(id).rank;
      counts[rank] = counts[rank]! - 1;
    }
    return counts;
  }

  List<RoomJson> _standings() {
    final ranked = [...people]
      ..sort((a, b) {
        final comparison = b.points.compareTo(a.points);
        return comparison == 0 ? a.id.compareTo(b.id) : comparison;
      });
    return [
      for (final person in ranked)
        {
          'seat': person.id,
          'name': person.name,
          'points': _scoreValue(person.points),
          'wins': person.wins,
        },
    ];
  }

  CardPlay? last;
  final _tablePlays = <int, CardPlay>{};
  ({int leader, CardPlay play})? _previousTrick;
  String? result;

  Set<int> get publicWild => phase != _Phase.bidding
      ? wild
      : rules.mode == CardMode.doubleWild
      ? {wild.first}
      : const {};

  bool get inProgress => phase == _Phase.bidding || phase == _Phase.playing;
  bool get canJoin => !inProgress && people.length < rules.players;
  _Person? get current => inProgress && turn != null
      ? people.where((person) => person.id == turn).firstOrNull
      : null;

  RoomJson get summary => {
    'room': code,
    'host': people.first.name,
    'players': people.length,
    'capacity': rules.players,
    'mode': rules.mode.name,
    'landlord': rules.landlord,
  };

  _Person join(String? name, {bool bot = false}) {
    if (!canJoin) throw const InputException('牌局已开始或座位已满');
    final id = ++_nextPerson;
    final choice = name?.trim() ?? '';
    if (choice.runes.length > 20 ||
        RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(choice)) {
      throw const InputException('昵称最多 20 个字，不可包含控制字符');
    }
    final person = _Person(
      id,
      bot ? '电脑 $id' : (choice.isEmpty ? '访客 $id' : choice),
      bot: bot,
    );
    people.add(person);
    event('join', '${person.name}加入了房间');
    return person;
  }

  _Person player(String token) =>
      people.where((entry) => entry.token == token && !entry.bot).firstOrNull ??
      (throw const InputException('座位已失效，请重新加入房间'));

  void requireHost(_Person person) {
    if (people.first != person) throw const InputException('只有房主可以执行此操作');
  }

  void event(String kind, String message, {int? from, int? target}) {
    events.add({
      'id': ++_eventId,
      'kind': kind,
      'text': message,
      'from': from,
      'target': target,
    });
    if (events.length > 48) events.removeAt(0);
  }

  RoomJson view(_Person person) => {
    'room': code,
    'version': version,
    'turnVersion': turnVersion,
    'phase': phase.name,
    'host': people.first.id,
    'you': person.id,
    'rules': rules.toJson(),
    'scope': scope,
    'people': [for (final player in people) player.publicView()],
    'hand': [for (final card in person.cards) card.id],
    'turn': turn,
    'landlord': landlord,
    'leader': leader,
    'bid': topBid,
    'bidder': bidder,
    'bottom': [
      if (landlord != null)
        for (final card in bottom) card.id,
    ],
    'wild': publicWild.toList(),
    'extra': extraSeat,
    'last': last?.toJson(),
    'tablePlays': [
      for (final person in people)
        if (_tablePlays[person.id] case final play?)
          {'seat': person.id, 'play': play.toJson()},
    ],
    if (_previousTrick case (leader: final actor, play: final played))
      'previousTrick': {'leader': actor, 'play': played.toJson()},
    'winners': winners,
    'multiplier': multiplier,
    'round': completedRounds + (inProgress ? 1 : 0),
    'rounds': rules.matchRounds,
    'matchComplete': matchComplete,
    'redeals': redeals,
    'firstCaller': firstCaller,
    'standings': _standings(),
    if (phase == _Phase.finished && settlement != null)
      'settlement': settlement!,
    if (rules.cardCounter && inProgress)
      'counter': _cardCounter(person).entries
          .map((entry) => {'rank': entry.key, 'count': entry.value})
          .toList(),
    'botThinking': thinking,
    if (_hintFor(person) case final hint?)
      'aiHint': Map<String, dynamic>.of(hint),
    'result': result,
    'events': events.map((event) => Map<String, dynamic>.of(event)).toList(),
  };

  void act(_Person person, String action, RoomJson input, Random random) {
    switch (action) {
      case 'rules':
        requireHost(person);
        if (inProgress) throw const InputException('牌局进行中');
        final next = CardRules.fromJson(_readRules(input));
        if (people.length > next.players) {
          throw const InputException('请先腾出多余座位');
        }
        rules = next;
        _resetMatch();
        abort('房主更新了规则');
      case 'bot':
        requireHost(person);
        if (scope == 'online') throw const InputException('在线房间使用真人座位');
        join(null, bot: true);
      case 'removeBot':
        requireHost(person);
        if (inProgress) throw const InputException('请先结束当前牌局');
        final bot = people.where((entry) => entry.bot).lastOrNull;
        if (bot == null) throw const InputException('当前没有电脑玩家');
        people.remove(bot);
        event('leave', '${bot.name}已移除');
      case 'kick':
        requireHost(person);
        if (inProgress) throw const InputException('请先结束当前牌局');
        final target = people
            .where((entry) => entry.id == input['target'])
            .firstOrNull;
        if (target == null || target == person) {
          throw const InputException('请选择其他座位');
        }
        people.remove(target);
        event('leave', '${target.name}已移出牌桌');
      case 'start':
        requireHost(person);
        if (inProgress || people.length != rules.players) {
          throw const InputException('请等所有座位坐满再开局');
        }
        final seats = people.map((person) => person.id).toList();
        if (matchComplete || !listEquals(seriesSeats, seats)) _resetMatch();
        seriesSeats = seats;
        redeals = 0;
        _deal(random);
      case 'autoplay':
        final enabled = input['enabled'];
        if (enabled is! bool || (enabled && !inProgress)) {
          throw const InputException('牌局进行中才可以开启托管');
        }
        if (person.autoplay != enabled) {
          person.autoplay = enabled;
          if (current == person) turnVersion++;
          event(
            'note',
            enabled ? '${person.name}开启托管' : '${person.name}接管手牌',
            from: person.id,
          );
        }
      case 'abort':
        requireHost(person);
        abort('房主结束了当前牌局');
      case 'bid':
        _requireTurn(person, input, _Phase.bidding);
        final value = input['bid'];
        if (value is! int || !rules.bidsAfter(topBid).contains(value)) {
          throw const InputException('请选择有效的叫牌选项');
        }
        _bid(person, value, random);
      case 'pass':
        _requireTurn(person, input, _Phase.playing);
        _pass(person);
      case 'play':
        _requireTurn(person, input, _Phase.playing);
        _play(person, _chosen(person, input));
      case 'chat':
        final raw = input['text'];
        if (raw is! String ||
            raw.trim().isEmpty ||
            raw.runes.length > 120 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw)) {
          throw const InputException('消息长度为 1 至 120 字');
        }
        person.lastChat = _throttle(person.lastChat, 650);
        event('chat', raw.trim(), from: person.id);
      case 'tomato':
        final target = people
            .where((entry) => entry.id == input['target'])
            .firstOrNull;
        if (target == null || target == person) {
          throw const InputException('请选择另一位玩家');
        }
        person.lastTomato = _throttle(person.lastTomato, 2200);
        event(
          'tomato',
          '${person.name}向${target.name}丢了一个番茄',
          from: person.id,
          target: target.id,
        );
      default:
        throw const InputException('未知牌桌操作');
    }
  }

  static RoomJson _readRules(RoomJson input) {
    final rule = input['rules'];
    if (rule is! Map<String, dynamic>) throw const InputException('请填写房间规则');
    return rule;
  }

  static DateTime _throttle(DateTime? previous, int milliseconds) {
    final now = DateTime.now();
    if (previous != null &&
        now.difference(previous).inMilliseconds < milliseconds) {
      throw const InputException('操作太快，请稍等');
    }
    return now;
  }

  void _requireTurn(_Person person, RoomJson input, _Phase expected) {
    if (phase != expected ||
        current != person ||
        person.autoplay ||
        input['turnVersion'] != turnVersion) {
      throw const InputException('回合已变化，请刷新后再试');
    }
  }

  void _deal(Random random, {bool repeat = false}) {
    deal++;
    apiFailed = false;
    _botLog.clear();
    _coachingHistory.clear();
    _hints.clear();
    _playedCards.clear();
    settlement = null;
    bombCount = 0;
    final dealt = dealCards(rules, random);
    for (final (i, person) in people.indexed) {
      person.cards = dealt.hands[i];
      person.moves = 0;
      person.lastMove = null;
      person.called = null;
    }
    bottom = dealt.bottom;
    extraSeat = dealt.extraSeat == null ? null : people[dealt.extraSeat!].id;
    final ranks = List.generate(13, (index) => index + 3)..shuffle(random);
    wild = ranks.take(rules.mode.index).toSet();
    final winner = rules.firstCaller == FirstCaller.previousWinner
        ? people.where((person) => person.id == previousWinner).firstOrNull
        : null;
    firstCaller = turn = (winner ?? people[random.nextInt(people.length)]).id;
    phase = rules.landlord ? _Phase.bidding : _Phase.playing;
    topBid = bids = passes = 0;
    multiplier = 1;
    landlord = bidder = leader = null;
    last = null;
    _tablePlays.clear();
    _previousTrick = null;
    result = null;
    winners = [];
    turnVersion++;
    event('deal', repeat ? '无人叫地主，第 $redeals 次重新发牌' : '发牌完成');
    if (repeat && redeals == 3) _assignLandlord(firstCaller!, forced: true);
  }

  int _next(_Person person) =>
      people[(people.indexOf(person) + 1) % people.length].id;

  void _resetMatch() {
    completedRounds = 0;
    previousWinner = null;
    settlement = null;
    for (final person in people) {
      person.points = BigInt.zero;
      person.wins = 0;
      person.autoplay = false;
    }
  }

  void _bid(_Person person, int value, Random random) {
    bids++;
    turnVersion++;
    person.called = value;
    if (value > topBid) {
      topBid = value;
      bidder = person.id;
    }
    event(
      'bid',
      value == 0
          ? '${person.name}不叫'
          : rules.landlordCall == LandlordCall.call
          ? '${person.name}叫地主'
          : '${person.name}叫 $value 分',
      from: person.id,
    );
    _rememberMove(
      person,
      value == 0
          ? '不叫'
          : rules.landlordCall == LandlordCall.call
          ? '叫地主'
          : '叫 $value 分',
    );
    final called = rules.landlordCall == LandlordCall.call && value == 1;
    if (!called && value != 3 && bids < people.length) {
      turn = _next(person);
      return;
    }
    if (bidder case final id?) {
      _assignLandlord(id);
    } else {
      redeals++;
      _deal(random, repeat: true);
    }
  }

  void _assignLandlord(int id, {bool forced = false}) {
    landlord = turn = id;
    final owner = people.firstWhere((entry) => entry.id == id);
    topBid = max(1, topBid);
    owner.cards.addAll(bottom);
    owner.cards.sort(PlayingCard.compare);
    phase = _Phase.playing;
    event(
      'landlord',
      forced ? '已重新发牌三次，${owner.name}成为地主' : '${owner.name}成为地主',
      from: id,
    );
  }

  void _pass(_Person person) {
    final played = last;
    if (played == null) throw const InputException('领出时必须出牌');
    turn = _next(person);
    passes++;
    person.lastMove = CardMove.pass;
    _tablePlays.remove(person.id);
    if (passes == people.length - 1) {
      // Keep the cards visible while the winner of the trick prepares to lead.
      _previousTrick = (leader: leader!, play: played);
      _tablePlays.clear();
      last = null;
      leader = null;
      passes = 0;
    }
    turnVersion++;
    _rememberMove(person, '不出');
    event('pass', '${person.name}不要', from: person.id);
  }

  List<CardPlay> _options(_Person person, RoomJson data) {
    final ids = data['cards'];
    if (ids is! List ||
        ids.isEmpty ||
        ids.length > person.cards.length ||
        ids.any((id) => id is! int) ||
        ids.toSet().length != ids.length) {
      throw const InputException('请选择有效的手牌');
    }
    final available = {for (final card in person.cards) card.id: card};
    final cards = [for (final id in ids) ?available[id]];
    if (cards.length != ids.length) throw const InputException('只能打出自己的手牌');
    final selection = inspectCardSelection(cards, wild, last, rules);
    if (selection.issue case final issue?) throw InputException(issue);
    return selection.options;
  }

  CardPlay _chosen(_Person person, RoomJson data) {
    final options = _options(person, data);
    final desired = data['pattern'];
    final play = desired == null
        ? options.firstOrNull
        : options.where((entry) => entry.key == desired).firstOrNull;
    return play ?? (throw const InputException('所选牌型不合法，或压不过上家的牌'));
  }

  void _play(_Person person, CardPlay play) {
    final leading = last == null;
    if (leading) {
      _tablePlays.clear();
      for (final player in people) {
        player.lastMove = null;
      }
    }
    person.lastMove = leading ? CardMove.lead : CardMove.beat;
    final used = play.cards.map((card) => card.id).toSet();
    person.cards.removeWhere((card) => used.contains(card.id));
    person.moves++;
    passes = 0;
    leader = person.id;
    last = play;
    _tablePlays[person.id] = play;
    _previousTrick = null;
    turnVersion++;
    if (play.bomb) {
      multiplier *= 2;
      bombCount++;
    }
    _playedCards.putIfAbsent(person.id, () => []).addAll(play.cards);
    event(
      play.kind == PlayKind.rocket
          ? 'rocket'
          : play.bomb
          ? 'bomb'
          : 'play',
      '${person.name}打出${play.label}',
      from: person.id,
    );
    final ranks = play.cards.map((card) => play.ranks[card.id] ?? card.rank);
    _rememberMove(person, '打出${play.label} ${formatBotRanks(ranks)}');
    if (person.cards.isEmpty) {
      _finish(person);
    } else {
      turn = _next(person);
    }
  }

  void _finish(_Person first) {
    phase = _Phase.finished;
    turn = null;
    completedRounds++;
    previousWinner = first.id;
    final landlordWon = first.id == landlord;
    final owner = people.where((person) => person.id == landlord).firstOrNull;
    final spring = owner == null
        ? null
        : landlordWon &&
              people
                  .where((person) => person != owner)
                  .every((person) => person.moves == 0)
        ? '春天'
        : !landlordWon && owner.moves == 1
        ? '反春'
        : null;
    if (spring != null) multiplier *= 2;
    final base = owner == null ? 1 : topBid;
    final score = BigInt.from(base) * BigInt.from(multiplier);
    winners = [
      for (final person in people)
        if (owner == null ? person == first : (person == owner) == landlordWon)
          person.id,
    ];
    final rows = <RoomJson>[];
    for (final person in people) {
      final won = winners.contains(person.id);
      final paired = owner == null ? person == first : person == owner;
      final delta =
          score *
          BigInt.from((won ? 1 : -1) * (paired ? people.length - 1 : 1));
      person.points += delta;
      if (won) person.wins++;
      if (matchComplete) person.autoplay = false;
      rows.add({
        'seat': person.id,
        'name': person.name,
        'cards': person.cards.map((card) => card.id).toList(),
        'delta': _scoreValue(delta),
        'total': _scoreValue(person.points),
      });
    }
    result = owner == null
        ? '${first.name}获胜'
        : '${landlordWon ? '地主' : '农民'}获胜 · $multiplier 倍${spring == null ? '' : ' · $spring'}';
    settlement = {
      'base': base,
      'bombs': bombCount,
      'multiplier': multiplier,
      'spring': spring,
      'players': rows,
    };
    event('finish', result!);
  }

  void abort(String reason) {
    phase = _Phase.lobby;
    turn = landlord = leader = bidder = extraSeat = null;
    topBid = 0;
    multiplier = 1;
    last = null;
    _tablePlays.clear();
    _previousTrick = null;
    result = null;
    winners = [];
    bottom = [];
    wild = {};
    _playedCards.clear();
    _coachingHistory.clear();
    _hints.clear();
    settlement = null;
    for (final person in people) {
      person.cards = [];
      person.lastMove = null;
      person.autoplay = false;
      person.called = null;
    }
    turnVersion++;
    event('abort', reason);
  }

  void _rememberMove(_Person person, String move) {
    if (_botLog.length == 12) _botLog.removeAt(0);
    _botLog.add('座位 ${person.id} $move');
  }

  BotTurn _botTurn(_Person bot) => BotTurn(
    room: code,
    deal: deal,
    bidding: phase == _Phase.bidding,
    rules: rules,
    hand: [...bot.cards],
    wild: {...publicWild},
    previous: last,
    leader: leader,
    topBid: topBid,
    seat: bot.id,
    landlord: landlord,
    bottom: [if (landlord != null) ...bottom],
    players: [
      for (final person in people)
        BotSeat(id: person.id, cards: person.cards.length),
    ],
    log: [..._botLog],
    playedBySeat: {
      for (final entry in _playedCards.entries)
        entry.key: entry.value.map((card) => card.rank).toList(),
    },
  );

  bool _applyAdvice(_Person bot, BotAdvice advice, Random random) {
    if (phase == _Phase.bidding) {
      final bid = advice.bid;
      if (bid == null || !rules.bidsAfter(topBid).contains(bid)) return false;
      _bid(bot, bid, random);
      return true;
    }
    if (phase != _Phase.playing) return false;
    if (advice.pass) {
      if (last == null) return false;
      _pass(bot);
      return true;
    }
    final play = advice.play;
    if (play == null) return false;
    final ids = play.cards.map((card) => card.id).toSet();
    final chosen = bot.cards.where((card) => ids.contains(card.id)).toList();
    if (chosen.length != ids.length || ids.length != play.cards.length) {
      return false;
    }
    final legal = legalCardPlays(
      chosen,
      wild,
      last,
      rules: rules,
    ).where((item) => item.key == play.key).firstOrNull;
    if (legal == null) return false;
    _play(bot, legal);
    return true;
  }

  void _noteApi(String text) {
    apiFailed = true;
    event('botFallback', '$text，本局改用本地电脑');
  }

  void _localBot(_Person bot, Random random) {
    if (phase == _Phase.bidding) {
      final knownWild = publicWild;
      final strong = bot.cards
          .where((card) => card.rank >= 15 || knownWild.contains(card.rank))
          .length;
      final call = strong >= 4
          ? 3
          : strong >= 2
          ? 2
          : 1;
      final value = rules.landlordCall == LandlordCall.call
          ? (strong >= 2 ? 1 : 0)
          : call;
      _bid(bot, value > topBid ? value : 0, random);
    } else if (phase == _Phase.playing) {
      final suggestion = suggestCards(bot.cards, wild, last, rules: rules);
      if (suggestion == null) {
        _pass(bot);
      } else {
        _play(bot, suggestion);
      }
    }
  }
}
