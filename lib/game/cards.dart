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
  CardRules({
    this.players = 3,
    this.decks = 1,
    this.discard = 0,
    this.remainder = DealRemainder.equal,
    this.landlord = true,
    this.bottom = 3,
    this.mode = CardMode.classic,
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

  factory CardRules.fromJson(Map<String, dynamic> values) {
    try {
      return CardRules(
        players: values['players'] as int,
        decks: values['decks'] as int,
        discard: values['discard'] as int,
        remainder: DealRemainder.values.byName(values['remainder'] as String),
        landlord: values['landlord'] as bool,
        bottom: values['bottom'] as int,
        mode: CardMode.values.byName(values['mode'] as String),
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
  int get available => 54 * decks - discard - bottom;

  Map<String, Object> toJson() => {
    'players': players,
    'decks': decks,
    'discard': discard,
    'remainder': remainder.name,
    'landlord': landlord,
    'bottom': bottom,
    'mode': mode.name,
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
  bool get bomb => kind == PlayKind.bomb || kind == PlayKind.rocket;
  bool beats(CardPlay? earlier) {
    if (earlier == null) return true;
    if (kind == PlayKind.rocket) {
      return earlier.kind != kind || width > earlier.width;
    }
    if (earlier.kind == PlayKind.rocket) return false;
    if (kind == PlayKind.bomb) {
      if (earlier.kind != kind) return true;
      if (width != earlier.width) return width > earlier.width;
      if (strength != earlier.strength) return strength > earlier.strength;
      return high > earlier.high;
    }
    return earlier.kind == kind &&
        earlier.width == width &&
        high > earlier.high;
  }

  String get label => switch (kind) {
    PlayKind.bomb => '$width 张${['软炸', '硬炸', '纯癞子炸弹'][strength]}',
    PlayKind.rocket => '$width 张王炸',
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

List<CardPlay> cardPlays(List<PlayingCard> chosen, Set<int> wildRanks) {
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
    if (wildRanks.contains(card.rank)) {
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
    final strength = kind != PlayKind.bomb
        ? 0
        : wild.isEmpty
        ? 1
        : fixed.isEmpty
        ? 2
        : 0;
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
    if (size == 6) {
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
    if (size == 8) {
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
  return result.values.toList();
}

/// Evaluates small, targeted candidate sets using exactly the same judge as play.
CardPlay? suggestCards(
  List<PlayingCard> hand,
  Set<int> wild,
  CardPlay? previous,
) {
  if (hand.isEmpty) return null;
  final byRank = <int, List<PlayingCard>>{};
  for (final card in hand) {
    byRank.putIfAbsent(card.rank, () => []).add(card);
  }
  final full = cardPlays(
    hand,
    wild,
  ).where((play) => play.beats(previous)).firstOrNull;
  if (full != null) return full;
  if (previous == null) return cardPlays([hand.first], wild).single;

  CardPlay? attempt(Map<int, int> core, {int wings = 0, int wingSize = 1}) {
    final included = <PlayingCard>[];
    for (final entry in core.entries) {
      final available = byRank[entry.key] ?? [];
      included.addAll(available.take(entry.value));
    }
    final taken = included.map((card) => card.id).toSet();
    for (final entry in core.entries) {
      final missing = max(0, entry.value - (byRank[entry.key]?.length ?? 0));
      final replacements = hand
          .where((card) => !taken.contains(card.id) && wild.contains(card.rank))
          .take(missing)
          .toList();
      if (missing != replacements.length || (missing > 0 && entry.key > 15)) {
        return null;
      }
      included.addAll(replacements);
      taken.addAll(replacements.map((card) => card.id));
    }
    var remaining = wings;
    for (final entry in byRank.entries) {
      if (remaining == 0) break;
      if (core.containsKey(entry.key)) continue;
      final kickers = entry.value
          .where((card) => !taken.contains(card.id))
          .take(wingSize)
          .toList();
      if (kickers.length < wingSize) continue;
      included.addAll(kickers);
      remaining--;
    }
    if (remaining != 0) return null;
    return cardPlays(
      included,
      wild,
    ).where((play) => play.beats(previous)).firstOrNull;
  }

  final kind = previous.kind;
  final multiple = switch (kind) {
    PlayKind.single || PlayKind.straight => 1,
    PlayKind.pair || PlayKind.pairs => 2,
    PlayKind.fourSingles || PlayKind.fourPairs => 4,
    _ => 3,
  };
  final wings = switch (kind) {
    PlayKind.tripleSingle || PlayKind.triplePair => 1,
    PlayKind.fourSingles || PlayKind.fourPairs => 2,
    PlayKind.planeSingles || PlayKind.planePairs => previous.width,
    _ => 0,
  };
  final wingSize =
      [
        PlayKind.triplePair,
        PlayKind.fourPairs,
        PlayKind.planePairs,
      ].contains(kind)
      ? 2
      : 1;
  if (!previous.bomb) {
    for (
      var high = previous.high + 1;
      high <= (previous.width == 1 ? 17 : 14);
      high++
    ) {
      final found = attempt(
        {
          for (var rank = high - previous.width + 1; rank <= high; rank++)
            rank: multiple,
        },
        wings: wings,
        wingSize: wingSize,
      );
      if (found != null) return found;
    }
  }
  for (
    var size = max(4, previous.bomb ? previous.width : 4);
    size <= min(hand.length, 16);
    size++
  ) {
    for (var rank = 3; rank <= 15; rank++) {
      final found = attempt({rank: size});
      if (found != null) return found;
    }
  }
  for (var pairs = 1; pairs <= 4; pairs++) {
    final rocket = attempt({16: pairs, 17: pairs});
    if (rocket != null) return rocket;
  }
  return null;
}
