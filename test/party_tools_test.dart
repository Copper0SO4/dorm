import 'dart:math';

import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/party_tools.dart';
import 'package:dormos/domain/preferences.dart';
import 'package:dormos/ui/common.dart';
import 'package:dormos/ui/tools/number_bomb_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final invalid = throwsA(isA<InputException>());

  test('pickRandomOption ignores blanks and rejects empty lists', () {
    expect(() => pickRandomOption(['  ', ''], Random(1)), invalid);
    final chosen = pickRandomOption([' 米饭 ', '', '面条'], Random(7));
    expect(['米饭', '面条'], contains(chosen));
  });

  test('penalty options retain order and round-trip through preferences', () {
    final options = parsePenaltyOptions(' 跑腿 \r\n\r\n清唱\r\n跑腿\n');
    expect(options, ['跑腿', '清唱']);
    final preferences = const DormPreferences().copyWith(
      penaltyOptions: options,
    );
    expect(
      DormPreferences.fromValues(preferences.toValues()).penaltyOptions,
      options,
    );
    expect(DormPreferences.fromValues({}).penaltyOptions, penaltyPresets);
  });

  testWidgets('number bomb draws from the edited penalty list', (tester) async {
    final repository = SqliteDormRepository.open(':memory:');
    addTearDown(repository.close);
    final controller = DormController(repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NumberBombCard(panelWidth: 416, controller: controller),
        ),
      ),
    );

    await tester.tap(find.text('编辑惩罚'));
    await tester.pumpAndSettle();
    final editor = find.byType(TextFormField);
    await tester.enterText(editor, '  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请至少填写一项惩罚'), findsOneWidget);

    await tester.enterText(editor, ' 测试惩罚 \n\n测试惩罚');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.preferences.penaltyOptions, ['测试惩罚']);

    final safeRange = find.textContaining(RegExp(r'^\d+  ~  \d+$'));
    final draw = find.text('抽个轻惩罚');
    for (var attempt = 0; attempt < 7 && draw.evaluate().isEmpty; attempt++) {
      final bounds = tester
          .widget<Text>(safeRange)
          .data!
          .split('  ~  ')
          .map(int.parse)
          .toList();
      await tester.enterText(
        find.byType(TextField),
        ((bounds.first + bounds.last) ~/ 2).toString(),
      );
      await tester.tap(find.text('报数'));
      await tester.pumpAndSettle();
    }
    await tester.tap(draw);
    await tester.pumpAndSettle();
    expect(find.text('本局惩罚：测试惩罚'), findsOneWidget);

    await tester.tap(find.text('编辑惩罚'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(repository.preferences.penaltyOptions, penaltyPresets);
    expect(find.text('本局惩罚：测试惩罚'), findsOneWidget);
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
