import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/identity.dart';
import '../domain/ledger.dart';
import 'card_rooms.dart';

const _discoveryPorts = [43897, 42137, 46627];
const _protocol = 'DormCards/1';
final _group = InternetAddress('239.255.77.42');

typedef DiscoveredRoom = ({Uri address, RoomJson room});

class CardDiscovery {
  RawDatagramSocket? _listener;

  Future<void> start(int port, List<RoomJson> Function() rooms) async {
    if (_listener != null) return;
    RawDatagramSocket? listener;
    for (final candidate in _discoveryPorts) {
      try {
        listener = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          candidate,
          reuseAddress: true,
        );
        break;
      } on SocketException {
        // A reserved or occupied port does not prevent discovery on another.
      }
    }
    if (listener == null) throw const SocketException('无法绑定斗地主搜房端口');
    final socket = _listener = listener;
    final networks = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    if (_listener != socket) return;
    for (final network in networks) {
      try {
        socket.joinMulticast(_group, network);
      } on SocketException {
        // Interfaces without multicast can still receive IPv4 broadcasts.
      }
    }
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (
        var packet = socket.receive();
        packet != null;
        packet = socket.receive()
      ) {
        final query = _decode(packet);
        final nonce = query?['query'];
        if (query?['protocol'] != _protocol || !isIdentityCode(nonce)) continue;
        for (final room in rooms()) {
          socket.send(
            utf8.encode(
              jsonEncode({
                'protocol': _protocol,
                'reply': nonce,
                'port': port,
                'room': room,
              }),
            ),
            packet.address,
            packet.port,
          );
        }
      }
    }, onError: (Object _) {});
  }

  void stop() {
    _listener?.close();
    _listener = null;
  }

  static Future<List<DiscoveredRoom>> search({
    Duration duration = const Duration(milliseconds: 1200),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final nonce = newIdentityCode();
    final found = <String, DiscoveredRoom>{};
    try {
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        for (
          var packet = socket.receive();
          packet != null;
          packet = socket.receive()
        ) {
          final reply = _decode(packet);
          if (reply?['protocol'] != _protocol || reply?['reply'] != nonce) {
            continue;
          }
          final port = reply?['port'];
          final room = reply?['room'];
          if (port is! int ||
              port < 1 ||
              port > 65535 ||
              room is! RoomJson ||
              room['room'] is! String ||
              !roomCodePattern.hasMatch(room['room'] as String)) {
            continue;
          }
          final target = Uri(
            scheme: 'http',
            host: packet.address.address,
            port: port,
            path: '/cards',
            queryParameters: {'room': room['room'] as String},
          );
          found[target.toString()] = (address: target, room: room);
        }
      }, onError: (Object _) {});
      final query = utf8.encode(
        jsonEncode({'protocol': _protocol, 'query': nonce}),
      );
      void send() {
        for (final address in [
          InternetAddress.loopbackIPv4,
          InternetAddress('255.255.255.255'),
          _group,
        ]) {
          try {
            for (final candidate in _discoveryPorts) {
              socket.send(query, address, candidate);
            }
          } on SocketException {
            // Other routes remain available.
          }
        }
      }

      send();
      await Future<void>.delayed(duration ~/ 2);
      send();
      await Future<void>.delayed(duration ~/ 2);
      final matches = <String, DiscoveredRoom>{};
      for (final result in found.values) {
        final room = result.room['room'] as String;
        if (!matches.containsKey(room) ||
            matches[room]!.address.host == '127.0.0.1') {
          matches[room] = result;
        }
      }
      return matches.values.toList();
    } finally {
      socket.close();
    }
  }

  static RoomJson? _decode(Datagram datagram) {
    if (datagram.data.length > 2048) return null;
    try {
      final object = jsonDecode(utf8.decode(datagram.data));
      return object is RoomJson ? object : null;
    } on FormatException {
      return null;
    }
  }
}

typedef RemoteCardEndpoint = ({Uri host, String room});

RemoteCardEndpoint parseCardLink(String input) {
  final url = Uri.tryParse(input.trim());
  final room = url?.queryParameters['room']?.toUpperCase();
  final ip = InternetAddress.tryParse(url?.host ?? '');
  if (url == null ||
      url.scheme != 'http' ||
      url.userInfo.isNotEmpty ||
      url.path != '/cards' ||
      (ip?.type != InternetAddressType.IPv4 && url.host != 'localhost') ||
      room == null ||
      !roomCodePattern.hasMatch(room)) {
    throw const InputException('请输入完整的 Dorm 牌桌链接');
  }
  return (host: Uri.parse(url.origin), room: room);
}

class CardHttp {
  CardHttp(this.host);
  final Uri host;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Future<RoomJson> request(
    String path, {
    RoomJson? data,
    String? token,
    int? since,
  }) async {
    final uri = host.replace(
      path: '/api/cards/$path',
      queryParameters: since == null ? null : {'since': '$since'},
    );
    final response = await _request(
      uri,
      data: data,
      token: token,
    ).timeout(const Duration(seconds: 9));
    return response;
  }

  Future<RoomJson> _request(Uri uri, {RoomJson? data, String? token}) async {
    final request = await _client.openUrl(data == null ? 'GET' : 'POST', uri);
    request.followRedirects = false;
    if (token != null) request.headers.set('X-Dorm-Seat', token);
    if (data != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(data));
    }
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    final result = jsonDecode(body);
    if (result is! RoomJson) throw const InputException('牌桌返回格式无效');
    if (response.statusCode != HttpStatus.ok) {
      throw InputException((result['error'] as String?) ?? '无法连接牌桌');
    }
    return result;
  }

  void close() => _client.close(force: true);
}
