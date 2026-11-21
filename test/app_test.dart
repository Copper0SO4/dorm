import 'dart:io';

import 'package:dormos/data/local_directory.dart';
import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/models.dart';
import 'package:dormos/domain/preferences.dart';
import 'package:dormos/domain/matters.dart';
import 'package:dormos/ui/app.dart';
import 'package:dormos/ui/common.dart';
import 'package:dormos/ui/tools/dice_scene.dart';
import 'package:dormos/ui/tools/draw_ceremony.dart';
import 'package:dormos/ui/tools/group_board.dart';
import 'package:dormos/ui/tools_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SqliteDormRepository repo;
  late DormController controller;

  setUp(() {
    repo = SqliteDormRepository.open(':memory:');
    controller = DormController(repo);
  });

  tearDown(() {
    controller.dispose();
    repo.close();
  });

  test(
    'renamed Windows application still resolves the old data directory',
    () async {
      final roaming = Platform.environment['APPDATA']!;
      final expected = [
        roaming,
        'org.dormos',
        'dormos',
        'dormos',
      ].join(Platform.pathSeparator);
      expect((await dormDataDirectory()).path, expected);
    },
    skip: !Platform.isWindows,
  );

  testWidgets('tools use dorm members for draws and quick rolls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('甲');
    repo.saveMember('乙');
    repo.saveMember('丙');
    repo.saveMember('丁');
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('寝室工具箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始抽签'));
    await tester.pump();
    expect(find.text('抽签中…'), findsOneWidget);
    expect(find.text('洗签中'), findsOneWidget);
    expect(find.text('抽签结果'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('抽出签牌'), findsOneWidget);
    expect(find.text('复制结果'), findsNothing);
    await tester.pump(const Duration(milliseconds: 360));
    expect(find.text('揭晓结果'), findsOneWidget);
    expect(find.text('抽签结果'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    final edit = find.ancestor(
      of: find.text('编辑名单'),
      matching: find.byWidgetPredicate((widget) => widget is TextButton),
    );
    expect(tester.widget<TextButton>(edit).onPressed, isNull);
    await tester.pumpAndSettle();
    expect(find.text('抽签结果'), findsOneWidget);
    expect(find.byType(Chip), findsOneWidget);
    await tester.tap(find.text('随机分组'));
    await tester.pumpAndSettle();
    expect(find.text('每组 2 人'), findsOneWidget);
    await tester.tap(find.text('开始分组'));
    await tester.pump();
    expect(find.byType(DrawCeremony), findsNothing);
    expect(find.text('正在分配成员'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 260));
    final partial = tester.widget<GroupBoard>(find.byType(GroupBoard));
    expect(partial.progress, inExclusiveRange(0, 1));
    expect(find.text('复制分组'), findsNothing);
    final names = find.descendant(
      of: find.byType(GroupBoard),
      matching: find.byWidgetPredicate(
        (item) => item is Text && ['甲', '乙', '丙', '丁'].contains(item.data),
      ),
    );
    expect(names.evaluate().length, inExclusiveRange(0, 4));
    await tester.pumpAndSettle();
    expect(find.text('第 1 组'), findsOneWidget);
    expect(find.text('第 2 组'), findsOneWidget);
    expect(names.evaluate().length, 4);
    expect(find.text('复制分组'), findsOneWidget);
    await tester.tap(find.text('骰子与硬币'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('掷骰子'));
    await tester.pump();
    expect(find.text('骰子滚动中…'), findsOneWidget);
    final points = find.textContaining(RegExp(r'^[1-6] 点$'));
    expect(points, findsNothing);
    final coin = find.ancestor(
      of: find.text('抛硬币'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(coin).onPressed, isNull);
    await tester.pump(const Duration(milliseconds: 320));
    final rolling = tester.widget<DiceScene>(find.byType(DiceScene));
    expect(rolling.progress, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(points, findsOneWidget);
    final settled = tester.widget<DiceScene>(find.byType(DiceScene));
    expect(settled.progress, 1);
    expect(settled.points, rolling.points);
    expect(tester.widget<Text>(points).data, '${settled.points} 点');
    await tester.tap(find.text('抛硬币'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^(正面|反面)$')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact tools keep results and honor reduced animation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 770));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('甲');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(body: ToolsPage(controller: controller)),
      ),
    );
    await tester.tap(find.text('随机分组'));
    await tester.pump();
    expect(find.text('至少需要 2 名成员，可以编辑名单添加。'), findsOneWidget);
    await tester.tap(find.text('编辑名单'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '甲\n乙\n乙');
    await tester.tap(find.text('使用名单'));
    await tester.pumpAndSettle();
    expect(find.text('每组 1 人'), findsOneWidget);
    await tester.tap(find.text('开始分组'));
    await tester.pump();
    expect(find.text('分组结果'), findsOneWidget);
    expect(find.text('正在分配成员'), findsNothing);
    await tester.tap(find.text('抽签'));
    await tester.pump();
    await tester.tap(find.text('开始抽签'));
    await tester.pump();
    expect(find.text('抽签结果'), findsOneWidget);
    expect(find.text('抽签中…'), findsNothing);

    await tester.tap(find.text('骰子与硬币'));
    await tester.pump();
    await tester.tap(find.text('掷骰子'));
    await tester.pump();
    final points = find.textContaining(RegExp(r'^[1-6] 点$'));
    expect(points, findsOneWidget);
    final recorded = tester.widget<Text>(points).data!;
    expect(find.text('骰子滚动中…'), findsNothing);
    await tester.tap(find.text('抽签'));
    await tester.pump();
    expect(find.text('抽签结果'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpAndSettle();
    expect(find.text('抽签结果'), findsOneWidget);
    await tester.tap(find.text('骰子与硬币'));
    await tester.pumpAndSettle();
    expect(find.text(recorded), findsOneWidget);
    await tester.tap(find.text('随机分组'));
    await tester.pumpAndSettle();
    expect(find.text('分组结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first bill continues directly after adding a roommate', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加室友并记账'));
    await tester.pumpAndSettle();
    expect(find.text('继续记账'), findsNothing);
    await tester.tap(find.text('添加成员'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '小林');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续记账'));
    await tester.pumpAndSettle();
    expect(find.text('写入总账'), findsOneWidget);
    expect(repo.members().single.name, '小林');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop creates and settles a bill through dialogs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 810));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('小李');
    repo.saveMember('小周');
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Dorm'), findsOneWidget);
    expect(find.text('DormOS'), findsNothing);
    expect(find.text("Dorm Organizes Roomates' Matters"), findsOneWidget);
    await tester.tap(find.text('新建账单'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '宿舍饮用水');
    await tester.enterText(fields.at(1), '10.01');
    await tester.pumpAndSettle();
    await tester.tap(find.text('写入总账'));
    await tester.pumpAndSettle();
    expect(repo.bills().single.outstanding, 500);
    await tester.tap(find.text('宿舍饮用水'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记转账'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认登记'));
    await tester.pumpAndSettle();
    expect(repo.bills().single.outstanding, 0);
    expect(find.text('小周 → 小李'), findsOneWidget);
    await tester.tap(find.text('删除账单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.bills(), hasLength(1));
    await tester.tap(find.text('删除账单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(repo.bills(), isEmpty);
    expect(find.text('宿舍饮用水'), findsNothing);
    expect(find.text('已删除账单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bill previews and saves one member personal expense', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final name in ['甲', '乙', '丙']) {
      repo.saveMember(name);
    }
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建账单'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '聚餐与饮料');
    await tester.enterText(find.byType(TextFormField).at(1), '30');
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丙').last);
    await tester.pumpAndSettle();
    final addPersonal = find.text('添加个人费用');
    await tester.ensureVisible(addPersonal);
    await tester.tap(addPersonal);
    await tester.pumpAndSettle();
    final person = find.byKey(const ValueKey('personal-member-1'));
    await tester.ensureVisible(person);
    await tester.tap(person);
    await tester.pumpAndSettle();
    final amount = find.byKey(const ValueKey('personal-amount-1'));
    await tester.ensureVisible(amount);
    await tester.enterText(amount, '8');
    await tester.pumpAndSettle();
    expect(find.text('甲承担 ¥18.00 · 转给 丙'), findsOneWidget);
    expect(find.text('公共分摊 ¥10.00 · 个人费用 ¥8.00'), findsOneWidget);
    await tester.tap(find.text('写入总账'));
    await tester.pumpAndSettle();
    expect(repo.bills().single.outstanding, 2800);
    await tester.tap(find.text('聚餐与饮料'));
    await tester.pumpAndSettle();
    expect(find.text('待转给 丙 ¥18.00'), findsOneWidget);
    expect(find.text('公共分摊 ¥10.00 · 个人费用 ¥8.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters bills by keyword and outstanding balance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('阿青');
    repo.saveMember('小林');
    repo.addBill(
      const BillDraft(
        title: '外卖',
        sharedAmount: 2000,
        payerId: 1,
        participantIds: [2],
      ),
    );
    final settled = repo.addBill(
      const BillDraft(
        title: '卫生纸',
        sharedAmount: 800,
        payerId: 2,
        participantIds: [1],
      ),
    );
    repo.recordTransfer(settled, 1, 800);
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('外卖'), findsOneWidget);
    expect(find.text('卫生纸'), findsOneWidget);
    await tester.tap(find.text('仅待结清'));
    await tester.pumpAndSettle();
    expect(find.text('外卖'), findsOneWidget);
    expect(find.text('卫生纸'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '搜索账单'), '小林');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的账单'), findsOneWidget);
    await tester.tap(find.text('仅待结清'));
    await tester.pumpAndSettle();
    expect(find.text('卫生纸'), findsOneWidget);
    expect(find.text('外卖'), findsNothing);
  });

  testWidgets('opens the matters board and completes an assigned matter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('小黎');
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建事务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '事务标题'), '报告漏水');
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小黎').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repo.matters().single.owner, '小黎');
    await tester.tap(find.text('报告漏水'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<MatterStatus>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已完成').last);
    await tester.pumpAndSettle();
    expect(repo.matters().single.status, MatterStatus.done);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已完成 · 1'));
    await tester.pumpAndSettle();
    expect(find.text('报告漏水'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('records and displays one transfer for two bills', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('小周');
    repo.saveMember('小林');
    for (final title in ['纸巾', '豆浆']) {
      repo.addBill(
        BillDraft(
          title: title,
          sharedAmount: 500,
          payerId: 1,
          participantIds: [2],
        ),
      );
    }
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结算中心'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小林 → 小周'));
    await tester.pumpAndSettle();
    expect(find.text('登记 ¥10.00'), findsOneWidget);
    await tester.tap(find.text('确认登记'));
    await tester.pumpAndSettle();
    expect(repo.bills().every((bill) => bill.outstanding == 0), isTrue);
    await tester.tap(find.text('结算记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小林 → 小周 · ¥10.00'));
    await tester.pumpAndSettle();
    expect(find.text('纸巾'), findsOneWidget);
    expect(find.text('豆浆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved budget compares against public spending in the report', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.saveMember('阿青');
    repo.saveMember('小林');
    repo.addBill(
      const BillDraft(
        title: '餐费',
        sharedAmount: 3200,
        personalAmounts: {2: 700},
        payerId: 1,
        participantIds: [1, 2],
      ),
    );
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账本偏好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月度公共预算'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '月度公共预算（元）'),
      '30',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月度分析'));
    await tester.pumpAndSettle();
    expect(find.text('已用 ¥32.00 / ¥30.00'), findsOneWidget);
    expect(find.text('已超出 ¥2.00'), findsOneWidget);
    await tester.tap(find.byTooltip('上个月'));
    await tester.pumpAndSettle();
    expect(find.text('这个月暂无垫付记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('procurement queue orders and receives a low stock item', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.savePreferences(
      const DormPreferences(startupPage: StartupPage.supplies),
    );
    repo.saveSupply((
      name: '海绵',
      category: '清洁用品',
      quantity: 1,
      location: '',
      note: '',
      status: PurchaseStatus.stocked,
    ));
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('低库存'), findsOneWidget);
    await tester.tap(find.text('采购清单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记采购中'));
    await tester.pumpAndSettle();
    expect(repo.supplies().single.status, PurchaseStatus.ordered);
    await tester.tap(find.text('补货入库'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '本次入库数量'), '4');
    await tester.tap(find.text('确认入库'));
    await tester.pumpAndSettle();
    expect(repo.supplies().single.quantity, 5);
    expect(find.text('暂无待采购物资'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen uses bottom navigation and toggles dark theme', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('排班'));
    await tester.pumpAndSettle();
    expect(find.text('任务设置'), findsOneWidget);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('寝室管理'), findsOneWidget);
    expect(find.text('本机数据'), findsOneWidget);
    expect(find.text('寝室成员'), findsNothing);
    expect(find.byType(DropdownButtonFormField<AppearanceMode>), findsNothing);
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<AppearanceMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(repo.appearanceMode, AppearanceMode.dark);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('寝室管理'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('任务设置'))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.text('物资'));
    await tester.pumpAndSettle();
    expect(find.text('新增物资'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
