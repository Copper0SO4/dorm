import 'package:material_ui/material_ui.dart';

import 'common.dart';
import 'member_identity.dart';
import 'members_dialog.dart';

class MePage extends StatelessWidget {
  const MePage({super.key, required this.controller});

  final DormController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('我'),
      leading: IconButton(
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.of(context).pop(),
      ),
    ),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final repository = controller.repository;
          final identity = repository.identity;
          final members = repository.members().where((member) => member.active);
          final mine = members
              .where((member) => member.id == identity.memberId)
              .firstOrNull;
          return PageBody(
            storageKey: 'me',
            children: [
              if (mine != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(panelGap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: MemberAvatar(
                            name: mine.name,
                            avatar: mine.avatar,
                            radius: 26,
                          ),
                          title: Text(mine.name),
                          subtitle: const Text('已认领'),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  editMember(context, controller, mine),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('编辑我的资料'),
                            ),
                            TextButton(
                              onPressed: () async {
                                final accepted = await confirm(
                                  context,
                                  '解除认领',
                                  '解除后，这位成员可以被其他设备认领。',
                                  action: '解除认领',
                                );
                                if (!accepted || !context.mounted) return;
                                perform(
                                  context,
                                  controller,
                                  repository.releaseMember,
                                  '已解除认领',
                                );
                              },
                              child: const Text('解除认领'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                PageHeading(
                  '认领寝室身份',
                  identity.conflicted
                      ? '同步发现重复认领，双方的认领都已取消。请重新选择成员。'
                      : '选择自己在寝室里的名字。编辑和记账时会使用本机设备码。',
                ),
                if (members.isEmpty)
                  EmptyPanel(
                    icon: Icons.person_add_alt_outlined,
                    title: '寝室还没有成员',
                    detail: '添加室友后即可认领。',
                    action: TextButton(
                      onPressed: () => showMembers(context, controller),
                      child: const Text('管理寝室成员'),
                    ),
                  )
                else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: panelGap,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          for (final member in members)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: MemberAvatar(
                                name: member.name,
                                avatar: member.avatar,
                              ),
                              title: Text(member.name),
                              trailing: member.deviceCode == null
                                  ? FilledButton.tonal(
                                      onPressed: () => perform(
                                        context,
                                        controller,
                                        () => repository.claimMember(member.id),
                                        '已认领 ${member.name}',
                                      ),
                                      child: const Text('认领'),
                                    )
                                  : const Text('已被认领'),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
              const SectionHeading('本机设备码'),
              DeviceCode(identity.deviceCode),
            ],
          );
        },
      ),
    ),
  );
}
