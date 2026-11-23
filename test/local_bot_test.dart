import 'package:dormos/game/bot_profile.dart';
import 'package:dormos/game/cards.dart';
import 'package:dormos/game/local_bot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a farmer keeps an ally in control unless it can go out', () {
    final earlier = legalCardPlays(_cards([5]), {}, null).single;
    final turn = _turn([7, 9, 11], previous: earlier, leader: 3);
    expect(localPlay(turn), isNull);
    final canWin = _turn([7], previous: earlier, leader: 3);
    expect(localPlay(canWin)?.high, 7);
  });

  test('blocks the next opponent from going out on a single', () {
    final earlier = legalCardPlays(_cards([5]), {}, null).single;
    final lead = _turn([6, 6, 8, 14], nextCards: 1);
    expect(localPlay(lead)?.kind, PlayKind.pair);
    final follow = _turn(
      [6, 8, 14],
      previous: earlier,
      leader: 3,
      nextCards: 1,
    );
    expect(localPlay(follow)?.high, 14);
  });

  test('saves its bomb on an ordinary response and uses it under pressure', () {
    final earlier = legalCardPlays(_cards([14]), {}, null).single;
    final turn = _turn([3, 3, 3, 3, 6, 9], previous: earlier, leader: 3);
    expect(localPlay(turn), isNull);
    final urgent = _turn(
      [3, 3, 3, 3, 6, 9],
      previous: earlier,
      leader: 3,
      nextCards: 1,
    );
    expect(localPlay(urgent)?.kind, PlayKind.bomb);
  });

  test('bids according to hand strength and the legal call options', () {
    expect(localBid(_turn([3, 4, 6, 8, 10], bidding: true)), 0);
    final strong = [3, 3, 3, 3, 14, 15, 16, 17];
    expect(localBid(_turn(strong, bidding: true)), 3);
    expect(localBid(_turn(strong, bidding: true, topBid: 3)), 0);
  });
}

BotTurn _turn(
  List<int> ranks, {
  CardPlay? previous,
  int? leader,
  int nextCards = 9,
  bool bidding = false,
  int topBid = 0,
}) => BotTurn(
  room: 'TEST',
  deal: 1,
  bidding: bidding,
  rules: CardRules(),
  hand: _cards(ranks),
  wild: {},
  previous: previous,
  leader: leader,
  topBid: topBid,
  seat: 1,
  landlord: 2,
  players: [
    BotSeat(id: 1, cards: ranks.length),
    BotSeat(id: 2, cards: nextCards),
    const BotSeat(id: 3, cards: 8),
  ],
  log: const [],
);

List<PlayingCard> _cards(List<int> ranks) {
  final copies = <int, int>{};
  return ranks.map((rank) {
    final copy = copies.update(rank, (count) => count + 1, ifAbsent: () => 0);
    final face = rank <= 15 ? (rank - 3) * 4 + copy : 52 + rank - 16;
    return PlayingCard(face);
  }).toList();
}
