import 'package:material_ui/material_ui.dart';

import '../domain/ledger.dart';
import '../domain/spending.dart';
import 'common.dart';

class SpendingPage extends StatefulWidget {
  const SpendingPage({super.key, required this.controller});
  final DormController controller;

  @override
  State<SpendingPage> createState() => _SpendingPageState();
}

class _SpendingPageState extends State<SpendingPage> {
  final _now = DateTime.now();
  int _offset = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('月度账务分析')),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final repository = widget.controller.repository;
          final bills = repository.bills();
          final months = [
            for (var index = 5; index >= 0; index--)
              monthlySpending(
                bills,
                DateTime(_now.year, _now.month + _offset - index),
              ),
          ];
          final month = months.last;
          final advanced = month.advanced.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          return PageBody(
            storageKey: 'spending',
            children: [
              PageHeading(
                '${month.month.year} 年 ${month.month.month} 月',
                '${month.billCount} 笔账单，按账单创建日期统计。',
                actions: [
                  IconButton(
                    tooltip: '上个月',
                    onPressed: _offset > -120
                        ? () => setState(() => _offset--)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: _offset < 0
                        ? () => setState(() => _offset = 0)
                        : null,
                    child: const Text('本月'),
                  ),
                  IconButton(
                    tooltip: '下个月',
                    onPressed: _offset < 0
                        ? () => setState(() => _offset++)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _Metric('公共支出', month.shared),
                  _Metric('个人代付', month.personal),
                  _Metric('账单合计', month.shared + month.personal),
                  _Metric('当前待结清', month.outstanding),
                ],
              ),
              if (_offset == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: _BudgetCard(
                    shared: month.shared,
                    budget: repository.preferences.monthlyBudget,
                  ),
                ),
              const SectionHeading('近六个月支出'),
              _SpendingTrend(months: months),
              const SectionHeading('按付款人查看垫付'),
              Card(
                child: advanced.isEmpty
                    ? const ListTile(title: Text('这个月暂无垫付记录'))
                    : Column(
                        children: [
                          for (final entry in advanced)
                            ListTile(
                              leading: const Icon(Icons.person_outline),
                              title: Text(entry.key),
                              trailing: Text(formatCents(entry.value)),
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.amount);
  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 5,
        children: [
          Text(label),
          Text(
            formatCents(amount),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ],
      ),
    ),
  );
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({required this.shared, required this.budget});
  final int shared;
  final int budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = budget - shared;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text('本月公共预算', style: theme.textTheme.titleMedium),
            if (budget == 0)
              const Text('在「设置 → 账本偏好」中设置预算，即可查看本月进度。')
            else ...[
              Text('已用 ${formatCents(shared)} / ${formatCents(budget)}'),
              LinearProgressIndicator(
                value: (shared / budget).clamp(0.0, 1.0),
                color: remaining < 0
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              Text(
                remaining < 0
                    ? '已超出 ${formatCents(-remaining)}'
                    : '还可使用 ${formatCents(remaining)}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SpendingTrend extends StatelessWidget {
  const _SpendingTrend({required this.months});
  final List<MonthSpending> months;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final max = months.fold(
      1,
      (peak, month) => month.shared + month.personal > peak
          ? month.shared + month.personal
          : peak,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Wrap(
              spacing: 14,
              children: [
                _Legend('公共支出', colors.primary),
                _Legend('个人代付', colors.tertiary),
              ],
            ),
            for (final month in months)
              Row(
                spacing: 9,
                children: [
                  SizedBox(width: 58, child: Text('${month.month.month} 月')),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: ColoredBox(
                          color: colors.surfaceContainerHighest,
                          child: SizedBox(
                            height: 9,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: box.maxWidth * month.shared / max,
                                  child: ColoredBox(color: colors.primary),
                                ),
                                SizedBox(
                                  width: box.maxWidth * month.personal / max,
                                  child: ColoredBox(color: colors.tertiary),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text(formatCents(month.shared + month.personal)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 5,
    children: [
      Icon(Icons.circle, size: 10, color: color),
      Text(label),
    ],
  );
}
