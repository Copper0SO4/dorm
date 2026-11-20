import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/ledger.dart';

const githubSshHost = 'ssh.github.com';
const githubSshPort = 443;

enum CloudProxyKind {
  http('HTTP CONNECT'),
  socks5('SOCKS5');

  const CloudProxyKind(this.label);
  final String label;
}

class CloudProxy {
  CloudProxy({
    required this.kind,
    required String host,
    required this.port,
    this.username = '',
    this.password = '',
  }) : host = _host(host) {
    if (port < 1 || port > 65535) {
      throw const InputException('请输入 1 至 65535 之间的代理端口');
    }
    if (username.isEmpty && password.isNotEmpty ||
        kind == CloudProxyKind.socks5 &&
            username.isNotEmpty &&
            password.isEmpty) {
      throw const InputException('请填写完整的代理用户名和密码');
    }
    if (utf8.encode(username).length > 255 ||
        utf8.encode(password).length > 255 ||
        (kind == CloudProxyKind.http && username.contains(':'))) {
      throw const InputException('代理用户名或密码格式不正确');
    }
  }

  final CloudProxyKind kind;
  final String host;
  final int port;
  final String username;
  final String password;

  static String _host(String input) {
    var host = input.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (InternetAddress.tryParse(host) == null &&
        !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$').hasMatch(host)) {
      throw const InputException('请输入代理主机名或 IP 地址');
    }
    return host;
  }
}

/// Exposes GitHub SSH through a temporary IPv4 loopback listener for libgit2.
/// It negotiates the proxy transport only. Git authenticates the SSH endpoint.
class GitHubProxyTunnel {
  GitHubProxyTunnel._(this._server, this._proxy);

  static Future<GitHubProxyTunnel> open(CloudProxy proxy) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tunnel = GitHubProxyTunnel._(server, proxy);
    server.listen(
      (client) => unawaited(tunnel._bridge(client)),
      onError: (Object _) {
        tunnel.failure ??= const InputException('无法建立本机 Git 代理隧道');
      },
    );
    return tunnel;
  }

  static const _handshakeTimeout = Duration(seconds: 8);
  static const _idleTimeout = Duration(seconds: 30);

  final ServerSocket _server;
  final CloudProxy _proxy;
  final _sockets = <Socket>{};
  bool _closed = false;
  InputException? failure;

  int get port => _server.port;

  Future<void> close() async {
    _closed = true;
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }

  Future<void> _bridge(Socket client) async {
    _sockets.add(client);
    Socket? upstream;
    _ProxyReader? reader;
    Timer? idle;
    try {
      final socket = upstream = await Socket.connect(
        _proxy.host,
        _proxy.port,
        timeout: _handshakeTimeout,
      );
      if (_closed) return;
      _sockets.add(socket);
      final input = reader = _ProxyReader(socket);
      final handshake = switch (_proxy.kind) {
        CloudProxyKind.http => _httpConnect(socket, input),
        CloudProxyKind.socks5 => _socksConnect(socket, input),
      };
      await handshake.timeout(_handshakeTimeout);
      void resetIdle() {
        idle?.cancel();
        idle = Timer(_idleTimeout, () {
          failure ??= const InputException('代理连接 GitHub 超时，请检查代理规则');
          client.destroy();
          socket.destroy();
        });
      }

      resetIdle();
      await Future.wait([
        _relay(client, socket, resetIdle),
        _relay(input.remaining(), client, resetIdle),
      ], eagerError: true);
    } on InputException catch (error) {
      if (!_closed) failure ??= error;
    } on TimeoutException {
      if (!_closed) {
        failure ??= const InputException('连接代理超时，请检查地址、端口和代理规则');
      }
    } on SocketException {
      if (!_closed) {
        failure ??= const InputException('代理连接失败，请检查地址、端口和代理服务');
      }
    } on StateError {
      if (!_closed) {
        failure ??= const InputException('代理连接已断开，请重试');
      }
    } finally {
      idle?.cancel();
      client.destroy();
      upstream?.destroy();
      _sockets.remove(client);
      _sockets.remove(upstream);
      await reader?.cancel();
    }
  }

  Future<void> _httpConnect(Socket socket, _ProxyReader reader) async {
    const target = '$githubSshHost:$githubSshPort';
    final auth = _proxy.username.isEmpty
        ? ''
        : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${_proxy.username}:${_proxy.password}'))}\r\n';
    socket.write('CONNECT $target HTTP/1.1\r\nHost: $target\r\n$auth\r\n');
    await socket.flush();
    final header = await reader.httpHeader();
    final status = RegExp(r'^HTTP/1\.[01] ([0-9]{3})(?: |$)')
        .firstMatch(header.split('\r\n').first)
        ?.group(1);
    if (status == '407') {
      throw const InputException('HTTP 代理需要认证或拒绝了用户名和密码');
    }
    if (status == null || !status.startsWith('2')) {
      throw const InputException('HTTP 代理未建立到 GitHub 的 CONNECT 隧道');
    }
  }

  Future<void> _socksConnect(Socket socket, _ProxyReader reader) async {
    final user = utf8.encode(_proxy.username);
    final password = utf8.encode(_proxy.password);
    final method = user.isEmpty ? 0 : 2;
    socket.add([5, 1, method]);
    await socket.flush();
    final choice = await reader.read(2);
    if (choice[0] != 5 || choice[1] != method) {
      throw const InputException('SOCKS5 代理不接受当前认证方式，请检查设置');
    }
    if (method == 2) {
      socket.add([1, user.length, ...user, password.length, ...password]);
      await socket.flush();
      final response = await reader.read(2);
      if (response[0] != 1 || response[1] != 0) {
        throw const InputException('SOCKS5 代理拒绝了用户名和密码');
      }
    }
    final host = ascii.encode(githubSshHost);
    socket.add([
      5,
      1,
      0,
      3,
      host.length,
      ...host,
      githubSshPort >> 8,
      githubSshPort & 255,
    ]);
    await socket.flush();
    final response = await reader.read(4);
    if (response[0] != 5 || response[1] != 0 || response[2] != 0) {
      throw const InputException('SOCKS5 代理未能连接 GitHub SSH');
    }
    final size = switch (response[3]) {
      1 => 4,
      3 => (await reader.read(1)).single,
      4 => 16,
      _ => throw const InputException('SOCKS5 代理返回了无效的地址类型'),
    };
    await reader.read(size + 2);
  }
}

Future<void> _relay(
  Stream<List<int>> source,
  Socket destination,
  void Function() onTraffic,
) async {
  await destination.addStream(
    source.map((bytes) {
      onTraffic();
      return bytes;
    }),
  );
  await destination.close();
}

class _ProxyReader {
  _ProxyReader(Socket socket) : _chunks = StreamIterator(socket);

  final StreamIterator<List<int>> _chunks;
  List<int> _chunk = const [];
  int _offset = 0;

  Future<int> _nextByte() async {
    if (_offset == _chunk.length) {
      if (!await _chunks.moveNext()) {
        throw const InputException('代理在完成握手前关闭了连接');
      }
      _chunk = _chunks.current;
      _offset = 0;
    }
    return _chunk[_offset++];
  }

  Future<List<int>> read(int length) async => [
    for (var i = 0; i < length; i++) await _nextByte(),
  ];

  Future<String> httpHeader() async {
    const end = [13, 10, 13, 10];
    var matched = 0;
    final bytes = <int>[];
    while (bytes.length < 16384) {
      final byte = await _nextByte();
      bytes.add(byte);
      matched = byte == end[matched] ? matched + 1 : (byte == 13 ? 1 : 0);
      if (matched == end.length) return latin1.decode(bytes);
    }
    throw const InputException('HTTP 代理响应头过长');
  }

  Stream<List<int>> remaining() async* {
    if (_offset < _chunk.length) yield _chunk.sublist(_offset);
    while (await _chunks.moveNext()) {
      yield _chunks.current;
    }
  }

  Future<void> cancel() => _chunks.cancel();
}
