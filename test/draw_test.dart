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
}
