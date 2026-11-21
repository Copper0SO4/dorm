import 'dart:io';
import 'dart:math';

import 'package:dormos/data/github_transport.dart';
import 'package:dormos/data/lan_server.dart';
import 'package:dormos/data/ssh_vault.dart';
import 'package:dormos/domain/cloud.dart';
import 'package:dormos/domain/ledger.dart';
import 'package:dormos/game/card_network.dart';
import 'package:dormos/game/card_mailbox.dart';
import 'package:dormos/game/card_rooms.dart';
import 'package:dormos/game/card_session.dart';
import 'package:dormos/game/cards.dart';
import 'package:dormos/game/online_cards.dart';
import 'package:dormos/ui/card_table.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as git;
import 'package:material_ui/material_ui.dart';

PlayingCard dealt(int rank, [int copy = 0]) {
  if (rank >= 16) return PlayingCard(copy * 54 + 52 + rank - 16);
  return PlayingCard(copy ~/ 4 * 54 + (rank - 3) * 4 + copy % 4);
}

List<PlayingCard> cards(List<int> ranks) {
  final count = <int, int>{};
  return [
    for (final rank in ranks)
      dealt(rank, count.update(rank, (value) => value + 1, ifAbsent: () => 0)),
  ];
}

void main() {
  final invalid = throwsA(isA<InputException>());

  test('multiple decks, discard, bottom and concentrated remainder never duplicate cards', () {
    final split = dealCards(
      CardRules(players: 5, decks: 2, discard: 3, bottom: 5),
      Random(1),
    );
    expect(split.hands.map((hand) => hand.length), everyElement(20));
    expect(split.extraSeat, isNull);
    expect(split.bottom, hasLength(5));
    expect(split.discarded, hasLength(3));
    expect(
      [
        ...split.hands.expand((hand) => hand),
        ...split.discarded,
        ...split.bottom,
      ].map((card) => card.id).toSet(),
      hasLength(108),
    );
    final uneven = dealCards(
      CardRules(
        players: 5,
        decks: 2,
        landlord: false,
        bottom: 0,
        remainder: DealRemainder.extra,
      ),
      Random(4),
    );
    expect(uneven.hands[uneven.extraSeat!], hasLength(24));
    expect(uneven.hands.where((hand) => hand.length == 21), hasLength(4));
    expect(() => CardRules(players: 5, landlord: false, bottom: 0), invalid);
  });

  test('classic sequences, wings, multi-deck rockets and wild comparison', () {
    PlayKind? natural(List<int> values) =>
        cardPlays(cards(values), {}).firstOrNull?.kind;
    expect(natural([3, 4, 5, 6, 7]), PlayKind.straight);
    expect(natural([11, 12, 13, 14, 15]), isNull);
    expect(natural([3, 3, 4, 4, 5, 5]), PlayKind.pairs);
    expect(natural([3, 3, 3, 4, 4, 4, 5, 6]), PlayKind.planeSingles);
    expect(natural([3, 3, 3, 4, 4, 4, 5, 5, 6, 6]), PlayKind.planePairs);
    expect(natural([3, 3, 3, 3, 7, 7]), PlayKind.fourSingles);
    expect(natural([16, 17, 16, 17]), PlayKind.rocket);

    final wild = {6, 9};
    final options = cardPlays(cards([3, 4, 5, 6, 9]), wild);
    final straight = options.singleWhere(
      (play) => play.kind == PlayKind.straight && play.high == 7,
    );
    expect(straight.ranks.values, contains(7));
    final soft = cardPlays(
      cards([3, 3, 3, 6]),
      wild,
    ).firstWhere((play) => play.bomb);
    final hard = cardPlays(
      cards([4, 4, 4, 4]),
      wild,
    ).singleWhere((play) => play.bomb);
    expect(hard.beats(soft), isTrue);
    expect(cardPlays(cards([6, 17]), wild), isEmpty);
    final rocket = cardPlays(cards([16, 17]), wild).single;
    expect(rocket.beats(hard), isTrue);
  });

  test(
    'rooms enforce turn, hide opponents, keep bottom and reset after passes',
    () {
      final rooms = CardRooms(random: Random(3));
      addTearDown(rooms.dispose);
      final a = rooms.create(CardRules(players: 3));
      final b = rooms.join(a.room);
      final c = rooms.join(a.room);
      rooms.action(a, 'start', {});
      final seats = [a, b, c];
      CardSeat turn() => seats.singleWhere(
        (seat) => rooms.state(seat)['you'] == rooms.state(seat)['turn'],
      );
      final first = turn();
      final game = rooms.state(first);
      expect(game['phase'], 'bidding');
      expect(game['bottom'], isEmpty);
      expect(game['hand'], hasLength(17));
      expect(
        (game['people'] as List).every(
          (person) => !(person as Map).containsKey('hand'),
        ),
        isTrue,
      );
      expect(
        () => rooms.action(seats.firstWhere((seat) => seat != first), 'bid', {
          'bid': 3,
          'turnVersion': game['turnVersion'],
        }),
        invalid,
      );
      rooms.action(first, 'bid', {
        'bid': 3,
        'turnVersion': game['turnVersion'],
      });
      final opened = rooms.state(first);
      expect(opened['hand'], hasLength(20));
      expect(opened['bottom'], hasLength(3));
      expect(
        () =>
            rooms.action(first, 'pass', {'turnVersion': opened['turnVersion']}),
        invalid,
      );
      final id = (opened['hand'] as List).first;
      expect(
        rooms.options(first, {
          'cards': [id],
          'turnVersion': opened['turnVersion'],
        }),
        hasLength(1),
      );
      rooms.action(first, 'play', {
        'cards': [id],
        'turnVersion': opened['turnVersion'],
      });
      expect(
        () => rooms.action(first, 'play', {
          'cards': [id],
          'turnVersion': opened['turnVersion'],
        }),
        invalid,
      );
      for (var i = 0; i < 2; i++) {
        final next = turn();
        rooms.action(next, 'pass', {
          'turnVersion': rooms.state(next)['turnVersion'],
        });
      }
      expect(turn(), first);
      expect(rooms.state(first)['last'], isNull);
      rooms.action(a, 'tomato', {'target': rooms.state(b)['you']});
      expect((rooms.state(b)['events'] as List).last['kind'], 'tomato');
      expect(
        () => rooms.action(a, 'tomato', {'target': rooms.state(b)['you']}),
        invalid,
      );
    },
  );

  testWidgets(
    'native table works without a browser, including computer seats',
    (tester) async {
      final session = CardSession(() => null);
      await session.create(CardRules(), '', CardLocation.local);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => CardTable(
                session: session,
                view: session.view!,
                share: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('添加电脑玩家'), findsOneWidget);
      await tester.tap(find.text('添加电脑玩家'));
      await tester.pump();
      expect(find.text('电脑 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  test('dedicated HTTP port serves an isolated anonymous lobby and advertises it over LAN', () async {
    final rooms = CardRooms();
    final server = DormLanServer.cards(
      rooms,
      (path) => File(path).readAsString(),
    );
    final seat = rooms.create(CardRules(), scope: 'lan');
    await server.start(0);
    addTearDown(rooms.dispose);
    addTearDown(server.dispose);
    final address = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
    final raw = HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());
    addTearDown(() => raw.close(force: true));
    final response = await (await raw.getUrl(address.replace(path: '/cards')))
        .close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    final ledger = await (await raw.getUrl(
      address.replace(path: '/api/ledger'),
    )).close();
    expect(ledger.statusCode, 404);
    await ledger.drain<void>();
    final options = await CardDiscovery.search(
      duration: const Duration(milliseconds: 550),
    );
    expect(options.any((room) => room.room['room'] == seat.room), isTrue);
    await HttpOverrides.runWithHttpOverrides(() async {
      final http = CardHttp(address);
      addTearDown(http.close);
      final guest = await http.request('${seat.room}/join', data: {'name': ''});
      expect(guest['token'], isNot(seat.token));
      final state = await http.request(
        '${seat.room}/state',
        token: guest['token'] as String,
      );
      expect(state['you'], 2);
      expect((state['people'] as List).last['name'], '访客 2');
    }, _RealHttp());
  });

  test(
    'two clients exchange encrypted room moves over real Git push and pull',
    () async {
      await git.PlatformSpecific.initialize();
      final root = await Directory.systemTemp.createTemp('dorm-git-cards-');
      addTearDown(() => root.delete(recursive: true));
      final bare = Directory('${root.path}/remote.git');
      git.Repository.initBasic(path: bare.path, bare: true).free();
      final key = await CloudKey.generate();
      final settings = CloudSettings(
        repository: 'test/cards',
        operator: 'Test card room',
      );
      GitHubTransport transport(String side) => GitHubTransport(
        Directory('${root.path}/$side'),
        localTestRemote: bare,
      );
      final aWire = transport('a')
          .cardMailbox(settings, () async => key, () async => null);
      final bWire = transport('b')
          .cardMailbox(settings, () async => key, () async => null);
      final rooms = CardRooms(random: Random(13));
      final other = CardRooms();
      final racing = _RacingMailbox(aWire);
      final a = OnlineCards(racing, rooms, interval: Duration.zero);
      final b = OnlineCards(bWire, other, interval: Duration.zero);
      addTearDown(rooms.dispose);
      addTearDown(other.dispose);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final host = await a.host(
        CardRules(players: 2, landlord: false, bottom: 0),
        '房主',
      );
      expect(a.error, isNull);
      await b.refresh();
      expect(b.directory.single['room'], host.room);
      await b.join(b.directory.single, '');
      await a.refresh();
      await b.refresh();
      expect(a.error, isNull);
      expect(b.error, isNull);
      expect(b.remoteView?['you'], 2);
      rooms.action(host, 'start', {});
      await a.refresh();
      await b.refresh();
      expect(b.remoteView?['hand'], hasLength(27));
      final wire = (await bWire.pull())!.body;
      expect(wire, isNot(contains('"hand"')));
      expect(wire, isNot(contains(host.token)));
      await b.send('chat', {'text': '这条测试消息是密文'});
      await b.refresh();
      racing.retryNextPush = true;
      await a.refresh();
      await b.refresh();
      expect(b.waiting, isFalse);
      expect(
        (b.remoteView?['events'] as List).where(
          (event) => event['text'] == '这条测试消息是密文',
        ),
        hasLength(1),
      );
      expect((b.remoteView?['events'] as List).last['text'], '这条测试消息是密文');
      expect((await bWire.pull())!.body, isNot(contains('这条测试消息是密文')));
      expect((await transport('a').pull(settings, key)), isNull);
    },
  );
}

class _RealHttp extends HttpOverrides {}

class _RacingMailbox implements CardMailbox {
  _RacingMailbox(this.mailbox);
  final CardMailbox mailbox;
  bool retryNextPush = false;

  @override
  Future<CardMailboxRead?> pull() => mailbox.pull();

  @override
  Future<void> push(String body, String? revision) async {
    await mailbox.push(body, revision);
    if (retryNextPush) {
      retryNextPush = false;
      throw const CardMailboxRace();
    }
  }
}
