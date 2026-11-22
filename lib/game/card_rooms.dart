import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/identity.dart';
import '../domain/ledger.dart';
import 'cards.dart';

const _alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
final roomCodePattern = RegExp(r'^[2-9A-HJ-NP-Z]{7}$');
typedef RoomJson = Map<String, dynamic>;
typedef CardSeat = ({String room, String token});

class CardRooms extends ChangeNotifier {
  CardRooms({Random? random, this.botDelay = const Duration(milliseconds: 650)})
    : _random = random ?? Random.secure();

  final Random _random;
  final Duration botDelay;
  final _rooms = <String, _CardRoom>{};
  final _bots = <String, Timer>{};

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
        _bots.remove(room.code)?.cancel();
        _rooms.remove(room.code);
        notifyListeners();
      } else {
        room.people.sort((a, b) => (a.bot ? 1 : 0).compareTo(b.bot ? 1 : 0));
        room.event('leave', '${player.name}离开了房间');
        _changed(room);
      }
      return {'left': true};
    }
    room.act(player, action, data, _random);
    _changed(room);
    return room.view(player);
  }

  void _changed(_CardRoom room) {
    room.version++;
    room.updated = DateTime.now();
    notifyListeners();
    if (room.current?.bot != true || _bots.containsKey(room.code)) return;
    _bots[room.code] = Timer(botDelay, () {
      _bots.remove(room.code);
      final bot = room.current;
      if (_rooms[room.code] != room || bot == null || !bot.bot) return;
      room.runBot(bot, _random);
      _changed(room);
    });
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
      _bots.remove(code)?.cancel();
      return true;
    });
  }

  String _code() => List.generate(
    7,
    (_) => _alphabet[_random.nextInt(_alphabet.length)],
  ).join();

  @override
  void dispose() {
    for (final timer in _bots.values) {
      timer.cancel();
    }
    _bots.clear();
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
  int points = 0;
  int wins = 0;
  int moves = 0;
  CardMove? lastMove;

  RoomJson publicView() => {
    'id': id,
    'name': name,
    'cards': cards.length,
    'bot': bot,
    'points': points,
    'wins': wins,
    'move': lastMove?.name,
  };
}

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
  CardPlay? last;
  ({int leader, CardPlay play})? _previousTrick;
  String? result;

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
    'wild': [
      if (phase != _Phase.bidding)
        ...wild
      else if (rules.mode == CardMode.doubleWild)
        wild.first,
    ],
    'extra': extraSeat,
    'last': last?.toJson(),
    if (_previousTrick case (leader: final actor, play: final played))
      'previousTrick': {'leader': actor, 'play': played.toJson()},
    'winners': winners,
    'multiplier': multiplier,
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
        _deal(random);
      case 'abort':
        requireHost(person);
        abort('房主结束了当前牌局');
      case 'bid':
        _requireTurn(person, input, _Phase.bidding);
        final value = input['bid'];
        if (value is! int ||
            value < 0 ||
            value > 3 ||
            (value > 0 && value <= topBid)) {
          throw const InputException('请选择弃叫或更高的分数');
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
        input['turnVersion'] != turnVersion) {
      throw const InputException('回合已变化，请刷新后再试');
    }
  }

  void _deal(Random random, {bool repeat = false}) {
    final deal = dealCards(rules, random);
    for (final (i, person) in people.indexed) {
      person.cards = deal.hands[i];
      person.moves = 0;
      person.lastMove = null;
    }
    bottom = deal.bottom;
    extraSeat = deal.extraSeat == null ? null : people[deal.extraSeat!].id;
    final ranks = List.generate(13, (index) => index + 3)..shuffle(random);
    wild = ranks.take(rules.mode.index).toSet();
    turn = people[random.nextInt(people.length)].id;
    phase = rules.landlord ? _Phase.bidding : _Phase.playing;
    topBid = bids = passes = 0;
    multiplier = 1;
    landlord = bidder = leader = null;
    last = null;
    _previousTrick = null;
    result = null;
    winners = [];
    turnVersion++;
    event('deal', repeat ? '无人叫分，重新发牌' : '发牌完成');
  }

  int _next(_Person person) =>
      people[(people.indexOf(person) + 1) % people.length].id;

  void _bid(_Person person, int value, Random random) {
    bids++;
    turnVersion++;
    if (value > topBid) {
      topBid = value;
      bidder = person.id;
    }
    event(
      'bid',
      value == 0 ? '${person.name}不叫' : '${person.name}叫 $value 分',
      from: person.id,
    );
    if (value == 3 || bids == people.length) {
      if (bidder == null) {
        _deal(random, repeat: true);
        return;
      }
      landlord = turn = bidder;
      final owner = people.firstWhere((entry) => entry.id == landlord);
      owner.cards.addAll(bottom);
      owner.cards.sort(PlayingCard.compare);
      phase = _Phase.playing;
      event('landlord', '${owner.name}成为地主', from: owner.id);
      return;
    }
    turn = _next(person);
  }

  void _pass(_Person person) {
    final played = last;
    if (played == null) throw const InputException('领出时必须出牌');
    turn = _next(person);
    passes++;
    person.lastMove = CardMove.pass;
    if (passes == people.length - 1) {
      // Keep the cards visible while the winner of the trick prepares to lead.
      _previousTrick = (leader: leader!, play: played);
      last = null;
      leader = null;
      passes = 0;
    }
    turnVersion++;
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
    final options = legalCardPlays(cards, wild, last, rules: rules);
    if (options.isEmpty) {
      throw InputException(
        disabledCardPlayMessage(cards, wild, rules) ?? '所选牌型不合法，或压不过上家的牌',
      );
    }
    return options;
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
    _previousTrick = null;
    turnVersion++;
    if (play.bomb) multiplier *= 2;
    event(
      play.kind == PlayKind.rocket
          ? 'rocket'
          : play.bomb
          ? 'bomb'
          : 'play',
      '${person.name}打出${play.label}',
      from: person.id,
    );
    if (person.cards.isEmpty) {
      _finish(person);
    } else {
      turn = _next(person);
    }
  }

  void _finish(_Person first) {
    phase = _Phase.finished;
    turn = null;
    if (landlord == null) {
      winners = [first.id];
      first.wins++;
      result = '${first.name}获胜';
    } else {
      final owner = people.firstWhere((entry) => entry.id == landlord);
      final landlordWon = first == owner;
      final spring = landlordWon
          ? people.where((p) => p != owner).every((p) => p.moves == 0)
          : owner.moves == 1;
      if (spring) multiplier *= 2;
      final score = topBid * multiplier;
      for (final person in people) {
        final won = (person == owner) == landlordWon;
        if (won) person.wins++;
        person.points +=
            (won ? 1 : -1) * score * (person == owner ? people.length - 1 : 1);
      }
      winners = [
        for (final person in people)
          if ((person == owner) == landlordWon) person.id,
      ];
      result =
          '${landlordWon ? '地主' : '农民'}获胜 · $multiplier 倍${spring ? ' · 春天' : ''}';
    }
    event('finish', result!);
  }

  void abort(String reason) {
    phase = _Phase.lobby;
    turn = landlord = leader = bidder = extraSeat = null;
    topBid = 0;
    multiplier = 1;
    last = null;
    _previousTrick = null;
    result = null;
    winners = [];
    bottom = [];
    wild = {};
    for (final person in people) {
      person.cards = [];
      person.lastMove = null;
    }
    turnVersion++;
    event('abort', reason);
  }

  void runBot(_Person bot, Random random) {
    if (phase == _Phase.bidding) {
      final strong = bot.cards
          .where((card) => card.rank >= 15 || wild.contains(card.rank))
          .length;
      final call = strong >= 4
          ? 3
          : strong >= 2
          ? 2
          : 1;
      _bid(bot, call > topBid ? call : 0, random);
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
