import 'dart:convert';
import 'dart:io';

import 'package:dormos/data/cloud_proxy.dart';
import 'package:dormos/data/cloud_sync.dart';
import 'package:dormos/data/github_transport.dart';
import 'package:dormos/data/schema.dart';
import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/data/ssh_vault.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/domain/matters.dart';
import 'package:dormos/domain/models.dart';
import 'package:dormos/ui/app.dart';
import 'package:dormos/ui/common.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  testWidgets(
    'desktop settings normalize the Git URL, mask the key, and copy the full key',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 840));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = Directory.systemTemp.createTempSync('dormos-cloud-widget-');
      addTearDown(() => root.delete(recursive: true));
      final repo = SqliteDormRepository.open(':memory:');
      addTearDown(repo.close);
      final sync = CloudSync(
        repo.cloud,
        _WidgetVault(root),
        GitHubTransport(root),
      );
      final controller = DormController(repo, cloud: sync);
      addTearDown(controller.dispose);
      await tester.pumpWidget(DormApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('配置仓库'), findsNothing);
      await tester.tap(find.text('云同步'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('配置仓库'));
      await tester.tap(find.text('配置仓库'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://github.com/Room/Dorm',
      );
      await tester.pumpAndSettle();
      expect(find.text('git@github.com:room/dorm.git'), findsOneWidget);
      expect(find.text('粘贴 SSH 私钥'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('生成 SSH 密钥'));
      await tester.tap(find.text('生成 SSH 密钥'));
      await tester.pumpAndSettle();
      final publicKey = _WidgetVault.publicKey;
      final data = publicKey.split(' ')[1];
      final mask = find.byKey(const ValueKey('masked-ssh-key'));
      expect(
        tester.widget<Text>(mask).data,
        'ssh-ed25519 ${data.substring(0, 6)}********${data.substring(data.length - 6)}',
      );
      expect(find.text(publicKey), findsNothing);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? copied;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.ensureVisible(find.text('复制公钥'));
      await tester.tap(find.text('复制公钥'));
      await tester.pumpAndSettle();
      expect(copied, _WidgetVault.publicKey);

      await tester.ensureVisible(find.text('配置仓库'));
      await tester.tap(find.text('配置仓库'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      expect(find.text('粘贴 SSH 私钥'), findsNothing);
    },
  );

  testWidgets(
    'proxy settings can be configured before connecting a repository',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('dormos-proxy-widget-');
      addTearDown(() => root.delete(recursive: true));
      final repo = SqliteDormRepository.open(':memory:');
      addTearDown(repo.close);
      final vault = _WidgetVault(root);
      final sync = CloudSync(repo.cloud, vault, GitHubTransport(root));
      final controller = DormController(repo, cloud: sync);
      addTearDown(controller.dispose);
      await tester.pumpWidget(DormApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('配置仓库'), findsNothing);
      await tester.tap(find.text('云同步'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('代理设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('代理设置'));
      await tester.pumpAndSettle();
      expect(find.text('云同步代理'), findsOneWidget);
      await tester.tap(find.text('启用代理'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<CloudProxyKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SOCKS5').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '代理主机'),
        '127.0.0.1',
      );
      await tester.enterText(find.widgetWithText(TextField, '代理端口'), '7891');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(sync.settings, isNull);
      expect((await vault.readProxy())?.kind, CloudProxyKind.socks5);
      expect((await vault.readProxy())?.port, 7891);
      expect(find.text('SOCKS5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'migrates a v2 cloud configuration with its existing sync baseline',
    () async {
      final root = await Directory.systemTemp.createTemp('dormos-cloud-v2-');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/dorm.sqlite';
      final before = SqliteDormRepository.open(path);
      before.saveMember('旧成员');
      before.cloud.saveSettings(
        CloudSettings(repository: 'test/dorm', operator: '原操作者'),
      );
      final base = before.cloud.snapshot();
      before.cloud.rememberBase(base);
      before.close();
      final raw = sqlite3.open(path);
      raw.execute('DROP TABLE matters');
      raw.execute('ALTER TABLE bills DROP COLUMN deleted');
      raw.execute('DROP INDEX transfers_batch');
      raw.execute('ALTER TABLE transfers DROP COLUMN batch_id');
      raw.execute('ALTER TABLE shares DROP COLUMN personal_amount');
      raw.execute('ALTER TABLE cloud_settings DROP COLUMN use_device_key');
      raw.execute('PRAGMA user_version = 2');
      raw.close();
      final after = SqliteDormRepository.open(path);
      addTearDown(after.close);

      expect(after.cloud.settings!.operator, '原操作者');
      expect(after.cloud.settings!.useDeviceKey, isFalse);
      expect(after.cloud.base!.sameAs(base), isTrue);
      expect(after.cloud.snapshot().sameAs(base), isTrue);
    },
  );

  test('deleted bills stay removed when merging a concurrent transfer', () {
    final a = SqliteDormRepository.open(':memory:');
    final b = SqliteDormRepository.open(':memory:');
    addTearDown(a.close);
    addTearDown(b.close);
    a.saveMember('付款人');
    a.saveMember('参与人');
    final firstId = a.addBill(
      const BillDraft(
        title: '将删除的账单',
        sharedAmount: 500,
        payerId: 1,
        participantIds: [2],
      ),
    );
    final base = CloudSnapshot.decode(a.cloud.snapshot().encoded);
    expect((jsonDecode(base.encoded) as Map)['format'], 1);
    b.cloud.accept(base, base);
    final debtor = b.members().singleWhere((member) => member.name == '参与人');
    b.recordTransfer(b.bills().single.id, debtor.id, 200);
    a.deleteBill(firstId);
    final deleted = CloudSnapshot.decode(a.cloud.snapshot().encoded);
    expect((jsonDecode(deleted.encoded) as Map)['format'], 4);
    expect(deleted.tables['bills']!.values.single['deleted'], 1);
    final merge = CloudMerge(b.cloud.snapshot(), deleted, base);
    expect(merge.conflicts, isEmpty);
    final result = merge.resolve({});
    b.cloud.accept(result, result);
    expect(b.bills(), isEmpty);
    expect(b.balances().every((balance) => balance.payable == 0), isTrue);
    expect(
      b.cloud.snapshot().tables['transfers']!.values.single['amount'],
      200,
    );
    expect(b.cloud.snapshot().sameAs(result), isTrue);
  });

  test('the bundled Git runtime supports SSH', () {
    expect(Libgit2.features, contains(GitFeature.ssh));
  });
  test(
    'normalizes GitHub HTTPS and SSH and rejects other hosts and extra paths',
    () {
      for (final value in [
        'https://github.com/Room/Dorm/',
        'git@github.com:ROOM/dorm.git',
        'ssh://git@github.com/room/dorm.git',
        'room/dorm',
      ]) {
        expect(githubSshAddress(value), 'git@github.com:room/dorm.git');
      }
      for (final value in [
        'https://github.com.evil.test/room/dorm',
        'git@evil.test:room/dorm',
        'https://github.com/room/dorm/tree/main',
        'room/dorm;ls',
        'room/..',
      ]) {
        expect(() => githubSshAddress(value), throwsA(isA<InputException>()));
      }
    },
  );

  test(
    'migrates an existing database and retains its integer IDs and transfers',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dormos-cloud-migrate-',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/dorm.sqlite';
      final old = sqlite3.open(path);
      for (final statement in schema) {
        old.execute(statement);
      }
      old.execute('PRAGMA user_version = 1');
      old.execute("INSERT INTO members(id,name) VALUES(47,'旧成员'),(48,'甲')");
      old.execute(
        "INSERT INTO bills(id,title,total,payer_id,created_at) VALUES(52,'旧账单',400,47,'2026-01-02T00:00:00Z')",
      );
      old.execute('INSERT INTO shares VALUES(52,47,200),(52,48,200)');
      old.execute(
        "INSERT INTO transfers(id,bill_id,member_id,amount,created_at) VALUES(57,52,48,100,'2026-01-02T00:00:00Z')",
      );
      old.close();
      final repository = SqliteDormRepository.open(path);
      addTearDown(repository.close);
      expect(repository.members().first.id, 47);
      expect(repository.billDetail(52).transfers.single.amount, 100);
      expect(
        repository.billDetail(52).shares.map((share) => share.personalAmount),
        [0, 0],
      );
      final data = repository.cloud.snapshot();
      expect(CloudSnapshot.decode(data.encoded).sameAs(data), isTrue);
      expect(
        data.tables['members']!.keys,
        everyElement(matches(r'^[a-f0-9]{32}$')),
      );
      final target = SqliteDormRepository.open(':memory:');
      addTearDown(target.close);
      target.cloud.accept(data, data);
      expect(target.cloud.snapshot().sameAs(data), isTrue);
      expect(target.bills().single.outstanding, 100);
    },
  );

  test('concurrent overpayment fails atomically without replacing any local records', () {
    final repository = SqliteDormRepository.open(':memory:');
    addTearDown(repository.close);
    repository.saveMember('甲');
    repository.saveMember('乙');
    final bill = repository.addBill(
      BillDraft(
        title: '水',
        sharedAmount: 200,
        payerId: 1,
        participantIds: [1, 2],
        supplyId: null,
      ),
    );
    final base = repository.cloud.snapshot();
    repository.recordTransfer(bill, 2, 60);
    final left = repository.cloud.snapshot();
    final other = SqliteDormRepository.open(':memory:');
    addTearDown(other.close);
    other.cloud.accept(base, base);
    final debtor = other.members().firstWhere((member) => member.name == '乙');
    other.recordTransfer(other.bills().single.id, debtor.id, 60);
    final right = other.cloud.snapshot();
    final merge = CloudMerge(left, right, base);
    expect(merge.conflicts, isEmpty);
    expect(
      () => repository.cloud.accept(merge.resolve({}), right),
      throwsA(isA<InputException>()),
    );
    expect(repository.cloud.snapshot().sameAs(left), isTrue);
    expect(repository.billDetail(bill).transfers.single.amount, 60);
  });

  test('two devices pull, merge independent edits, and resolve a row conflict through a Git repository', () async {
    final root = await Directory.systemTemp.createTemp('dormos-cloud-git-');
    addTearDown(() => root.delete(recursive: true));
    final bare = Directory('${root.path}/remote.git')..createSync();
    Repository.initBasic(path: bare.path, bare: true).free();
    final a = SqliteDormRepository.open('${root.path}/a.sqlite');
    final b = SqliteDormRepository.open('${root.path}/b.sqlite');
    addTearDown(a.close);
    addTearDown(b.close);
    final homeA = Directory('${root.path}/a');
    final homeB = Directory('${root.path}/b');
    final gitA = GitHubTransport(
      Directory('${homeA.path}/git'),
      localTestRemote: bare,
    );
    final gitB = GitHubTransport(
      Directory('${homeB.path}/git'),
      localTestRemote: bare,
    );
    final syncA = CloudSync(a.cloud, SshVault(homeA), gitA);
    final syncB = CloudSync(b.cloud, SshVault(homeB), gitB);
    addTearDown(syncA.dispose);
    addTearDown(syncB.dispose);
    final key = _syntheticKey();
    final identityA = CloudSettings(
      repository: 'https://github.com/test-owner/dorm',
      operator: '操作者甲',
    );
    final identityB = CloudSettings(
      repository: 'test-owner/dorm',
      operator: '操作者乙',
    );

    final deviceIdentity = CloudSettings(
      repository: identityA.repository,
      operator: identityA.operator,
      useDeviceKey: true,
    );
    final keys = await Future.wait([
      syncA.generateDevicePublicKey(),
      syncA.generateDevicePublicKey(),
    ]);
    expect(keys.first, matches(r'^ssh-ed25519 [A-Za-z0-9+/]+=*$'));
    expect(keys.last, keys.first);
    final newVault = SshVault(homeA);
    expect((await newVault.readDevice())!.publicKey, keys.first);
    expect((await CloudKey.generate()).publicKey, isNot(keys.first));

    a.saveMember('原姓名');
    await syncA.configure(deviceIdentity, null);
    final invite = await syncA.exportInvite();
    expect(invite.repository, identityA.repository);
    expect(invite.requiresPassword, isFalse);
    expect(a.cloud.settings!.useDeviceKey, isTrue);
    expect(await newVault.read(identityA.repository), isNull);
    expect(syncA.error, isNull);
    await syncB.configure(identityB, key);
    expect(syncB.error, isNull);
    expect(b.members().single.name, '原姓名');
    expect(b.cloud.settings!.operator, '操作者乙');
    final localA = a.members().single.id;
    final localB = b.members().single.id;

    a.saveMember('独立成员甲');
    b.saveMember('独立成员乙');
    await syncA.sync();
    await syncB.sync();
    expect(syncB.error, isNull);
    expect(syncB.conflict, isNull);
    await syncA.sync();
    expect(
      a.members().map((member) => member.name),
      unorderedEquals(['原姓名', '独立成员甲', '独立成员乙']),
    );

    a.saveMember('本机甲版本', id: localA);
    b.saveMember('本机乙版本', id: localB);
    await syncA.sync();
    await syncB.sync();
    expect(syncB.conflict?.merge?.conflicts, hasLength(1));
    await syncB.resolve(choices: {0: CloudSide.local});
    expect(syncB.error, isNull);
    expect(syncB.conflict, isNull);
    await syncA.sync();
    expect(
      a.members().firstWhere((member) => member.id == localA).name,
      '本机乙版本',
    );
    final remote = (await gitA.pull(identityA, key))!;
    expect(remote.author, '操作者乙');
    expect(remote.data.encoded, isNot(contains('OPENSSH PRIVATE KEY')));
    a.saveMember('重启时拉取');
    await syncA.sync();
    final reopened = SqliteDormRepository.open('${root.path}/b.sqlite');
    addTearDown(reopened.close);
    final restarted = CloudSync(
      reopened.cloud,
      SshVault(homeB),
      GitHubTransport(Directory('${homeB.path}/git'), localTestRemote: bare),
    );
    addTearDown(restarted.dispose);
    await restarted.startup();
    expect(restarted.error, isNull);
    expect(reopened.cloud.settings!.operator, '操作者乙');
    expect(reopened.members().map((member) => member.name), contains('重启时拉取'));

    expect((jsonDecode(a.cloud.snapshot().encoded) as Map)['format'], 1);
    final payerId = a
        .members()
        .firstWhere((member) => member.name == '本机乙版本')
        .id;
    final borrowerId = a
        .members()
        .firstWhere((member) => member.name == '独立成员甲')
        .id;
    a.addBill(
      BillDraft(
        title: '饮料代付',
        sharedAmount: 1000,
        payerId: payerId,
        participantIds: [borrowerId, payerId],
        personalAmounts: {borrowerId: 300},
      ),
    );
    await syncA.sync();
    expect(syncA.error, isNull);
    await restarted.sync();
    expect(restarted.error, isNull);
    final syncedBill = reopened.billDetail(reopened.bills().single.id);
    expect(syncedBill.bill.total, 1300);
    expect(syncedBill.bill.outstanding, 800);
    expect(
      syncedBill.shares.singleWhere((share) => share.personalAmount > 0).amount,
      800,
    );
    expect((jsonDecode(reopened.cloud.snapshot().encoded) as Map)['format'], 2);

    final charge = a.openSettlements().single.charges.single;
    a.recordSettlement(borrowerId, payerId, {
      charge.billId: charge.amount,
    }, 200);
    final matter = a.saveMatter((
      title: '联系宿管',
      note: '处理公共照明',
      ownerId: borrowerId,
      due: DateTime(2026, 12, 10),
      urgent: true,
    ));
    a.setMatterStatus(matter, MatterStatus.doing);
    await syncA.sync();
    expect(syncA.error, isNull);
    await restarted.sync();
    expect(restarted.error, isNull);
    expect((jsonDecode(reopened.cloud.snapshot().encoded) as Map)['format'], 3);
    expect(reopened.matters().single.owner, '独立成员甲');
    expect(reopened.matters().single.status, MatterStatus.doing);
    expect(reopened.settlementHistory().single.allocations.single.amount, 200);

    final openedA = SqliteDormRepository.open('${root.path}/a.sqlite');
    addTearDown(openedA.close);
    expect(openedA.cloud.settings!.useDeviceKey, isTrue);
    await syncA.disconnect();
    expect(syncA.settings, isNull);
    expect(await syncA.devicePublicKey(), keys.first);
  });
}

// Deliberately not a usable private key. The transport test uses a local bare
// repository, and this fixture exercises the application's key container parser.
CloudKey _syntheticKey() {
  Uint8List field(List<int> value) {
    final length = ByteData(4)..setUint32(0, value.length);
    return Uint8List.fromList([...length.buffer.asUint8List(), ...value]);
  }

  final body = [
    ...utf8.encode('openssh-key-v1\u0000'),
    ...field(utf8.encode('none')),
    ...field(utf8.encode('none')),
    ...field([]),
    0,
    0,
    0,
    1,
    ...field(field(utf8.encode('ssh-ed25519'))),
    ...field([0, 0, 0, 0]),
  ];
  return CloudKey(
    '-----BEGIN OPENSSH PRIVATE KEY-----\n${base64.encode(body)}\n-----END OPENSSH PRIVATE KEY-----',
    '',
  );
}

class _WidgetVault extends SshVault {
  _WidgetVault(super.appDirectory);

  static String get publicKey => _syntheticKey().publicKey;
  CloudKey? _deviceKey;
  CloudProxy? _proxy;

  @override
  Future<CloudProxy?> readProxy() async => _proxy;

  @override
  Future<void> saveProxy(CloudProxy? proxy) async {
    _proxy = proxy;
  }

  @override
  Future<CloudKey?> readDevice() async => _deviceKey;

  @override
  Future<CloudKey> generateDevice() async => _deviceKey ??= _syntheticKey();
}
