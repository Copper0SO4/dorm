import 'dart:math';

import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/party_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final invalid = throwsA(isA<InputException>());

  test('pickRandomOption ignores blanks and rejects empty lists', () {
    expect(() => pickRandomOption(['  ', ''], Random(1)), invalid);
    final chosen = pickRandomOption([' 米饭 ', '', '面条'], Random(7));
    expect(['米饭', '面条'], contains(chosen));
  });

  test('NumberBombGame narrows safe bounds until bomb explodes', () {
    final game = NumberBombGame(min: 1, max: 100, random: Random(3));
    final bomb = game.secret;
    expect(bomb, inInclusiveRange(1, 100));

    if (bomb > 1) {
      expect(game.guess(bomb - 1), BombOutcome.tooLow);
      expect(game.low, bomb);
    }
    if (bomb < 100) {
      expect(game.guess(bomb + 1), BombOutcome.tooHigh);
      expect(game.high, bomb);
    }
    expect(() => game.guess(0), invalid);
    expect(game.guess(bomb), BombOutcome.exploded);
    expect(game.exploded, isTrue);
    expect(() => game.guess(bomb), invalid);

    game.reset(min: 1, max: 50);
    expect(
      (game.low, game.high, game.exploded, game.attempts),
      (1, 50, false, 0),
    );
  });
}
