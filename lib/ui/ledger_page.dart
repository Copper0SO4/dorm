import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/ledger.dart';
import '../domain/ledger_export.dart';
import '../domain/models.dart';
import 'common.dart';
import 'data_exports.dart';
import 'members_dialog.dart';
import 'settlement_page.dart';

class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  var _showBalances = false;
  var _onlyUnsettled = false;
  var _thisMonth = false;
  var _exporting = false;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Bill> _filtered(List<Bill> bills) {
    final query = _search.text.trim().toLowerCase();
    final now = DateTime.now();
    return bills.where((bill) {
      if (_onlyUnsettled && bill.outstanding == 0) return false;
      if (_thisMonth) {
        final date = DateTime.tryParse(bill.createdAt)?.toLocal();
        if (date?.year != now.year || date?.month != now.month) return false;
      }
      return query.isEmpty ||
          [
            bill.title,
            bill.payer,
            bill.supplyName ?? '',
          ].any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  void _clearFilters() => setState(() {
    _search.clear();
    _onlyUnsettled = false;
    _thisMonth = false;
  });

  Future<void> _export(List<Bill> bills) async {
    setState(() => _exporting = true);
    try {
      await exportBills(context, bills);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _historyTools(List<Bill> visible, int total) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: '搜索账单',
            hintText: '账单名称、付款人或关联物资',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            FilterChip(
              label: const Text('仅待结清'),
              selected: _onlyUnsettled,
              onSelected: (value) => setState(() => _onlyUnsettled = value),
            ),
            FilterChip(
              label: const Text('本月'),
              selected: _thisMonth,
              onSelected: (value) => setState(() => _thisMonth = value),
            ),
            if (visible.length != total) Text('${visible.length} / $total 笔'),
            TextButton.icon(
              onPressed: !(_exporting || visible.isEmpty)
                  ? () => _export(visible)
                  : null,
              icon: const Icon(Icons.download_outlined),
              label: const Text('导出当前结果'),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final bills = controller.repository.bills();
      final visible = _showBalances ? bills : _filtered(bills);
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
            '查看公共费用、个人费用和转账进度。',
            actions: [
              OutlinedButton.icon(
                onPressed: () => showMembers(context, controller),
                icon: const Icon(Icons.group_outlined),
                label: const Text('寝室成员'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SettlementPage(controller: controller),
                  ),
                ),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('结算中心'),
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
                  ? '记下第一笔共同开销，Dorm 会算出各成员的分摊。'
                  : '先添加寝室成员，再开始记录共同开销。',
              action: TextButton.icon(
                onPressed: haveMembers
                    ? () => editBill(context, controller)
                    : () => showMembers(context, controller),
                icon: const Icon(Icons.arrow_forward),
                label: Text(haveMembers ? '记录开销' : '管理成员'),
              ),
            )
          else ...[
            _historyTools(visible, bills.length),
            if (visible.isEmpty)
              EmptyPanel(
                icon: Icons.search_off_outlined,
                title: '没有匹配的账单',
                detail: '试试修改关键词或筛选条件。',
                action: TextButton(
                  onPressed: _clearFilters,
                  child: const Text('清除筛选'),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) => BillList(
                  items: visible,
                  onOpen: (bill) => showBill(context, controller, bill.id),
                  useTable: constraints.maxWidth >= 690,
                ),
              ),
          ],
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
            '累计账单金额',
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
  final personalInputs = <int, String>{};
  var showPersonal = false;

  int? sharedAmount() => amount.trim().isEmpty ? 0 : parseCents(amount);
  Map<int, int> personalAmounts() => {
    for (final entry in personalInputs.entries)
      entry.key: parseCents(entry.value) ?? 0,
  };

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: supply == null ? '新建账单' : '记录采购账单',
      action: '写入总账',
      fields: StatefulBuilder(
        builder: (context, update) {
          final personal = personalAmounts();
          final payerName = members
              .firstWhere((person) => person.id == payer)
              .name;
          ({int total, Map<int, int> shares})? preview;
          if (sharedAmount() case final cents?) {
            try {
              preview = allocateBill(cents, participants, personal);
            } on InputException {
              // Incomplete amounts are validated when the form is saved.
            }
          }
          return fieldColumn([
            if (supply != null) Text('关联物资 · ${supply.name}'),
            textField('账单名称', title, (value) => title = value, autofocus: true),
            _amountField(
              '公共费用（元）',
              '',
              (value) => update(() => amount = value),
              allowZero: true,
              helperText: '只记个人费用时可留空',
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
            const Text(
              '公共费用参与成员',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
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
            if (!showPersonal)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => update(() => showPersonal = true),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('添加个人费用'),
                ),
              )
            else ...[
              const Text('个人费用', style: TextStyle(fontWeight: FontWeight.w700)),
              const Text('选择成员后填写金额，该笔费用由该成员全额承担。'),
              Wrap(
                spacing: 7,
                runSpacing: 4,
                children: [
                  for (final member in members)
                    FilterChip(
                      key: ValueKey('personal-member-${member.id}'),
                      label: Text(member.name),
                      selected: personalInputs.containsKey(member.id),
                      onSelected: (selected) => update(() {
                        if (selected) {
                          personalInputs[member.id] = '';
                        } else {
                          personalInputs.remove(member.id);
                        }
                      }),
                    ),
                ],
              ),
              for (final member in members.where(
                (member) => personalInputs.containsKey(member.id),
              ))
                _amountField(
                  '${member.name}的个人费用（元）',
                  personalInputs[member.id]!,
                  (value) => update(() => personalInputs[member.id] = value),
                  key: ValueKey('personal-amount-${member.id}'),
                ),
            ],
            if (preview case final allocation?)
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
                      Text('账单合计 ${formatCents(allocation.total)}'),
                      for (final member in members)
                        if (allocation.shares[member.id] case final share?) ...[
                          Text(
                            '${member.name}承担 ${formatCents(share)} · ${member.id == payer || share == 0 ? '无须转账' : '转给 $payerName'}',
                          ),
                          if (personal[member.id] case final amount?)
                            Text(_shareBreakdown(share, amount)),
                        ],
                    ],
                  ),
                ),
              ),
          ]);
        },
      ),
      onSave: () => controller.write(
        () => controller.repository.addBill(
          BillDraft(
            title: title,
            sharedAmount: sharedAmount()!,
            payerId: payer,
            participantIds: participants.toList(),
            personalAmounts: personalAmounts(),
            supplyId: supply?.id,
          ),
        ),
      ),
    ),
  );
  if (saved == true && context.mounted) notify(context, '已写入公共总账');
}

Widget _amountField(
  String label,
  String initial,
  ValueChanged<String> onChanged, {
  Key? key,
  int? maximum,
  bool allowZero = false,
  String? helperText,
}) => TextFormField(
  key: key,
  initialValue: initial,
  onChanged: onChanged,
  decoration: InputDecoration(
    labelText: label,
    prefixText: '¥ ',
    helperText: helperText,
  ),
  keyboardType: const TextInputType.numberWithOptions(decimal: true),
  validator: (value) {
    final input = value?.trim() ?? '';
    if (allowZero && input.isEmpty) return null;
    final cents = parseCents(input);
    if (cents == null || (!allowZero && cents == 0)) {
      return '请输入有效金额，最多两位小数';
    }
    if (maximum != null && cents > maximum) return '金额超过未结清金额';
    return null;
  },
);

String _shareBreakdown(int total, int personal) =>
    '公共分摊 ${formatCents(total - personal)} · 个人费用 ${formatCents(personal)}';

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
              if (detail.shares.any((share) => share.personalAmount > 0))
                Text(
                  _shareBreakdown(
                    bill.total,
                    detail.shares.fold(
                      0,
                      (sum, share) => sum + share.personalAmount,
                    ),
                  ),
                ),
              const SectionHeading('成员应付'),
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
          if (bill.outstanding > 0)
            TextButton.icon(
              onPressed: () async {
                try {
                  await Clipboard.setData(
                    ClipboardData(text: settlementSummary(detail)),
                  );
                  if (context.mounted) notify(context, '已复制待付清单');
                } catch (_) {
                  if (context.mounted) notify(context, '复制待付清单失败');
                }
              },
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制待付清单'),
            ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
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
        ),
        if (share.personalAmount > 0)
          Text(_shareBreakdown(share.amount, share.personalAmount)),
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
