import 'package:material_ui/material_ui.dart';

import '../domain/ledger.dart';
import '../domain/models.dart';
import 'common.dart';
import 'members_dialog.dart';

class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  var _showBalances = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final bills = controller.repository.bills();
      final haveMembers = controller.repository.members().any(
        (member) => member.active,
      );
      final total = bills.fold(0, (sum, bill) => sum + bill.total);
      final outstanding = bills.fold(0, (sum, bill) => sum + bill.outstanding);
      return PageBody(
        storageKey: 'ledger',
        children: [
          PageHeading(
            '公共账本',
            '查看共同支出、成员分摊和转账进度。',
            actions: [
              OutlinedButton.icon(
                onPressed: () => showMembers(context, controller),
                icon: const Icon(Icons.group_outlined),
                label: const Text('寝室成员'),
              ),
              FilledButton.icon(
                onPressed: () => editBill(context, controller),
                icon: const Icon(Icons.add),
                label: const Text('新建账单'),
              ),
            ],
          ),
          _LedgerSummary(
            total: total,
            outstanding: outstanding,
            billCount: bills.length,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('账单历史')),
                  ButtonSegment(value: true, label: Text('成员汇总')),
                ],
                selected: {_showBalances},
                onSelectionChanged: (selection) =>
                    setState(() => _showBalances = selection.single),
              ),
            ),
          ),
          if (_showBalances)
            _Balances(items: controller.repository.balances())
          else if (bills.isEmpty)
            EmptyPanel(
              icon: Icons.receipt_long_outlined,
              title: '还没有公共账单',
              detail: haveMembers
                  ? '记下第一笔共同开销，DormOS 会算出各成员的分摊。'
                  : '先添加寝室成员，再开始记录共同开销。',
              action: TextButton.icon(
                onPressed: haveMembers
                    ? () => editBill(context, controller)
                    : () => showMembers(context, controller),
                icon: const Icon(Icons.arrow_forward),
                label: Text(haveMembers ? '记录开销' : '管理成员'),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) => BillList(
                items: bills,
                onOpen: (bill) => showBill(context, controller, bill.id),
                useTable: constraints.maxWidth >= 690,
              ),
            ),
        ],
      );
    },
  );
}

class _LedgerSummary extends StatelessWidget {
  const _LedgerSummary({
    required this.total,
    required this.outstanding,
    required this.billCount,
  });

  final int total;
  final int outstanding;
  final int billCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const ink = Color(0xfff1f8ed);
    final info = Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '累计公共支出',
            style: TextStyle(
              color: Color(0xffc5dece),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            formatCents(total),
            style: theme.textTheme.displaySmall?.copyWith(
              color: ink,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.4,
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              _SummaryItem(
                Icons.pending_actions_outlined,
                '未结清 ${formatCents(outstanding)}',
              ),
              _SummaryItem(Icons.receipt_long_outlined, '$billCount 笔账单'),
            ],
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff173d32), Color(0xff326654)],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (constraints.maxWidth >= 540)
                Positioned(
                  right: 30,
                  top: 18,
                  bottom: 18,
                  child: SizedBox(
                    width: 148,
                    child: Center(
                      child: Container(
                        width: 124,
                        height: 124,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xff769683)),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.account_balance_wallet_outlined,
                            color: Color(0xffc7e5bd),
                            size: 50,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              SizedBox(width: double.infinity, child: info),
            ],
          );
        },
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 17, color: const Color(0xffc7e5bd)),
      const SizedBox(width: 7),
      Flexible(
        child: Text(text, style: const TextStyle(color: Color(0xfff1f8ed))),
      ),
    ],
  );
}

class BillList extends StatelessWidget {
  const BillList({
    super.key,
    required this.items,
    required this.onOpen,
    this.useTable = false,
  });

  final List<Bill> items;
  final ValueChanged<Bill> onOpen;
  final bool useTable;

  @override
  Widget build(BuildContext context) {
    if (!useTable) {
      return Column(
        spacing: 9,
        children: [
          for (final bill in items)
            Card(
              child: ListTile(
                leading: const IconTile(Icons.receipt_outlined),
                title: Text(
                  bill.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${bill.payer} 垫付 · ${localTime(context, bill.createdAt)}\n${_billStatus(bill)}',
                ),
                trailing: Text(
                  formatCents(bill.total),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => onOpen(bill),
              ),
            ),
        ],
      );
    }
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ColoredBox(
            color: theme.colorScheme.surfaceContainerHigh,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: _BillRow(['账单名称', '付款人', '日期', '金额', '结算状态']),
            ),
          ),
          for (final bill in items) ...[
            InkWell(
              onTap: () => onOpen(bill),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: _BillRow([
                  bill.title,
                  bill.payer,
                  localTime(context, bill.createdAt),
                  formatCents(bill.total),
                  _billStatus(bill),
                ]),
              ),
            ),
            if (bill != items.last) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

String _billStatus(Bill bill) =>
    bill.outstanding == 0 ? '已结清' : '待收 ${formatCents(bill.outstanding)}';

class _BillRow extends StatelessWidget {
  const _BillRow(this.columns);

  final List<String> columns;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 8,
    children: [
      for (var index = 0; index < columns.length; index++)
        Expanded(
          flex: const [4, 2, 3, 2, 3][index],
          child: Text(
            columns[index],
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            style: TextStyle(
              fontWeight: index == 0 || index == 3
                  ? FontWeight.w700
                  : FontWeight.normal,
            ),
          ),
        ),
      const Icon(Icons.chevron_right, size: 17),
    ],
  );
}

class _Balances extends StatelessWidget {
  const _Balances({required this.items});

  final List<Balance> items;

  @override
  Widget build(BuildContext context) => items.isEmpty
      ? const EmptyPanel(
          icon: Icons.group_outlined,
          title: '还没有成员数据',
          detail: '添加成员后即可查看应收和应付。',
        )
      : Column(
          spacing: 9,
          children: [
            for (final item in items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 26,
                        runSpacing: 8,
                        children: [
                          Text('累计应收 ${formatCents(item.receivable)}'),
                          Text('累计应付 ${formatCents(item.payable)}'),
                          Text('未收 ${formatCents(item.openReceivable)}'),
                          Text('未付 ${formatCents(item.openPayable)}'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
}

Future<void> editBill(
  BuildContext context,
  DormController controller, {
  Supply? supply,
}) async {
  final members = controller.repository
      .members()
      .where((member) => member.active)
      .toList();
  if (members.isEmpty) {
    notify(context, '请先在公共账本或卫生排班中添加寝室成员。');
    await showMembers(context, controller);
    return;
  }
  var title = supply == null ? '' : '采购 ${supply.name}';
  if (title.runes.length > 80) {
    title = String.fromCharCodes(title.runes.take(80));
  }
  var amount = '';
  var payer = members.first.id;
  final participants = members.map((member) => member.id).toSet();
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: supply == null ? '新建账单' : '记录采购账单',
      action: '写入总账',
      fields: StatefulBuilder(
        builder: (context, update) {
          final cents = parseCents(amount);
          final preview = cents != null && cents > 0 && participants.isNotEmpty
              ? splitEvenly(cents, participants)
              : <int, int>{};
          return fieldColumn([
            if (supply != null) Text('关联物资 · ${supply.name}'),
            textField('账单名称', title, (value) => title = value, autofocus: true),
            _amountField(
              '账单金额（元）',
              '',
              (value) => update(() => amount = value),
            ),
            DropdownButtonFormField<int>(
              decoration: const InputDecoration(labelText: '付款人'),
              initialValue: payer,
              isExpanded: true,
              items: [
                for (final person in members)
                  DropdownMenuItem(
                    value: person.id,
                    child: Text(person.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => update(() => payer = value!),
            ),
            const Text('参与成员', style: TextStyle(fontWeight: FontWeight.w700)),
            Wrap(
              spacing: 7,
              runSpacing: 4,
              children: [
                for (final member in members)
                  FilterChip(
                    label: Text(member.name),
                    selected: participants.contains(member.id),
                    onSelected: (selected) => update(() {
                      if (selected) {
                        participants.add(member.id);
                      } else {
                        participants.remove(member.id);
                      }
                    }),
                  ),
              ],
            ),
            if (preview.isNotEmpty)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 6,
                    children: [
                      const Text(
                        '分摊预览',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      for (final member in members.where(
                        (member) => preview.containsKey(member.id),
                      ))
                        Text(
                          '${member.name}承担 ${formatCents(preview[member.id]!)} · ${member.id == payer || preview[member.id] == 0 ? '无须转账' : '转给 ${members.firstWhere((person) => person.id == payer).name}'}',
                        ),
                    ],
                  ),
                ),
              ),
          ]);
        },
      ),
      onSave: () => controller.write(
        () => controller.repository.addBill((
          title: title,
          total: parseCents(amount)!,
          payerId: payer,
          participantIds: participants.toList(),
          supplyId: supply?.id,
        )),
      ),
    ),
  );
  if (saved == true && context.mounted) notify(context, '已写入公共总账');
}

Widget _amountField(
  String label,
  String initial,
  ValueChanged<String> onChanged, {
  int? maximum,
}) => TextFormField(
  initialValue: initial,
  onChanged: onChanged,
  decoration: InputDecoration(labelText: label, prefixText: '¥ '),
  keyboardType: const TextInputType.numberWithOptions(decimal: true),
  validator: (value) {
    final cents = parseCents(value ?? '');
    if (cents == null || cents == 0) return '请输入有效金额，最多两位小数';
    if (maximum != null && cents > maximum) return '金额超过未结清金额';
    return null;
  },
);

Future<void> showBill(
  BuildContext context,
  DormController controller,
  int id,
) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final detail = controller.repository.billDetail(id);
      final bill = detail.bill;
      return AlertDialog(
        scrollable: true,
        title: Text(bill.title),
        content: SizedBox(
          width: 545,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 9,
            children: [
              Text(
                formatCents(bill.total),
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text('${bill.payer} 垫付 · ${localTime(context, bill.createdAt)}'),
              Text(
                _billStatus(bill),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (bill.supplyName != null) Text('关联物资 · ${bill.supplyName}'),
              const SectionHeading('成员分摊'),
              for (final share in detail.shares)
                _ShareLine(bill: bill, share: share, controller: controller),
              const SectionHeading('实际转账'),
              if (detail.transfers.isEmpty)
                const Text('暂无转账记录。')
              else
                for (final transfer in detail.transfers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${transfer.member} → ${bill.payer}'),
                    subtitle: Text(localTime(context, transfer.createdAt)),
                    trailing: Text(formatCents(transfer.amount)),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  ),
);

class _ShareLine extends StatelessWidget {
  const _ShareLine({
    required this.bill,
    required this.share,
    required this.controller,
  });

  final Bill bill;
  final Share share;
  final DormController controller;

  @override
  Widget build(BuildContext context) {
    final own = share.memberId == bill.payerId;
    final left = own ? 0 : share.amount - share.paid;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${share.member}承担 ${formatCents(share.amount)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          own
              ? '已直接垫付'
              : left == 0
              ? '已结清'
              : '待转给 ${bill.payer} ${formatCents(left)}',
        ),
        if (left > 0)
          TextButton(
            onPressed: () => _record(context, left),
            child: const Text('登记转账'),
          ),
      ],
    );
  }

  Future<void> _record(BuildContext context, int left) async {
    final initial = formatCents(left).substring(1);
    var amount = initial;
    await showDialog<bool>(
      context: context,
      builder: (context) => EditorDialog(
        title: '登记转账',
        action: '确认登记',
        fields: fieldColumn([
          Text('${share.member} → ${bill.payer} · 未结清 ${formatCents(left)}'),
          _amountField(
            '实际转账（元）',
            initial,
            (value) => amount = value,
            maximum: left,
          ),
        ]),
        onSave: () => controller.write(
          () => controller.repository.recordTransfer(
            bill.id,
            share.memberId,
            parseCents(amount)!,
          ),
        ),
      ),
    );
  }
}
