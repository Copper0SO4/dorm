part of 'card_rooms.dart';

const _debugRanks = {
  '3': 3,
  '4': 4,
  '5': 5,
  '6': 6,
  '7': 7,
  '8': 8,
  '9': 9,
  '10': 10,
  'T': 10,
  'J': 11,
  'Q': 12,
  'K': 13,
  'A': 14,
  '2': 15,
  'B': 16,
  'R': 17,
  'BLACK_JOKER': 16,
  'RED_JOKER': 17,
};
final _debugSequence = RegExp(r'^(?:10|[2-9TJQKABR]){1,128}$');
final _debugRankToken = RegExp(r'10|[2-9TJQKABR]');

extension _CardDebug on _CardRoom {
  Map<String, _Person> _debugSeats(_Person actor) {
    final seat = people.indexOf(actor);
    final opponents = <_Person?>[
      for (var step = 1; step < people.length; step++)
        people[(seat + step) % people.length],
      for (var missing = people.length; missing < rules.players; missing++)
        null,
    ].reversed.toList();
    return {
      'B': actor,
      for (final (index, person) in opponents.indexed)
        (index == 0
                ? 'A'
                : index == opponents.length - 1
                ? 'C'
                : String.fromCharCode(67 + index)):
            ?person,
    };
  }

  bool _canForceOut(_Person actor) => people.first == actor && actor._forceOut;

  _Person? _debugFocused(_Person actor) => actor._debugGui
      ? people.where((person) => person.id == actor._debugTarget).firstOrNull
      : null;

  RoomJson _debugView(_Person actor) => {
    'gui': actor._debugGui,
    if (_debugFocused(actor) case final person?)
      'editor': {
        'seat': person.id,
        'cards': person.cards.map((card) => card.id).toList(),
      },
    'deal': deal,
    'forceOut': actor._forceOut,
    'seats': {
      for (final entry in _debugSeats(actor).entries) entry.key: entry.value.id,
    },
    'hands': {
      for (final person in people)
        if (actor._inspectSeats.contains(person.id))
          '${person.id}': person.cards.map((card) => card.id).toList(),
    },
  };

  PlayingCard _debugCard(int rank, int serial) {
    final face = rank <= 15 ? (rank - 3) * 4 + serial % 4 : 52 + rank - 16;
    return PlayingCard((rules.decks + serial) * 54 + face);
  }

  void _requireDebugDeal(RoomJson input) {
    if (!inProgress || input['deal'] != deal) {
      throw const InputException('牌局已变化，请在当前牌局重新执行');
    }
  }

  void _debugCommand(_Person actor, RoomJson input) {
    requireHost(actor);
    final line = input['command'];
    if (line is! String || line.isEmpty || line.length > 500) {
      throw const InputException('请输入有效的调试指令');
    }
    final parts = line.trim().split(RegExp(r'\s+'));
    final command = parts.first.toLowerCase();
    if (command == '/gui') {
      if (parts.length != 2) throw const InputException('开关指令的参数数量有误');
      _setDebugGui(actor, _debugToggle(parts[1]));
      return;
    }
    if (parts.length < 3) throw const InputException('请输入指令、座位和参数');
    final seat = parts[1].toUpperCase();
    final target = _debugSeats(actor)[seat];
    if (target == null) throw const InputException('该座位没有玩家');

    switch (command) {
      case '/invsee':
        if (parts.length != 3) throw const InputException('开关指令的参数数量有误');
        _setDebugInspect(actor, target, _debugToggle(parts[2]));
      case '/forceout':
        if (target != actor) throw const InputException('只能修改自己的出牌规则');
        if (parts.length != 3) throw const InputException('开关指令的参数数量有误');
        _setDebugForce(actor, _debugToggle(parts[2]));
      case '/give':
        _requireDebugDeal(input);
        if (parts.length != 4) {
          throw const InputException('发牌指令的参数数量有误');
        }
        final rank = _debugRanks[parts[2].toUpperCase()];
        final amount = int.tryParse(parts[3]);
        if (rank == null || amount == null || amount < 1 || amount > 64) {
          throw const InputException('请输入有效牌面和数量，每次可发 1 至 64 张');
        }
        _addDebugCards(target, List.filled(amount, rank));
      case '/add':
        _requireDebugDeal(input);
        _addDebugCards(target, _parseDebugRanks(parts.skip(2).join()));
      case '/giveout':
        if (target != actor) throw const InputException('只能替自己的座位出牌');
        _requireDebugDeal(input);
        _playDebugCards(actor, input, _parseDebugRanks(parts.skip(2).join()));
      default:
        throw const InputException('未知调试指令');
    }
  }

  void _debugGuiAction(_Person actor, RoomJson input) {
    requireHost(actor);
    if (!actor._debugGui) throw const InputException('Cheats 面板已关闭');
    final operation = input['op'];
    if (operation == 'hide') {
      _setDebugGui(actor, false);
      return;
    }
    final target = people
        .where((person) => person.id == input['seat'])
        .firstOrNull;
    if (target == null) throw const InputException('该座位没有玩家');
    if (operation == 'select') {
      actor._debugTarget = target.id;
      return;
    }
    if (target.id != actor._debugTarget) {
      throw const InputException('所选座位已变化');
    }
    switch (operation) {
      case 'inspect':
        final enabled = input['enabled'];
        if (enabled is! bool) throw const InputException('开关参数无效');
        _setDebugInspect(actor, target, enabled);
      case 'force':
        if (target != actor) throw const InputException('只能修改自己的出牌规则');
        final enabled = input['enabled'];
        if (enabled is! bool) throw const InputException('开关参数无效');
        _setDebugForce(actor, enabled);
      case 'add':
        _requireDebugDeal(input);
        _addDebugCards(target, _parseDebugRanks(input['cards']));
      case 'play':
        if (target != actor) throw const InputException('只能替自己的座位出牌');
        _requireDebugDeal(input);
        _playDebugCards(actor, input, _parseDebugRanks(input['cards']));
      default:
        throw const InputException('未知 Cheats 操作');
    }
  }

  void _setDebugGui(_Person actor, bool enabled) {
    actor._debugGui = enabled;
    if (!enabled) actor._debugTarget = null;
  }

  void _setDebugInspect(_Person actor, _Person target, bool enabled) {
    if (enabled) {
      actor._inspectSeats.add(target.id);
    } else {
      actor._inspectSeats.remove(target.id);
    }
  }

  void _setDebugForce(_Person actor, bool enabled) {
    if (actor._forceOut != enabled && current == actor) turnVersion++;
    actor._forceOut = enabled;
  }

  List<int> _parseDebugRanks(Object? input) {
    if (input is! String || input.length > 500) {
      throw const InputException('牌面格式无效');
    }
    final sequence = input.replaceAll(RegExp(r'[\s,]+'), '').toUpperCase();
    if (!_debugSequence.hasMatch(sequence)) {
      throw const InputException('牌面格式无效');
    }
    return _debugRankToken
        .allMatches(sequence)
        .map((token) => _debugRanks[token.group(0)]!)
        .toList();
  }

  void _addDebugCards(_Person target, List<int> ranks) {
    if (target.cards.length + ranks.length > 256) {
      throw const InputException('目标座位最多保留 256 张手牌');
    }
    target.cards.addAll(ranks.map((rank) => _debugCard(rank, _debugSerial++)));
    target.cards.sort(PlayingCard.compare);
    turnVersion++;
  }

  void _playDebugCards(_Person actor, RoomJson input, List<int> ranks) {
    _requireTurn(actor, input, _Phase.playing);
    final available = [...actor.cards];
    var serial = _debugSerial;
    final cards = <PlayingCard>[];
    for (final rank in ranks) {
      final index = available.indexWhere((card) => card.rank == rank);
      cards.add(
        index < 0 ? _debugCard(rank, serial++) : available.removeAt(index),
      );
    }
    final matches = cardPlays(cards, wild, rules: rules);
    if (matches.isEmpty) {
      throw InputException(
        disabledCardPlayMessage(cards, wild, rules) ?? '指定的牌面无法组成合法牌型',
      );
    }
    final selected = matches.reduce((a, b) => b.beats(a, rules: rules) ? b : a);
    _debugSerial = serial;
    _play(actor, selected);
  }

  bool _debugToggle(String value) {
    return switch (value.toLowerCase()) {
      'on' => true,
      'off' => false,
      _ => throw const InputException('开关参数无效'),
    };
  }

  void _debugRemove(_Person actor, RoomJson input) {
    requireHost(actor);
    _requireDebugDeal(input);
    final target = people
        .where((person) => person.id == input['seat'])
        .firstOrNull;
    if (target == null ||
        (!actor._inspectSeats.contains(target.id) &&
            target != _debugFocused(actor))) {
      throw const InputException('请先打开该座位的手牌');
    }
    final raw = input['cards'] ?? [input['card']];
    if (raw is! List || raw.isEmpty || raw.any((id) => id is! int)) {
      throw const InputException('请选择要删除的牌');
    }
    final ids = raw.cast<int>().toSet();
    final available = target.cards.map((card) => card.id).toSet();
    if (!available.containsAll(ids)) {
      throw const InputException('所选手牌已变化，请重新选择');
    }
    if (target.cards.length <= ids.length) {
      throw const InputException('每个座位至少保留一张手牌');
    }
    target.cards.removeWhere((card) => ids.contains(card.id));
    turnVersion++;
  }
}
