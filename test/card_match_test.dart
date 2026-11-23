import 'dart:math';

import 'package:dormos/domain/ledger.dart';
import 'package:dormos/game/bot_profile.dart';
import 'package:dormos/game/card_rooms.dart';
import 'package:dormos/game/cards.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(rooms.state(winner)['multiplier'], 2);
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
    expect(settle['multiplier'], 4);
    final entries = (settle['players'] as List).cast<RoomJson>();
    expect(
      entries.map((player) => player['delta']),
      unorderedEquals([12, -12]),
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
      18,
      -18,
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
    expect(calls.last.history, ['单张：给座位 $firstId 的领出理由']);
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
