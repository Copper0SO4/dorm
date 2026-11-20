import 'dart:convert';
import 'dart:io';

import 'package:dormos/data/lan_api.dart';
import 'package:dormos/data/lan_server.dart';
import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/matters.dart';
import 'package:dormos/domain/models.dart';
import 'package:dormos/domain/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
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
    String? token,
    String? origin,
  }) async {
    final uri = address.resolve(path);
    final request = await client.openUrl(data == null ? 'GET' : 'POST', uri);
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
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

  Future<String> connect() async {
    final response = await request(
      '/api/session',
      data: {'code': server.pairingCode},
      origin: address.origin,
    );
    expect(response.status, 200);
    final body = jsonDecode(response.text) as Map<String, dynamic>;
    return body['token'] as String;
  }

  test(
    'serves the bundled workspace and requires a current pairing code',
    () async {
      final page = await request('/');
      expect(page.status, 200);
      expect(page.text, contains('局域网'));
      expect(page.csp, contains("script-src 'self'"));
      expect((await request('/dorm.css')).status, 200);
      expect((await request('/dorm.js')).status, 200);
      expect((await request('/assets/lan/index.html')).status, 404);
      expect((await request('/api/members')).status, 401);
      expect(
        (await request('/api/session', data: {'code': 'wrong'})).status,
        401,
      );
      final token = await connect();
      expect((await request('/api/members', token: token)).text, contains('甲'));
      final denied = await request(
        '/api/chores/generate',
        token: token,
        origin: 'https://elsewhere.invalid',
        data: {'day': dayKey(today())},
      );
      expect(denied.status, 403);
      expect(writes, 0);

      server.rotateCode();
      expect((await request('/api/members', token: token)).status, 401);
      server.addresses.singleWhere((item) => item == address.origin);
      final fresh = await connect();
      expect((await request('/api/members', token: fresh)).status, 200);
      await server.stop();
      expect(server.running, isFalse);
    },
  );

  test('updates the same repository across all workspace modules', () async {
    final token = await connect();
    Future<void> post(String path, Map<String, Object?> data) async {
      final response = await request(
        path,
        data: data,
        token: token,
        origin: address.origin,
      );
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
    expect(
      (await request('/api/ledger/${bill.id}', token: token)).text,
      contains('室友采购'),
    );
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
  });
}
