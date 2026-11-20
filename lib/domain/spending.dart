import 'models.dart';

typedef MonthSpending = ({
  DateTime month,
  int shared,
  int personal,
  int outstanding,
  int billCount,
  Map<String, int> advanced,
});

MonthSpending monthlySpending(Iterable<Bill> bills, DateTime month) {
  var shared = 0;
  var personal = 0;
  var outstanding = 0;
  var billCount = 0;
  final advanced = <String, int>{};
  for (final bill in bills) {
    final created = DateTime.tryParse(bill.createdAt)?.toLocal();
    if (created?.year != month.year || created?.month != month.month) continue;
    shared += bill.total - bill.personalAmount;
    personal += bill.personalAmount;
    outstanding += bill.outstanding;
    billCount++;
    advanced.update(
      bill.payer,
      (value) => value + bill.total,
      ifAbsent: () => bill.total,
    );
  }
  return (
    month: month,
    shared: shared,
    personal: personal,
    outstanding: outstanding,
    billCount: billCount,
    advanced: advanced,
  );
}
