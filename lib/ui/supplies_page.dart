import 'package:material_ui/material_ui.dart';

import '../domain/models.dart';
import '../domain/procurement.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'procurement_page.dart';

class SuppliesPage extends StatefulWidget {
  const SuppliesPage({super.key, required this.controller});

  final DormController controller;

  @override
  State<SuppliesPage> createState() => _SuppliesPageState();
}

class _SuppliesPageState extends State<SuppliesPage> {
  var _query = '';
  String? _category;
  PurchaseStatus? _status;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final supplies = controller.repository.supplies();
      final preferences = controller.repository.preferences;
      final categories = supplies.map((item) => item.category).toSet().toList()
        ..sort();
      final category = categories.contains(_category) ? _category : null;
      final filtered = supplies
          .where(
            (item) =>
                (category == null || category == item.category) &&
                (_status == null || _status == item.status) &&
                [
                  item.name,
                  item.category,
                  item.location,
                  item.note,
                ].any((field) => field.toLowerCase().contains(_query)),
          )
          .toList();
      return PageBody(
        storageKey: 'supplies',
        children: [
          PageHeading(
            '公共物资',
            '管理库存、存放位置和公共采购。',
            actions: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ProcurementPage(controller: controller),
                  ),
                ),
                icon: const Icon(Icons.shopping_cart_outlined),
                label: const Text('采购清单'),
              ),
              FilledButton.icon(
                onPressed: () => _editSupply(context, controller),
                icon: const Icon(Icons.add),
                label: const Text('新增物资'),
              ),
            ],
          ),
          if (supplies.isEmpty)
            const EmptyPanel(
              icon: Icons.inventory_2_outlined,
              title: '还没有公共物资',
              detail: '添加清洁用品、工具等公共物品，之后可从物资记录采购开销。',
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    TextField(
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: '搜索物资、位置或备注',
                      ),
                    ),
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DropdownButton<String>(
                          value: category,
                          hint: const Text('全部分类'),
                          items: [
                            const DropdownMenuItem<String>(child: Text('全部分类')),
                            for (final label in categories)
                              DropdownMenuItem(
                                value: label,
                                child: Text(
                                  label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => _category = value),
                        ),
                        for (final status in PurchaseStatus.values)
                          FilterChip(
                            selected: _status == status,
                            label: Text(status.label),
                            onSelected: (selected) => setState(
                              () => _status = selected ? status : null,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SectionHeading('物资清单', trailing: Text('${filtered.length} 项')),
            if (filtered.isEmpty)
              const EmptyPanel(
                icon: Icons.search_off_outlined,
                title: '没有匹配的物资',
                detail: '试试其他关键词或调整筛选条件。',
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth >= 700
                      ? (constraints.maxWidth - 14) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final item in filtered)
                        SizedBox(
                          width: width,
                          child: _SupplyCard(
                            item: item,
                            lowStock: isLowStock(item, preferences),
                            controller: controller,
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        ],
      );
    },
  );
}

class _SupplyCard extends StatelessWidget {
  const _SupplyCard({
    required this.item,
    required this.lowStock,
    required this.controller,
  });

  final Supply item;
  final bool lowStock;
  final DormController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              spacing: 10,
              children: [
                const IconTile(Icons.inventory_2_outlined),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        item.category,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '物资操作',
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑物资')),
                    PopupMenuItem(value: 'delete', child: Text('删除物资')),
                  ],
                  onSelected: (action) async {
                    if (action == 'edit') {
                      await _editSupply(context, controller, item: item);
                    } else if (await confirm(
                          context,
                          '删除物资',
                          '将从物资清单移除「${item.name}」。已关联的采购账单仍可在公共账本中查询。',
                          action: '删除',
                        ) &&
                        context.mounted) {
                      perform(
                        context,
                        controller,
                        () => controller.repository.deleteSupply(item.id),
                        '已删除物资',
                      );
                    }
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 9,
              runSpacing: 7,
              children: [
                _Tag(
                  '库存 ${item.quantity}',
                  background: theme.colorScheme.surfaceContainerHighest,
                  foreground: theme.colorScheme.onSurfaceVariant,
                ),
                if (lowStock)
                  _Tag(
                    '低库存',
                    background: theme.colorScheme.errorContainer,
                    foreground: theme.colorScheme.onErrorContainer,
                  ),
                _Tag(
                  item.status.label,
                  background: item.status == PurchaseStatus.needed
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.secondaryContainer,
                  foreground: item.status == PurchaseStatus.needed
                      ? theme.colorScheme.onTertiaryContainer
                      : theme.colorScheme.onSecondaryContainer,
                ),
              ],
            ),
            Text(item.location.isEmpty ? '未填写存放位置' : '位置 · ${item.location}'),
            if (item.note.isNotEmpty)
              Text(
                item.note,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => editBill(context, controller, supply: item),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('记录采购'),
                ),
                TextButton(
                  onPressed: () => _purchaseHistory(context, controller, item),
                  child: const Text('采购账单'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {required this.background, required this.foreground});

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(
        label,
        style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

Future<void> _purchaseHistory(
  BuildContext context,
  DormController controller,
  Supply item,
) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final bills = controller.repository.bills(supplyId: item.id);
      return AlertDialog(
        scrollable: true,
        title: Text('${item.name}的采购账单'),
        content: SizedBox(
          width: 520,
          child: bills.isEmpty
              ? const Text('这项物资还没有采购账单。')
              : BillList(
                  items: bills,
                  onOpen: (bill) => showBill(context, controller, bill.id),
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

Future<void> _editSupply(
  BuildContext context,
  DormController controller, {
  Supply? item,
}) async {
  var name = item?.name ?? '';
  var category = item?.category ?? '';
  var quantity = '${item?.quantity ?? 0}';
  var location = item?.location ?? '';
  var note = item?.note ?? '';
  var status = item?.status ?? PurchaseStatus.stocked;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: item == null ? '新增公共物资' : '编辑公共物资',
      fields: fieldColumn([
        textField('名称', name, (value) => name = value, autofocus: true),
        textField('分类标签', category, (value) => category = value, limit: 40),
        TextFormField(
          initialValue: quantity,
          decoration: const InputDecoration(labelText: '数量'),
          keyboardType: TextInputType.number,
          onChanged: (value) => quantity = value,
          validator: (value) =>
              RegExp(r'^\d{1,6}$').hasMatch((value ?? '').trim())
              ? null
              : '请输入 0 到 999999 之间的整数',
        ),
        textField(
          '存放位置',
          location,
          (value) => location = value,
          required: false,
        ),
        DropdownButtonFormField<PurchaseStatus>(
          initialValue: status,
          decoration: const InputDecoration(labelText: '采购状态'),
          items: [
            for (final option in PurchaseStatus.values)
              DropdownMenuItem(value: option, child: Text(option.label)),
          ],
          onChanged: (value) => status = value!,
        ),
        textField(
          '备注',
          note,
          (value) => note = value,
          required: false,
          limit: 500,
          maxLines: 3,
        ),
      ]),
      onSave: () => controller.write(
        () => controller.repository.saveSupply((
          name: name,
          category: category,
          quantity: int.parse(quantity.trim()),
          location: location,
          note: note,
          status: status,
        ), id: item?.id),
      ),
    ),
  );
  if (saved == true && context.mounted) {
    notify(context, item == null ? '已新增物资' : '已更新物资');
  }
}
