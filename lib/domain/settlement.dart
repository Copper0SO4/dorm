import 'ledger.dart';

typedef OpenCharge = ({int billId, String title, String createdAt, int amount});

typedef SettlementPair = ({
  int debtorId,
  String debtor,
  int payerId,
  String payer,
  List<OpenCharge> charges,
});

typedef SettlementBatch = ({
  String id,
  String debtor,
  String payer,
  String createdAt,
  List<OpenCharge> allocations,
});

Map<int, int> allocateSettlement(Iterable<OpenCharge> charges, int amount) {
  if (amount <= 0) throw const InputException('登记金额必须大于零');
  final allocations = <int, int>{};
  var remaining = amount;
  for (final charge in charges) {
    final part = remaining < charge.amount ? remaining : charge.amount;
    allocations[charge.billId] = part;
    remaining -= part;
    if (remaining == 0) return allocations;
  }
  throw const InputException('登记金额超过所选账单的待付金额');
}
