import 'dart:io';

import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/identity.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/models.dart';
import 'package:dormos/ui/member_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final invalid = throwsA(isA<InputException>());
  late SqliteDormRepository a;
  late SqliteDormRepository b;

  setUp(() {
    a = SqliteDormRepository.open(':memory:');
    b = SqliteDormRepository.open(':memory:');
    a.saveMember('张小林');
    a.saveMember('欧阳明');
    a.saveMember('周小程');
  });
  tearDown(() {
    a.close();
    b.close();
  });

  test(
    'installation code survives restart and is independent of a backup',
    () async {
      final directory = await Directory.systemTemp.createTemp('dorm-identity-');
      addTearDown(() => directory.delete(recursive: true));
      final db = '${directory.path}/original.sqlite3';
      final backup = '${directory.path}/backup.sqlite3';
      final source = SqliteDormRepository.open(db);
      final code = source.identity.deviceCode;
      expect(isIdentityCode(code), isTrue);
      source.saveMember('王小周');
      source.claimMember(1);
      await source.writeBackup(backup);
      source.close();

      final reopened = SqliteDormRepository.open(db);
      final copied = SqliteDormRepository.open(backup);
      addTearDown(reopened.close);
      addTearDown(copied.close);
      expect(reopened.identity.memberId, 1);
      expect(reopened.identity.deviceCode, code);
      expect(copied.identity.deviceCode, isNot(code));
      expect(copied.identity.memberId, isNull);
      expect(copied.members().single.deviceCode, code);
    },
  );

  test(
    'both concurrent claims are withdrawn and stale claims stay withdrawn',
    () {
      final base = a.cloud.snapshot();
      b.cloud.accept(base, base);
      final otherId = b
          .members()
          .singleWhere((member) => member.name == '张小林')
          .id;
      a.claimMember(1);
      a.claimMember(1);
      expect(() => a.claimMember(2), invalid);
      b.claimMember(otherId);
      final stale = b.cloud.snapshot();
      final merge = CloudMerge(a.cloud.snapshot(), stale, base);
      expect(merge.conflicts, isEmpty);
      final synced = CloudSnapshot.decode(merge.resolve({}).encoded);
      a.cloud.accept(synced, synced);
      b.cloud.accept(synced, synced);
      expect(a.identity.conflicted, isTrue);
      expect(b.identity.conflicted, isTrue);
      expect(a.identity.memberId, isNull);
      expect(b.identity.memberId, isNull);
      expect(a.members().first.deviceCode, isNull);

      a.claimMember(1);
      final newResult = CloudMerge(a.cloud.snapshot(), stale, base).resolve({});
      a.cloud.accept(newResult, newResult);
      b.cloud.accept(newResult, newResult);
      expect(a.identity.memberId, 1);
      expect(() => b.claimMember(otherId), invalid);
      a.releaseMember();
      expect(a.identity.memberId, isNull);
      expect(a.members().first.deviceCode, isNull);
    },
  );

  test(
    'logs pin the device and historical claim even after switching identities',
    () {
      a.claimMember(1);
      final bill = a.addBill(
        const BillDraft(
          title: '原票据',
          sharedAmount: 400,
          payerId: 1,
          participantIds: [2],
        ),
      );
      final code = a.identity.deviceCode;
      a.releaseMember();
      a.claimMember(3);
      a.saveMember('欧阳晓明', id: 2);
      expect(a.memberActivity(2).first.memberName, '周小程');
      expect(a.memberActivity(2).first.deviceCode, code);
      final before = a.billDetail(bill);
      a.updateBill(
        bill,
        const BillDraft(
          title: '新票据',
          sharedAmount: 400,
          payerId: 1,
          participantIds: [2],
        ),
        expectedVersion: before.version,
      );
      final activity = a.billDetail(bill).activity;
      expect(activity.first.memberName, '周小程');
      expect(activity.last.memberName, '张小林');
      expect(activity.map((entry) => entry.deviceCode).toSet(), {code});
      final snapshot = CloudSnapshot.decode(a.cloud.snapshot().encoded);
      for (final event in snapshot.tables['audit_entries']!.values.where(
        (row) => row['target_kind'] == 'bill',
      )) {
        expect(event['device_code'], code);
        expect(event, isNot(contains('member_name')));
      }
    },
  );

  test('bill edit retains transfers, validates stale revisions and merges money as a unit', () {
    final id = a.addBill(
      const BillDraft(
        title: '水费',
        sharedAmount: 800,
        payerId: 1,
        participantIds: [2, 3],
      ),
    );
    a.recordTransfer(id, 2, 250);
    final base = a.cloud.snapshot();
    b.cloud.accept(base, base);
    final before = a.billDetail(id);
    expect(
      () => a.updateBill(
        id,
        const BillDraft(
          title: '无效',
          sharedAmount: 400,
          payerId: 1,
          participantIds: [2, 3],
        ),
        expectedVersion: before.version,
      ),
      invalid,
    );
    expect(
      () => a.updateBill(
        id,
        const BillDraft(
          title: '无效',
          sharedAmount: 800,
          payerId: 2,
          participantIds: [2, 3],
        ),
        expectedVersion: before.version,
      ),
      invalid,
    );
    a.updateBill(
      id,
      const BillDraft(
        title: '本机水费',
        sharedAmount: 1000,
        payerId: 1,
        participantIds: [2, 3],
      ),
      expectedVersion: before.version,
    );
    expect(
      () => a.updateBill(
        id,
        const BillDraft(
          title: '过期',
          sharedAmount: 800,
          payerId: 1,
          participantIds: [2, 3],
        ),
        expectedVersion: before.version,
      ),
      invalid,
    );
    final there = b.billDetail(b.bills().single.id);
    b.updateBill(
      there.bill.id,
      BillDraft(
        title: '云端水费',
        sharedAmount: 900,
        payerId: there.bill.payerId,
        participantIds: there.participants,
      ),
      expectedVersion: there.version,
    );
    final merge = CloudMerge(a.cloud.snapshot(), b.cloud.snapshot(), base);
    expect(merge.conflicts.single.table.name, 'bills');
    final merged = merge.resolve({0: CloudSide.remote});
    a.cloud.accept(merged, merged);
    final after = a.billDetail(id);
    expect(after.bill.total, 900);
    expect(after.bill.outstanding, 650);
    expect(after.transfers.single.amount, 250);
    expect(
      after.activity
          .where((entry) => entry.action == AuditAction.update)
          .map((entry) => entry.deviceCode)
          .toSet(),
      {a.identity.deviceCode, b.identity.deviceCode},
    );
  });

  test('an unclaimed device can edit another avatar and sync its device log', () {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAApElEQVR4nO3QQQ0AIBDAsPOEODyhEgd82aPJBCydtY8ezfeDeIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQD+7huLSwsQlcSUAAAAASUVORK5CYII=';
    a.saveMember('欧阳明', id: 2, avatar: png);
    expect(a.members()[1].avatar, png);
    final first = CloudSnapshot.decode(a.cloud.snapshot().encoded);
    b.cloud.accept(first, first);
    final member = b.members().singleWhere((member) => member.name == '欧阳明');
    expect(member.avatar, png);
    expect(b.memberActivity(member.id).first.deviceCode, a.identity.deviceCode);
    b.saveMember(member.name, id: member.id, clearAvatar: true);
    expect(b.memberActivity(member.id).first.deviceCode, b.identity.deviceCode);
    expect(
      b.members().singleWhere((entry) => entry.id == member.id).avatar,
      isNull,
    );
    expect(
      () => b.saveMember(member.name, id: member.id, avatar: 'bad image'),
      invalid,
    );
  });

  test(
    'given-name avatars keep compound surnames and handle ambiguous names',
    () {
      expect(givenName('张小林'), '小林');
      expect(givenName('欧阳明'), '明');
      expect(givenName('Alice Chen'), 'Alice');
      expect(givenName('小'), isNull);
      expect(givenName('R2-D2'), isNull);
    },
  );
}
