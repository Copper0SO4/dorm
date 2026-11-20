import 'ledger.dart';
import 'models.dart';

String billsCsv(Iterable<Bill> bills) {
  final csv = StringBuffer('\uFEFF账单名称,付款人,创建时间,账单金额（元）,未收金额（元）,结算状态,关联物资\r\n');
  for (final bill in bills) {
    csv
      ..write(
        [
          _cell(bill.title),
          _cell(bill.payer),
          _cell(bill.createdAt),
          formatCents(bill.total).substring(1),
          formatCents(bill.outstanding).substring(1),
          bill.outstanding == 0 ? '已结清' : '待结清',
          _cell(bill.supplyName ?? ''),
        ].join(','),
      )
      ..write('\r\n');
  }
  return csv.toString();
}

// Keep user-entered text as text in spreadsheet viewers.
String _cell(String value) {
  final unsafe = RegExp(r'^(?:[\t\r\n]|[\s\uFEFF]*[=+@-])').hasMatch(value);
  final text = unsafe ? "'$value" : value;
  return '"${text.replaceAll('"', '""')}"';
}

String settlementSummary(BillDetail detail) {
  final bill = detail.bill;
  return [
    '${bill.title} · ${bill.payer}垫付 ${formatCents(bill.total)}',
    for (final share in detail.shares)
      if (share.memberId != bill.payerId && share.amount > share.paid)
        '${share.member} → ${bill.payer} ${formatCents(share.amount - share.paid)}',
  ].join('\n');
}
