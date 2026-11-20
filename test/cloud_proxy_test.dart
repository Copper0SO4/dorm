import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dormos/data/cloud_proxy.dart';
import 'package:dormos/data/cloud_sync.dart';
import 'package:dormos/data/github_transport.dart';
import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/data/ssh_vault.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'HTTP CONNECT keeps buffered SSH bytes and relays both directions',
    () async {
      await _roundTrip(CloudProxyKind.http, (peer) async {
        final request = await peer.readHeader();
        expect(request, startsWith('CONNECT ssh.github.com:443 HTTP/1.1\r\n'));
        expect(request, contains('Host: ssh.github.com:443\r\n'));
        expect(
          request,
          contains('Proxy-Authorization: Basic dXNlcjpwYXNz\r\n'),
        );
        peer.socket.write('HTTP/1.1 200 Connection established\r\n\r\nserver');
      });
    },
  );

  test('SOCKS5 authenticates, uses proxy-side DNS, and relays SSH', () async {
    await _roundTrip(CloudProxyKind.socks5, (peer) async {
      expect(await peer.read(3), [5, 1, 2]);
      peer.socket.add([5]);
      await peer.socket.flush();
      peer.socket.add([2]);
      expect(await peer.read(11), [
        1,
        4,
        ...ascii.encode('user'),
        4,
        ...ascii.encode('pass'),
      ]);
      peer.socket.add([1, 0]);
      final address = ascii.encode('ssh.github.com');
      expect(await peer.read(5 + address.length + 2), [
        5,
        1,
        0,
        3,
        address.length,
        ...address,
        1,
        187,
      ]);
      peer.socket.add([
        5,
        0,
        0,
        4,
        ...List.filled(16, 0),
        0,
        0,
        ...ascii.encode('server'),
      ]);
    });
  });

  test(
    'Git operations use the proxy and surface HTTP authentication errors',
    () async {
      final proxyServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(proxyServer.close);
      final requests = <String>[];
      proxyServer.listen((socket) async {
        final peer = _Peer(socket);
        try {
          requests.add(await peer.readHeader());
          socket.write('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');
          await socket.flush();
          await socket.close();
        } finally {
          socket.destroy();
          await peer.close();
        }
      });
      final root = await Directory.systemTemp.createTemp('dormos-proxy-git-');
      addTearDown(() => root.delete(recursive: true));
      final settings = CloudSettings(repository: 'test/dorm', operator: '测试');
      final key = await CloudKey.generate();
      final proxy = CloudProxy(
        kind: CloudProxyKind.http,
        host: '127.0.0.1',
        port: proxyServer.port,
      );
      final transport = GitHubTransport(root);
      final rejected = throwsA(
        isA<InputException>().having(
          (e) => e.message,
          'message',
          contains('HTTP 代理需要认证'),
        ),
      );
      await expectLater(transport.pull(settings, key, proxy: proxy), rejected);
      await expectLater(
        transport.push(settings, key, CloudSnapshot({}), null, proxy: proxy),
        rejected,
      );
      expect(requests, hasLength(2));
      expect(requests, everyElement(startsWith('CONNECT ssh.github.com:443 ')));
      final config = File(
        '${root.path}/${cloudRepositoryId(settings.repository)}/config',
      );
      final localConfig = await config.readAsString();
      expect(
        localConfig,
        contains('ssh://git@ssh.github.com:443/test/dorm.git'),
      );
      expect(localConfig, isNot(contains('127.0.0.1')));
    },
  );

  test(
    'proxy settings survive reopening and are applied to pull and push',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dormos-proxy-settings-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = SqliteDormRepository.open(':memory:');
      addTearDown(repository.close);
      final transport = _Transport();
      final cloud = CloudSync(repository.cloud, SshVault(root), transport);
      addTearDown(cloud.dispose);

      final proxy = CloudProxy(
        kind: CloudProxyKind.socks5,
        host: '[::1]',
        port: 7891,
        username: 'proxy-test',
        password: 'test-only',
      );
      await cloud.saveProxy(proxy);
      await cloud.configure(
        CloudSettings(repository: 'owner/repo', operator: '测试'),
        await CloudKey.generate(),
      );
      expect(transport.used.map((proxy) => proxy?.host), ['::1', '::1']);
      expect(transport.used.map((proxy) => proxy?.kind), [
        CloudProxyKind.socks5,
        CloudProxyKind.socks5,
      ]);
      expect((await SshVault(root).readProxy())?.password, 'test-only');
      final invite = (await cloud.exportInvite()).encode();
      expect(utf8.decode(invite), isNot(contains('proxy-test')));
      await cloud.disconnect();
      await cloud.saveProxy(null);
      expect(await SshVault(root).readProxy(), isNull);
    },
  );
}

Future<void> _roundTrip(
  CloudProxyKind kind,
  Future<void> Function(_Peer) handshake,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final exchange = server.first.then((socket) async {
    final peer = _Peer(socket);
    try {
      await handshake(peer);
      await socket.flush();
      expect(ascii.decode(await peer.read(6)), 'client');
    } finally {
      socket.destroy();
      await peer.close();
    }
  });
  // Attach the handler before waiting for the reply so failed expectations
  // terminate the test rather than leaving the client waiting on the socket.
  final done = expectLater(exchange, completes);
  final tunnel = await GitHubProxyTunnel.open(
    CloudProxy(
      kind: kind,
      host: '127.0.0.1',
      port: server.port,
      username: 'user',
      password: 'pass',
    ),
  );
  addTearDown(tunnel.close);
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    tunnel.port,
  );
  final peer = _Peer(socket);
  addTearDown(() async {
    socket.destroy();
    await peer.close();
  });
  expect(ascii.decode(await peer.read(6)), 'server');
  socket.write('client');
  await socket.flush();
  await done;
}

class _Peer {
  _Peer(this.socket) : _bytes = StreamIterator(socket.expand((chunk) => chunk));
  final Socket socket;
  final StreamIterator<int> _bytes;

  Future<int> _read() async {
    if (!await _bytes.moveNext()) throw StateError('premature EOF');
    return _bytes.current;
  }

  Future<List<int>> read(int count) async => [
    for (var i = 0; i < count; i++) await _read(),
  ];

  Future<String> readHeader() async {
    var text = '';
    while (!text.endsWith('\r\n\r\n')) {
      text += String.fromCharCode(await _read());
    }
    return text;
  }

  Future<void> close() => _bytes.cancel();
}

class _Transport implements CloudTransport {
  final used = <CloudProxy?>[];

  @override
  Future<RemoteCloud?> pull(
    CloudSettings settings,
    CloudKey key, {
    CloudProxy? proxy,
  }) async {
    used.add(proxy);
    return null;
  }

  @override
  Future<void> push(
    CloudSettings settings,
    CloudKey key,
    CloudSnapshot data,
    String? expectedRevision, {
    CloudProxy? proxy,
  }) async {
    used.add(proxy);
  }
}
