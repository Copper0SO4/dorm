import 'dart:math';

import '../domain/ledger.dart';

enum CardMode {
  classic('经典'),
  wild('癞子'),
  doubleWild('天地癞子');

  const CardMode(this.label);
  final String label;
}

enum DealRemainder { equal, extra }

class CardRules {
  static const defaultRocketBeatsChain = false;

  CardRules({
    this.players = 3,
    this.decks = 1,
    this.discard = 0,
    this.remainder = DealRemainder.equal,
    this.landlord = true,
    this.bottom = 3,
    this.mode = CardMode.classic,
    this.chainBombs = true,
    this.rocketBeatsChain = defaultRocketBeatsChain,
    this.fourWithTwo = true,
  }) {
    if (players < 2 || players > 8 || decks < 1 || decks > 4) {
      throw const InputException('支持 2 至 8 人，1 至 4 副牌');
    }
    if (discard < 0 ||
        bottom < 0 ||
        bottom > 30 ||
        (!landlord && bottom != 0) ||
        available < players) {
      throw const InputException('请检查舍弃张数和地主牌，至少给每人发一张');
    }
    if (remainder == DealRemainder.equal && available % players != 0) {
      throw const InputException('剩余牌数不能平分，请调整舍弃张数或选择随机多发给一人');
    }
  }

  factory CardRules.fromJson(
    Map<String, dynamic> values, {
    bool newRoom = false,
  }) {
    try {
      return CardRules(
        players: values['players'] as int,
        decks: values['decks'] as int,
        discard: values['discard'] as int,
        remainder: DealRemainder.values.byName(values['remainder'] as String),
        landlord: values['landlord'] as bool,
        bottom: values['bottom'] as int,
        mode: CardMode.values.byName(values['mode'] as String),
        chainBombs: (values['chainBombs'] as bool?) ?? false,
        rocketBeatsChain:
            (values['rocketBeatsChain'] as bool?) ??
            (newRoom ? defaultRocketBeatsChain : true),
        fourWithTwo: (values['fourWithTwo'] as bool?) ?? true,
      );
    } on ArgumentError {
      throw const InputException('房间规则格式有误');
    } on TypeError {
      throw const InputException('房间规则格式有误');
    }
  }

  final int players;
  final int decks;
  final int discard;
  final DealRemainder remainder;
  final bool landlord;
  final int bottom;
  final CardMode mode;
  final bool chainBombs;
  final bool rocketBeatsChain;
  final bool fourWithTwo;
  int get available => 54 * decks - discard - bottom;

  Map<String, Object> toJson() => {
    'players': players,
    'decks': decks,
    'discard': discard,
    'remainder': remainder.name,
    'landlord': landlord,
    'bottom': bottom,
    'mode': mode.name,
    'chainBombs': chainBombs,
    'rocketBeatsChain': rocketBeatsChain,
    'fourWithTwo': fourWithTwo,
  };
}

class PlayingCard {
  const PlayingCard(this.id);

  final int id;
  int get face => id % 54;
  int get rank => face < 52 ? 3 + face ~/ 4 : 16 + face - 52;
  int? get suit => face < 52 ? face % 4 : null;

  static String rankLabel(int rank) => switch (rank) {
    11 => 'J',
    12 => 'Q',
    13 => 'K',
    14 => 'A',
    15 => '2',
    16 => '小王',
    17 => '大王',
    _ => '$rank',
  };

  static int compare(PlayingCard a, PlayingCard b) {
    final rank = a.rank.compareTo(b.rank);
    return rank == 0 ? a.id.compareTo(b.id) : rank;
  }
}

typedef CardDeal = ({
  List<List<PlayingCard>> hands,
  List<PlayingCard> bottom,
  List<PlayingCard> discarded,
  int? extraSeat,
});

CardDeal dealCards(CardRules rules, Random random) {
  final deck = List.generate(rules.decks * 54, PlayingCard.new)
    ..shuffle(random);
  final bottom = deck.sublist(rules.discard, rules.discard + rules.bottom);
  final dealing = deck.skip(rules.discard + rules.bottom).toList();
  final each = dealing.length ~/ rules.players;
  final spill = dealing.length % rules.players;
  final extra = spill == 0 ? null : random.nextInt(rules.players);
  final hands = List.generate(rules.players, (_) => <PlayingCard>[]);
  for (var i = 0; i < each * rules.players; i++) {
    hands[i % rules.players].add(dealing[i]);
  }
  if (extra != null) hands[extra].addAll(dealing.skip(each * rules.players));
  for (final hand in hands) {
    hand.sort(PlayingCard.compare);
  }
  return (
    hands: hands,
    bottom: bottom,
    discarded: deck.take(rules.discard).toList(),
    extraSeat: extra,
  );
}

enum PlayKind {
  single('单张'),
  pair('对子'),
  triple('三张'),
  tripleSingle('三带一'),
  triplePair('三带对'),
  straight('顺子'),
  pairs('连对'),
  plane('飞机'),
  planeSingles('飞机带单'),
  planePairs('飞机带对'),
  fourSingles('四带二'),
  fourPairs('四带两对'),
  bomb('炸弹'),
  chainBomb('连炸'),
  rocket('王炸');

  const PlayKind(this.label);
  final String label;
}

class CardPlay {
  const CardPlay(
    this.kind,
    this.high,
    this.width,
    this.strength,
    this.cards,
    this.ranks,
  );
  factory CardPlay.fromJson(Map<String, dynamic> json) {
    final parts = (json['key'] as String).split(':');
    return CardPlay(
      PlayKind.values.byName(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
      int.parse(parts[3]),
      [],
      {},
    );
  }

  final PlayKind kind;
  final int high;
  final int width;
  final int strength;
  final List<PlayingCard> cards;
  final Map<int, int> ranks;

  String get key => '${kind.name}:$high:$width:$strength';
  int _bombOrder(CardRules? rules) {
    final rocketFirst =
        rules?.rocketBeatsChain ?? CardRules.defaultRocketBeatsChain;
    return switch (kind) {
      PlayKind.bomb => 1,
      PlayKind.chainBomb => rocketFirst ? 2 : 3,
      PlayKind.rocket => rocketFirst ? 3 : 2,
      _ => 0,
    };
  }

  bool get bomb => _bombOrder(null) > 0;

  int _compareBombs(CardPlay other, CardRules? rules) {
    final order = _bombOrder(rules).compareTo(other._bombOrder(rules));
    if (order != 0) return order;
    final count = width.compareTo(other.width);
    if (count != 0) return count;
    final firmness = strength.compareTo(other.strength);
    return firmness == 0 ? high.compareTo(other.high) : firmness;
  }

  bool beats(CardPlay? earlier, {CardRules? rules}) {
    if (earlier == null) return true;
    if (bomb || earlier.bomb) return _compareBombs(earlier, rules) > 0;
    return earlier.kind == kind &&
        earlier.width == width &&
        high > earlier.high;
  }

  String get label => switch (kind) {
    PlayKind.bomb => '$width 张${['软炸', '硬炸', '纯癞子炸弹'][strength]}',
    PlayKind.chainBomb => '$width 连炸',
    PlayKind.rocket => switch (width) {
      2 => '王炸',
      4 => '双王炸',
      _ => '${width ~/ 2} 组王炸',
    },
    _ => kind.label,
  };

  Map<String, Object> toJson() => {
    'key': key,
    'label': label,
    'high': high,
    'bomb': bomb,
    'cards': [
      for (final card in cards)
        {'id': card.id, 'rank': ranks[card.id] ?? card.rank},
    ],
  };
}

List<CardPlay> cardPlays(
  List<PlayingCard> chosen,
  Set<int> wildRanks, {
  CardRules? rules,
}) => _matchingPlays(
  chosen,
  wildRanks,
  chainBombs: rules?.chainBombs ?? false,
  fourWithTwo: rules?.fourWithTwo ?? true,
);

List<CardPlay> _matchingPlays(
  List<PlayingCard> chosen,
  Set<int> wildRanks, {
  required bool chainBombs,
  required bool fourWithTwo,
}) {
  if (chosen.isEmpty ||
      chosen.map((card) => card.id).toSet().length != chosen.length) {
    return [];
  }
  final cards = [...chosen]..sort(PlayingCard.compare);
  final size = cards.length;
  if (size == 1) {
    return [CardPlay(PlayKind.single, cards.single.rank, 1, 0, cards, {})];
  }
  final fixed = <int, int>{};
  final wild = <PlayingCard>[];
  for (final card in cards) {
    if (card.rank <= 15 && wildRanks.contains(card.rank)) {
      wild.add(card);
    } else {
      fixed.update(card.rank, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  final result = <String, CardPlay>{};

  void add(
    PlayKind kind,
    int high,
    int width,
    Map<int, int> core, {
    int wingSlots = 0,
    int wingSize = 0,
    bool distinct = true,
  }) {
    final deficits = <int>[];
    for (final entry in core.entries) {
      final needed = entry.value - (fixed[entry.key] ?? 0);
      if (needed < 0 || (needed > 0 && entry.key > 15)) return;
      deficits.addAll(List.filled(needed, entry.key));
    }
    var used = 0;
    for (final entry in fixed.entries) {
      if (core.containsKey(entry.key)) continue;
      if (wingSlots == 0) return;
      if (wingSize == 1 && !distinct) {
        used += entry.value;
      } else {
        if (entry.value > wingSize) return;
        used++;
        final needed = wingSize - entry.value;
        if (needed > 0 && entry.key > 15) return;
        deficits.addAll(List.filled(needed, entry.key));
      }
    }
    if (used > wingSlots) return;
    for (var remaining = used; remaining < wingSlots; remaining++) {
      final rank = List.generate(13, (index) => index + 3)
          .where(
            (rank) =>
                !core.containsKey(rank) &&
                (!distinct ||
                    (!fixed.containsKey(rank) && !deficits.contains(rank))),
          )
          .firstOrNull;
      if (rank == null) return;
      deficits.addAll(List.filled(wingSize, rank));
    }
    if (deficits.length != wild.length) return;
    final conversion = <int, int>{};
    final unmatched = <PlayingCard>[];
    for (final card in wild) {
      if (!deficits.remove(card.rank)) unmatched.add(card);
    }
    for (final (i, card) in unmatched.indexed) {
      conversion[card.id] = deficits[i];
    }
    final strength = switch (kind) {
      PlayKind.bomb => wild.isEmpty ? 1 : (fixed.isEmpty ? 2 : 0),
      PlayKind.chainBomb => wild.isEmpty ? 1 : 0,
      _ => 0,
    };
    final play = CardPlay(kind, high, width, strength, cards, conversion);
    result[play.key] = play;
  }

  if (size.isEven && fixed[16] == size ~/ 2 && fixed[17] == size ~/ 2) {
    add(PlayKind.rocket, 17, size, {16: size ~/ 2, 17: size ~/ 2});
  }
  for (var rank = 3; rank <= 17; rank++) {
    if (size == 2) add(PlayKind.pair, rank, 1, {rank: 2});
    if (rank > 15) continue;
    if (size == 3) add(PlayKind.triple, rank, 1, {rank: 3});
    if (size == 4) {
      add(PlayKind.tripleSingle, rank, 1, {rank: 3}, wingSlots: 1, wingSize: 1);
    }
    if (size == 5) {
      add(PlayKind.triplePair, rank, 1, {rank: 3}, wingSlots: 1, wingSize: 2);
    }
    if (size == 6 && fourWithTwo) {
      add(
        PlayKind.fourSingles,
        rank,
        1,
        {rank: 4},
        wingSlots: 2,
        wingSize: 1,
        distinct: false,
      );
    }
    if (size == 8 && fourWithTwo) {
      add(PlayKind.fourPairs, rank, 1, {rank: 4}, wingSlots: 2, wingSize: 2);
    }
    if (size >= 4 &&
        (fixed.isNotEmpty || wild.any((card) => card.rank == rank))) {
      add(PlayKind.bomb, rank, size, {rank: size});
    }
  }

  void sequence(PlayKind kind, int multiplicity, int wings, int minimum) {
    final group = multiplicity + wings;
    if (size % group != 0) return;
    final width = size ~/ group;
    if (width < minimum || width > 12) return;
    for (var start = 3; start + width - 1 <= 14; start++) {
      add(
        kind,
        start + width - 1,
        width,
        {for (var i = 0; i < width; i++) start + i: multiplicity},
        wingSlots: wings == 0 ? 0 : width,
        wingSize: wings,
      );
    }
  }

  sequence(PlayKind.straight, 1, 0, 5);
  sequence(PlayKind.pairs, 2, 0, 3);
  sequence(PlayKind.plane, 3, 0, 2);
  sequence(PlayKind.planeSingles, 3, 1, 2);
  sequence(PlayKind.planePairs, 3, 2, 2);
  if (chainBombs) sequence(PlayKind.chainBomb, 4, 0, 2);
  return result.values.toList();
}

String? disabledCardPlayMessage(
  List<PlayingCard> chosen,
  Set<int> wildRanks,
  CardRules rules,
) {
  if (rules.chainBombs || chosen.length < 8 || chosen.length % 4 != 0) {
    return null;
  }
  final matches = _matchingPlays(
    chosen,
    wildRanks,
    chainBombs: true,
    fourWithTwo: false,
  );
  return matches.any((play) => play.kind == PlayKind.chainBomb)
      ? '本房间未开启连炸'
      : null;
}

/// The room and both clients validate the same declared play.
List<CardPlay> legalCardPlays(
  List<PlayingCard> chosen,
  Set<int> wild,
  CardPlay? previous, {
  CardRules? rules,
}) => cardPlays(
  chosen,
  wild,
  rules: rules,
).where((play) => play.beats(previous, rules: rules)).toList();

/// Bots prefer an immediate win, then the smallest available response.
CardPlay? suggestCards(
  List<PlayingCard> hand,
  Set<int> wild,
  CardPlay? previous, {
  CardRules? rules,
}) {
  if (hand.isEmpty) return null;
  final finish = legalCardPlays(hand, wild, previous, rules: rules).firstOrNull;
  if (finish != null) return finish;
  if (previous == null) {
    final lowest = hand.reduce(
      (a, b) => PlayingCard.compare(a, b) <= 0 ? a : b,
    );
    return cardPlays([lowest], wild).single;
  }
  return hintPlays(hand, wild, previous, rules: rules).firstOrNull;
}

const _hintShapes = [
  (kind: PlayKind.single, copies: 1, minimum: 1, wings: 0, wingSize: 0),
  (kind: PlayKind.pair, copies: 2, minimum: 1, wings: 0, wingSize: 0),
  (kind: PlayKind.triple, copies: 3, minimum: 1, wings: 0, wingSize: 0),
  (kind: PlayKind.tripleSingle, copies: 3, minimum: 1, wings: 1, wingSize: 1),
  (kind: PlayKind.triplePair, copies: 3, minimum: 1, wings: 1, wingSize: 2),
  (kind: PlayKind.straight, copies: 1, minimum: 5, wings: 0, wingSize: 0),
  (kind: PlayKind.pairs, copies: 2, minimum: 3, wings: 0, wingSize: 0),
  (kind: PlayKind.plane, copies: 3, minimum: 2, wings: 0, wingSize: 0),
  (kind: PlayKind.planeSingles, copies: 3, minimum: 2, wings: 1, wingSize: 1),
  (kind: PlayKind.planePairs, copies: 3, minimum: 2, wings: 1, wingSize: 2),
  (kind: PlayKind.fourSingles, copies: 4, minimum: 1, wings: 2, wingSize: 1),
  (kind: PlayKind.fourPairs, copies: 4, minimum: 1, wings: 2, wingSize: 2),
];

/// Finds a playable card set for each possible rank and shape. Alternate
/// suits for the same play do not need separate hint entries.
List<CardPlay> hintPlays(
  List<PlayingCard> hand,
  Set<int> wild,
  CardPlay? previous, {
  CardRules? rules,
}) {
  if (hand.isEmpty) return [];
  final sorted = [...hand]..sort(PlayingCard.compare);
  final printed = <int, List<PlayingCard>>{};
  final naturals = <int, List<PlayingCard>>{};
  final wildCards = <PlayingCard>[];
  for (final card in sorted) {
    printed.putIfAbsent(card.rank, () => []).add(card);
    if (card.rank <= 15 && wild.contains(card.rank)) {
      wildCards.add(card);
    } else {
      naturals.putIfAbsent(card.rank, () => []).add(card);
    }
  }

  List<PlayingCard>? choose(
    Map<int, int> core, {
    int wings = 0,
    int wingSize = 0,
    bool repeatedSingles = false,
  }) {
    final chosen = <PlayingCard>[];
    final spares = [...wildCards];

    bool useWild(int count, {int? asRank}) {
      if (count > spares.length || (count > 0 && (asRank ?? 0) > 15)) {
        return false;
      }
      for (var i = 0; i < count; i++) {
        final natural = spares.indexWhere((card) => card.rank == asRank);
        chosen.add(spares.removeAt(natural < 0 ? 0 : natural));
      }
      return true;
    }

    for (final rank in core.keys) {
      final count = core[rank]!;
      final cards = (naturals[rank] ?? const <PlayingCard>[]).take(count);
      chosen.addAll(cards);
      if (!useWild(count - cards.length, asRank: rank)) return null;
    }
    if (wings == 0) return chosen;
    if (repeatedSingles) {
      final cards = naturals.entries
          .where((entry) => !core.containsKey(entry.key))
          .expand((entry) => entry.value)
          .take(wings)
          .toList();
      chosen.addAll(cards);
      return useWild(wings - cards.length) ? chosen : null;
    }

    final attachments = <({int rank, List<PlayingCard> cards, int needed})>[];
    for (var rank = 3; rank <= 17; rank++) {
      if (core.containsKey(rank)) continue;
      final cards = (naturals[rank] ?? const <PlayingCard>[])
          .take(wingSize)
          .toList();
      final needed = wingSize - cards.length;
      if (rank > 15 && needed > 0) continue;
      attachments.add((rank: rank, cards: cards, needed: needed));
    }
    if (attachments.length < wings) return null;
    attachments.sort((a, b) {
      final cost = a.needed.compareTo(b.needed);
      return cost == 0 ? a.rank.compareTo(b.rank) : cost;
    });
    for (final attachment in attachments.take(wings)) {
      chosen.addAll(attachment.cards);
      if (!useWild(attachment.needed, asRank: attachment.rank)) return null;
    }
    return chosen;
  }

  final hints = <String, CardPlay>{};
  void add(List<PlayingCard>? cards, PlayKind kind, int high, int width) {
    if (cards == null || cards.isEmpty) return;
    final play = legalCardPlays(cards, wild, previous, rules: rules)
        .where(
          (play) =>
              play.kind == kind && play.high == high && play.width == width,
        )
        .firstOrNull;
    if (play == null) return;
    final ids = [for (final card in play.cards) card.id]..sort();
    final signature = ids.join(',');
    final current = hints[signature];
    if (current == null || _compareHints(play, current, rules) < 0) {
      hints[signature] = play;
    }
  }

  for (final shape in _hintShapes) {
    if (previous != null && previous.kind != shape.kind) continue;
    if (rules?.fourWithTwo == false &&
        (shape.kind == PlayKind.fourSingles ||
            shape.kind == PlayKind.fourPairs)) {
      continue;
    }
    final sequential = shape.minimum > 1;
    final maxWidth = sequential
        ? min(12, hand.length ~/ (shape.copies + shape.wings * shape.wingSize))
        : 1;
    final firstWidth = previous?.width ?? shape.minimum;
    final lastWidth = min(maxWidth, previous?.width ?? maxWidth);
    final lastRank = sequential
        ? 14
        : shape.kind == PlayKind.single || shape.kind == PlayKind.pair
        ? 17
        : 15;
    for (var width = firstWidth; width <= lastWidth; width++) {
      final firstHigh = max(width + 2, (previous?.high ?? 2) + 1);
      for (var high = firstHigh; high <= lastRank; high++) {
        if (shape.kind == PlayKind.single) {
          final card = printed[high]?.firstOrNull;
          if (card != null) add([card], shape.kind, high, width);
          continue;
        }
        add(
          choose(
            {
              for (var rank = high - width + 1; rank <= high; rank++)
                rank: shape.copies,
            },
            wings: width * shape.wings,
            wingSize: shape.wingSize,
            repeatedSingles: shape.kind == PlayKind.fourSingles,
          ),
          shape.kind,
          high,
          width,
        );
      }
    }
  }

  if (previous == null || previous._bombOrder(rules) <= 1) {
    final first = previous?.kind == PlayKind.bomb ? previous!.width : 4;
    for (var rank = 3; rank <= 15; rank++) {
      final count = naturals[rank]?.length ?? 0;
      if (count == 0 && !wild.contains(rank)) continue;
      for (var length = first; length <= count + wildCards.length; length++) {
        add(choose({rank: length}), PlayKind.bomb, rank, length);
      }
    }
  }
  if (rules?.chainBombs == true &&
      (previous?.kind != PlayKind.rocket || rules?.rocketBeatsChain == false)) {
    final first = previous?.kind == PlayKind.chainBomb ? previous!.width : 2;
    for (var width = first; width <= min(12, hand.length ~/ 4); width++) {
      for (var high = width + 2; high <= 14; high++) {
        add(
          choose({
            for (var rank = high - width + 1; rank <= high; rank++) rank: 4,
          }),
          PlayKind.chainBomb,
          high,
          width,
        );
      }
    }
  }
  final smallJokers = naturals[16] ?? const <PlayingCard>[];
  final bigJokers = naturals[17] ?? const <PlayingCard>[];
  for (
    var pairs = 1;
    pairs <= min(smallJokers.length, bigJokers.length);
    pairs++
  ) {
    add(
      [...smallJokers.take(pairs), ...bigJokers.take(pairs)],
      PlayKind.rocket,
      17,
      pairs * 2,
    );
  }
  return hints.values.toList()..sort((a, b) => _compareHints(a, b, rules));
}

int _compareHints(CardPlay a, CardPlay b, CardRules? rules) {
  if (a.bomb || b.bomb) return a._compareBombs(b, rules);
  final high = a.high.compareTo(b.high);
  return high == 0 ? a.cards.length.compareTo(b.cards.length) : high;
}
