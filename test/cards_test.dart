import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dormos/data/github_transport.dart';
import 'package:dormos/data/lan_server.dart';
import 'package:dormos/data/ssh_vault.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/preferences.dart';
import 'package:dormos/game/card_network.dart';
import 'package:dormos/game/bot_profile.dart';
import 'package:dormos/game/card_mailbox.dart';
import 'package:dormos/game/card_rooms.dart';
import 'package:dormos/game/card_session.dart';
import 'package:dormos/game/cards.dart';
import 'package:dormos/game/online_cards.dart';
import 'package:dormos/ui/card_table.dart';
import 'package:dormos/ui/common.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as git;
import 'package:material_ui/material_ui.dart';

PlayingCard dealt(int rank, [int copy = 0]) {
  if (rank >= 16) return PlayingCard(copy * 54 + 52 + rank - 16);
  return PlayingCard(copy ~/ 4 * 54 + (rank - 3) * 4 + copy % 4);
}

List<PlayingCard> cards(List<int> ranks) {
  final count = <int, int>{};
  return [
    for (final rank in ranks)
      dealt(rank, count.update(rank, (value) => value + 1, ifAbsent: () => 0)),
  ];
}

void main() {
  final invalid = throwsA(isA<InputException>());

  test('连炸需要开关，比较组数、硬软和点数，提示也遵守规则', () {
    final on = CardRules(chainBombs: true);
    final off = CardRules(chainBombs: false);
    CardPlay chain(List<int> ranks, [Set<int> wild = const {}]) => cardPlays(
      cards(ranks),
      wild,
      rules: on,
    ).singleWhere((play) => play.kind == PlayKind.chainBomb);
    final ranks = [3, 3, 3, 3, 4, 4, 4, 4];
    final low = chain(ranks);
    final high = chain([4, 4, 4, 4, 5, 5, 5, 5]);
    final soft = chain([5, 5, 5, 5, 6, 6, 6, 8], {8});
    final three = chain([...ranks, 5, 5, 5, 5]);
    final bomb = cardPlays(cards(List.filled(8, 15)), {}).single;
    final rocket = cardPlays(cards([16, 17]), {}).single;
    expect(low.label, '2 连炸');
    expect(low.beats(bomb), isTrue);
    expect(bomb.beats(low), isFalse);
    expect(high.beats(low), isTrue);
    expect(low.beats(soft), isTrue);
    expect(three.beats(high), isTrue);
    expect(three.beats(rocket), isTrue);
    expect(high.beats(CardPlay.fromJson(low.toJson())), isTrue);
    expect(cardPlays(cards(ranks), {}, rules: off), isEmpty);
    expect(
      cardPlays(cards([14, 14, 14, 14, 15, 15, 15, 15]), {}, rules: on),
      isEmpty,
    );
    final hand = cards([...ranks, 9]);
    expect(hintPlays(hand, {}, bomb, rules: on).first.kind, PlayKind.chainBomb);
    expect(hintPlays(hand, {}, bomb, rules: off), isEmpty);
    expect(suggestCards(hand, {}, bomb, rules: on)?.kind, PlayKind.chainBomb);
  });

  test('thick chain bombs rank by groups, thickness, strength and rank', () {
    final rules = CardRules(decks: 2);
    final off = CardRules(decks: 2, chainBombs: false);
    final rocketFirst = CardRules(decks: 2, rocketBeatsChain: true);
    CardPlay chain(List<int> ranks, [Set<int> wild = const {}]) => cardPlays(
      cards(ranks),
      wild,
      rules: rules,
    ).singleWhere((play) => play.kind == PlayKind.chainBomb);
    final fiveByTwo = [...List.filled(5, 5), ...List.filled(5, 6)];
    final thick = chain(fiveByTwo);
    final higherThanThin = chain(
      [...List.filled(5, 5), ...List.filled(4, 6), 8],
      {8},
    );
    final thin = chain([...List.filled(4, 9), ...List.filled(4, 10)]);
    final long = chain([
      ...List.filled(4, 7),
      ...List.filled(4, 8),
      ...List.filled(4, 9),
    ]);
    final doubleRocket = cardPlays(cards([16, 16, 17, 17]), {}).single;
    final royal = cardPlays(cards([16, 17]), {}).single;
    expect(thick.label, '5 张 2 连炸');
    expect(higherThanThin.beats(thin, rules: rules), isTrue);
    expect(thick.beats(higherThanThin, rules: rules), isTrue);
    expect(long.beats(thick, rules: rules), isTrue);
    expect(doubleRocket.beats(royal, rules: rules), isTrue);
    expect(thick.beats(doubleRocket, rules: rules), isTrue);
    expect(thick.beats(doubleRocket, rules: rocketFirst), isFalse);
    expect(CardPlay.fromJson(thick.toJson()).chainCopies, 5);
    expect(
      hintPlays(
        cards([...fiveByTwo, 9]),
        {},
        thin,
        rules: rules,
      ).map((play) => play.key),
      contains(thick.key),
    );
    expect(
      hintPlays(cards([...fiveByTwo, 9]), {}, thick, rules: rules),
      isEmpty,
    );
    expect(unplayableReason(cards(fiveByTwo), {}, thin, off), '本房间未开启连炸');
    expect(unplayableReason(cards(fiveByTwo), {}, long, rules), '压不过上家的牌');
    for (final ranks in [
      [...List.filled(4, 5), ...List.filled(5, 6)],
      [...List.filled(5, 5), ...List.filled(5, 7)],
      [...List.filled(5, 14), ...List.filled(5, 15)],
    ]) {
      expect(
        cardPlays(
          cards(ranks),
          {},
          rules: rules,
        ).where((play) => play.kind == PlayKind.chainBomb),
        isEmpty,
      );
    }
  });

  test('four-with-two disabled feedback covers singles and pairs', () {
    final rules = CardRules(fourWithTwo: false);
    for (final ranks in [
      [5, 5, 5, 5, 8, 9],
      [5, 5, 5, 5, 8, 8, 9, 9],
    ]) {
      expect(unplayableReason(cards(ranks), {}, null, rules), '本房间未开启四带二');
    }
    expect(unplayableReason(cards([5, 5, 6]), {}, null, rules), '这组牌无法打出');
  });

  test('offline bot leads a long ordinary play before isolated singles', () {
    final suggestion = suggestCards(
      cards([3, 4, 5, 6, 7, 9, 9, 9, 9]),
      {},
      null,
    );
    expect(suggestion?.kind, PlayKind.straight);
    expect(suggestion?.cards, hasLength(5));
  });

  for (final chainEnabled in [true, false]) {
    testWidgets(
      chainEnabled ? '两副牌新房间中四个 10 加四个 J 可以实际压过四个 7' : '关闭连炸时，同一组牌给出明确的房间规则提示',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final session = CardSession(
          () => null,
          rooms: CardRooms(random: Random(15)),
        );
        addTearDown(session.dispose);
        final defaults = CardRules(
          players: 2,
          decks: 2,
          landlord: false,
          bottom: 0,
        );
        expect(defaults.chainBombs, isTrue);
        final rules = chainEnabled
            ? defaults
            : CardRules.fromJson({...defaults.toJson(), 'chainBombs': false});
        await session.create(rules, '房主', CardLocation.local);
        final other = session.rooms.join(
          session.view!['room'] as String,
          name: '对手',
        );
        await session.act('start');
        final first = session.rooms.state(other);
        expect(first['turn'], first['you']);
        List<int> four(RoomJson snapshot, int rank) =>
            (snapshot['hand'] as List)
                .cast<int>()
                .where((id) => PlayingCard(id).rank == rank)
                .take(4)
                .toList();
        final sevens = four(first, 7);
        expect(sevens, hasLength(4));
        session.rooms.action(other, 'play', {
          'cards': sevens,
          'turnVersion': first['turnVersion'],
        });
        final before = session.view!;
        final tens = four(before, 10);
        final jacks = four(before, 11);
        expect(tens, hasLength(4));
        expect(jacks, hasLength(4));
        final chain = [...tens, ...jacks];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: session,
                builder: (_, _) => CardTable(
                  session: session,
                  view: session.view!,
                  share: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final id in chain) {
          final rect = tester.getRect(find.byKey(ValueKey(id)));
          await tester.tapAt(Offset(rect.left + 3, rect.top + 6));
          await tester.pumpAndSettle();
        }
        final play = find.widgetWithText(FilledButton, '出牌');
        if (chainEnabled) {
          expect(tester.widget<FilledButton>(play).onPressed, isNotNull);
          await tester.tap(play);
          await tester.pumpAndSettle();
          final last = session.view!['last'] as RoomJson;
          expect(last['label'], '2 连炸');
          expect(CardPlay.fromJson(last).kind, PlayKind.chainBomb);
          expect(
            (last['cards'] as List)
                .cast<RoomJson>()
                .map((card) => card['id'])
                .toSet(),
            chain.toSet(),
          );
        } else {
          expect(tester.widget<FilledButton>(play).onPressed, isNull);
          expect(find.text('本房间未开启连炸'), findsOneWidget);
          await session.act('play', {'cards': chain});
          expect(session.error, '本房间未开启连炸');
          expect((session.view!['last'] as RoomJson)['label'], '4 张硬炸');
        }
      },
    );
  }

  test('带牌只比较主牌，牌型或长度不同时无法互压', () {
    final rules = CardRules(decks: 2);
    CardPlay shape(List<int> ranks, PlayKind kind) => cardPlays(
      cards(ranks),
      {},
      rules: rules,
    ).singleWhere((play) => play.kind == kind);
    final low = shape([3, 3, 3, 4, 4, 4, 14, 15], PlayKind.planeSingles);
    final high = shape([4, 4, 4, 5, 5, 5, 6, 7], PlayKind.planeSingles);
    final sameBody = shape([4, 4, 4, 5, 5, 5, 14, 15], PlayKind.planeSingles);
    final pairs = shape([4, 4, 4, 5, 5, 5, 6, 6, 7, 7], PlayKind.planePairs);
    final longer = shape([
      3,
      3,
      3,
      4,
      4,
      4,
      5,
      5,
      5,
      6,
      7,
      8,
    ], PlayKind.planeSingles);
    expect(high.beats(low, rules: rules), isTrue);
    expect(sameBody.compareStrengthTo(high, rules: rules), 0);
    expect(sameBody.beats(high, rules: rules), isFalse);
    expect(pairs.compareStrengthTo(low, rules: rules), isNull);
    expect(longer.compareStrengthTo(low, rules: rules), isNull);
    expect(unplayableReason(pairs.cards, {}, low, rules), '需跟相同牌型和长度，或使用炸弹');
  });

  test('同一组癞子牌的不同合法出法进入提示，可按声明点数比较', () {
    final rules = CardRules(mode: CardMode.doubleWild);
    final selected = cards([6, 9]);
    final wild = {6, 9};
    final earlier = cardPlays(cards([7, 7]), {}, rules: rules).single;
    final classified = inspectCardSelection(selected, wild, earlier, rules);
    final hints = hintPlays(selected, wild, earlier, rules: rules);
    expect(classified.options.map((play) => play.high), [
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
    ]);
    expect(
      hints.map((play) => play.key),
      classified.options.map((play) => play.key),
    );
    expect(hints.last.beats(hints.first, rules: rules), isTrue);
  });

  test('癞子按本身点数出连炸属于硬炸，提示能压同级软连炸', () {
    final rules = CardRules(decks: 2, mode: CardMode.wild);
    final wild = {8};
    final earlier = cardPlays(
      cards([10, 10, 10, 10, 11, 11, 11, 8]),
      wild,
      rules: rules,
    ).singleWhere((play) => play.kind == PlayKind.chainBomb);
    final hand = cards([7, 7, 7, 7, 8, 8, 8, 8]);
    final allowed = legalCardPlays(hand, wild, earlier, rules: rules).single;
    expect(allowed.high, 8);
    expect(allowed.ranks, isEmpty);
    expect(allowed.strength, 1);
    expect(earlier.strength, 0);
    expect(
      hintPlays(hand, wild, earlier, rules: rules).map((play) => play.key),
      contains(allowed.key),
    );
  });

  test('四副牌 13 张硬炸能接 8 张连炸，提示和出牌判定一致', () {
    final rules = CardRules(players: 2, decks: 4, landlord: false, bottom: 0);
    final chain = cardPlays(
      cards([...List.filled(4, 9), ...List.filled(4, 10)]),
      {},
      rules: rules,
    ).single;
    final hardBomb = cards(List.filled(13, 8));
    final allowed = legalCardPlays(hardBomb, {}, chain, rules: rules).single;
    expect(allowed.kind, PlayKind.bomb);
    expect(
      hintPlays(
        [...hardBomb, dealt(7)],
        {},
        chain,
        rules: rules,
      ).map((play) => play.key),
      contains(allowed.key),
    );
    expect(chain.beats(allowed, rules: rules), isFalse);

    final thin = cardPlays(
      cards([...List.filled(4, 3), ...List.filled(4, 4), ...List.filled(4, 5)]),
      {},
      rules: rules,
    ).single;
    final thick = cards([...List.filled(7, 6), ...List.filled(7, 7)]);
    expect(legalCardPlays(thick, {}, thin, rules: rules).single.chainCopies, 7);
    expect(
      hintPlays(thick, {}, thin, rules: rules).any(
        (play) =>
            play.kind == PlayKind.chainBomb &&
            play.width == 2 &&
            play.chainCopies == 7,
      ),
      isTrue,
    );
  });

  test('炸弹按等级翻倍，王对数越多倍率越大', () {
    final rules = CardRules(players: 2, decks: 4, landlord: false, bottom: 0);
    CardPlay bomb(List<int> ranks) => cardPlays(
      cards(ranks),
      {},
      rules: rules,
    ).singleWhere((play) => play.bomb);
    expect(bomb(List.filled(4, 8)).bombMultiplier, BigInt.two);
    expect(bomb(List.filled(6, 8)).bombMultiplier, BigInt.from(4));
    expect(bomb([3, 3, 3, 3, 4, 4, 4, 4]).bombMultiplier, BigInt.from(8));
    expect(bomb(List.filled(13, 8)).bombMultiplier, BigInt.from(32));
    expect(bomb([16, 17]).bombMultiplier, BigInt.from(8));
    expect(bomb([16, 16, 17, 17]).bombMultiplier, BigInt.from(16));
  });

  test('炸弹大小遵守房间开关，双王炸大于王炸', () {
    final chainFirst = CardRules();
    final royalFirst = CardRules(rocketBeatsChain: true);
    expect(chainFirst.toJson()['rocketBeatsChain'], isFalse);
    final old = royalFirst.toJson()..remove('rocketBeatsChain');
    expect(CardRules.fromJson(old).rocketBeatsChain, isTrue);
    expect(CardRules.fromJson(old, newRoom: true).rocketBeatsChain, isFalse);
    expect(
      CardRules.fromJson(royalFirst.toJson(), newRoom: true).rocketBeatsChain,
      isTrue,
    );
    final chainCards = cards([3, 3, 3, 3, 4, 4, 4, 4]);
    final chain = cardPlays(chainCards, {}, rules: royalFirst).single;
    final bomb = cardPlays(cards(List.filled(8, 15)), {}).single;
    final rocket = cardPlays(cards([16, 17]), {}).single;
    final doubleRocket = cardPlays(cards([16, 16, 17, 17]), {}).single;
    final tripleRocket = cardPlays(cards([16, 16, 16, 17, 17, 17]), {}).single;

    expect(rocket.label, '王炸');
    expect(doubleRocket.label, '双王炸');
    expect(tripleRocket.label, '3 组王炸');
    for (final rules in [royalFirst, chainFirst]) {
      expect(chain.beats(bomb, rules: rules), isTrue);
      expect(bomb.beats(chain, rules: rules), isFalse);
      expect(doubleRocket.beats(rocket, rules: rules), isTrue);
      expect(tripleRocket.beats(doubleRocket, rules: rules), isTrue);
      expect(rocket.beats(doubleRocket, rules: rules), isFalse);
    }
    expect(rocket.beats(chain, rules: royalFirst), isTrue);
    expect(chain.beats(tripleRocket, rules: royalFirst), isFalse);
    expect(chain.beats(tripleRocket, rules: chainFirst), isTrue);
    expect(doubleRocket.beats(chain, rules: chainFirst), isFalse);
    expect(legalCardPlays(chainCards, {}, rocket, rules: royalFirst), isEmpty);
    expect(
      legalCardPlays(chainCards, {}, rocket, rules: chainFirst).single.kind,
      PlayKind.chainBomb,
    );
    expect(
      hintPlays(
        [...chainCards, dealt(7)],
        {},
        doubleRocket,
        rules: chainFirst,
      ).single.kind,
      PlayKind.chainBomb,
    );
    expect(
      suggestCards(
        [...chainCards, dealt(7)],
        {},
        rocket,
        rules: chainFirst,
      )?.kind,
      PlayKind.chainBomb,
    );

    final hand = [...chainCards, ...doubleRocket.cards];
    expect(
      hintPlays(hand, {}, bomb, rules: royalFirst).map((hint) => hint.label),
      ['2 连炸', '王炸', '双王炸'],
    );
    expect(
      hintPlays(hand, {}, bomb, rules: chainFirst).map((hint) => hint.label),
      ['王炸', '双王炸', '2 连炸'],
    );
  });

  testWidgets('保留其他座位的出牌，轮到对手时清空面前的旧牌', (tester) async {
    final (session, guests) = await _openGame(
      tester,
      size: const Size(740, 360),
    );
    CardSeat currentGuest() => guests.firstWhere(
      (guest) => session.rooms.state(guest)['you'] == session.view!['turn'],
    );
    void playGuest(CardSeat guest, int id) {
      session.rooms.action(guest, 'play', {
        'cards': [id],
        'turnVersion': session.view!['turnVersion'],
      });
    }

    int firstHigher(CardSeat guest, int rank) =>
        (session.rooms.state(guest)['hand'] as List).cast<int>().firstWhere(
          (id) => PlayingCard(id).rank > rank,
        );
    RoomJson publicSeat(CardSeat guest) {
      final id = session.rooms.state(guest)['you'];
      return (session.view!['people'] as List).cast<RoomJson>().firstWhere(
        (player) => player['id'] == id,
      );
    }

    final first = PlayingCard((session.view!['hand'] as List).first as int);
    await session.act('play', {
      'cards': [first.id],
    });
    await tester.pumpAndSettle();
    final own = find.byKey(const ValueKey('my-played-cards'));
    final ownRect = tester.getRect(own);
    expect(find.text('我的出牌'), findsOneWidget);

    final right = currentGuest();
    final higher = firstHigher(right, first.rank);
    playGuest(right, higher);
    await tester.pumpAndSettle();
    final side = find.byKey(ValueKey('played-by-${publicSeat(right)['id']}'));
    expect(tester.getRect(side).center.dx, greaterThan(ownRect.center.dx + 60));
    expect(own, findsNothing);
    expect(publicSeat(right)['move'], 'beat');
    expect(find.text('管上'), findsAtLeastNWidgets(1));
    final last = session.view!['last'];

    final left = currentGuest();
    session.rooms.action(left, 'pass', {
      'turnVersion': session.view!['turnVersion'],
    });
    await tester.pumpAndSettle();
    expect(publicSeat(left)['move'], 'pass');
    expect(find.text('不要'), findsOneWidget);
    expect(side, findsOneWidget);

    await session.act('pass');
    await tester.pumpAndSettle();
    expect(session.view!['last'], isNull);
    expect(session.view!['turn'], publicSeat(right)['id']);
    expect(session.view!['previousTrick'], {
      'leader': publicSeat(right)['id'],
      'play': last,
    });
    expect(find.text('不要'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 5));
    expect(side, findsNothing);
    expect(find.text('上轮'), findsNothing);
    expect(find.text('管上'), findsNothing);
    final lead = (session.rooms.state(right)['hand'] as List).first as int;
    playGuest(right, lead);
    await tester.pumpAndSettle();
    expect(session.view!['previousTrick'], isNull);
    expect(
      find.descendant(of: side, matching: find.byKey(ValueKey(lead))),
      findsOneWidget,
    );
    expect(find.text('上轮'), findsNothing);
    expect(find.text('不要'), findsNothing);
    final leftHigher = firstHigher(left, PlayingCard(lead).rank);
    playGuest(left, leftHigher);
    await tester.pumpAndSettle();
    final leftSide = find.byKey(
      ValueKey('played-by-${publicSeat(left)['id']}'),
    );
    expect(
      tester.getRect(leftSide).center.dx,
      lessThan(ownRect.center.dx - 60),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('出牌前显示牌型，宽桌保留各座位出牌，矮窗口聚焦当前牌', (tester) async {
    final (session, guests) = await _openGame(
      tester,
      size: const Size(1280, 760),
    );
    final hand = (session.view!['hand'] as List)
        .cast<int>()
        .map(PlayingCard.new)
        .toList();
    final first = hand.first;
    final different = hand.firstWhere((card) => card.rank != first.rank);
    final play = find.widgetWithText(FilledButton, '出牌');
    Future<void> select(PlayingCard card) async {
      final rect = tester.getRect(find.byKey(ValueKey(card.id)));
      await tester.tapAt(rect.topLeft + const Offset(10, 14));
      await tester.pumpAndSettle();
    }

    await select(first);
    expect(find.text('单张 · 1 张'), findsOneWidget);
    expect(tester.widget<FilledButton>(play).onPressed, isNotNull);
    await select(different);
    expect(find.text('这组牌无法打出'), findsOneWidget);
    expect(tester.widget<FilledButton>(play).onPressed, isNull);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await select(first);
    await tester.tap(play);
    await tester.pumpAndSettle();
    final guest = guests.firstWhere(
      (guest) => session.rooms.state(guest)['you'] == session.view!['turn'],
    );
    final guestView = session.rooms.state(guest);
    final higher = (guestView['hand'] as List).cast<int>().firstWhere(
      (id) => PlayingCard(id).rank > first.rank,
    );
    session.rooms.action(guest, 'play', {
      'cards': [higher],
      'turnVersion': guestView['turnVersion'],
    });
    await tester.pumpAndSettle();
    final mine = find.byKey(const ValueKey('my-played-cards'));
    final theirs = find.byKey(ValueKey('played-by-${guestView['you']}'));
    expect(
      tester.getRect(mine).top,
      greaterThan(tester.getRect(theirs).bottom),
    );
    expect(
      (session.view!['tablePlays'] as List).map((play) => play['seat']),
      unorderedEquals([session.view!['you'], guestView['you']]),
    );
    await tester.binding.setSurfaceSize(const Size(640, 320));
    await tester.pumpAndSettle();
    expect(mine, findsNothing);
    expect(theirs, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生牌桌支持叫地主、AI 建议与赛后余牌和总分', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rooms = CardRooms(
      random: Random(8),
      coach: (turn, _) async => BotAdvice.play(
        cardPlays(turn.hand, {}, rules: turn.rules).single,
        '这一手可以出完手牌。',
      ),
    );
    final session = CardSession(() => null, rooms: rooms);
    addTearDown(session.dispose);
    await session.create(
      CardRules(
        players: 2,
        bottom: 0,
        discard: 52,
        matchRounds: 1,
        landlordCall: LandlordCall.call,
        cardCounter: true,
      ),
      '甲',
      CardLocation.local,
    );
    final opponent = rooms.join(session.view!['room'] as String, name: '乙');
    await session.act('start');
    if (session.view!['turn'] != session.view!['you']) {
      rooms.action(opponent, 'bid', {
        'bid': 0,
        'turnVersion': session.view!['turnVersion'],
      });
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (context, _) =>
                CardTable(session: session, view: session.view!, share: () {}),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('card-counter')), findsOneWidget);
    expect(find.text('3 分'), findsNothing);
    await tester.tap(find.text('叫地主'));
    await tester.pumpAndSettle();
    expect(find.text('地主'), findsOneWidget);
    await tester.tap(find.text('AI 提示'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('这一手可以出完手牌。'));
    await tester.pumpAndSettle();
    expect(find.text('AI 出牌建议'), findsOneWidget);
    expect(find.textContaining('建议动作　出牌 · 单张'), findsOneWidget);
    expect(find.textContaining('出牌牌面　'), findsOneWidget);
    expect(find.textContaining('判断理由　这一手可以出完手牌。'), findsOneWidget);
    await tester.tap(find.text('选中建议的牌'));
    await tester.pumpAndSettle();
    expect(find.text('单张 · 1 张'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '出牌'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('你率先出完', findRichText: true), findsOneWidget);
    expect(find.text('我的出牌'), findsOneWidget);
    expect(find.text('全场结算'), findsNothing);
    expect(find.text('开始新比赛'), findsNothing);
    await tester.pump(const Duration(milliseconds: 850));
    await tester.pumpAndSettle();
    expect(find.text('全场结算'), findsOneWidget);
    expect(find.text('地主'), findsOneWidget);
    expect(find.text('总分 +2'), findsOneWidget);
    expect(find.text('总分 -2'), findsOneWidget);
    expect(find.text('开始新比赛'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对手地主出牌后仍有身份标识，最后一手保留后再结算', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rooms = CardRooms(random: Random(8));
    final session = CardSession(() => null, rooms: rooms);
    addTearDown(session.dispose);
    await session.create(
      CardRules(
        players: 2,
        bottom: 0,
        discard: 52,
        landlordCall: LandlordCall.call,
      ),
      '房主',
      CardLocation.local,
    );
    final other = rooms.join(session.view!['room'] as String, name: '乙');
    await session.act('start');
    if (session.view!['turn'] == session.view!['you']) {
      await session.act('bid', {'bid': 0});
    }
    var opponent = rooms.state(other);
    rooms.action(other, 'bid', {
      'bid': 1,
      'turnVersion': opponent['turnVersion'],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (_, _) =>
                CardTable(session: session, view: session.view!, share: () {}),
          ),
        ),
      ),
    );
    expect(find.text('地主'), findsOneWidget);
    opponent = rooms.state(other);
    rooms.action(other, 'play', {
      'cards': opponent['hand'],
      'turnVersion': opponent['turnVersion'],
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('地主'), findsOneWidget);
    expect(find.text('乙 出牌'), findsOneWidget);
    expect(find.text('乙率先出完', findRichText: true), findsOneWidget);
    expect(find.text('第 1 局结算'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('第 1 局结算'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('API 托管等待时可在牌桌上立即接管出牌', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final answer = Completer<BotAdvice>();
    var cancelled = false;
    const delay = Duration(milliseconds: 10);
    final rooms = CardRooms(
      random: Random(8),
      botDelay: delay,
      advisor: (turn) {
        unawaited(turn.cancelled!.then((_) => cancelled = true));
        turn.onProgress?.call(BotProgress.waiting);
        return answer.future;
      },
    );
    final session = CardSession(() => null, rooms: rooms);
    addTearDown(session.dispose);
    await session.create(
      CardRules(players: 2, landlord: false, bottom: 0),
      '甲',
      CardLocation.local,
    );
    final other = rooms.join(session.view!['room'] as String, name: '乙');
    await session.act('start');
    if (session.view!['turn'] != session.view!['you']) {
      final state = rooms.state(other);
      rooms.action(other, 'play', {
        'turnVersion': state['turnVersion'],
        'cards': [(state['hand'] as List).first],
      });
    }
    await session.act('autoplay', {'enabled': true, 'mode': 'api'});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (_, _) =>
                CardTable(session: session, view: session.view!, share: () {}),
          ),
        ),
      ),
    );
    await tester.pump(delay);
    expect(find.textContaining('AI 代打思考中', findRichText: true), findsOneWidget);
    expect(find.textContaining('模型正在分析', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('剩余最多 45 秒', findRichText: true),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.textContaining('剩余最多 44 秒', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('本手用本地'), findsOneWidget);
    await tester.tap(find.text('接管出牌'));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(session.view!['turn'], session.view!['you']);
    expect(find.text('出牌'), findsOneWidget);
    answer.complete(const BotAdvice.failed('过期请求', timedOut: true));
    await tester.pump();
    expect(session.view!['apiTimeouts'], 0);
    expect(tester.takeException(), isNull);
  });

  test('房间规则兼容旧快照，一个开关控制两种四带二', () {
    final switches = CardRules(chainBombs: true, fourWithTwo: false);
    final decoded = CardRules.fromJson(switches.toJson());
    expect(decoded.chainBombs, isTrue);
    expect(decoded.fourWithTwo, isFalse);
    final old = switches.toJson()
      ..remove('chainBombs')
      ..remove('fourWithTwo');
    final legacy = CardRules.fromJson(old);
    expect(legacy.chainBombs, isFalse);
    expect(legacy.fourWithTwo, isTrue);
    final withSingles = cards([4, 4, 4, 4, 6, 6]);
    final withPairs = cards([4, 4, 4, 4, 6, 6, 7, 7]);
    expect(
      cardPlays(withSingles, {}, rules: legacy).single.kind,
      PlayKind.fourSingles,
    );
    expect(
      cardPlays(withPairs, {}, rules: legacy).single.kind,
      PlayKind.fourPairs,
    );
    expect(cardPlays(withSingles, {}, rules: decoded), isEmpty);
    expect(cardPlays(withPairs, {}, rules: decoded), isEmpty);
    expect(
      hintPlays(withPairs, {}, null, rules: decoded).map((hint) => hint.kind),
      isNot(
        anyOf(contains(PlayKind.fourSingles), contains(PlayKind.fourPairs)),
      ),
    );
  });

  testWidgets('窄横屏能完整显示标准手牌，多副牌最多两排', (tester) async {
    const screen = Size(640, 320);
    final (classic, _) = await _openGame(tester, size: screen);
    List<Rect> handRects(CardSession session) => [
      for (final id in (session.view!['hand'] as List).cast<int>())
        tester.getRect(find.byKey(ValueKey(id))),
    ];
    void verify(List<Rect> rects, int rows) {
      expect(rects.map((rect) => rect.top).toSet(), hasLength(rows));
      expect(
        rects.every(
          (rect) =>
              rect.left >= 0 &&
              rect.top >= 0 &&
              rect.right <= screen.width &&
              rect.bottom <= screen.height,
        ),
        isTrue,
      );
    }

    verify(handRects(classic), 1);
    final bottom = find.byKey(const ValueKey('bottom-card-preview'));
    expect(tester.getCenter(bottom).dx, closeTo(screen.width / 2, 1));
    expect(find.widgetWithText(FilledButton, '出牌'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final multi = CardSession(() => null, rooms: CardRooms(random: Random(4)));
    addTearDown(multi.dispose);
    await multi.create(
      CardRules(players: 2, decks: 3, landlord: false, bottom: 0),
      '房主',
      CardLocation.local,
    );
    multi.rooms.join(multi.view!['room'] as String);
    await multi.act('start');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardTable(session: multi, view: multi.view!, share: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final crowded = handRects(multi);
    expect(crowded, hasLength(81));
    verify(crowded, 2);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(2200, 1200));
    await tester.pumpAndSettle();
    final felt = tester.getRect(
      find.byKey(const ValueKey('dorm-card-table-frame')),
    );
    expect(felt.size, const Size(2200, 1200));
    expect(felt.center, const Offset(1100, 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('牌桌通知只计入别人发的聊天，打开后清除未读', (tester) async {
    final (session, guests) = await _openGame(tester);
    final room = session.rooms;
    final other = guests.first;
    final me = session.view!['you'];
    final guest = room.state(other);
    final sender = (guest['people'] as List).cast<RoomJson>().firstWhere(
      (player) => player['id'] == guest['you'],
    )['name'];
    room.action(other, 'tomato', {'target': me});
    await tester.pump();
    final button = find.byTooltip('牌桌消息');
    final unread = find.descendant(of: button, matching: find.text('1'));
    expect(unread, findsNothing);

    room.action(other, 'chat', {'text': '这局结束下楼吃饭'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(unread, findsOneWidget);
    expect(find.text('$sender · 这局结束下楼吃饭'), findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(unread, findsNothing);
    room.action(guests.last, 'chat', {'text': '我也一起去'});
    await tester.pumpAndSettle();
    expect(find.textContaining('我也一起去'), findsOneWidget);
    await tester.tap(find.text('系统'));
    await tester.pumpAndSettle();
    expect(find.textContaining('我也一起去'), findsNothing);
    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    expect(find.text('我也一起去'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(unread, findsNothing);
  });

  testWidgets('Cheats 从调试启用后可选座位、批量加牌和删牌', (tester) async {
    final (session, _) = await _openGame(tester);
    expect(find.text('Cheats'), findsNothing);
    await tester.tap(find.byTooltip('牌桌菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('调试'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/gui on');
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cheats'));
    await tester.pumpAndSettle();
    final seat = session.view!['debug']['seats']['A'] as int;
    await tester.tap(find.byKey(ValueKey(('cheats-seat', seat))));
    await tester.pumpAndSettle();
    final before = (session.view!['debug']['editor']['cards'] as List).length;
    final input = find.byKey(const ValueKey('cheats-ranks'));
    await tester.ensureVisible(input);
    await tester.enterText(input, '45245234');
    final add = find.text('添加牌');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final after = (session.view!['debug']['editor']['cards'] as List)
        .cast<int>();
    expect(after, hasLength(before + 8));
    final ids = after.take(2).toList();
    for (final id in ids) {
      final card = find.byKey(ValueKey(('cheats-card', id)));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      final semantics = find.descendant(
        of: card,
        matching: find.byType(Semantics),
      );
      expect(
        tester
            .widgetList<Semantics>(semantics)
            .any((item) => item.properties.selected == true),
        isTrue,
      );
    }
    final delete = find.text('删除 2 张牌');
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    final remaining = session.view!['debug']['editor']['cards'] as List;
    expect(remaining, hasLength(before + 6));
    expect(remaining.toSet().intersection(ids.toSet()), isEmpty);
    await tester.tap(find.text('隐藏 Cheats'));
    await tester.pumpAndSettle();
    expect(find.text('Cheats'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('房主可用菜单查看并删除指定手牌', (tester) async {
    final (session, _) = await _openGame(tester);
    await tester.tap(find.byTooltip('牌桌菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('调试'));
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller?.text, isEmpty);
    expect(input.decoration?.hintText, isNull);
    expect(find.byType(ActionChip), findsNothing);
    await tester.enterText(find.byType(TextField), '/invsee A on');
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
    expect(find.text('已执行'), findsOneWidget);
    final view = session.view!;
    final debug = view['debug'] as RoomJson;
    final seat = debug['seats']['A'];
    final name =
        (view['people'] as List).cast<RoomJson>().singleWhere(
              (p) => p['id'] == seat,
            )['name']
            as String;
    final initial = (debug['hands']['$seat'] as List).cast<int>();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
    expect(find.text('$name 的手牌'), findsOneWidget);
    expect(find.text('删除 1 张牌'), findsNothing);
    await tester.tap(
      find
          .byTooltip(PlayingCard.rankLabel(PlayingCard(initial.first).rank))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 1 张牌'));
    await tester.pumpAndSettle();
    expect(
      session.view!['debug']['hands']['$seat'],
      hasLength(initial.length - 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 牌桌用 F11、按钮和 Esc 切换全屏', (tester) async {
    const channel = MethodChannel('dorm/cards/window');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requests = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'fullscreen');
      final enabled = call.arguments as bool;
      requests.add(enabled);
      return enabled;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await _openGame(tester, platform: TargetPlatform.windows);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出全屏（F11）'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏（F11）'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(requests, [true, false, true, false]);
  });

  testWidgets('Windows 手牌紧叠且相邻两张可分别点击', (tester) async {
    final (session, _) = await _openGame(tester, size: const Size(1680, 960));
    final ids = (session.view!['hand'] as List).cast<int>();
    final rects = [
      for (final id in ids) tester.getRect(find.byKey(ValueKey(id))),
    ];
    expect(rects.map((rect) => rect.top).toSet(), hasLength(1));
    expect(rects.first.width, greaterThan(90));
    final step = rects[1].left - rects.first.left;
    expect(step, inInclusiveRange(34, 40));
    expect((rects.last.right + rects.first.left) / 2, closeTo(840, 1));

    final first = _handCard(PlayingCard(ids.first));
    final second = _handCard(PlayingCard(ids[1]));
    await tester.tapAt(rects.first.topLeft + const Offset(12, 25));
    await tester.pumpAndSettle();
    expect(_isSelected(tester, first), isTrue);
    expect(_isSelected(tester, second), isFalse);
    await tester.tapAt(rects[1].topLeft + const Offset(12, 25));
    await tester.pumpAndSettle();
    expect(_isSelected(tester, first), isTrue);
    expect(_isSelected(tester, second), isTrue);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  test('hints offer the smallest follow first and keep bombs for later', () {
    final hand = cards([3, 3, 4, 6, 6, 8, 16, 17]);
    final previous = CardPlay(PlayKind.single, 3, 1, 0, const [], const {});
    final follow = hintPlays(hand, const {}, previous);
    final lead = hintPlays(hand, const {}, null);
    expect(follow.first.kind, PlayKind.single);
    expect(follow.first.high, 4);
    expect(follow.last.bomb, isTrue);
    expect(lead.first.kind, PlayKind.single);
    expect(lead.first.high, 3);
    expect(
      follow.map((play) => play.cards.map((card) => card.id).join(',')).toSet(),
      hasLength(follow.length),
    );
  });

  test('hints find a matching four-with-two and bombs longer than a natural deck group', () {
    final ordinary = hintPlays(
      cards([6, 6, 6, 6, 7, 7, 7]),
      const {},
      CardPlay(PlayKind.fourSingles, 3, 1, 0, const [], const {}),
    );
    expect(ordinary.first.kind, PlayKind.fourSingles);
    expect(ordinary.first.high, 6);
    expect(ordinary.last.kind, PlayKind.bomb);

    final long = hintPlays(cards([...List.filled(16, 6), 9, 9, 7]), {
      9,
    }, CardPlay(PlayKind.bomb, 15, 17, 0, const [], const {}));
    expect(
      long.any((play) => play.kind == PlayKind.bomb && play.width == 18),
      isTrue,
    );
  });

  testWidgets('tapping a visibly raised overlapping card toggles that card', (
    tester,
  ) async {
    final (session, _) = await _openGame(tester);
    final hand = (session.view!['hand'] as List)
        .cast<int>()
        .map(PlayingCard.new)
        .toList();
    final first = _handCard(hand[0]);
    final second = _handCard(hand[1]);

    final firstRect = tester.getRect(first);
    await tester.tapAt(Offset(firstRect.left + 3, firstRect.center.dy));
    await tester.pumpAndSettle();
    expect(_isSelected(tester, first), isTrue);
    final raised = tester.getRect(first);
    final beside = tester.getRect(second);
    final overlap = Offset(beside.left + 2, raised.top + 5);
    expect(raised.contains(overlap), isTrue);
    expect(beside.contains(overlap), isFalse);
    await tester.tapAt(overlap);
    await tester.pumpAndSettle();

    expect(_isSelected(tester, first), isFalse);
    expect(_isSelected(tester, second), isFalse);

    await tester.tapAt(Offset(firstRect.left + 3, firstRect.center.dy));
    await tester.pumpAndSettle();
    final neighborRank = Offset(beside.left + 3, beside.top + 7);
    expect(tester.getRect(first).contains(neighborRank), isTrue);
    await tester.tapAt(neighborRank);
    await tester.pumpAndSettle();
    expect(_isSelected(tester, first), isTrue);
    expect(_isSelected(tester, second), isTrue);
  });

  testWidgets(
    'drag submits the exact pair and keeps a prepared card through other turns',
    (tester) async {
      final (session, guests) = await _openGame(tester);
      final before = (session.view!['hand'] as List)
          .cast<int>()
          .map(PlayingCard.new)
          .toList();
      final index = Iterable<int>.generate(before.length - 1)
          .firstWhere((i) => before[i].rank == before[i + 1].rank);
      final a = _handCard(before[index]);
      final b = _handCard(before[index + 1]);
      final left = tester.getRect(a);
      final right = tester.getRect(b);
      final drag = await tester.startGesture(
        Offset(left.left + 3, left.center.dy),
      );
      await drag.moveTo(Offset(right.left + 3, left.center.dy));
      await drag.up();
      await tester.pumpAndSettle();
      expect(_isSelected(tester, a), isTrue);
      expect(_isSelected(tester, b), isTrue);
      await tester.tap(find.widgetWithText(FilledButton, '出牌'));
      await tester.pumpAndSettle();

      final played = CardPlay.fromJson(session.view!['last'] as RoomJson);
      expect(played.kind, PlayKind.pair);
      final removed = {before[index].id, before[index + 1].id};
      expect(
        ((session.view!['last'] as RoomJson)['cards'] as List)
            .cast<RoomJson>()
            .map((card) => card['id'])
            .toSet(),
        removed,
      );
      expect(
        session.view!['hand'],
        before
            .map((card) => card.id)
            .where((id) => !removed.contains(id))
            .toList(),
      );

      final prepared = PlayingCard(
        (session.view!['hand'] as List).first as int,
      );
      final preparedFinder = _handCard(prepared);
      final preparedRect = tester.getRect(preparedFinder);
      await tester.tapAt(Offset(preparedRect.left + 2, preparedRect.center.dy));
      await tester.pumpAndSettle();
      expect(_isSelected(tester, preparedFinder), isTrue);
      await tester.tap(find.byTooltip('牌桌菜单'));
      await tester.pumpAndSettle();
      for (var i = 0; i < guests.length; i++) {
        final guest = guests.firstWhere(
          (seat) => session.rooms.state(seat)['you'] == session.view!['turn'],
        );
        session.rooms.action(guest, 'pass', {
          'turnVersion': session.view!['turnVersion'],
        });
      }
      await tester.pumpAndSettle();
      expect(session.view!['last'], isNull);
      await tester.tap(find.text('查看上一手'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('对子'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(_isSelected(tester, preparedFinder), isTrue);

      final priorTurn = (session.view!['turnVersion'] as int) - 1;
      await session.act('play', {
        'cards': [prepared.id],
        'turnVersion': priorTurn,
      });
      expect(session.error, '回合已变化，请刷新后再试');
      expect(session.view!['last'], isNull);
      expect(session.view!['hand'], contains(prepared.id));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '出牌'));
      await tester.pumpAndSettle();
      final next = (session.view!['last'] as RoomJson)['cards'] as List;
      expect((next.single as RoomJson)['id'], prepared.id);
    },
  );

  test('hint availability agrees with exhaustive judging of small hands', () {
    final random = Random(29);
    final earlier = [
      const CardPlay(PlayKind.single, 11, 1, 0, [], {}),
      const CardPlay(PlayKind.pair, 7, 1, 0, [], {}),
      const CardPlay(PlayKind.triplePair, 4, 1, 0, [], {}),
      const CardPlay(PlayKind.straight, 8, 5, 0, [], {}),
      const CardPlay(PlayKind.fourSingles, 4, 1, 0, [], {}),
      const CardPlay(PlayKind.planePairs, 6, 2, 0, [], {}),
      const CardPlay(PlayKind.bomb, 11, 4, 1, [], {}),
      const CardPlay(PlayKind.rocket, 17, 2, 0, [], {}),
    ];
    for (final wild in <Set<int>>[
      {},
      {7},
      {4, 9},
    ]) {
      for (var i = 0; i < 10; i++) {
        final hand = (List.generate(
          108,
          PlayingCard.new,
        )..shuffle(random)).take(9).toList();
        final all = [
          for (var mask = 1; mask < (1 << hand.length); mask++)
            ...cardPlays([
              for (var j = 0; j < hand.length; j++)
                if ((mask & (1 << j)) != 0) hand[j],
            ], wild),
        ];
        for (final last in earlier) {
          final expected = all.where((play) => play.beats(last)).toList();
          final hints = hintPlays(hand, wild, last);
          final trace =
              '${last.key}, wild $wild, hand ${hand.map((card) => card.id).toList()}';
          expect(hints.isNotEmpty, expected.isNotEmpty, reason: trace);
          if (expected.any((play) => play.kind == last.kind)) {
            expect(
              hints.any((play) => play.kind == last.kind),
              isTrue,
              reason: trace,
            );
          }
          for (final hint in hints) {
            expect(
              legalCardPlays(
                hint.cards,
                wild,
                last,
              ).any((play) => play.key == hint.key),
              isTrue,
              reason: trace,
            );
          }
        }
      }
    }
  });

  test('multiple decks, discard, bottom and concentrated remainder never duplicate cards', () {
    final split = dealCards(
      CardRules(players: 5, decks: 2, discard: 3, bottom: 5),
      Random(1),
    );
    expect(split.hands.map((hand) => hand.length), everyElement(20));
    expect(split.extraSeat, isNull);
    expect(split.bottom, hasLength(5));
    expect(split.discarded, hasLength(3));
    expect(
      [
        ...split.hands.expand((hand) => hand),
        ...split.discarded,
        ...split.bottom,
      ].map((card) => card.id).toSet(),
      hasLength(108),
    );
    final uneven = dealCards(
      CardRules(
        players: 5,
        decks: 2,
        landlord: false,
        bottom: 0,
        remainder: DealRemainder.extra,
      ),
      Random(4),
    );
    expect(uneven.hands[uneven.extraSeat!], hasLength(24));
    expect(uneven.hands.where((hand) => hand.length == 21), hasLength(4));
    expect(() => CardRules(players: 5, landlord: false, bottom: 0), invalid);
  });

  test('classic sequences, wings, multi-deck rockets and wild comparison', () {
    PlayKind? natural(List<int> values) =>
        cardPlays(cards(values), {}).firstOrNull?.kind;
    expect(natural([3, 4, 5, 6, 7]), PlayKind.straight);
    expect(natural([11, 12, 13, 14, 15]), isNull);
    expect(natural([3, 3, 4, 4, 5, 5]), PlayKind.pairs);
    expect(natural([3, 3, 3, 4, 4, 4, 5, 6]), PlayKind.planeSingles);
    expect(natural([3, 3, 3, 4, 4, 4, 5, 5, 6, 6]), PlayKind.planePairs);
    expect(natural([3, 3, 3, 3, 7, 7]), PlayKind.fourSingles);
    expect(natural([16, 17, 16, 17]), PlayKind.rocket);

    final wild = {6, 9};
    final options = cardPlays(cards([3, 4, 5, 6, 9]), wild);
    final straight = options.singleWhere(
      (play) => play.kind == PlayKind.straight && play.high == 7,
    );
    expect(straight.ranks.values, contains(7));
    final soft = cardPlays(
      cards([3, 3, 3, 6]),
      wild,
    ).firstWhere((play) => play.bomb);
    final hard = cardPlays(
      cards([4, 4, 4, 4]),
      wild,
    ).singleWhere((play) => play.bomb);
    expect(hard.beats(soft), isTrue);
    expect(cardPlays(cards([6, 17]), wild), isEmpty);
    final rocket = cardPlays(cards([16, 17]), wild).single;
    expect(rocket.beats(hard), isTrue);
  });

  test(
    'rooms enforce turn, hide opponents, keep bottom and reset after passes',
    () {
      final rooms = CardRooms(random: Random(3));
      addTearDown(rooms.dispose);
      final a = rooms.create(CardRules(players: 3));
      final b = rooms.join(a.room);
      final c = rooms.join(a.room);
      rooms.action(a, 'start', {});
      final seats = [a, b, c];
      CardSeat turn() => seats.singleWhere(
        (seat) => rooms.state(seat)['you'] == rooms.state(seat)['turn'],
      );
      final first = turn();
      final game = rooms.state(first);
      expect(game['phase'], 'bidding');
      expect(game['bottom'], isEmpty);
      expect(game['hand'], hasLength(17));
      expect(
        (game['people'] as List).every(
          (person) => !(person as Map).containsKey('hand'),
        ),
        isTrue,
      );
      expect(
        () => rooms.action(seats.firstWhere((seat) => seat != first), 'bid', {
          'bid': 3,
          'turnVersion': game['turnVersion'],
        }),
        invalid,
      );
      rooms.action(first, 'bid', {
        'bid': 3,
        'turnVersion': game['turnVersion'],
      });
      final opened = rooms.state(first);
      expect(opened['hand'], hasLength(20));
      expect(opened['bottom'], hasLength(3));
      expect(
        () =>
            rooms.action(first, 'pass', {'turnVersion': opened['turnVersion']}),
        invalid,
      );
      final id = (opened['hand'] as List).first;
      expect(
        rooms.options(first, {
          'cards': [id],
          'turnVersion': opened['turnVersion'],
        }),
        hasLength(1),
      );
      rooms.action(first, 'play', {
        'cards': [id],
        'turnVersion': opened['turnVersion'],
      });
      expect(
        () => rooms.action(first, 'play', {
          'cards': [id],
          'turnVersion': opened['turnVersion'],
        }),
        invalid,
      );
      for (var i = 0; i < 2; i++) {
        final next = turn();
        rooms.action(next, 'pass', {
          'turnVersion': rooms.state(next)['turnVersion'],
        });
      }
      expect(turn(), first);
      expect(rooms.state(first)['last'], isNull);
      rooms.action(a, 'tomato', {'target': rooms.state(b)['you']});
      expect((rooms.state(b)['events'] as List).last['kind'], 'tomato');
      expect(
        () => rooms.action(a, 'tomato', {'target': rooms.state(b)['you']}),
        invalid,
      );
      expect(rooms.state(b)['previousTrick'], isNotNull);
      rooms.action(a, 'abort', {});
      expect(rooms.state(b)['previousTrick'], isNull);
    },
  );

  testWidgets(
    'native table works without a browser, including computer seats',
    (tester) async {
      final session = CardSession(() => null);
      await session.create(CardRules(), '', CardLocation.local);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => CardTable(
                session: session,
                view: session.view!,
                share: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('添加电脑玩家'), findsOneWidget);
      await tester.tap(find.text('添加电脑玩家'));
      await tester.pumpAndSettle();
      expect(find.text('本地电脑'), findsOneWidget);
      expect(find.text('API 电脑'), findsOneWidget);
      await tester.tap(find.text('本地电脑'));
      await tester.pumpAndSettle();
      expect(find.text('本地电脑 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'CardTable distinguishes local/API autoplay and auto-selects AI play hints but not pass hints',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var advisePass = false;
      final rooms = CardRooms(
        random: Random(12),
        botDelay: const Duration(milliseconds: 50),
        apiEnabled: () => true,
        coach: (turn, _) async => advisePass
            ? const BotAdvice.pass('手牌暂无优势，建议不出')
            : BotAdvice.play(
                cardPlays([turn.hand.first], {}, rules: turn.rules).single,
                '先出单张试探',
              ),
      );
      final session = CardSession(() => null, rooms: rooms);
      await session.create(
        CardRules(players: 2, discard: 48, landlord: false, bottom: 0),
        '房主',
        CardLocation.local,
      );
      final hostId = session.view!['you'];
      await session.act('bot', {'mode': 'local'});
      await session.act('start');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => CardTable(
                session: session,
                view: session.view!,
                share: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.view!['turn'], hostId);

      // AI 提示建议出牌时，自动选中对应牌面。
      await tester.tap(find.text('AI 提示'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('AI 建议 · 出牌 · 单张 · 先出单张试探'), findsOneWidget);
      expect(find.text('清空'), findsOneWidget);

      // 打出选中的牌并等本地电脑走一步，随后测试建议「不出」时不自动选牌。
      await tester.tap(find.text('出牌'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('清空'), findsNothing);

      advisePass = true;
      await tester.tap(find.text('AI 提示'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('AI 建议 · 不出 · 手牌暂无优势，建议不出'), findsOneWidget);
      expect(find.text('清空'), findsNothing);

      // 托管按钮明确区分本地托管和 API 托管。
      await tester.tap(find.byTooltip('开启托管'));
      await tester.pumpAndSettle();
      expect(find.text('本地托管'), findsOneWidget);
      expect(find.text('API 托管'), findsOneWidget);
      await tester.tap(find.text('本地托管'));
      await tester.pump();
      expect(find.textContaining('本地托管中', findRichText: true), findsOneWidget);
      expect(find.byTooltip('取消托管'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  test('dedicated HTTP port serves an isolated anonymous lobby and advertises it over LAN', () async {
    final rooms = CardRooms();
    final server = DormLanServer.cards(
      rooms,
      (path) => File(path).readAsString(),
    );
    final seat = rooms.create(CardRules(), scope: 'lan');
    await server.start(0);
    addTearDown(rooms.dispose);
    addTearDown(server.dispose);
    final address = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
    final raw = HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());
    addTearDown(() => raw.close(force: true));
    final response = await (await raw.getUrl(address.replace(path: '/cards')))
        .close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    final ledger = await (await raw.getUrl(
      address.replace(path: '/api/ledger'),
    )).close();
    expect(ledger.statusCode, 404);
    await ledger.drain<void>();
    final options = await CardDiscovery.search(
      duration: const Duration(milliseconds: 550),
    );
    expect(options.any((room) => room.room['room'] == seat.room), isTrue);
    await HttpOverrides.runWithHttpOverrides(() async {
      final http = CardHttp(address);
      addTearDown(http.close);
      final guest = await http.request('${seat.room}/join', data: {'name': ''});
      expect(guest['token'], isNot(seat.token));
      final state = await http.request(
        '${seat.room}/state',
        token: guest['token'] as String,
      );
      expect(state['you'], 2);
      expect((state['people'] as List).last['name'], '访客 2');
    }, _RealHttp());
  });

  test(
    'two clients exchange encrypted room moves over real Git push and pull',
    () async {
      await git.PlatformSpecific.initialize();
      final root = await Directory.systemTemp.createTemp('dorm-git-cards-');
      addTearDown(() => root.delete(recursive: true));
      final bare = Directory('${root.path}/remote.git');
      git.Repository.initBasic(path: bare.path, bare: true).free();
      final key = await CloudKey.generate();
      final settings = CloudSettings(
        repository: 'test/cards',
        operator: 'Test card room',
      );
      GitHubTransport transport(String side) => GitHubTransport(
        Directory('${root.path}/$side'),
        localTestRemote: bare,
      );
      final aWire = transport('a')
          .cardMailbox(settings, () async => key, () async => null);
      final bWire = transport('b')
          .cardMailbox(settings, () async => key, () async => null);
      final rooms = CardRooms(random: Random(13));
      final other = CardRooms();
      final racing = _RacingMailbox(aWire);
      final a = OnlineCards(racing, rooms, interval: Duration.zero);
      final b = OnlineCards(bWire, other, interval: Duration.zero);
      addTearDown(rooms.dispose);
      addTearDown(other.dispose);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final host = await a.host(
        CardRules(players: 2, landlord: false, bottom: 0),
        '房主',
      );
      expect(a.error, isNull);
      await b.refresh();
      expect(b.directory.single['room'], host.room);
      await b.join(b.directory.single, '');
      await a.refresh();
      await b.refresh();
      expect(a.error, isNull);
      expect(b.error, isNull);
      expect(b.remoteView?['you'], 2);
      rooms.action(host, 'start', {});
      await a.refresh();
      await b.refresh();
      expect(b.remoteView?['hand'], hasLength(27));
      final wire = (await bWire.pull())!.body;
      expect(wire, isNot(contains('"hand"')));
      expect(wire, isNot(contains(host.token)));
      await b.send('chat', {'text': '这条测试消息是密文'});
      await b.refresh();
      racing.retryNextPush = true;
      await a.refresh();
      await b.refresh();
      expect(b.waiting, isFalse);
      expect(
        (b.remoteView?['events'] as List).where(
          (event) => event['text'] == '这条测试消息是密文',
        ),
        hasLength(1),
      );
      expect((b.remoteView?['events'] as List).last['text'], '这条测试消息是密文');
      expect((await bWire.pull())!.body, isNot(contains('这条测试消息是密文')));
      expect((await transport('a').pull(settings, key)), isNull);
    },
  );

  testWidgets('手机窄屏支持 8 人同桌多排对手且菜单可调缩放', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = CardSession(
      () => null,
      rooms: CardRooms(random: Random(19)),
    );
    addTearDown(session.dispose);
    await session.create(
      CardRules(players: 8, decks: 2, bottom: 4),
      '房主',
      CardLocation.local,
    );
    for (var i = 0; i < 7; i++) {
      await session.act('bot', {'mode': 'local'});
    }
    await session.act('start');

    double scale = 1.0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          builder: (context, child) => DormUiScaleScope(
            scale: scale,
            onAdjust: (delta) =>
                setState(() => scale = clampUiScale(scale + delta * 0.05)),
            onReset: () => setState(() => scale = 1.0),
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => CardTable(
                session: session,
                view: session.view!,
                share: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var id = 2; id <= 8; id++) {
      expect(find.text('本地电脑 $id'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('牌桌菜单'));
    await tester.pumpAndSettle();
    expect(find.text('界面缩放'), findsOneWidget);
    await tester.tap(find.byTooltip('放大界面'));
    await tester.pumpAndSettle();
    expect(find.text('105%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<(CardSession, List<CardSeat>)> _openGame(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  TargetPlatform? platform,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final session = CardSession(() => null, rooms: CardRooms(random: Random(3)));
  addTearDown(session.dispose);
  await session.create(CardRules(), '房主', CardLocation.local);
  final code = session.view!['room'] as String;
  final guests = [session.rooms.join(code), session.rooms.join(code)];
  await session.act('start');
  while (session.view!['you'] != session.view!['turn']) {
    final guest = guests.firstWhere(
      (seat) => session.rooms.state(seat)['you'] == session.view!['turn'],
    );
    session.rooms.action(guest, 'bid', {
      'bid': 0,
      'turnVersion': session.view!['turnVersion'],
    });
  }
  await session.act('bid', {'bid': 3});
  await tester.pumpWidget(
    MaterialApp(
      theme: platform == null ? null : ThemeData(platform: platform),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: session,
          builder: (context, _) =>
              CardTable(session: session, view: session.view!, share: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(session.view!['phase'], 'playing');
  return (session, guests);
}

Finder _handCard(PlayingCard card) {
  final mark = card.suit == null ? '★' : ['♠', '♥', '♦', '♣'][card.suit!];
  final label = '${PlayingCard.rankLabel(card.rank)} $mark';
  return find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_HandStrip',
    ),
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    ),
  );
}

bool _isSelected(WidgetTester tester, Finder finder) =>
    tester.widget<Semantics>(finder).properties.selected == true;

class _RealHttp extends HttpOverrides {}

class _RacingMailbox implements CardMailbox {
  _RacingMailbox(this.mailbox);
  final CardMailbox mailbox;
  bool retryNextPush = false;

  @override
  Future<CardMailboxRead?> pull() => mailbox.pull();

  @override
  Future<void> push(String body, String? revision) async {
    await mailbox.push(body, revision);
    if (retryNextPush) {
      retryNextPush = false;
      throw const CardMailboxRace();
    }
  }
}
