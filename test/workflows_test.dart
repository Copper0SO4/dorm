import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/schedule.dart';
import 'package:dormos/ui/app.dart';
import 'package:dormos/ui/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late SqliteDormRepository repo;
  late DormController controller;

  setUp(() {
    repo = SqliteDormRepository.open(':memory:');
    repo.saveMember('小李');
    repo.saveMember('小周');
    controller = DormController(repo);
  });

  tearDown(() {
    controller.dispose();
    repo.close();
  });

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> openApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 810));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(DormApp(controller: controller));
    await tester.pumpAndSettle();
  }

  testWidgets('task settings generate a shift that can be checked off', (
    tester,
  ) async {
    await openApp(tester);
    await tapText(tester, '卫生排班');
    await tapText(tester, '任务设置');
    await tapText(tester, '添加任务');
    await tester.enterText(find.byType(TextFormField), '打扫地板');
    await tapText(tester, '保存');
    await tapText(tester, '关闭');
    expect(find.text('打扫地板'), findsOneWidget);
    await tapText(tester, '完成打卡');
    expect(repo.shifts(today(), today()).single.completedAt, isNotNull);
    expect(find.textContaining('完成于'), findsOneWidget);
  });

  testWidgets('inventory creates a purchase bill and opens its details', (
    tester,
  ) async {
    await openApp(tester);
    await tapText(tester, '公共物资');
    await tapText(tester, '新增物资');
    var fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '洁厕剂');
    await tester.enterText(fields.at(1), '清洁');
    await tester.enterText(fields.at(2), '2');
    await tapText(tester, '保存');
    final supply = repo.supplies().single;
    expect(supply.quantity, 2);
    await tapText(tester, '记录采购');
    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), '9.90');
    await tapText(tester, '写入总账');
    expect(repo.bills(supplyId: supply.id).single.total, 990);
    await tapText(tester, '采购账单');
    await tapText(tester, '采购 洁厕剂');
    expect(find.text('关联物资 · 洁厕剂'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
