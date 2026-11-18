import 'package:dormos/domain/ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses decimal yuan without floating point', () {
    expect(parseCents('10'), 1000);
    expect(parseCents(' 1.2 '), 120);
    expect(parseCents('0.01'), 1);
    expect(parseCents('9999999.99'), maxAmountCents);
    for (final invalid in ['1.001', '1e3', '-1', '1,00', '10000000.00', '']) {
      expect(parseCents(invalid), isNull, reason: invalid);
    }
    expect(formatCents(-5), '-¥0.05');
  });

  test('allocates 10 yuan among three in a stable order', () {
    expect(splitEvenly(1000, [3, 1, 2]), {1: 334, 2: 333, 3: 333});
    expect(splitEvenly(1, [3, 1, 2]), {1: 1, 2: 0, 3: 0});
  });

  test('preserves the total and limits the difference to one cent', () {
    for (var count = 1; count <= 12; count++) {
      final members = List.generate(count, (index) => index + 1);
      for (var cents = 1; cents <= 125; cents++) {
        final shares = splitEvenly(cents, members).values.toList();
        expect(shares.fold(0, (sum, value) => sum + value), cents);
        expect(shares.first - shares.last, inInclusiveRange(0, 1));
      }
    }
    for (final participants in <List<int>>[
      [],
      [1, 1],
    ]) {
      expect(
        () => splitEvenly(1000, participants),
        throwsA(isA<InputException>()),
      );
    }
    expect(() => splitEvenly(0, [1]), throwsA(isA<InputException>()));
  });
}
