import 'dart:convert';
import 'dart:io';

import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/ledger_export.dart';
import 'package:dormos/domain/models.dart';
import 'package:dormos/domain/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SqliteDormRepository repo;
  final invalid = throwsA(isA<InputException>());

  setUp(() {
    repo = SqliteDormRepository.open(':memory:');
    for (final name in ['甲', '乙', '丙', '丁']) {
      repo.saveMember(name);
    }
  });

  tearDown(() => repo.close());

  test('nonparticipant payer can receive partial and full repayments', () {
    final id = repo.addBill(
      BillDraft(
        title: '纸巾',
        sharedAmount: 1000,
        payerId: 4,
        participantIds: [1, 2, 3],
        supplyId: null,
      ),
    );
    expect(repo.billDetail(id).shares.map((share) => share.amount), [
      334,
      333,
      333,
    ]);
    expect(repo.bills().single.outstanding, 1000);
    repo.recordTransfer(id, 1, 100);
    expect(() => repo.recordTransfer(id, 1, 235), invalid);
    expect(() => repo.recordTransfer(id, 4, 1), invalid);
    final payer = repo.balances().last;
    expect(
      (payer.receivable, payer.payable, payer.openReceivable),
      (1000, 0, 900),
    );
    expect(repo.balances().first.openPayable, 234);
    repo.recordTransfer(id, 1, 234);
    repo.recordTransfer(id, 2, 333);
    repo.setMemberActive(3, false);
    repo.recordTransfer(id, 3, 333);
    expect(repo.billDetail(id).transfers.length, 4);
    expect(repo.bills().single.outstanding, 0);
    expect(repo.balances().first.payable, 334);
  });

  test('payer share creates no obligation and invalid bills write nothing', () {
    expect(
      () => repo.addBill(
        BillDraft(
          title: '坏账单',
          sharedAmount: 1000,
          payerId: 1,
          participantIds: [1, 99],
          supplyId: null,
        ),
      ),
      invalid,
    );
    expect(repo.bills(), isEmpty);
    final id = repo.addBill(
      BillDraft(
        title: '洗衣液',
        sharedAmount: 1000,
        payerId: 1,
        participantIds: [1, 2, 3],
        supplyId: null,
      ),
    );
    expect(repo.bills().single.outstanding, 666);
    expect(() => repo.recordTransfer(id, 1, 334), invalid);
    expect(repo.billDetail(id).transfers, isEmpty);
  });

  test(
    'personal costs add to public shares and are payable by their owner',
    () {
      final id = repo.addBill(
        const BillDraft(
          title: '聚餐和饮料',
          sharedAmount: 1000,
          payerId: 3,
          participantIds: [1, 2, 3],
          personalAmounts: {1: 800, 3: 500, 4: 200},
        ),
      );
      final detail = repo.billDetail(id);
      expect(detail.bill.total, 2500);
      expect(
        detail.shares.map(
          (share) => (share.member, share.amount, share.personalAmount),
        ),
        [('甲', 1134, 800), ('乙', 333, 0), ('丙', 833, 500), ('丁', 200, 200)],
      );
      expect(detail.bill.outstanding, 1667);
      expect(repo.balances()[2].receivable, 1667);
      expect(() => repo.recordTransfer(id, 3, 833), invalid);
      repo.recordTransfer(id, 1, 1000);
      expect(repo.balances().first.openPayable, 134);
      expect(() => repo.recordTransfer(id, 1, 135), invalid);
      repo.recordTransfer(id, 1, 134);
      expect(repo.billDetail(id).shares.first.paid, 1134);
    },
  );

  test('a personal-only bill needs no public participant and invalid items do not write', () {
    final id = repo.addBill(
      const BillDraft(
        title: '代买饮料',
        sharedAmount: 0,
        payerId: 3,
        participantIds: [],
        personalAmounts: {1: 550},
      ),
    );
    expect(repo.billDetail(id).shares.single.amount, 550);
    expect(repo.billDetail(id).bill.outstanding, 550);
    for (final (shared, personal) in [
      (0, <int, int>{}),
      (0, {2: 0}),
      (0, {99: 200}),
      (maxAmountCents, {1: 1}),
    ]) {
      expect(
        () => repo.addBill(
          BillDraft(
            title: '无效',
            sharedAmount: shared,
            payerId: 3,
            participantIds: [1],
            personalAmounts: personal,
          ),
        ),
        invalid,
      );
    }
    expect(repo.bills(), hasLength(1));
  });

  test('purchase updates procurement and preserves history after inventory deletion', () {
    const draft = (
      name: '纸巾',
      category: '日用品',
      quantity: 0,
      location: '置物架',
      note: '',
      status: PurchaseStatus.needed,
    );
    repo.saveSupply(draft);
    final item = repo.supplies().single;
    final id = repo.addBill(
      BillDraft(
        title: '采购纸巾',
        sharedAmount: 399,
        payerId: 4,
        participantIds: [1, 2],
        supplyId: item.id,
      ),
    );
    expect(repo.supplies().single.status, PurchaseStatus.ordered);
    expect(repo.supplies().single.quantity, 0);
    repo.deleteSupply(item.id);
    expect(repo.supplies(), isEmpty);
    expect(repo.bills(supplyId: item.id).single.supplyName, '纸巾');
    expect(repo.billDetail(id).bill.outstanding, 399);
    expect(
      () => repo.addBill(
        BillDraft(
          title: '已删除',
          sharedAmount: 100,
          payerId: 1,
          participantIds: [2],
          supplyId: item.id,
        ),
      ),
      invalid,
    );
    expect(repo.bills(), hasLength(1));
  });

  test(
    'daily rotations survive retries and swapping does not change the cursor',
    () {
      final start = DateTime.utc(2020, 2, 27);
      DateTime at(int offset) => start.add(Duration(days: offset));
      repo.addChore('扫地', Cadence.daily, start);
      repo.generateShiftsThrough(at(3));
      repo.generateShiftsThrough(at(3));
      final first = repo.shifts(start, at(3));
      expect(first.map((shift) => shift.memberId), [1, 2, 3, 4]);
      repo.swapShifts(first[0].id, first[1].id);
      repo.setMemberActive(3, false);
      repo.generateShiftsThrough(at(7));
      final shifted = repo.shifts(start, at(7));
      expect(shifted.map((shift) => shift.memberId), [2, 1, 3, 4, 1, 2, 4, 1]);
      expect(shifted[2].day, '2020-02-29');
      repo.completeShift(first.first.id);
      expect(repo.shifts(start, start).single.completedAt, isNotNull);
      expect(() => repo.swapShifts(first[0].id, first[1].id), invalid);
      expect(() => repo.reassignShift(first[0].id, 3), invalid);
      repo.archiveChore(first.first.taskId, at(7));
      repo.generateShiftsThrough(at(15));
      expect(repo.shifts(start, at(15)), hasLength(7));
    },
  );

  test('weekly shifts begin on the selected date and future shifts cannot be checked off', () {
    final start = today().add(const Duration(days: 1));
    final through = start.add(const Duration(days: 20));
    repo.addChore('擦桌', Cadence.weekly, start);
    repo.generateShiftsThrough(through);
    final shifts = repo.shifts(start, through);
    expect(shifts.map((item) => item.day), [
      for (final days in [0, 7, 14]) dayKey(start.add(Duration(days: days))),
    ]);
    expect(() => repo.completeShift(shifts.first.id), invalid);
  });

  test(
    'exports a consistent database with records and local preferences',
    () async {
      final temp = Directory.systemTemp.createTempSync('dorm-backup-test-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final backup = '${temp.path}${Platform.pathSeparator}copy.dormbak';
      repo.saveAppearanceMode(AppearanceMode.dark);
      repo.cloud.saveSettings(
        CloudSettings(repository: 'owner/private', operator: '填写人'),
      );
      final id = repo.addBill(
        const BillDraft(
          title: '清洁用品',
          sharedAmount: 4000,
          payerId: 1,
          participantIds: [2],
        ),
      );
      repo.recordTransfer(id, 2, 1500);
      await repo.writeBackup(backup);
      final restored = SqliteDormRepository.open(backup);
      addTearDown(restored.close);
      expect(restored.bills().single.outstanding, 2500);
      expect(restored.billDetail(id).transfers.single.amount, 1500);
      expect(restored.appearanceMode, AppearanceMode.dark);
      expect(restored.cloud.settings, isNull);
      expect(
        repo.cloud.settings!.repository,
        'git@github.com:owner/private.git',
      );
      expect(
        File(backup).readAsStringSync(encoding: latin1),
        isNot(contains('owner/private')),
      );
    },
  );

  test('exports sheet-safe CSV and formats the current unpaid amounts', () {
    final id = repo.addBill(
      const BillDraft(
        title: '=SUM(1,2) "饮料"',
        sharedAmount: 1000,
        personalAmounts: {2: 300},
        payerId: 1,
        participantIds: [1, 2],
      ),
    );
    repo.recordTransfer(id, 2, 250);
    final csv = billsCsv(repo.bills());
    expect(csv, startsWith('\uFEFF账单名称'));
    expect(csv, contains('\x22\u0027=SUM(1,2) \x22\x22饮料\x22\x22\x22'));
    expect(csv, contains(',13.00,5.50,待结清,'));
    expect(
      settlementSummary(repo.billDetail(id)),
      '=SUM(1,2) "饮料" · 甲垫付 ¥13.00\n乙 → 甲 ¥5.50',
    );
  });

  test('file database survives close and two connections cannot overpay', () {
    final folder = Directory.systemTemp.createTempSync('dormos-test-');
    final file = '${folder.path}${Platform.pathSeparator}dormos.sqlite3';
    addTearDown(() => folder.deleteSync(recursive: true));
    final original = SqliteDormRepository.open(file);
    int id;
    try {
      expect(original.members(), isEmpty);
      original.saveMember('甲');
      original.saveMember('乙');
      id = original.addBill(
        BillDraft(
          title: '水',
          sharedAmount: 500,
          payerId: 1,
          participantIds: [2],
          supplyId: null,
        ),
      );
    } finally {
      original.close();
    }
    final first = SqliteDormRepository.open(file);
    final second = SqliteDormRepository.open(file);
    addTearDown(first.close);
    addTearDown(second.close);
    expect(first.billDetail(id).shares.single.amount, 500);
    first.recordTransfer(id, 2, 200);
    expect(() => second.recordTransfer(id, 2, 500), invalid);
    expect(second.bills().single.outstanding, 300);
  });
}
