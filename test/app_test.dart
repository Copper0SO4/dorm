import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/ui/app.dart';
import 'package:dormos/ui/common.dart';
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
    await tester.tap(find.byTooltip('切换深色主题'));
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
