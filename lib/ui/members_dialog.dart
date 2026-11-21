import 'package:material_ui/material_ui.dart';

import '../domain/models.dart';
import 'common.dart';

Future<bool?> showMembers(
  BuildContext context,
  DormController controller, {
  bool continueToBill = false,
}) => showDialog<bool>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final members = controller.repository.members();
      final canContinue =
          continueToBill && members.any((member) => member.active);
      return AlertDialog(
        scrollable: true,
        title: const Text('寝室成员'),
        content: SizedBox(
          width: 450,
          child: members.isEmpty
              ? const Text('添加成员后即可分摊账单和生成排班。')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final member in members)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: IconTile(
                          member.active
                              ? Icons.person_outline
                              : Icons.person_off_outlined,
                        ),
                        title: Text(member.name),
                        subtitle: member.active ? null : const Text('已停用'),
                        trailing: PopupMenuButton<String>(
                          tooltip: '成员操作',
                          onSelected: (action) async {
                            if (action == 'edit') {
                              await _editMember(context, controller, member);
                            } else {
                              try {
                                controller.write(
                                  () => controller.repository.setMemberActive(
                                    member.id,
                                    !member.active,
                                  ),
                                );
                              } catch (error) {
                                if (!context.mounted) return;
                                await showDialog<void>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('成员状态未更新'),
                                    content: Text(errorText(error)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('关闭'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('修改姓名'),
                            ),
                            PopupMenuItem(
                              value: 'status',
                              child: Text(member.active ? '停用成员' : '启用成员'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => _editMember(context, controller, null),
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('添加成员'),
          ),
          if (canContinue)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续记账'),
            ),
        ],
      );
    },
  ),
);

Future<void> _editMember(
  BuildContext context,
  DormController controller,
  Member? member,
) async {
  var name = member?.name ?? '';
  await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: member == null ? '添加成员' : '修改姓名',
      fields: textField(
        '姓名',
        name,
        (value) => name = value,
        limit: 40,
        autofocus: true,
      ),
      onSave: () => controller.write(
        () => controller.repository.saveMember(name, id: member?.id),
      ),
    ),
  );
}
