import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../domain/identity.dart';
import '../domain/ledger.dart';
import 'card_mailbox.dart';
import 'card_rooms.dart';
import 'cards.dart';

const _stale = Duration(minutes: 3);
const _heartbeat = Duration(seconds: 35);
final _exchange = X25519();
final _cipher = AesGcm.with256bits();

class OnlineCards extends ChangeNotifier {
  OnlineCards(this._mailbox, this._rooms, {Duration? interval}) {
    if (interval ?? const Duration(seconds: 7) case final period
        when period > Duration.zero) {
      _timer = Timer.periodic(period, (_) => unawaited(refresh()));
    }
  }

  final CardMailbox _mailbox;
  final CardRooms _rooms;
  Timer? _timer;
  Future<void>? _running;
  _OnlineHost? _host;
  _OnlineGuest? _guest;
  final _retired = <String>{};
  bool _disposed = false;
  bool get busy => _running != null;
  String? error;
  List<RoomJson> directory = const [];
  RoomJson? get remoteView => _guest?.state;
  bool get waiting => _guest?.pending != null;
  String? get replyError => _guest?.error;
  String? get remoteCode => _guest?.room;

  Future<CardSeat> host(CardRules rules, String name) async {
    if (_host != null || _guest != null) {
      throw const InputException('请先离开当前在线房间');
    }
    final key = await _newKey();
    final seat = _rooms.create(rules, name: name, scope: 'online');
    _host = _OnlineHost(seat, key);
    await refresh();
    return seat;
  }

  Future<void> join(RoomJson room, String name) async {
    if (_guest != null || _host != null) {
      throw const InputException('请先离开当前在线房间');
    }
    final code = room['room'];
    final hostKey = room['key'];
    if (code is! String ||
        !roomCodePattern.hasMatch(code) ||
        hostKey is! String ||
        !_validPub(hostKey)) {
      throw const InputException('在线房间记录无效');
    }
    final key = await _newKey();
    final secret = await _secret(key, hostKey);
    final guest = _guest = _OnlineGuest(code, key.public, secret);
    await _enqueue(guest, 'join', {'name': name});
    await refresh();
  }

  Future<void> send(String action, RoomJson data) async {
    final guest = _guest;
    if (guest == null || guest.state == null) {
      throw const InputException('还在等待房主确认');
    }
    await _enqueue(guest, action, data);
    unawaited(refresh());
  }

  Future<void> closeHost() async {
    final host = _host;
    if (host == null) return;
    _retired.add(host.seat.room);
    _host = null;
    await refresh();
  }

  void forgetGuest() {
    _guest = null;
    _notify();
  }

  Future<void> _enqueue(
    _OnlineGuest guest,
    String action,
    RoomJson data,
  ) async {
    if (guest.pending != null || guest.encoding) {
      throw const InputException('请等待上一条操作同步');
    }
    guest.encoding = true;
    try {
      final id = newIdentityCode();
      final box = await _seal(
        guest.secret,
        guest.room,
        guest.public,
        'request',
        id,
        {'action': action, 'data': data, 'sequence': ++guest.sequence},
      );
      guest.pending = {'id': id, 'box': box};
      guest.error = null;
      _notify();
    } finally {
      guest.encoding = false;
    }
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_running case final running?) return running;
    final task = _cycle().whenComplete(() {
      _running = null;
      _notify();
    });
    _running = task;
    _notify();
    return task;
  }

  Future<void> _cycle() async {
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final remote = await _mailbox.pull();
          if (_disposed) return;
          final board = _read(remote?.body);
          final before = jsonEncode(board);
          final now = DateTime.now().toUtc();
          board.removeWhere((_, room) {
            final stamp = DateTime.tryParse(room['updated'] as String? ?? '');
            return stamp == null || stamp.isBefore(now.subtract(_stale));
          });
          final retired = _retired.toList();
          for (final code in retired) {
            board.remove(code);
          }
          if (_host case final host?) await _publishHost(host, board, now);
          if (_guest case final guest?) await _updateGuest(guest, board);
          if (_disposed) return;
          final body = jsonEncode(board);
          if (body != before) await _mailbox.push(body, remote?.revision);
          if (_disposed) return;
          _retired.removeAll(retired);
          directory = board.values
              .where(
                (room) =>
                    room['open'] == true && room['room'] != _host?.seat.room,
              )
              .map(
                (room) => {
                  for (final key in [
                    'room',
                    'host',
                    'players',
                    'capacity',
                    'mode',
                    'landlord',
                    'key',
                  ])
                    key: room[key],
                },
              )
              .toList();
          error = null;
          return;
        } on CardMailboxRace {
          if (attempt == 2) throw const InputException('房间列表正在更新，下一轮会重试');
        }
      }
    } catch (e) {
      error = e is InputException ? e.message : '无法同步在线房间，稍后会重试';
    }
  }

  Future<void> _publishHost(
    _OnlineHost host,
    Map<String, RoomJson> board,
    DateTime now,
  ) async {
    final code = host.seat.room;
    final old = board[code];
    final entry = board[code] = <String, dynamic>{
      if (old?['key'] == host.key.public) ...old!,
      'room': code,
      'key': host.key.public,
    };
    final requests = _map(entry['requests']);
    final replies = _map(entry['replies']);
    for (final inbound in requests.entries.take(24)) {
      final peerKey = inbound.key;
      final request = inbound.value;
      if (!_validPub(peerKey) || request is! RoomJson) continue;
      final id = request['id'];
      if (!isIdentityCode(id) || request['box'] is! String) continue;
      requests[peerKey] = request;
      var peer = host.peers[peerKey];
      if (peer == null) {
        if (host.peers.length >= 24) continue;
        try {
          final key = await _secret(host.key, peerKey);
          final body = await _open(
            key,
            code,
            peerKey,
            'request',
            id as String,
            request['box'] as String,
          );
          if (body['action'] != 'join') continue;
          peer = host.peers[peerKey] = _OnlinePeer(key);
        } catch (_) {
          continue;
        }
      }
      if (peer.seen == id) continue;
      try {
        final body = await _open(
          peer.secret,
          code,
          peerKey,
          'request',
          id as String,
          request['box'] as String,
        );
        final action = body['action'];
        final data = body['data'];
        final sequence = body['sequence'];
        if (action is! String ||
            data is! RoomJson ||
            sequence is! int ||
            sequence <= peer.sequence) {
          continue;
        }
        peer.sequence = sequence;
        peer.error = null;
        if (action == 'join') {
          peer.seat ??= _rooms.join(
            code,
            name: data['name'] as String?,
            scope: 'online',
          );
        } else {
          if (peer.seat == null) throw const InputException('座位已失效');
          _rooms.action(peer.seat!, action, data);
          if (action == 'leave') peer.seat = null;
        }
        peer.seen = id;
      } catch (e) {
        peer.error = e is InputException ? e.message : '牌桌没有接受本次操作';
        peer.seen = id as String;
      }
    }
    final state = _rooms.state(host.seat);
    final rules = state['rules'] as RoomJson;
    final people = state['people'] as List;
    final version = state['version'];
    final stamp = DateTime.tryParse(entry['updated'] as String? ?? '');
    if (entry['version'] != version ||
        stamp == null ||
        now.difference(stamp) > _heartbeat) {
      entry.addAll({
        'host': (people.first as RoomJson)['name'],
        'players': people.length,
        'capacity': rules['players'],
        'mode': rules['mode'],
        'landlord': rules['landlord'],
        'version': version,
        'open':
            ['lobby', 'finished'].contains(state['phase']) &&
            people.length < (rules['players'] as int),
        'updated': now.toIso8601String(),
      });
    }
    for (final item in host.peers.entries) {
      final peer = item.value;
      final response = replies[item.key];
      if (response is RoomJson &&
          response['revision'] == version &&
          response['ack'] == peer.seen) {
        continue;
      }
      final id = newIdentityCode();
      RoomJson? state;
      if (peer.seat case final seat?) {
        try {
          state = _rooms.state(seat);
        } on InputException catch (error) {
          peer.seat = null;
          peer.error = error.message;
        }
      }
      final payload = {'ack': peer.seen, 'error': peer.error, 'state': state};
      final box = await _seal(
        peer.secret,
        code,
        item.key,
        'reply',
        id,
        payload,
      );
      replies[item.key] = {
        'id': id,
        'box': box,
        'revision': version,
        'ack': peer.seen,
      };
    }
    entry['requests'] = requests;
    entry['replies'] = replies;
  }

  Future<void> _updateGuest(
    _OnlineGuest guest,
    Map<String, RoomJson> board,
  ) async {
    final room = board[guest.room];
    if (room == null) {
      guest.error = '房主已离线或关闭了房间';
      guest.pending = null;
      guest.state = null;
      return;
    }
    final reply = _map(room['replies'])[guest.public];
    if (reply is RoomJson &&
        reply['id'] is String &&
        reply['box'] is String &&
        reply['id'] != guest.latestReply) {
      final body = await _open(
        guest.secret,
        guest.room,
        guest.public,
        'reply',
        reply['id'] as String,
        reply['box'] as String,
      );
      guest.latestReply = reply['id'] as String;
      guest.state = body['state'] as RoomJson?;
      if (guest.pending?['id'] == body['ack']) {
        guest.pending = null;
        guest.error = body['error'] as String?;
      }
    }
    if (guest.pending case final pending?) {
      final requests = _map(room['requests']);
      if (requests.length >= 24 && !requests.containsKey(guest.public)) {
        throw const InputException('在线房间请求已满，请稍后再试');
      }
      requests[guest.public] = pending;
      room['requests'] = requests;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

typedef _OnlineKey = ({KeyPair pair, String public});

class _OnlineHost {
  _OnlineHost(this.seat, this.key);
  final CardSeat seat;
  final _OnlineKey key;
  final peers = <String, _OnlinePeer>{};
}

class _OnlinePeer {
  _OnlinePeer(this.secret);
  final SecretKey secret;
  CardSeat? seat;
  int sequence = 0;
  String? seen;
  String? error;
}

class _OnlineGuest {
  _OnlineGuest(this.room, this.public, this.secret);
  final String room;
  final String public;
  final SecretKey secret;
  bool encoding = false;
  int sequence = 0;
  RoomJson? pending;
  RoomJson? state;
  String? latestReply;
  String? error;
}

Future<_OnlineKey> _newKey() async {
  final pair = await _exchange.newKeyPair();
  final key = await pair.extractPublicKey();
  return (pair: pair, public: base64UrlEncode(key.bytes));
}

bool _validPub(String key) {
  try {
    return key.length == 44 && base64Url.decode(key).length == 32;
  } on FormatException {
    return false;
  }
}

Future<SecretKey> _secret(_OnlineKey key, String peer) async {
  final shared = await _exchange.sharedSecretKey(
    keyPair: key.pair,
    remotePublicKey: SimplePublicKey(
      base64Url.decode(peer),
      type: KeyPairType.x25519,
    ),
  );
  return Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  ).deriveKey(secretKey: shared, info: utf8.encode('DormCards Git room v1'));
}

List<int> _aad(String room, String peer, String direction, String id) =>
    utf8.encode('DormCards/1:$room:$peer:$direction:$id');

Future<String> _seal(
  SecretKey key,
  String room,
  String peer,
  String direction,
  String id,
  RoomJson payload,
) async {
  final box = await _cipher.encrypt(
    utf8.encode(jsonEncode(payload)),
    secretKey: key,
    aad: _aad(room, peer, direction, id),
  );
  return base64Encode(box.concatenation());
}

Future<RoomJson> _open(
  SecretKey key,
  String room,
  String peer,
  String direction,
  String id,
  String encoded,
) async {
  if (encoded.length > 160000) throw const FormatException();
  final box = SecretBox.fromConcatenation(
    base64Decode(encoded),
    nonceLength: _cipher.nonceLength,
    macLength: _cipher.macAlgorithm.macLength,
  );
  final bytes = await _cipher.decrypt(
    box,
    secretKey: key,
    aad: _aad(room, peer, direction, id),
  );
  return jsonDecode(utf8.decode(bytes)) as RoomJson;
}

RoomJson _map(Object? value) => value is RoomJson ? Map.of(value) : {};

Map<String, RoomJson> _read(String? body) {
  if (body == null) return {};
  final decoded = jsonDecode(body);
  if (decoded is! RoomJson || decoded.length > 128) {
    throw const InputException('在线大厅格式有误');
  }
  return {
    for (final entry in decoded.entries)
      if (roomCodePattern.hasMatch(entry.key) &&
          entry.value is RoomJson &&
          (entry.value as RoomJson)['room'] == entry.key &&
          (entry.value as RoomJson)['key'] is String)
        entry.key: Map.of(entry.value as RoomJson),
  };
}
