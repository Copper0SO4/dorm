import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  _LanSession? _session;
  bool _starting = false;
  bool _disposed = false;

  bool get starting => _starting;
  bool get running => _session != null;
  int? get port => _session?.server.port;
  String? get pairingCode => _session?.code;
  List<String> get addresses => _session?.addresses ?? const [];

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
      }.toList()..sort();
      final session = _session = _LanSession(listener, assets, [
        for (final host in hosts) 'http://$host:${listener.port}',
        'http://127.0.0.1:${listener.port}',
      ]);
      listener.listen(
        (request) => unawaited(_serve(session, request)),
        onError: (Object _) {
          if (identical(_session, session)) unawaited(stop());
        },
      );
    } on SocketException {
      throw const InputException('无法启动局域网服务器，请检查端口是否已被占用');
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  void rotateCode() {
    final session = _session;
    if (session == null) return;
    session.rotate();
    notifyListeners();
  }

  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    await session.server.close(force: true);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }

  Future<void> _serve(_LanSession session, HttpRequest request) async {
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
      await _handle(session, request);
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

  Future<void> _handle(_LanSession session, HttpRequest request) async {
    final response = request.response;
    if (!identical(_session, session)) {
      _error(response, HttpStatus.serviceUnavailable, '服务器已停止');
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
      response.write(session.assets[path]!);
      return;
    }
    if (!path.startsWith('/api/')) {
      _error(response, HttpStatus.notFound, '页面不存在');
      return;
    }
    if (request.method == 'POST') {
      final origin = request.headers.value('origin');
      final host = request.headers.value(HttpHeaders.hostHeader);
      if (origin != null && origin != 'http://$host') {
        _error(response, HttpStatus.forbidden, '跨站请求已拒绝');
        return;
      }
    }
    if (path == '/api/session' && request.method == 'POST') {
      await _pair(session, request);
      return;
    }
    final bearer = request.headers.value(HttpHeaders.authorizationHeader);
    if (!_sameSecret(bearer ?? '', 'Bearer ${session.ticket}')) {
      _error(response, HttpStatus.unauthorized, '请先输入访问码');
      return;
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
      if (!identical(_session, session) ||
          !_sameSecret(bearer ?? '', 'Bearer ${session.ticket}')) {
        _error(response, HttpStatus.unauthorized, '会话已失效，请重新连接');
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

  Future<void> _pair(_LanSession session, HttpRequest request) async {
    final body = await _body(request).timeout(const Duration(seconds: 8));
    if (!identical(_session, session)) {
      _error(request.response, HttpStatus.serviceUnavailable, '服务器已停止');
      return;
    }
    if (session.pairingLimited()) {
      _error(request.response, HttpStatus.tooManyRequests, '尝试过多，请稍后再试');
      return;
    }
    final code = body['code'];
    if (code is! String ||
        !_sameSecret(code.trim().toUpperCase(), session.code)) {
      session.failedPairings++;
      _error(request.response, HttpStatus.unauthorized, '访问码不正确');
      return;
    }
    _json(request.response, HttpStatus.ok, {'token': session.ticket});
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

class _LanSession {
  _LanSession(this.server, this.assets, this.addresses) {
    rotate();
  }

  final HttpServer server;
  final Map<String, String> assets;
  final List<String> addresses;
  final _random = Random.secure();
  late String code;
  late String ticket;
  late DateTime _windowStart;
  int failedPairings = 0;

  void rotate() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    code = List.generate(
      12,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
    ticket = base64UrlEncode(List.generate(32, (_) => _random.nextInt(256)));
    _windowStart = DateTime.now();
    failedPairings = 0;
  }

  bool pairingLimited() {
    if (DateTime.now().difference(_windowStart) >= const Duration(minutes: 1)) {
      _windowStart = DateTime.now();
      failedPairings = 0;
    }
    return failedPairings >= 12;
  }
}

bool _sameSecret(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
  }
  return difference == 0;
}
