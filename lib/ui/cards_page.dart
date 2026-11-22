import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/qr_image.dart';
import '../domain/ledger.dart';
import '../game/card_session.dart';
import '../game/cards.dart';
import 'card_table.dart';
import 'common.dart';
import 'me_page.dart';

const _locations = {
  CardLocation.local: '本机',
  CardLocation.lan: '局域网',
  CardLocation.git: 'GitHub 在线',
};

class CardsPage extends StatefulWidget {
  const CardsPage({super.key, required this.controller});
  final DormController controller;

  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  CardSession get session => widget.controller.cards;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(session.search());
    });
  }

  Future<String?> _name() async {
    final repo = widget.controller.repository;
    var memberId = repo.identity.memberId;
    var member = repo
        .members()
        .where((person) => person.id == memberId)
        .firstOrNull;
    var name = '';
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('选择上桌身份'),
        content: TextField(
          onChanged: (value) => name = value,
          maxLength: 20,
          decoration: const InputDecoration(labelText: '牌桌昵称（可选）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('跳过，匿名加入'),
          ),
          if (member case final me?)
            TextButton(
              onPressed: () => Navigator.pop(context, me.name),
              child: const Text('使用寝室身份'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(context, '\u0000'),
              child: const Text('认领寝室身份'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: const Text('用昵称继续'),
          ),
        ],
      ),
    );
    if (choice != '\u0000' || !mounted) return choice;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => MePage(controller: widget.controller)),
    );
    if (!mounted) return null;
    memberId = repo.identity.memberId;
    member = repo
        .members()
        .where((person) => person.id == memberId)
        .firstOrNull;
    return member?.name ?? '';
  }

  Future<void> _create() async {
    final setup = await showDialog<({CardRules rules, CardLocation where})>(
      context: context,
      builder: (_) => CardRulesDialog(gitAvailable: session.gitAvailable),
    );
    if (setup == null || !mounted) return;
    final name = await _name();
    if (name != null && mounted) {
      await session.create(setup.rules, name, setup.where);
    }
  }

  Future<void> _join(LobbyRoom room) async {
    final name = await _name();
    if (name != null && mounted) await session.join(room, name);
  }

  Future<void> _joinLink() async {
    var source = '';
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('用链接加入'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => source = value,
          decoration: const InputDecoration(labelText: '粘贴室友的牌桌链接'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, source),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (link == null || link.trim().isEmpty || !mounted) return;
    final name = await _name();
    if (name != null && mounted) await session.joinLink(link, name);
  }

  Future<void> _share() async {
    if (session.links.isEmpty) await session.share();
    if (!mounted || session.links.isEmpty) return;
    final url = session.links.first;
    try {
      final qr = await makeQrPng(url.toString());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('分享斗地主牌桌'),
          content: SizedBox(
            width: 320,
            child: Column(
              spacing: 12,
              children: [
                Image.memory(qr, width: 200, filterQuality: FilterQuality.none),
                SelectableText(url.toString()),
                const Text('连接同一局域网后，扫码打开网页或在 Dorm 搜房。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: () async {
                if (!await launchUrl(
                      url,
                      mode: LaunchMode.externalApplication,
                    ) &&
                    context.mounted) {
                  notify(context, '无法打开浏览器');
                }
              },
              child: const Text('打开网页'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url.toString()));
                if (context.mounted) notify(context, '已复制牌桌链接');
              },
              child: const Text('复制链接'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) notify(context, errorText(e, fallback: '无法分享牌桌'));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final view = session.view;
      if (session.opened && view != null) {
        final table = CardTable(session: session, view: view, share: _share);
        return Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            child: Platform.isAndroid ? _LandscapeRoom(child: table) : table,
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('斗地主'),
          leading: IconButton(
            tooltip: '返回工具箱',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: SafeArea(
          top: false,
          child: session.opened
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 14,
                      children: [
                        if (session.error == null)
                          const CircularProgressIndicator(),
                        Text(session.error ?? '正在加入牌桌…'),
                        if (session.gitError case final failure?) Text(failure),
                        TextButton(
                          onPressed: session.cancelRemote,
                          child: const Text('返回房间列表'),
                        ),
                      ],
                    ),
                  ),
                )
              : PageBody(
                  storageKey: 'card-lobby',
                  children: [
                    PageHeading(
                      '斗地主牌桌',
                      '本机练手、局域网组局，或加入同一 GitHub 仓库的在线房间。',
                      actions: [
                        OutlinedButton.icon(
                          onPressed: session.working ? null : _joinLink,
                          icon: const Icon(Icons.link),
                          label: const Text('用链接加入'),
                        ),
                        FilledButton.icon(
                          onPressed: session.working ? null : _create,
                          icon: const Icon(Icons.add),
                          label: const Text('创建房间'),
                        ),
                      ],
                    ),
                    Row(
                      spacing: 12,
                      children: [
                        Expanded(
                          child: Text(
                            '公共房间',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: session.searching ? null : session.search,
                          icon: const Icon(Icons.radar_outlined),
                          label: Text(session.searching ? '正在搜索…' : '搜索局域网房间'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (session.error case final error?)
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (session.gitError case final failure?)
                      Text('在线大厅 · $failure'),
                    if (session.directory.isEmpty)
                      const EmptyPanel(
                        icon: Icons.style_outlined,
                        title: '暂时没有可加入的房间',
                        detail: '可以创建牌桌，或让房主开启局域网分享。',
                      )
                    else
                      Column(
                        spacing: 8,
                        children: [
                          for (final room in session.directory)
                            Card(
                              child: ListTile(
                                onTap: session.working
                                    ? null
                                    : () => _join(room),
                                leading: Icon(
                                  room.location == CardLocation.git
                                      ? Icons.cloud_outlined
                                      : Icons.wifi,
                                ),
                                title: Text('${room.info['host']}的牌桌'),
                                subtitle: Text(
                                  '${_locations[room.location]} · ${room.info['players']}/${room.info['capacity']} 人 · ${_mode(room.info['mode'])}',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                              ),
                            ),
                        ],
                      ),
                    if (!session.gitAvailable)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text('在设置中连接 GitHub 仓库后，同仓库室友的在线房间会出现在这里。'),
                      ),
                  ],
                ),
        ),
      );
    },
  );
  String _mode(Object? value) =>
      CardMode.values.where((mode) => mode.name == value).firstOrNull?.label ??
      '自定义';
}

class _LandscapeRoom extends StatefulWidget {
  const _LandscapeRoom({required this.child});
  final Widget child;

  @override
  State<_LandscapeRoom> createState() => _LandscapeRoomState();
}

class _LandscapeRoomState extends State<_LandscapeRoom> {
  static const _window = MethodChannel('dorm/cards/window');

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(_immersive(true));
  }

  Future<void> _immersive(bool enabled) async {
    try {
      await _window.invokeMethod<void>('immersive', enabled);
    } on MissingPluginException {
      // The window integration is optional outside the Android runner.
    }
  }

  @override
  void dispose() {
    unawaited(_immersive(false));
    unawaited(SystemChrome.setPreferredOrientations([]));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => RotatedBox(
      quarterTurns: constraints.maxHeight > constraints.maxWidth ? 1 : 0,
      child: widget.child,
    ),
  );
}

class CardRulesDialog extends StatefulWidget {
  const CardRulesDialog({super.key, this.current, this.gitAvailable = false});
  final CardRules? current;
  final bool gitAvailable;

  @override
  State<CardRulesDialog> createState() => _CardRulesDialogState();
}

class _CardRulesDialogState extends State<CardRulesDialog> {
  late int players = widget.current?.players ?? 3;
  late int decks = widget.current?.decks ?? 1;
  late int discard = widget.current?.discard ?? 0;
  late int bottom = widget.current?.bottom ?? 3;
  late bool landlord = widget.current?.landlord ?? true;
  late bool reserve = bottom != 0;
  late final _discard = TextEditingController(text: '$discard');
  late final _bottom = TextEditingController(
    text: '${bottom == 0 ? 3 : bottom}',
  );

  @override
  void dispose() {
    _discard.dispose();
    _bottom.dispose();
    super.dispose();
  }

  late DealRemainder remainder =
      widget.current?.remainder ?? DealRemainder.equal;
  late CardMode mode = widget.current?.mode ?? CardMode.classic;
  late bool chainBombs = widget.current?.chainBombs ?? true;
  late bool rocketBeatsChain =
      widget.current?.rocketBeatsChain ?? CardRules.defaultRocketBeatsChain;
  late bool fourWithTwo = widget.current?.fourWithTwo ?? true;
  CardLocation where = CardLocation.local;
  String? issue;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.current == null ? '创建斗地主房间' : '调整房间规则'),
    content: SizedBox(
      width: 470,
      child: Column(
        spacing: 12,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.current == null)
            _select(
              '房间方式',
              where,
              [
                CardLocation.local,
                CardLocation.lan,
                if (widget.gitAvailable) CardLocation.git,
              ],
              (value) => _locations[value]!,
              (value) => where = value,
            ),
          if (where == CardLocation.git)
            const Text('每个回合通过 Git 推送和拉取，可能等待数秒或更久。'),
          _select(
            '玩法',
            mode,
            CardMode.values,
            (value) => value.label,
            (value) => mode = value,
          ),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: _select(
                  '人数',
                  players,
                  List.generate(7, (i) => i + 2),
                  (value) => '$value 人',
                  (value) => players = value,
                ),
              ),
              Expanded(
                child: _select(
                  '牌副数',
                  decks,
                  [1, 2, 3, 4],
                  (value) => '$value 副',
                  (value) => decks = value,
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('连炸'),
            subtitle: const Text('两组或更多相邻点数的四张牌'),
            value: chainBombs,
            onChanged: (value) => setState(() => chainBombs = value),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.only(left: 16),
            title: const Text('王炸大于连炸'),
            subtitle: Text(
              rocketBeatsChain
                  ? '普通炸弹 ＜ 连炸 ＜ 王炸 ＜ 双王炸'
                  : '普通炸弹 ＜ 王炸 ＜ 双王炸 ＜ 连炸',
            ),
            value: rocketBeatsChain,
            onChanged: chainBombs
                ? (value) => setState(() => rocketBeatsChain = value)
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('四带二／四带两对'),
            value: fourWithTwo,
            onChanged: (value) => setState(() => fourWithTwo = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用地主'),
            value: landlord,
            onChanged: (value) => setState(() {
              landlord = value;
              issue = null;
            }),
          ),
          if (landlord)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('给地主底牌'),
              value: reserve,
              onChanged: (value) => setState(() {
                reserve = value;
                issue = null;
              }),
            ),
          if (landlord && reserve)
            _number('底牌张数', _bottom, (value) => bottom = value),
          _select(
            '余牌处理',
            remainder,
            DealRemainder.values,
            (value) => value == DealRemainder.equal ? '必须平分' : '随机多发给一人',
            (value) => remainder = value,
          ),
          _number('随机舍弃张数', _discard, (value) => discard = value),
          Text(
            '共 ${54 * decks} 张 · 每位起手 ${(54 * decks - discard - _reserve) < 0 ? 0 : (54 * decks - discard - _reserve) ~/ players} 张',
          ),
          if (remainder == DealRemainder.equal &&
              (54 * decks - discard - _reserve) % players != 0)
            TextButton(
              onPressed: () => setState(() {
                discard += (54 * decks - discard - _reserve) % players;
                _discard.text = '$discard';
                issue = null;
              }),
              child: const Text('自动补齐舍弃张数'),
            ),
          if (issue case final text?)
            Text(
              text,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _apply,
        child: Text(widget.current == null ? '创建房间' : '保存规则'),
      ),
    ],
  );

  int get _reserve => landlord && reserve ? (bottom > 0 ? bottom : 3) : 0;

  void _apply() {
    try {
      final rules = CardRules(
        players: players,
        decks: decks,
        discard: discard,
        bottom: _reserve,
        landlord: landlord,
        remainder: remainder,
        mode: mode,
        chainBombs: chainBombs,
        rocketBeatsChain: rocketBeatsChain,
        fourWithTwo: fourWithTwo,
      );
      Navigator.pop(context, (rules: rules, where: where));
    } on InputException catch (e) {
      setState(() => issue = e.message);
    }
  }

  Widget _number(
    String name,
    TextEditingController controller,
    ValueChanged<int> update,
  ) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: name),
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(3),
    ],
    onChanged: (value) => setState(() {
      update(int.tryParse(value) ?? 0);
      issue = null;
    }),
  );

  Widget _select<T>(
    String name,
    T selected,
    List<T> values,
    String Function(T) label,
    ValueChanged<T> update,
  ) => DropdownButtonFormField<T>(
    initialValue: selected,
    decoration: InputDecoration(labelText: name),
    isExpanded: true,
    items: [
      for (final value in values)
        DropdownMenuItem(value: value, child: Text(label(value))),
    ],
    onChanged: (value) {
      if (value != null) {
        setState(() {
          update(value);
          issue = null;
        });
      }
    },
  );
}
