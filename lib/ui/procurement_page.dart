import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models.dart';
import '../domain/preferences.dart';
import '../domain/procurement.dart';
import 'common.dart';
import 'ledger_page.dart';

class ProcurementPage extends StatelessWidget {
  const ProcurementPage({super.key, required this.controller});
  final DormController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('采购清单')),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final repository = controller.repository;
          final preferences = repository.preferences;
          final items = repository.supplies();
          final pending =
              items.where((item) => needsPurchase(item, preferences)).toList()
                ..sort((a, b) => a.quantity.compareTo(b.quantity));
          final ordered = items
              .where((item) => item.status == PurchaseStatus.ordered)
              .toList();
          return PageBody(
            storageKey: 'procurement',
            children: [
              PageHeading(
                '公共采购',
                preferences.stockAlerts
                    ? '列出待采购物资、低库存物资（不高于 ${preferences.stockThreshold} 件）及采购中物资。'
                    : '列出已标记待采购或采购中的物资。',
                actions: [
                  OutlinedButton.icon(
                    onPressed: pending.isEmpty
                        ? null
                        : () => _copy(context, pending),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('复制待采购清单'),
                  ),
                ],
              ),
              if (pending.isEmpty && ordered.isEmpty)
                const EmptyPanel(
                  icon: Icons.shopping_cart_outlined,
                  title: '暂无待采购物资',
                  detail: '可在物资详情将采购状态改为待采购。',
                )
              else ...[
                SectionHeading('待采购', trailing: Text('${pending.length} 项')),
                _items(pending, isOrdered: false),
                SectionHeading('采购中', trailing: Text('${ordered.length} 项')),
                _items(ordered, isOrdered: true),
              ],
            ],
          );
        },
      ),
    ),
  );

  Widget _items(List<Supply> items, {required bool isOrdered}) => items.isEmpty
      ? const Card(child: ListTile(title: Text('没有物资')))
      : Column(
          spacing: 8,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const IconTile(Icons.inventory_2_outlined),
                        title: Text(item.name),
                        subtitle: Text(
                          '${item.category} · 库存 ${item.quantity}',
                        ),
                      ),
                      Builder(
                        builder: (context) => Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (!isOrdered)
                              OutlinedButton(
                                onPressed: () => perform(
                                  context,
                                  controller,
                                  () => controller.repository.markSupplyOrdered(
                                    item.id,
                                  ),
                                  '已标记采购中',
                                ),
                                child: const Text('标记采购中'),
                              ),
                            TextButton(
                              onPressed: () => editBill(
                                context,
                                controller,
                                supply: item,
                                markSupplyOrdered: true,
                              ),
                              child: const Text('记录采购'),
                            ),
                            FilledButton.tonal(
                              onPressed: () => _receive(context, item),
                              child: const Text('补货入库'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );

  Future<void> _copy(BuildContext context, List<Supply> pending) async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: [
            'Dorm 待采购清单',
            for (final item in pending)
              '□ ${item.name} · 当前库存 ${item.quantity}',
          ].join('\n'),
        ),
      );
      if (context.mounted) notify(context, '已复制采购清单');
    } catch (_) {
      if (context.mounted) notify(context, '无法复制采购清单');
    }
  }

  Future<void> _receive(BuildContext context, Supply item) async {
    var input = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => EditorDialog(
        title: '补货入库',
        action: '确认入库',
        fields: fieldColumn([
          Text('${item.name} · 当前库存 ${item.quantity}'),
          TextFormField(
            decoration: const InputDecoration(labelText: '本次入库数量'),
            autofocus: true,
            keyboardType: TextInputType.number,
            onChanged: (value) => input = value.trim(),
            validator: (value) {
              final units = int.tryParse((value ?? '').trim());
              if (units == null || units < 1 || units > maxStockQuantity) {
                return '请输入 1 至 999999 的整数';
              }
              return null;
            },
          ),
        ]),
        onSave: () => controller.write(
          () => controller.repository.receiveSupply(item.id, int.parse(input)),
        ),
      ),
    );
    if (saved == true && context.mounted) notify(context, '已增加库存并更新采购状态');
  }
}
