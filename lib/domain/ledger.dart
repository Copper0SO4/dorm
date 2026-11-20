const maxAmountCents = 999999999;

class InputException implements Exception {
  const InputException(this.message);

  final String message;
}

int? parseCents(String input) {
  final match = RegExp(r'^(\d{1,7})(?:\.(\d{1,2}))?$').firstMatch(input.trim());
  if (match == null) return null;
  final whole = int.parse(match[1]!);
  final cents = int.parse((match[2] ?? '').padRight(2, '0'));
  return whole * 100 + cents;
}

String formatCents(int cents) {
  final absolute = cents.abs();
  final fraction = (absolute % 100).toString().padLeft(2, '0');
  return '${cents < 0 ? '-' : ''}¥${absolute ~/ 100}.$fraction';
}

/// Stable member IDs decide who absorbs the remaining cents.
Map<int, int> splitEvenly(int cents, Iterable<int> participants) {
  if (cents <= 0 || cents > maxAmountCents) {
    throw const InputException('请输入 0.01 至 9999999.99 元之间的金额');
  }
  final ids = participants.toList()..sort();
  if (ids.isEmpty) throw const InputException('至少选择一位参与成员');
  if (ids.toSet().length != ids.length) {
    throw const InputException('参与成员不能重复');
  }
  final base = cents ~/ ids.length;
  final remainder = cents % ids.length;
  return {
    for (var i = 0; i < ids.length; i++) ids[i]: base + (i < remainder ? 1 : 0),
  };
}

/// The payer advances both parts. Each personal cost belongs to one member.
({int total, Map<int, int> shares}) allocateBill(
  int sharedAmount,
  Iterable<int> participants,
  Map<int, int> personalAmounts,
) {
  final shares = sharedAmount == 0
      ? <int, int>{}
      : splitEvenly(sharedAmount, participants);
  var total = sharedAmount;
  for (final entry in personalAmounts.entries) {
    final amount = entry.value;
    if (amount <= 0 || amount > maxAmountCents) {
      throw const InputException('每位成员的个人费用须为 0.01 至 9999999.99 元');
    }
    total += amount;
    if (total > maxAmountCents) {
      throw const InputException('公共费用和个人费用合计不能超过 9999999.99 元');
    }
    shares.update(
      entry.key,
      (shared) => shared + amount,
      ifAbsent: () => amount,
    );
  }
  if (total == 0) throw const InputException('请填写公共费用或个人费用');
  return (total: total, shares: shares);
}
