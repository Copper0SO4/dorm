import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/ledger.dart';
import 'lan_api.dart';

const _files = {
  '/': (file: 'index.html', type: 'html'),
  '/dorm.css': (file: 'dorm.css', type: 'css'),
  '/dorm.js': (file: 'dorm.js', type: 'javascript'),
};

class DormLanServer extends ChangeNotifier {
  DormLanServer(this._api, this._loadAsset);

  final LanApi _api;
  final Future<String> Function(String) _loadAsset;
  _LanShare? _share;
  bool _starting = false;
  bool _disposed = false;

  bool get starting => _starting;
  bool get running => _share != null;
  int? get port => _share?.server.port;
  List<String> get addresses => _share?.addresses ?? const [];

  Future<void> start(int port) async {
    if (_disposed || _starting || running) return;
    if (port < 0 || port > 65535) throw const InputException('请输入有效端口');
    _starting = true;
    notifyListeners();
    try {
      final assets = <String, String>{};
      for (final entry in _files.entries) {
        assets[entry.key] = await _loadAsset('assets/lan/${entry.value.file}');
      }
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      if (_disposed) return;
      final listener = await HttpServer.bind(InternetAddress.anyIPv4, port);
      if (_disposed) {
        await listener.close(force: true);
        return;
      }
      listener.idleTimeout = const Duration(seconds: 10);
      final hosts = {
        for (final network in interfaces)
          for (final address in network.addresses) address.address,
      }..remove('127.0.0.1');
      final names = [...hosts]..sort();
      final boundPort = listener.port;
      final share = _share = _LanShare(
        listener,
        assets,
        [
          for (final host in [...names, '127.0.0.1'])
            Uri(scheme: 'http', host: host, port: boundPort).origin,
        ],
        {
          for (final host in [...names, '127.0.0.1', 'localhost']) ...[
            '$host:$boundPort',
            if (boundPort == 80) host,
          ],
        },
      );
      listener.listen(
        (request) => unawaited(_serve(share, request)),
        onError: (Object _) {
          if (identical(_share, share)) unawaited(stop());
        },
      );
    } on SocketException {
      throw const InputException('无法启动局域网服务器，请检查端口是否已被占用');
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stop() async {
    final share = _share;
    if (share == null) return;
    _share = null;
    await share.server.close(force: true);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }

  Future<void> _serve(_LanShare share, HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('X-Frame-Options', 'DENY')
      ..set(
        'Content-Security-Policy',
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
      );
    try {
      await _handle(share, request);
    } on InputException catch (error) {
      _error(response, HttpStatus.badRequest, error.message);
    } on FormatException {
      _error(response, HttpStatus.badRequest, '请求格式有误');
    } on TimeoutException {
      _error(response, HttpStatus.requestTimeout, '请求超时');
    } on HttpException {
      _error(response, HttpStatus.badRequest, '无法读取请求');
    } on SocketException {
      // The peer may close the connection before a response is available.
    } catch (_) {
      _error(response, HttpStatus.internalServerError, '操作失败，请稍后重试');
    } finally {
      try {
        await response.close();
      } on IOException {
        // A disconnected browser no longer needs the response.
      }
    }
  }

  Future<void> _handle(_LanShare share, HttpRequest request) async {
    final response = request.response;
    if (!identical(_share, share)) {
      _error(response, HttpStatus.serviceUnavailable, '服务器已停止');
      return;
    }
    // Limit HTTP origins to this listener's addresses to guard against DNS rebinding.
    final host = request.headers.value(HttpHeaders.hostHeader)?.toLowerCase();
    if (host == null || !share.hostHeaders.contains(host)) {
      _error(response, HttpStatus.forbidden, '请使用 Dorm 设置中显示的地址');
      return;
    }
    final path = request.uri.path;
    final file = _files[path];
    if (request.method == 'GET' && file != null) {
      response.headers.contentType = ContentType(
        'text',
        file.type,
        charset: 'utf-8',
      );
      response.write(share.assets[path]!);
      return;
    }
    if (!path.startsWith('/api/')) {
      _error(response, HttpStatus.notFound, '页面不存在');
      return;
    }
    if (request.method == 'POST') {
      final origin = request.headers.value('origin');
      final site = request.headers.value('sec-fetch-site');
      if ((origin != null && origin != Uri.parse('http://$host').origin) ||
          site == 'cross-site' ||
          site == 'same-site') {
        _error(response, HttpStatus.forbidden, '跨站请求已拒绝');
        return;
      }
    }
    final route = request.uri.pathSegments.skip(1).toList();
    if (request.method == 'GET') {
      final result = _api.read(route, request.uri.queryParameters);
      if (result == null) {
        _error(response, HttpStatus.notFound, '接口不存在');
      } else {
        _json(response, HttpStatus.ok, result);
      }
    } else if (request.method == 'POST') {
      final body = await _body(request).timeout(const Duration(seconds: 8));
      if (!identical(_share, share)) {
        _error(response, HttpStatus.serviceUnavailable, '服务器已停止');
      } else if (!_api.mutate(route, body)) {
        _error(response, HttpStatus.notFound, '接口不存在');
      } else {
        _json(response, HttpStatus.ok, {'ok': true});
      }
    } else {
      response.headers.set(HttpHeaders.allowHeader, 'GET, POST');
      _error(response, HttpStatus.methodNotAllowed, '请求方法不支持');
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    const maxBytes = 32 * 1024;
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const InputException('请使用 JSON 请求');
    }
    if (request.contentLength > maxBytes) throw const InputException('请求内容过大');
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const InputException('请求内容过大');
      }
      bytes.addAll(chunk);
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map<String, dynamic>) throw const FormatException();
    return body;
  }

  void _error(HttpResponse response, int status, String message) =>
      _json(response, status, {'error': message});

  void _json(HttpResponse response, int status, Object value) {
    final json = jsonEncode(value);
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(json);
  }
}

class _LanShare {
  const _LanShare(this.server, this.assets, this.addresses, this.hostHeaders);

  final HttpServer server;
  final Map<String, String> assets;
  final List<String> addresses;
  final Set<String> hostHeaders;
}
