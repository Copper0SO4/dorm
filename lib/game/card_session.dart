import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/lan_server.dart';
import '../domain/ledger.dart';
import 'card_mailbox.dart';
import 'card_network.dart';
import 'card_rooms.dart';
import 'cards.dart';
import 'online_cards.dart';

enum CardLocation { local, lan, git }

typedef LobbyRoom = ({RoomJson info, CardLocation location, Uri? link});

class CardSession extends ChangeNotifier {
  CardSession(this._mailbox) {
    rooms.addListener(_offlineChanged);
  }

  final CardMailbox? Function() _mailbox;
  final rooms = CardRooms();
  DormLanServer? _listener;
  OnlineCards? _online;
  CardHttp? _http;
  CardSeat? _seat;
  Timer? _poll;
  bool _polling = false;
  bool _disposed = false;
  bool _onlineGuest = false;
  bool _opened = false;
  bool get opened => _opened;
  bool searching = false;
  bool working = false;
  bool get awaitingGit => _onlineGuest && (_online?.waiting ?? false);
  bool get gitAvailable => _mailbox() != null;
  String? error;
  String? get gitError => _online?.error;
  List<DiscoveredRoom> _nearby = [];
  RoomJson? view;

  List<LobbyRoom> get directory => [
    for (final room in _nearby)
      (info: room.room, location: CardLocation.lan, link: room.address),
    for (final room in _online?.directory ?? <RoomJson>[])
      (info: room, location: CardLocation.git, link: null),
  ];

  List<Uri> get links {
    final seat = _seat;
    if (seat == null || _http != null || view?['scope'] != 'lan') {
      return const [];
    }
    return [
      for (final address in _listener?.addresses ?? <String>[])
        Uri.parse(address)
            .replace(path: '/cards', queryParameters: {'room': seat.room}),
    ];
  }

  Future<void> search() async {
    if (searching) return;
    searching = true;
    _notify();
    try {
      if (gitAvailable) unawaited(_git().refresh());
      _nearby = await CardDiscovery.search();
    } catch (e) {
      _error(e);
    } finally {
      searching = false;
      _notify();
    }
  }

  OnlineCards _git() {
    final existing = _online;
    if (existing != null) {
      if (_opened || existing.error != 'GitHub 仓库已更改，请重新进入在线大厅') {
        return existing;
      }
      existing.dispose();
      _online = null;
    }
    final mailbox = _mailbox();
    if (mailbox == null) throw const InputException('请先在设置中连接 GitHub 仓库');
    final created = OnlineCards(mailbox, rooms)..addListener(_onlineChanged);
    return _online = created;
  }

  Future<void> create(CardRules rules, String name, CardLocation location) =>
      _work(() async {
        if (_opened) return;
        _opened = true;
        try {
          _seat = location == CardLocation.git
              ? await _git().host(rules, name)
              : rooms.create(rules, name: name);
          _offlineChanged();
          if (location == CardLocation.lan) await _share();
        } catch (_) {
          if (_seat == null) _opened = false;
          rethrow;
        }
      });

  Future<void> join(LobbyRoom target, String name) => _work(() async {
    if (_opened) return;
    if (target.location == CardLocation.git) {
      _onlineGuest = _opened = true;
      try {
        await _git().join(target.info, name);
      } catch (_) {
        _onlineGuest = _opened = false;
        rethrow;
      }
    } else {
      await _connect(parseCardLink(target.link.toString()), name);
    }
  });

  Future<void> joinLink(String link, String name) => _work(() {
    if (_opened) return Future.value();
    return _connect(parseCardLink(link), name);
  });

  Future<void> _connect(RemoteCardEndpoint address, String name) async {
    final http = CardHttp(address.host);
    try {
      final result = await http.request(
        '${address.room}/join',
        data: {'name': name},
      );
      _http = http;
      _opened = true;
      _seat = (
        room: result['room'] as String,
        token: result['token'] as String,
      );
      view = await http.request('${_seat!.room}/state', token: _seat!.token);
      _poll = Timer.periodic(
        const Duration(milliseconds: 650),
        (_) => unawaited(_pullLan()),
      );
    } catch (_) {
      http.close();
      _http = null;
      _seat = null;
      _opened = false;
      rethrow;
    }
  }

  Future<void> _pullLan() async {
    final http = _http;
    final seat = _seat;
    if (_polling || working || http == null || seat == null) return;
    _polling = true;
    try {
      final next = await http.request(
        '${seat.room}/state',
        token: seat.token,
        since: view?['version'] as int?,
      );
      if (_http != http || _seat != seat || _disposed) return;
      if (next.containsKey('phase') &&
          (next['version'] as int) >= (view?['version'] as int? ?? 0)) {
        view = next;
      }
      if (error == '局域网牌桌暂不可用，正在重连') error = null;
      _notify();
    } catch (_) {
      if (_http == http) {
        error = '局域网牌桌暂不可用，正在重连';
        _notify();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> share() => _work(_share);

  Future<void> _share() async {
    final seat = _seat;
    if (seat == null || _http != null) return;
    final listener = _listener ??= DormLanServer.cards(
      rooms,
      rootBundle.loadString,
    );
    if (!listener.running) await listener.start(0);
    rooms.share(seat.room, seat.token);
  }

  Future<void> act(String action, [RoomJson choices = const {}]) =>
      _work(() async {
        final input = <String, dynamic>{
          ...choices,
          'turnVersion': view?['turnVersion'],
        };
        if (_onlineGuest) {
          if (action == 'leave' && view == null) {
            _online?.forgetGuest();
            _clear();
          } else {
            await _git().send(action, input);
          }
          return;
        }
        final seat = _seat;
        if (seat == null) return;
        if (_http case final http?) {
          final next = await http.request(
            '${seat.room}/$action',
            data: input,
            token: seat.token,
          );
          if (action != 'leave') view = next;
        } else {
          final wasOnline = view?['scope'] == 'online';
          if (action == 'leave' && wasOnline) await _online?.closeHost();
          rooms.action(seat, action, input);
          if (wasOnline && action != 'leave') unawaited(_online!.refresh());
        }
        if (action == 'leave') _clear();
      });

  void cancelRemote() {
    if (!_onlineGuest && _http == null) return;
    _clear();
    _online?.forgetGuest();
    _notify();
  }

  void _clear() {
    _poll?.cancel();
    _http?.close();
    _http = null;
    _seat = null;
    _onlineGuest = _opened = false;
    view = null;
  }

  void _offlineChanged() {
    final seat = _seat;
    if (seat != null && _http == null) {
      try {
        view = rooms.state(seat);
      } on InputException {
        view = null;
      }
    }
    _notify();
  }

  void _onlineChanged() {
    if (_onlineGuest) {
      final online = _online!;
      if (online.replyError != null) error = online.replyError;
      if (view != null &&
          online.remoteView == null &&
          !online.waiting &&
          online.replyError == null) {
        _clear();
        online.forgetGuest();
      } else {
        view = online.remoteView;
      }
    }
    _notify();
  }

  Future<void> _work(Future<void> Function() work) async {
    if (working) return;
    working = true;
    error = null;
    _notify();
    try {
      await work();
    } catch (e) {
      _error(e);
    } finally {
      working = false;
      _notify();
    }
  }

  void _error(Object e) {
    error = e is InputException ? e.message : '牌桌暂不可用，请稍后重试';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _http?.close();
    _online?.dispose();
    _listener?.dispose();
    rooms.dispose();
    super.dispose();
  }
}
