import 'bot_profile.dart';
import 'cards.dart';

int localBid(BotTurn turn) {
  final counts = _ranks(turn.hand);
  final power = counts.entries.fold(0, (total, entry) {
    final rank = entry.key;
    final count = entry.value;
    final control = switch (rank) {
      17 => 4,
      16 => 3,
      15 => 2,
      14 => 1,
      _ => 0,
    };
    return total +
        (turn.wild.contains(rank) ? 3 : control) * count +
        (count >= 4 ? 4 : 0);
  });
  final strength = power / (turn.hand.length / 17).clamp(0.7, 3);
  final bid = turn.rules.landlordCall == LandlordCall.call
      ? (strength >= 8 ? 1 : 0)
      : strength >= 13
      ? 3
      : strength >= 10
      ? 2
      : strength >= 7
      ? 1
      : 0;
  return turn.rules.bidsAfter(turn.topBid).contains(bid) ? bid : 0;
}

CardPlay? localPlay(BotTurn turn) {
  final hand = turn.hand;
  final previous = turn.previous;
  final finish = legalCardPlays(
    hand,
    turn.wild,
    previous,
    rules: turn.rules,
  ).firstOrNull;
  if (finish != null) return finish;
  final options = hintPlays(hand, turn.wild, previous, rules: turn.rules);
  if (options.isEmpty) return null;

  bool teammate(int id) =>
      turn.landlord != null &&
      turn.seat != turn.landlord &&
      id != turn.landlord;

  final index = turn.players.indexWhere((seat) => seat.id == turn.seat);
  final next = turn.players[(index + 1) % turn.players.length];
  final leader = turn.players
      .where((seat) => seat.id == turn.leader)
      .firstOrNull;
  final nextAtRisk = !teammate(next.id) && next.cards <= 2;
  final nextCanFinish =
      previous != null && nextAtRisk && next.cards == previous.cards.length;
  if (previous != null &&
      leader != null &&
      teammate(leader.id) &&
      !nextCanFinish) {
    return null;
  }

  final counts = _ranks(hand);
  final hasRocket = counts.containsKey(16) && counts.containsKey(17);
  final nextHasOne = nextAtRisk && next.cards == 1;
  final blockSingle = nextHasOne && previous?.kind == PlayKind.single;
  final urgent =
      nextCanFinish ||
      (leader != null && !teammate(leader.id) && leader.cards <= 2);

  CardPlay? ordinary;
  int? bestScore;
  for (final play in options) {
    if (play.bomb) continue;
    final used = _ranks(play.cards);
    var cost = 0;
    for (final entry in used.entries) {
      final rank = entry.key;
      final count = counts[rank]!;
      if (count >= 4 || (hasRocket && rank >= 16)) {
        cost += 20;
      } else if (entry.value != count) {
        cost += 4;
      }
      if (turn.wild.contains(rank)) cost += 5;
    }
    var score = -cost - play.high;
    if (previous == null) {
      score += 10 * play.cards.length;
      if (nextHasOne) score += play.cards.length == 1 ? 3 * play.high : 70;
    } else if (blockSingle) {
      score += 4 * play.high;
    }
    if (bestScore == null || score > bestScore) {
      bestScore = score;
      ordinary = play;
    }
  }
  if (ordinary != null) return ordinary;

  final bombs = options.where((play) => play.bomb);
  if (previous == null || urgent) return bombs.firstOrNull;
  // Take control if the remaining cards can be played in a single lead.
  for (final bomb in bombs) {
    final used = bomb.cards.map((card) => card.id).toSet();
    final remaining = hand.where((card) => !used.contains(card.id)).toList();
    if (legalCardPlays(
      remaining,
      turn.wild,
      null,
      rules: turn.rules,
    ).isNotEmpty) {
      return bomb;
    }
  }
  return null;
}

Map<int, int> _ranks(Iterable<PlayingCard> cards) {
  final counts = <int, int>{};
  for (final card in cards) {
    counts.update(card.rank, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}
