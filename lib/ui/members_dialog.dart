import 'package:material_ui/material_ui.dart';

import '../domain/ledger.dart';
import '../domain/models.dart';
import 'common.dart';
import 'member_identity.dart';

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
                        leading: MemberAvatar(
                          name: member.name,
                          avatar: member.avatar,
                        ),
                        title: Text(member.name),
                        subtitle: member.active ? null : const Text('已停用'),
                        trailing: PopupMenuButton<String>(
                          tooltip: '成员操作',
                          onSelected: (action) async {
                            if (action == 'edit') {
                              await editMember(context, controller, member);
                            } else if (action == 'activity') {
                              await showMemberActivity(
                                context,
                                controller,
                                member,
                              );
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
                              child: Text('编辑资料'),
                            ),
                            const PopupMenuItem(
                              value: 'activity',
                              child: Text('修改日志'),
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
            onPressed: () => editMember(context, controller, null),
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

Future<void> editMember(
  BuildContext context,
  DormController controller,
  Member? member,
) async {
  var name = member?.name ?? '';
  var avatar = member?.avatar;
  var avatarChanged = false;
  var picking = false;
  await showDialog<bool>(
    context: context,
    builder: (context) => EditorDialog(
      title: member == null ? '添加成员' : '编辑成员资料',
      fields: StatefulBuilder(
        builder: (context, update) => fieldColumn([
          Row(
            spacing: 12,
            children: [
              MemberAvatar(name: name, avatar: avatar, radius: 30),
              Expanded(
                child: Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: picking
                          ? null
                          : () async {
                              update(() => picking = true);
                              try {
                                final image = await pickAvatar();
                                if (image != null && context.mounted) {
                                  update(() {
                                    avatar = image;
                                    avatarChanged = true;
                                  });
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  notify(
                                    context,
                                    errorText(error, fallback: '无法打开头像图片'),
                                  );
                                }
                              } finally {
                                if (context.mounted) {
                                  update(() => picking = false);
                                }
                              }
                            },
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('选择头像'),
                    ),
                    if (avatar != null)
                      TextButton(
                        onPressed: picking
                            ? null
                            : () => update(() {
                                avatar = null;
                                avatarChanged = true;
                              }),
                        child: const Text('恢复默认头像'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          textField(
            '姓名',
            name,
            (value) => update(() => name = value),
            limit: 40,
            autofocus: true,
          ),
        ]),
      ),
      onSave: () {
        if (picking) throw const InputException('请先完成头像选择');
        controller.write(
          () => controller.repository.saveMember(
            name,
            id: member?.id,
            expectedIdentityCode: member?.identityCode,
            avatar: avatarChanged ? avatar : null,
            clearAvatar: avatarChanged && avatar == null,
          ),
        );
      },
    ),
  );
}

Future<void> showMemberActivity(
  BuildContext context,
  DormController controller,
  Member member,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: Text('${member.name}的修改日志'),
    content: SizedBox(
      width: 460,
      child: AuditHistory(controller.repository.memberActivity(member.id)),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);
