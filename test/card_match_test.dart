import 'dart:async';
import 'dart:math';

import 'package:dormos/domain/ledger.dart';
import 'package:dormos/game/bot_profile.dart';
import 'package:dormos/game/card_rooms.dart';
import 'package:dormos/game/cards.dart';
import 'package:flutter_test/flutter_test.dart';

void _debug(CardRooms rooms, CardSeat seat, String command) {
  final debug = rooms.state(seat)['debug'] as RoomJson?;
  act(rooms, seat, 'debug', {'command': command, 'deal': debug?['deal']});
}

CardSeat current(CardRooms rooms, List<CardSeat> seats) =>
    seats.firstWhere((seat) {
      final state = rooms.state(seat);
      return state['you'] == state['turn'];
    });

RoomJson act(
  CardRooms rooms,
  CardSeat seat,
  String action, [
  RoomJson data = const {},
]) => rooms.action(seat, action, {
  'turnVersion': rooms.state(seat)['turnVersion'],
  ...data,
});

List<PlayingCard> hand(CardRooms rooms, CardSeat seat) =>
    (rooms.state(seat)['hand'] as List)
        .cast<int>()
        .map(PlayingCard.new)
        .toList();

int unseen(RoomJson state) => (state['counter'] as List).fold(
  0,
  (int total, item) => total + (item['count'] as int),
);

void main() {
  test('API bots reply once per human message and reset chat context on a new round', () async {
    final requests = <BotTurn>[];
    final answers = <Completer<String?>>[];
    final rooms = CardRooms(
      advisor: (_) async => const BotAdvice.off(),
      chat: (turn) {
        requests.add(turn);
        final answer = Completer<String?>();
        answers.add(answer);
        return answer.future;
      },
    );
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 6, landlord: false, bottom: 0),
    );
    final guest = rooms.join(host.room);
    final nextSpeaker = rooms.join(host.room);
    rooms.action(host, 'bot', {'mode': 'api'});
    rooms.action(host, 'bot', {'mode': 'local'});
    rooms.action(host, 'bot', {'mode': 'api'});
    final apiSeats = (rooms.state(host)['people'] as List)
        .where((player) => player['bot'] == true && player['botMode'] == 'api')
        .map((player) => player['id'])
        .toList();

    rooms.action(host, 'chat', {'text': '大家好'});
    rooms.action(guest, 'chat', {'text': '下一局再来'});
    final hostId = rooms.state(host)['you'] as int;
    final guestId = rooms.state(guest)['you'] as int;
    expect(requests.single.publicChat, [
      (seat: hostId, ai: false, text: '大家好'),
    ]);
    answers.first.complete(' 好呀\n ');
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(2));
    expect(requests.last.publicChat, [
      (seat: hostId, ai: false, text: '大家好'),
      (seat: guestId, ai: false, text: '下一局再来'),
    ]);
    answers.last.complete('没问题');
    await Future<void>.delayed(Duration.zero);

    final events = (rooms.state(guest)['events'] as List)
        .where((event) => event['kind'] == 'chat')
        .toList();
    expect(events.map((event) => event['text']), ['大家好', '下一局再来', '好呀', '没问题']);
    expect(events.skip(2).map((event) => event['from']), apiSeats);
    expect(events[2]['replyTo'], events[0]['id']);
    expect(events[3]['replyTo'], events[1]['id']);
    expect(requests, hasLength(2));

    rooms.action(host, 'start', {});
    rooms.action(nextSpeaker, 'chat', {'text': '新一局'});
    expect(requests.last.publicChat.single.text, '新一局');
    expect(requests.last.hand, hasLength(9));
    expect(requests.last.playedBySeat, isEmpty);
    answers.last.complete(null);
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'host can enable a public-only AI assistant and retry failed replies',
    () async {
      final requests = <BotTurn>[];
      final replies = <Completer<String?>>[];
      final rooms = CardRooms(
        chat: (turn) {
          requests.add(turn);
          final reply = Completer<String?>();
          replies.add(reply);
          return reply.future;
        },
      );
      addTearDown(rooms.dispose);
      final host = rooms.create(
        CardRules(players: 3, landlord: false, bottom: 0),
      );
      final guest = rooms.join(host.room);
      final reader = rooms.join(host.room);
      rooms.action(host, 'start', {});
      expect(
        () => rooms.action(guest, 'chatAi', {'enabled': true}),
        throwsA(isA<InputException>()),
      );
      final enabled = rooms.action(host, 'chatAi', {'enabled': true});
      expect(enabled['chat']['enabled'], isTrue);
      final sent = rooms.action(guest, 'chat', {'text': '打个招呼'});
      final source = sent['chat']['messages'].last['id'];
      expect(sent['chat']['status'], {'pending': true, 'source': source});
      expect(requests.single.seat, 0);
      expect(requests.single.hand, isEmpty);
      expect(requests.single.players.map((player) => player.cards), [
        18,
        18,
        18,
      ]);
      replies.last.completeError(const BotChatFailure('AI 回复超时'));
      await Future<void>.delayed(Duration.zero);
      expect(rooms.state(guest)['chat']['status']['error'], 'AI 回复超时');
      expect(
        () => rooms.action(reader, 'retryChatAi', {'source': source}),
        throwsA(isA<InputException>()),
      );
      rooms.action(guest, 'retryChatAi', {'source': source});
      replies.last.complete('你好！');
      await Future<void>.delayed(Duration.zero);
      final chat = rooms.state(reader)['chat'] as RoomJson;
      expect(chat['status'], isNull);
      expect(chat['messages'], hasLength(2));
      expect(chat['messages'].last, containsPair('sender', 'AI 助手'));
      expect(chat['messages'].last, containsPair('replyTo', source));
      expect(
        () => rooms.action(guest, 'retryChatAi', {'source': source}),
        throwsA(isA<InputException>()),
      );

      rooms.action(reader, 'chat', {'text': '再问一句'});
      rooms.action(host, 'chatAi', {'enabled': false});
      replies.last.complete('迟到的回复');
      await Future<void>.delayed(Duration.zero);
      final disabled = rooms.state(host)['chat'] as RoomJson;
      expect(disabled['enabled'], isFalse);
      expect(disabled['status'], isNull);
      expect(disabled['messages'], hasLength(3));
    },
  );

  test('chat history survives system events that fill the activity log', () {
    final rooms = CardRooms();
    addTearDown(rooms.dispose);
    final host = rooms.create(CardRules());
    rooms.action(host, 'chat', {'text': '聊天单独保留'});
    for (var i = 0; i < 26; i++) {
      final guest = rooms.join(host.room);
      rooms.action(guest, 'leave', {});
    }
    final view = rooms.state(host);
    expect(
      (view['events'] as List).any((event) => event['kind'] == 'chat'),
      isFalse,
    );
    expect(view['chat']['messages'].single['text'], '聊天单独保留');
  });

  test('AI chat keeps queued replies and marks any excess messages', () async {
    final requests = <BotTurn>[];
    final answers = <Completer<String?>>[];
    final rooms = CardRooms(
      chat: (turn) {
        requests.add(turn);
        final answer = Completer<String?>();
        answers.add(answer);
        return answer.future;
      },
    );
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 6, landlord: false, bottom: 0),
    );
    rooms.action(host, 'chatAi', {'enabled': true});
    final senders = [host, for (var i = 0; i < 4; i++) rooms.join(host.room)];
    for (final (index, sender) in senders.indexed) {
      rooms.action(sender, 'chat', {'text': '消息 $index'});
    }
    final chat = rooms.state(host)['chat'] as RoomJson;
    expect(chat['queued'], 3);
    expect(chat['messages'].last['aiSkipped'], 'AI 回复队列已满');
    for (var i = 0; i < 4; i++) {
      expect(requests.last.publicChat.last.text, '消息 $i');
      answers.last.complete('收到 $i');
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, hasLength(4));
    expect(rooms.state(host)['chat']['queued'], 0);
    expect(rooms.state(host)['chat']['messages'], hasLength(9));
  });

  test('removing the API computer cancels a pending chat reply', () async {
    final answer = Completer<String?>();
    Future<void>? cancelled;
    final rooms = CardRooms(
      advisor: (_) async => const BotAdvice.off(),
      chat: (turn) {
        cancelled = turn.cancelled;
        return answer.future;
      },
    );
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 4, discard: 2, landlord: false, bottom: 0),
    );
    final guest = rooms.join(host.room);
    rooms.action(host, 'bot', {'mode': 'local'});
    rooms.action(guest, 'chat', {'text': '本地电脑不调用接口'});
    expect(cancelled, isNull);

    rooms.action(host, 'bot', {'mode': 'api'});
    rooms.action(host, 'chat', {'text': '这条会发起回复'});
    rooms.action(host, 'removeBot', {});
    await cancelled;
    answer.complete('迟到的回复');
    await Future<void>.delayed(Duration.zero);
    final events = rooms.state(host)['events'] as List;
    expect(events.where((event) => event['replyTo'] != null), isEmpty);
  });

  test(
    'Cheats selects private hands and shares compact rank parsing with add',
    () {
      final rooms = CardRooms(random: Random(18));
      addTearDown(rooms.dispose);
      final host = rooms.create(
        CardRules(players: 2, discard: 50, landlord: false, bottom: 0),
      );
      final guest = rooms.join(host.room, name: '对手');
      rooms.action(host, 'start', {});
      final guestId = rooms.state(guest)['you'];
      final hostId = rooms.state(host)['you'];
      final initial = hand(rooms, host).length;
      final deal = rooms.state(host)['debug']['deal'];
      _debug(rooms, host, '/add B 33334444');
      final addedHome = hand(
        rooms,
        host,
      ).where((card) => card.id >= 54).map((card) => card.rank).toList();
      expect(hand(rooms, host), hasLength(initial + 8));
      expect(addedHome, [3, 3, 3, 3, 4, 4, 4, 4]);
      expect(
        () => act(rooms, host, 'debugGui', {'op': 'select', 'seat': guestId}),
        throwsA(isA<InputException>()),
      );
      expect(
        () => _debug(rooms, guest, '/gui on'),
        throwsA(isA<InputException>()),
      );
      _debug(rooms, host, '/gui on');
      expect(rooms.state(host)['debug']['gui'], isTrue);
      act(rooms, host, 'debugGui', {'op': 'select', 'seat': guestId});
      final editor = rooms.state(host)['debug']['editor'];
      expect(editor['seat'], guestId);
      expect(editor['cards'], hasLength(2));
      expect(rooms.state(guest).containsKey('debug'), isFalse);
      expect(
        () => act(rooms, host, 'debugGui', {
          'op': 'add',
          'seat': hostId,
          'deal': deal,
          'cards': 'BR',
        }),
        throwsA(isA<InputException>()),
      );
      act(rooms, host, 'debugGui', {
        'op': 'add',
        'seat': guestId,
        'deal': deal,
        'cards': '45245234',
      });
      final added = hand(rooms, guest).where((card) => card.id >= 54).toList();
      expect(added.map((card) => card.rank), [3, 4, 4, 4, 5, 5, 15, 15]);
      final previous = rooms.state(host)['turnVersion'] as int;
      expect(
        () => act(rooms, host, 'debugRemove', {
          'seat': guestId,
          'cards': [added.first.id, -1],
          'deal': deal,
        }),
        throwsA(isA<InputException>()),
      );
      expect(rooms.state(host)['debug']['editor']['cards'], hasLength(10));
      expect(rooms.state(host)['turnVersion'], previous);
      final removed = [added.first.id, added.last.id];
      act(rooms, host, 'debugRemove', {
        'seat': guestId,
        'cards': [...removed, removed.first],
        'deal': deal,
      });
      final remaining = rooms.state(host)['debug']['editor']['cards'] as List;
      expect(remaining, hasLength(8));
      expect(remaining.toSet().intersection(removed.toSet()), isEmpty);
      expect(rooms.state(host)['turnVersion'], previous + 1);
      act(rooms, host, 'debugGui', {
        'op': 'inspect',
        'seat': guestId,
        'enabled': true,
      });
      expect(rooms.state(host)['debug']['hands']['$guestId'], hasLength(8));
      act(rooms, host, 'debugGui', {'op': 'select', 'seat': hostId});
      act(rooms, host, 'debugGui', {
        'op': 'force',
        'seat': hostId,
        'enabled': true,
      });
      _debug(rooms, host, '/gui off');
      final closed = rooms.state(host)['debug'];
      expect(closed['gui'], isFalse);
      expect(closed.containsKey('editor'), isFalse);
      expect(closed['forceOut'], isTrue);
      expect(rooms.state(guest).containsKey('debug'), isFalse);
    },
  );

  test('large bomb multipliers stay exact through round settlement', () {
    final rooms = CardRooms(random: Random(18));
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 2, decks: 4, discard: 212, landlord: false, bottom: 0),
    );
    final guest = rooms.join(host.room);
    rooms.action(host, 'start', {});
    _debug(rooms, host, '/add B R');
    final initialGuest = rooms.state(guest);
    if (initialGuest['turn'] == initialGuest['you']) {
      act(rooms, guest, 'play', {
        'cards': [hand(rooms, guest).first.id],
      });
    }
    final chain = [
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '10',
    ].map((rank) => List.filled(14, rank).join()).join();
    _debug(rooms, host, '/giveout B $chain');
    final expected = (BigInt.one << 55).toString();
    expect(rooms.state(host)['last']['bombMultiplier'], expected);
    expect(rooms.state(host)['multiplier'], expected);
    act(rooms, guest, 'pass');
    _debug(rooms, host, '/invsee B on');
    final state = rooms.state(host);
    final seat = state['you'];
    final deal = state['debug']['deal'];
    final remaining = hand(rooms, host);
    for (final card in remaining.skip(1)) {
      act(rooms, host, 'debugRemove', {
        'seat': seat,
        'card': card.id,
        'deal': deal,
      });
    }
    act(rooms, host, 'play', {
      'cards': [remaining.first.id],
    });
    final finalState = rooms.state(host);
    expect(finalState['phase'], 'finished');
    expect(finalState['settlement']['multiplier'], expected);
    expect(finalState['settlement']['players'][0]['delta'], expected);
    expect(finalState['settlement']['players'][1]['delta'], '-$expected');
  });

  test('debug uses visible seats and only discloses hands to the host', () {
    final rooms = CardRooms(random: Random(18));
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 3, discard: 48, landlord: false, bottom: 0),
    );
    final right = rooms.join(host.room, name: '右');
    final left = rooms.join(host.room, name: '左');
    rooms.action(host, 'start', {});
    final initial = rooms.state(host);
    final leftId = rooms.state(left)['you'];
    expect(initial['debug']['seats'], {
      'A': leftId,
      'B': initial['you'],
      'C': rooms.state(right)['you'],
    });
    expect(
      () => _debug(rooms, left, '/invsee B on'),
      throwsA(isA<InputException>()),
    );
    _debug(rooms, host, '/give A black_joker 1');
    final given = hand(rooms, left).singleWhere((card) => card.id >= 54);
    expect(given.rank, 16);
    expect(hand(rooms, left), hasLength(3));
    _debug(rooms, host, '/invsee A on');
    final after = rooms.state(host);
    expect(after['debug']['hands']['$leftId'], contains(given.id));
    expect(rooms.state(left).containsKey('debug'), isFalse);
    expect(rooms.state(right).containsKey('debug'), isFalse);
    act(rooms, host, 'debugRemove', {
      'seat': leftId,
      'card': given.id,
      'deal': after['debug']['deal'],
    });
    expect(hand(rooms, left).map((card) => card.id), isNot(contains(given.id)));
    _debug(rooms, host, '/invsee A off');
    expect(rooms.state(host)['debug']['hands'], isEmpty);
    expect(rooms.state(left)['events'], initial['events']);
    expect(rooms.state(right)['events'], initial['events']);
  });

  test(
    'forceout and giveout validate shape and allow other players to respond',
    () {
      final rooms = CardRooms(random: Random(18));
      addTearDown(rooms.dispose);
      final host = rooms.create(
        CardRules(
          players: 2,
          decks: 4,
          discard: 212,
          landlord: false,
          bottom: 0,
        ),
      );
      final guest = rooms.join(host.room);
      rooms.action(host, 'start', {});
      _debug(rooms, host, '/give A red_joker 2');
      _debug(rooms, host, '/give B 3 2');
      _debug(rooms, host, '/give B 7 1');
      if (rooms.state(host)['turn'] == rooms.state(host)['you']) {
        _debug(rooms, host, '/giveout B 3');
      }
      final jokers = hand(
        rooms,
        guest,
      ).where((card) => card.id >= 216).toList();
      act(rooms, guest, 'play', {
        'cards': [jokers.first.id],
      });
      int low() => hand(rooms, host).firstWhere((card) => card.rank == 3).id;
      expect(
        () => act(rooms, host, 'play', {
          'cards': [low()],
        }),
        throwsA(isA<InputException>()),
      );
      _debug(rooms, host, '/forceout B on');
      final firstHand = rooms.state(host)['hand'] as List;
      expect(
        () => _debug(rooms, host, '/giveout B 347'),
        throwsA(isA<InputException>()),
      );
      expect(rooms.state(host)['hand'], firstHand);
      act(rooms, host, 'play', {
        'cards': [low()],
      });
      expect(rooms.state(guest)['last']['high'], 3);
      expect(rooms.state(guest).containsKey('debug'), isFalse);
      act(rooms, guest, 'play', {
        'cards': [jokers.last.id],
      });

      _debug(rooms, host, '/forceout B off');
      _debug(rooms, host, '/giveout B 33334444');
      var next = rooms.state(guest);
      expect(
        CardPlay.fromJson(next['last'] as RoomJson).kind,
        PlayKind.chainBomb,
      );
      expect(next['phase'], 'playing');
      act(rooms, guest, 'pass');
      _debug(rooms, host, '/giveout B BR');
      next = rooms.state(guest);
      expect(CardPlay.fromJson(next['last'] as RoomJson).kind, PlayKind.rocket);
    },
  );

  test('three redeals force the first caller to become landlord without counting as matches', () {
    final rules = CardRules(
      players: 2,
      discard: 51,
      bottom: 1,
      matchRounds: 3,
      landlordCall: LandlordCall.call,
      cardCounter: true,
    );
    expect(CardRules.fromJson(rules.toJson()).toJson(), rules.toJson());
    final rooms = CardRooms(random: Random(16));
    addTearDown(rooms.dispose);
    final host = rooms.create(rules);
    final seats = [host, rooms.join(host.room)];
    rooms.action(host, 'start', {});
    expect(
      () => act(rooms, current(rooms, seats), 'bid', {'bid': 2}),
      throwsA(isA<InputException>()),
    );
    for (var i = 0; i < 6; i++) {
      expect(rooms.state(host)['phase'], 'bidding');
      act(rooms, current(rooms, seats), 'bid', {'bid': 0});
    }
    final state = rooms.state(host);
    expect(state['phase'], 'playing');
    expect(state['redeals'], 3);
    expect(state['landlord'], state['firstCaller']);
    expect(state['turn'], state['landlord']);
    expect(state['bid'], 1);
    expect(state['round'], 1);
    expect(
      (state['events'] as List).where((event) => event['kind'] == 'deal'),
      hasLength(4),
    );
    expect((state['counter'] as List), hasLength(15));
    expect(state.containsKey('settlement'), isFalse);
  });

  test('bomb, spring and match scoring are zero-sum and reveal the remaining hands only at settlement', () {
    final rules = CardRules(
      players: 2,
      discard: 44,
      bottom: 0,
      matchRounds: 2,
      firstCaller: FirstCaller.previousWinner,
      cardCounter: true,
    );
    CardRooms? match;
    List<CardSeat>? seats;
    CardSeat? owner;
    CardPlay? openingBomb;
    for (var seed = 0; seed < 1000 && match == null; seed++) {
      final room = CardRooms(random: Random(seed));
      final host = room.create(rules);
      final roster = [host, room.join(host.room)];
      room.action(host, 'start', {});
      for (final seat in roster) {
        final bomb = hintPlays(
          hand(room, seat),
          {},
          null,
          rules: rules,
        ).where((hint) => hint.bomb).firstOrNull;
        if (bomb == null) continue;
        match = room;
        seats = roster;
        owner = seat;
        openingBomb = bomb;
        break;
      }
      if (match == null) room.dispose();
    }
    expect(
      match,
      isNotNull,
      reason: 'The seeded search must find a small hand with a bomb',
    );
    final rooms = match!;
    addTearDown(rooms.dispose);
    final roster = seats!;
    final winner = owner!;
    final host = roster.first;
    final loser = roster.firstWhere((seat) => seat != winner);
    final winnerId = rooms.state(winner)['you'];
    if (current(rooms, roster) != winner) act(rooms, loser, 'bid', {'bid': 0});
    act(rooms, winner, 'bid', {'bid': 3});
    final before = rooms.state(loser);
    expect(unseen(before), 49);
    expect(before.containsKey('settlement'), isFalse);

    final bomb = openingBomb!;
    act(rooms, winner, 'play', {
      'cards': bomb.cards.map((card) => card.id).toList(),
      'pattern': bomb.key,
    });
    expect(unseen(rooms.state(loser)), 49 - bomb.cards.length);
    final bombFactor = bomb.bombMultiplier.toInt();
    expect(rooms.state(winner)['multiplier'], bombFactor);
    act(rooms, loser, 'pass');
    void playSingles() {
      while (rooms.state(winner)['phase'] == 'playing') {
        act(rooms, winner, 'play', {
          'cards': [hand(rooms, winner).first.id],
        });
        if (rooms.state(winner)['phase'] == 'playing') {
          act(rooms, loser, 'pass');
        }
      }
    }

    playSingles();
    final round = rooms.state(loser);
    final settle = round['settlement'] as RoomJson;
    expect(settle['base'], 3);
    expect(settle['bombs'], 1);
    expect(settle['spring'], '春天');
    expect(settle['multiplier'], bombFactor * 2);
    final firstScore = 3 * bombFactor * 2;
    final entries = (settle['players'] as List).cast<RoomJson>();
    expect(
      entries.map((player) => player['delta']),
      unorderedEquals([firstScore, -firstScore]),
    );
    expect(
      entries.singleWhere((player) => player['seat'] == round['you'])['cards'],
      hasLength(5),
    );
    expect(round['matchComplete'], false);

    rooms.action(host, 'start', {});
    expect(rooms.state(host)['firstCaller'], winnerId);
    expect(rooms.state(host)['round'], 2);
    expect(rooms.state(host).containsKey('settlement'), false);
    act(rooms, winner, 'bid', {'bid': 3});
    playSingles();
    final finalView = rooms.state(host);
    expect(finalView['matchComplete'], true);
    expect((finalView['standings'] as List).map((entry) => entry['points']), [
      firstScore + 6,
      -firstScore - 6,
    ]);
    rooms.action(host, 'start', {});
    expect(rooms.state(host)['round'], 1);
    expect(
      (rooms.state(host)['standings'] as List).map((entry) => entry['points']),
      [0, 0],
    );
  });

  testWidgets(
    'a human can cancel scheduled autoplay and other seats see its status',
    (tester) async {
      final rooms = CardRooms(
        random: Random(14),
        botDelay: const Duration(milliseconds: 40),
      );
      addTearDown(rooms.dispose);
      final host = rooms.create(
        CardRules(players: 2, discard: 52, landlord: false, bottom: 0),
      );
      final seats = [host, rooms.join(host.room)];
      rooms.action(host, 'start', {});
      final own = current(rooms, seats);
      final other = seats.firstWhere((seat) => seat != own);
      final seatId = rooms.state(own)['you'];
      act(rooms, own, 'autoplay', {'enabled': true});
      expect(
        (rooms.state(other)['people'] as List).singleWhere(
          (seat) => seat['id'] == seatId,
        )['autoplay'],
        true,
      );
      expect(
        () => act(rooms, own, 'play', {
          'cards': [hand(rooms, own).first.id],
        }),
        throwsA(isA<InputException>()),
      );
      act(rooms, own, 'autoplay', {'enabled': false});
      await tester.pump(const Duration(milliseconds: 41));
      expect(rooms.state(own)['phase'], 'playing');
      expect(rooms.state(own)['turn'], seatId);
      act(rooms, own, 'autoplay', {'enabled': true});
      await tester.pump(const Duration(milliseconds: 41));
      expect(rooms.state(other)['phase'], 'finished');
      expect(rooms.state(other)['winners'], [seatId]);
    },
  );

  test('AI explanations and history stay private to a seat and are cleared on the next deal', () async {
    final calls = <({BotTurn turn, List<String> history})>[];
    final rooms = CardRooms(
      random: Random(12),
      coach: (turn, history) async {
        calls.add((turn: turn, history: history));
        if (turn.previous != null) {
          return BotAdvice.pass('给座位 ${turn.seat} 的过牌理由');
        }
        return BotAdvice.play(
          cardPlays([turn.hand.first], {}, rules: turn.rules).single,
          '给座位 ${turn.seat} 的领出理由',
        );
      },
    );
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 2, discard: 50, landlord: false, bottom: 0),
    );
    final seats = [host, rooms.join(host.room)];
    rooms.action(host, 'start', {});
    final first = current(rooms, seats);
    final other = seats.firstWhere((seat) => seat != first);
    final firstId = rooms.state(first)['you'];
    Future<void> ask(CardSeat seat) async {
      final state = act(rooms, seat, 'aiHint');
      expect(state['aiHint']['pending'], true);
      await Future<void>.delayed(Duration.zero);
      expect(rooms.state(seat)['aiHint']['pending'], false);
    }

    await ask(first);
    expect(rooms.state(other).containsKey('aiHint'), false);
    expect(rooms.state(first)['aiHint']['reason'], '给座位 $firstId 的领出理由');
    expect(calls.single.history, isEmpty);
    await ask(first);
    expect(calls.last.history, isEmpty);
    expect(calls.last.turn.hintRequest, isNot(calls.first.turn.hintRequest));
    final firstCard = hand(rooms, first).first;
    act(rooms, first, 'play', {
      'cards': [firstCard.id],
    });
    await ask(other);
    expect(calls.last.history, isEmpty);
    expect(calls.last.turn.playedBySeat, {
      firstId: [firstCard.rank],
    });
    expect(rooms.state(first).containsKey('aiHint'), false);
    act(rooms, other, 'pass');
    act(rooms, first, 'play', {
      'cards': [hand(rooms, first).first.id],
    });
    rooms.action(host, 'start', {});
    await ask(current(rooms, seats));
    expect(calls.last.history, isEmpty);
    expect(calls.last.turn.playedBySeat, isEmpty);
    expect(calls.last.turn.deal, greaterThan(calls.first.turn.deal));
  });

  test('regenerating while pending drops the stale reply', () async {
    final requests = <BotTurn>[];
    final answers = <Completer<BotAdvice>>[];
    final rooms = CardRooms(
      random: Random(12),
      coach: (turn, _) {
        requests.add(turn);
        final answer = Completer<BotAdvice>();
        answers.add(answer);
        return answer.future;
      },
    );
    addTearDown(rooms.dispose);
    final host = rooms.create(
      CardRules(players: 2, landlord: false, bottom: 0),
    );
    final seats = [host, rooms.join(host.room)];
    rooms.action(host, 'start', {});
    final seat = current(rooms, seats);
    final first = act(rooms, seat, 'aiHint')['aiHint'];
    final second = act(rooms, seat, 'aiHint')['aiHint'];
    expect(requests, hasLength(2));
    expect(second['id'], isNot(first['id']));
    await requests.first.cancelled;
    final turn = requests.last;
    final play = cardPlays(
      [turn.hand.first],
      turn.wild,
      rules: turn.rules,
    ).single;
    answers.last.complete(BotAdvice.play(play, '新理由'));
    await Future<void>.delayed(Duration.zero);
    answers.first.complete(BotAdvice.play(play, '旧理由'));
    await Future<void>.delayed(Duration.zero);
    expect(rooms.state(seat)['aiHint']['reason'], '新理由');
  });

  testWidgets('host can end an API wait without counting it as a timeout', (
    tester,
  ) async {
    const delay = Duration(milliseconds: 10);
    final answer = Completer<BotAdvice>();
    var cancelled = false;
    final rooms = CardRooms(
      random: Random(11),
      botDelay: delay,
      advisor: (turn) {
        turn.onProgress?.call(BotProgress.waiting);
        unawaited(turn.cancelled!.then((_) => cancelled = true));
        return answer.future;
      },
    );
    addTearDown(rooms.dispose);
    final seat = rooms.create(
      CardRules(players: 2, landlord: false, bottom: 0),
    );
    rooms.action(seat, 'bot', {'mode': 'api'});
    var state = rooms.action(seat, 'start', {});
    if (state['turn'] == state['you']) {
      state = act(rooms, seat, 'play', {
        'cards': [hand(rooms, seat).first.id],
      });
    }
    await tester.pump(delay);
    state = rooms.state(seat);
    final before = state['turnVersion'];
    expect(state['botProgress']['stage'], 'waiting');
    act(rooms, seat, 'skipBotWait');
    await tester.pump(const Duration(milliseconds: 1));
    expect(cancelled, isTrue);
    expect(rooms.state(seat)['turnVersion'], isNot(before));
    answer.complete(const BotAdvice.failed('旧回复', timedOut: true));
    await tester.pump();
    expect(rooms.state(seat)['botThinking'], isFalse);
    expect(rooms.state(seat)['apiTimeouts'], 0);
  });

  testWidgets(
    'local vs API modes for bot seats and autoplay are strictly separated',
    (tester) async {
      var apiOn = false;
      var advisorCalls = 0;
      final rooms = CardRooms(
        random: Random(11),
        botDelay: const Duration(milliseconds: 10),
        apiEnabled: () => apiOn,
        advisor: (turn) async {
          advisorCalls++;
          if (turn.bidding) return const BotAdvice.bid(0);
          return const BotAdvice.pass();
        },
      );
      addTearDown(rooms.dispose);
      final rules = CardRules(
        players: 2,
        discard: 50,
        landlord: false,
        bottom: 0,
      );
      final host = rooms.create(rules);

      // 未启用 API 时，不能添加 API 电脑或开启 API 托管，但本地电脑与本地托管可用。
      expect(
        () => rooms.action(host, 'bot', {'mode': 'api'}),
        throwsA(isA<InputException>()),
      );
      final withLocalBot = rooms.action(host, 'bot', {'mode': 'local'});
      final botSeat = (withLocalBot['people'] as List).last as RoomJson;
      expect(botSeat['name'], '本地电脑 2');
      expect(botSeat['botMode'], 'local');
      expect(withLocalBot['apiAvailable'], isFalse);

      rooms.action(host, 'start', {});
      expect(
        () => act(rooms, host, 'autoplay', {'enabled': true, 'mode': 'api'}),
        throwsA(isA<InputException>()),
      );
      await tester.pump(const Duration(milliseconds: 15));
      expect(advisorCalls, 0);

      // 启用 API 后，可以添加 API 电脑和开启 API 托管，本地电脑仍不走 API。
      apiOn = true;
      rooms.syncCapabilities();
      expect(rooms.state(host)['apiAvailable'], isTrue);
      act(rooms, host, 'autoplay', {'enabled': true, 'mode': 'api'});
      expect((rooms.state(host)['people'] as List).first['botMode'], 'api');
      await tester.pump(const Duration(milliseconds: 15));
      await tester.pump(const Duration(milliseconds: 15));
      expect(advisorCalls, greaterThanOrEqualTo(1));

      // 在新房间中验证 API 电脑可明确添加并标记为 api。
      final apiRoom = rooms.create(rules);
      final addedApiBot = rooms.action(apiRoom, 'bot', {'mode': 'api'});
      final apiSeat = (addedApiBot['people'] as List).last as RoomJson;
      expect(apiSeat['name'], 'API 电脑 2');
      expect(apiSeat['botMode'], 'api');
    },
  );
}
