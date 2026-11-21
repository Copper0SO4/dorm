import 'dart:math';

import 'package:dormos/domain/draw.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('draws unique options and balances teams of uneven sizes', () {
    final options = drawEntries(' 甲\n乙\n\n甲\n丙\n丁\n戊 ');
    expect(options, ['甲', '乙', '丙', '丁', '戊']);
    final result = makeDraw(options, 3, DrawMode.draw, Random(1)).single;
    expect(result, hasLength(3));
    expect(result.toSet(), hasLength(3));
    expect(result.every(options.contains), isTrue);
    final teams = makeDraw(options, 2, DrawMode.teams, Random(1));
    expect(teams.map((team) => team.length), [3, 2]);
    expect(teams.expand((team) => team), unorderedEquals(options));
    expect(
      () => makeDraw(options, 6, DrawMode.draw, Random(1)),
      throwsA(isA<InputException>()),
    );
  });

  test(
    'deduplicates raw inputs and gives a meaningful low-count group error',
    () {
      expect(
        makeDraw([' 甲', '甲 ', '乙', ''], 2, DrawMode.draw, Random(2)).single,
        unorderedEquals(['甲', '乙']),
      );
      expect(
        () => makeDraw([' 甲', '甲 '], 2, DrawMode.teams, Random(2)),
        throwsA(
          isA<InputException>().having(
            (error) => error.message,
            'message',
            '随机分组至少需要 2 个不同的候选项',
          ),
        ),
      );
    },
  );
}
