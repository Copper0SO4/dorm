import 'dart:convert';
import 'dart:io';

import 'package:dormos/data/lan_api.dart';
import 'package:dormos/data/lan_server.dart';
import 'package:dormos/data/qr_image.dart';
import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/matters.dart';
import 'package:dormos/domain/models.dart';
import 'package:dormos/domain/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SqliteDormRepository repository;
  late DormLanServer server;
  late HttpClient client;
  late Uri address;
  late int writes;

  setUp(() async {
    repository = SqliteDormRepository.open(':memory:');
    for (final name in ['甲', '乙', '丙']) {
      repository.saveMember(name);
    }
    writes = 0;
    server = DormLanServer(
      LanApi(repository, (operation) {
        operation();
        writes++;
      }),
      (path) => File(path).readAsString(),
    );
    client =
        HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttpClient())
          ..connectionTimeout = const Duration(seconds: 5)
          ..findProxy = ((_) => 'DIRECT');
    await server.start(0);
    address = Uri.parse('http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    server.dispose();
    repository.close();
  });

  Future<({int status, String text, String? csp})> request(
    String path, {
    Map<String, Object?>? data,
    String? origin,
    String? host,
    String? fetchSite,
  }) async {
    final uri = address.resolve(path);
    final request = await client.openUrl(data == null ? 'GET' : 'POST', uri);
    if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
    if (fetchSite != null) request.headers.set('Sec-Fetch-Site', fetchSite);
    if (origin != null) request.headers.set('Origin', origin);
    if (data != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(data));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (
      status: response.statusCode,
      text: text,
      csp: response.headers.value('Content-Security-Policy'),
    );
  }

  test(
    'browser bill edits preserve the browser device code in the audit log',
    () async {
      const clientCode = 'd7a33e5d731d4a3aa05b45e1da54c819';
      final fields = <String, Object?>{
        'title': '局域网原始账单',
        'shared': '5',
        'payerId': 1,
        'participants': [2],
        'personal': <String, Object?>{},
        'browserDevice': clientCode,
      };
      expect(
        (await request(
          '/api/ledger',
          data: fields,
          origin: address.origin,
        )).status,
        200,
      );
      final bill = repository.bills().single;
      final response = await request('/api/ledger/${bill.id}');
      final original = jsonDecode(response.text) as Map;
      final update = await request(
        '/api/ledger/edit',
        origin: address.origin,
        data: {
          ...fields,
          'title': '局域网修改账单',
          'id': bill.id,
          'version': original['version'],
        },
      );
      expect(update.status, 200, reason: update.text);
      final result = repository.billDetail(bill.id);
      expect(result.bill.title, '局域网修改账单');
      expect(result.activity.map((entry) => entry.deviceCode).toSet(), {
        clientCode,
      });
      expect(
        result.activity.every((entry) => entry.memberName == null),
        isTrue,
      );
    },
  );

  test(
    'opens the workspace without an access code and guards other sites',
    () async {
      final link = server.addresses.singleWhere(
        (item) => item == address.origin,
      );
      final fromQr = await readQrImageText(await makeQrPng(link));
      expect(fromQr, link);
      final page = await request(Uri.parse(fromQr).path);
      expect(page.status, 200);
      expect(page.text, contains('局域网'));
      expect(page.text, isNot(contains('id="pair"')));
      expect(page.csp, contains("script-src 'self'"));
      expect((await request('/dorm.css')).status, 200);
      expect((await request('/dorm.js')).status, 200);
      expect((await request('/tools.js')).status, 200);
      expect((await request('/assets/lan/index.html')).status, 404);
      expect((await request('/api/members')).text, contains('甲'));
      final toolsJson = jsonDecode((await request('/api/tools')).text) as Map;
      expect(toolsJson['members'], ['甲', '乙', '丙']);
      expect((toolsJson['presets'] as List), isNotEmpty);

      final task = {'day': dayKey(today())};
      expect(
        (await request(
          '/api/chores/generate',
          data: task,
          origin: 'https://elsewhere.invalid',
        )).status,
        403,
      );
      expect(
        (await request(
          '/api/chores/generate',
          data: task,
          fetchSite: 'same-site',
        )).status,
        403,
      );
      expect(
        (await request(
          '/api/members',
          host: '127.0.0.2:${server.port}',
        )).status,
        403,
      );
      expect(
        (await request(
          '/api/chores/generate',
          data: task,
          host: '127.0.0.2:${server.port}',
          origin: 'http://127.0.0.2:${server.port}',
        )).status,
        403,
      );
      expect(writes, 0);

      await server.stop();
      expect(server.running, isFalse);
      expect(server.addresses, isEmpty);
    },
  );

  test('updates the same repository across all workspace modules', () async {
    Future<void> post(String path, Map<String, Object?> data) async {
      final response = await request(path, data: data, origin: address.origin);
      expect(response.status, 200, reason: '$path ${response.text}');
    }

    await post('/api/supplies/save', {
      'name': '清洁剂',
      'category': '卫生',
      'quantity': 0,
      'location': '柜子',
      'note': '',
      'status': 'needed',
    });
    final supply = repository.supplies().single;
    await post('/api/ledger', {
      'title': '室友采购',
      'shared': '10.01',
      'payerId': 3,
      'participants': [1, 2],
      'personal': {'1': '2.75'},
      'supplyId': supply.id,
    });
    final bill = repository.bills().single;
    expect(bill.total, 1276);
    expect(bill.supplyName, '清洁剂');
    expect(repository.supplies().single.status, PurchaseStatus.ordered);
    await post('/api/transfers', {
      'billId': bill.id,
      'memberId': 1,
      'amount': '7.76',
    });
    expect(repository.bills().single.outstanding, 500);
    expect((await request('/api/ledger/${bill.id}')).text, contains('室友采购'));
    await post('/api/supplies/receive', {'id': supply.id, 'quantity': 2});
    expect(repository.supplies().single.quantity, 2);
    expect(repository.supplies().single.status, PurchaseStatus.stocked);

    repository.addChore('扫地', Cadence.daily, today());
    await post('/api/chores/generate', {'day': dayKey(today())});
    final shift = repository.shifts(today(), today()).single;
    await post('/api/chores/complete', {'id': shift.id});
    expect(repository.shifts(today(), today()).single.completedAt, isNotNull);

    await post('/api/matters/save', {
      'title': '报修',
      'note': '',
      'ownerId': 2,
      'due': '',
      'urgent': true,
    });
    final matter = repository.matters().single;
    await post('/api/matters/status', {'id': matter.id, 'status': 'done'});
    await post('/api/matters/archive', {'id': matter.id, 'archived': true});
    expect(repository.matters().single.status, MatterStatus.done);
    expect(repository.matters().single.archived, isTrue);
    expect(writes, 9);

    await post('/api/ledger/delete', {'id': bill.id});
    expect(repository.bills(), isEmpty);
    expect(repository.supplies().single.name, '清洁剂');
    expect((await request('/api/ledger/${bill.id}')).status, 400);
    expect(jsonDecode((await request('/api/ledger')).text)['count'], 0);
    expect(writes, 10);

    await post('/api/members/save', {'name': '丁'});
    final added = repository.members().singleWhere((m) => m.name == '丁');
    await post('/api/members/active', {'id': added.id, 'active': false});
    expect(
      repository.members().singleWhere((m) => m.id == added.id).active,
      isFalse,
    );
    await post('/api/members/delete', {'id': added.id});
    expect(repository.members().any((m) => m.id == added.id), isFalse);

    await post('/api/ledger', {
      'title': '批量核销测试',
      'shared': '10.00',
      'payerId': 1,
      'participants': [1, 2],
      'personal': <String, Object?>{},
    });
    final ledgerJson = jsonDecode((await request('/api/ledger')).text) as Map;
    final openPairs = ledgerJson['openSettlements'] as List;
    expect(openPairs, hasLength(1));
    final pair = openPairs.single as Map;
    final charge = (pair['charges'] as List).single as Map;
    await post('/api/settlement', {
      'debtorId': pair['debtorId'],
      'payerId': pair['payerId'],
      'expected': {'${charge['billId']}': charge['amount']},
      'amount': '5.00',
    });
    expect(repository.openSettlements(), isEmpty);

    final nextDay = today().add(const Duration(days: 1));
    await post('/api/chores/generate', {'day': dayKey(nextDay)});
    final tomorrowShift = repository.shifts(nextDay, nextDay).single;
    await post('/api/chores/reassign', {'id': tomorrowShift.id, 'memberId': 2});
    expect(repository.shifts(nextDay, nextDay).single.memberId, 2);
    await post('/api/supplies/delete', {'id': supply.id});
    expect(repository.supplies(), isEmpty);
  });
}

class _RealHttpClient extends HttpOverrides {}
