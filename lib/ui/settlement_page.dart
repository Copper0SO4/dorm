import 'package:material_ui/material_ui.dart';

import '../domain/ledger.dart';
import '../domain/settlement.dart';
import 'common.dart';

class SettlementPage extends StatefulWidget {
  const SettlementPage({super.key, required this.controller});
  final DormController controller;

  @override
  State<SettlementPage> createState() => _SettlementPageState();
}

class _SettlementPageState extends State<SettlementPage> {
  var _showHistory = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('结算中心')),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final repository = widget.controller.repository;
          final pairs = _showHistory
              ? const <SettlementPair>[]
              : repository.openSettlements();
          final history = _showHistory
              ? repository.settlementHistory()
              : const <SettlementBatch>[];
          return PageBody(
            storageKey: 'settlement',
            children: [
              PageHeading(
                _showHistory ? '批量结算记录' : '跨账单结算',
                _showHistory
                    ? '展开记录可查看登记金额被分配到哪些账单。'
                    : '选择付款方向和账单，把一笔实际转账分配到多张账单。',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('待结算')),
                    ButtonSegment(value: true, label: Text('结算记录')),
                  ],
                  selected: {_showHistory},
                  onSelectionChanged: (selection) =>
                      setState(() => _showHistory = selection.single),
                ),
              ),
              const SizedBox(height: 16),
              if ((_showHistory ? history : pairs).isEmpty)
                EmptyPanel(
                  icon: Icons.receipt_long_outlined,
                  title: _showHistory ? '还没有批量结算记录' : '当前没有待付金额',
                  detail: _showHistory
                      ? '登记跨账单转账后，记录会显示在这里。'
                      : '账单产生待付款后，可在这里集中登记。',
                )
              else
                Column(
                  spacing: 8,
                  children: [
                    for (final pair in pairs)
                      Card(
                        child: ListTile(
                          leading: const IconTile(Icons.swap_horiz),
                          title: Text('${pair.debtor} → ${pair.payer}'),
                          subtitle: Text('${pair.charges.length} 张账单待结清'),
                          trailing: Text(formatCents(_total(pair.charges))),
                          onTap: () =>
                              _showSettlement(context, widget.controller, pair),
                        ),
                      ),
                    for (final batch in history)
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          key: ValueKey(batch.id),
                          title: Text(
                            '${batch.debtor} → ${batch.payer} · ${formatCents(_total(batch.allocations))}',
                          ),
                          subtitle: Text(
                            '${localTime(context, batch.createdAt)} · ${batch.allocations.length} 张账单',
                          ),
                          children: [
                            for (final item in batch.allocations)
                              ListTile(
                                title: Text(item.title),
                                trailing: Text(formatCents(item.amount)),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    ),
  );
}

int _total(Iterable<OpenCharge> charges) =>
    charges.fold(0, (sum, line) => sum + line.amount);

Future<void> _showSettlement(
  BuildContext context,
  DormController controller,
  SettlementPair pair,
) async {
  final chosen = pair.charges.map((charge) => charge.billId).toSet();
  var partial = false;
  var entered = '';
  List<OpenCharge> selected() =>
      pair.charges.where((charge) => chosen.contains(charge.billId)).toList();
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: '${pair.debtor} → ${pair.payer}',
      action: '确认登记',
      fields: StatefulBuilder(
        builder: (context, update) {
          final charges = selected();
          final total = _total(charges);
          final amount = partial ? parseCents(entered) : total;
          final plan = amount != null && amount > 0 && amount <= total
              ? allocateSettlement(charges, amount)
              : const <int, int>{};
          return fieldColumn([
            const Text('选择要结算的账单。登记金额将按账单时间从早到晚分配。'),
            for (final charge in pair.charges)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(charge.title),
                subtitle: Text(
                  '${localTime(context, charge.createdAt)} · 待付 ${formatCents(charge.amount)}',
                ),
                value: chosen.contains(charge.billId),
                onChanged: (value) => update(() {
                  if (value == true) {
                    chosen.add(charge.billId);
                  } else {
                    chosen.remove(charge.billId);
                  }
                }),
              ),
            Text('所选账单待付 ${formatCents(total)}'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('只登记部分金额'),
              value: partial,
              onChanged: (value) => update(() => partial = value),
            ),
            if (partial)
              TextFormField(
                decoration: const InputDecoration(labelText: '实际转账金额（元）'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: entered,
                onChanged: (value) => update(() => entered = value),
                validator: (_) {
                  final value = parseCents(entered);
                  if (value == null || value <= 0) return '请输入大于零的金额';
                  if (value > total) return '金额超过所选账单待付总额';
                  return null;
                },
              ),
            if (plan.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 5,
                    children: [
                      Text(
                        '登记 ${formatCents(amount!)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      for (final charge in charges)
                        if (plan[charge.billId] case final part?)
                          Text('${charge.title} · ${formatCents(part)}'),
                    ],
                  ),
                ),
              ),
          ]);
        },
      ),
      onSave: () {
        final charges = selected();
        final amount = partial ? parseCents(entered)! : _total(charges);
        controller.write(
          () => controller.repository.recordSettlement(
            pair.debtorId,
            pair.payerId,
            {for (final charge in charges) charge.billId: charge.amount},
            amount,
          ),
        );
      },
    ),
  );
  if (saved == true && context.mounted) notify(context, '已登记批量结算');
}
