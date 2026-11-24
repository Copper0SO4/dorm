import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dormos/domain/preferences.dart';
import 'package:dormos/game/bot_api.dart';
import 'package:dormos/game/bot_profile.dart';
import 'package:dormos/game/card_rooms.dart';
import 'package:dormos/game/cards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to DeepSeek Flash with low thinking and migrates obsolete official aliases', () {
    final profile = BotProfile.fromPreferences(const DormPreferences());
    expect(profile.provider, BotProvider.deepseek);
    expect(profile.model, 'deepseek-flash');
    expect(profile.baseUrl, 'https://api.deepseek.com');
    expect(profile.effort, BotEffort.low);
    expect(profile.effectiveEffort, BotEffort.low);
    for (final provider in BotProvider.values) {
      expect(provider.defaultEffort, BotEffort.low);
      final providerProfile = BotProfile.fromPreferences(
        DormPreferences(botProvider: provider.name),
      );
      expect(providerProfile.effectiveEffort, BotEffort.low);
    }
    expect(
      BotProfile.fromPreferences(const DormPreferences(botEffort: 'off'))
          .effectiveEffort,
      BotEffort.off,
    );
    expect(profile.usable, isFalse);
    expect(botEndpoint(profile).path, '/chat/completions');
    expect(
      BotProfile.fromPreferences(
        const DormPreferences(botApiModel: 'deepseek-chat'),
      ).model,
      'deepseek-flash',
    );
    expect(
      BotProfile.fromPreferences(
        const DormPreferences(
          botApiBase: 'https://proxy.example.test',
          botApiModel: 'deepseek-chat',
        ),
      ).model,
      'deepseek-chat',
    );
  });

  test('only legal integer actions are accepted', () {
    expect(interpretBotText('{"bid":2}', _bidTurn(), []).bid, 2);
    expect(interpretBotText('```json\n{"bid":1}\n```', _bidTurn(), []).bid, 1);
    for (final reply in [
      '{"bid":1.8}',
      '{"bid":"1"}',
      '{"bid":4}',
      '{"bid":1,"i":0}',
      'explanation {"bid":1}',
    ]) {
      expect(
        interpretBotText(reply, _bidTurn(), []).ready,
        isFalse,
        reason: reply,
      );
    }
  });

  test('coaching requests private history and public rank counts and requires an explanation', () async {
    final prompts = <String>[];
    final response = ['{"i":1,"reason":"用小牌接手，保留大牌。"}', '{"i":1}'].iterator;
    final coach = ApiBotAdvisor(
      () => _profile(BotProvider.deepseek, BotProvider.deepseek.defaultBase),
      transport: (_, system, user) async {
        expect(system, contains('教练'));
        expect(system, contains('队友已控制牌权'));
        expect(system, contains('下家余牌'));
        prompts.add(user);
        response.moveNext();
        return response.current;
      },
    );
    final turn = BotTurn(
      room: 'ROOM',
      deal: 2,
      bidding: false,
      rules: CardRules(decks: 2),
      hand: const [PlayingCard(4), PlayingCard(8)],
      wild: const {},
      previous: const CardPlay(PlayKind.single, 3, 1, 0, [], {}),
      leader: 2,
      topBid: 1,
      seat: 1,
      landlord: 2,
      players: const [BotSeat(id: 1, cards: 2), BotSeat(id: 2, cards: 7)],
      log: const [],
      playedBySeat: const {
        2: [3, 3, 14],
      },
    );
    final advice = await coach.coach(turn, ['这是当前座位的上一条建议']);
    expect(advice.explanation, '用小牌接手，保留大牌。');
    expect(advice.play?.cards, hasLength(1));
    expect(prompts.single, contains('共 108 张'));
    expect(prompts.single, contains('座位 2 已出 3 张：2张3 A'));
    expect(prompts.single, isNot(contains('×')));
    expect(formatBotRanks([4, 4, 15, 15, 15, 15]), '2张4 4张2');
    expect(botCoachPrompt, contains('禁止使用“4*2”“4×2”'));
    expect(prompts.single, contains('当前座位的上一条建议'));
    expect((await coach.coach(turn, [])).failure, isNotNull);
  });

  test(
    'manual hints call the model again even with one possible move',
    () async {
      final prompts = <String>[];
      final engine = ApiBotAdvisor(
        () => _profile(BotProvider.deepseek, BotProvider.deepseek.defaultBase),
        transport: (_, _, user) async {
          prompts.add(user);
          final index = user.contains('1. 单张') ? 1 : 0;
          return jsonEncode({
            'i': index,
            'reason': '第 ${prompts.length} 次生成的理由。',
          });
        },
      );
      BotTurn turn(int request, int earlier) => BotTurn(
        room: 'ROOM',
        deal: 1,
        bidding: false,
        rules: CardRules(),
        hand: const [PlayingCard(4)],
        wild: const {},
        previous: CardPlay(PlayKind.single, earlier, 1, 0, [], {}),
        topBid: 0,
        seat: 1,
        landlord: null,
        players: const [],
        log: const [],
        hintRequest: request,
      );
      final first = await engine.coach(turn(1, 3), []);
      final regenerated = await engine.coach(turn(2, 3), []);
      final noResponse = await engine.coach(turn(3, 5), []);
      expect(prompts, hasLength(3));
      expect(prompts[0], contains('提示请求 #1'));
      expect(prompts[1], contains('提示请求 #2'));
      expect(first.play?.cards.single.id, 4);
      expect(regenerated.explanation, '第 2 次生成的理由。');
      expect(noResponse.pass, isTrue);
      expect(noResponse.explanation, '第 3 次生成的理由。');
    },
  );

  test(
    'a four-deck bot does not offer a plane that dismantles established bombs',
    () async {
      String? prompt;
      final engine = ApiBotAdvisor(
        () => _profile(BotProvider.deepseek, BotProvider.deepseek.defaultBase),
        transport: (_, _, user) async {
          prompt = user;
          return '{"i":0}';
        },
      );
      final hand = [
        for (var i = 0; i < 13; i++) PlayingCard(i ~/ 4 * 54 + 20 + i % 4),
        for (var i = 0; i < 13; i++) PlayingCard(i ~/ 4 * 54 + 24 + i % 4),
        const PlayingCard(0),
        const PlayingCard(8),
      ];
      final advice = await engine.choose(
        BotTurn(
          room: 'ROOM',
          deal: 1,
          bidding: false,
          rules: CardRules(players: 2, decks: 4, landlord: false, bottom: 0),
          hand: hand,
          wild: {},
          previous: null,
          topBid: 0,
          seat: 1,
          landlord: null,
          players: const [BotSeat(id: 1, cards: 28), BotSeat(id: 2, cards: 20)],
          log: const [],
        ),
      );
      expect(prompt, isNotNull);
      expect(prompt, isNot(contains('飞机')));
      final play = advice.play!;
      expect(
        play.bomb ||
            play.cards.every((card) => card.rank != 8 && card.rank != 9),
        isTrue,
      );
    },
  );

  test(
    'chat reply uses the current deal, played cards and public dialogue',
    () async {
      final prompts = <String>[];
      final bot = ApiBotAdvisor(
        () => _profile(BotProvider.deepseek, BotProvider.deepseek.defaultBase),
        transport: (_, system, user) async {
          expect(system, contains('不透露自己的未公开手牌'));
          expect(system.toLowerCase(), contains('json'));
          prompts.add(user);
          return switch (prompts.length) {
            1 => '{"reply":"下局继续！","format":"chat"}',
            2 => '可以，下一局见！',
            3 => '{"reply":"  "}',
            _ => '{"reply":12}',
          };
        },
      );
      final turn = BotTurn(
        room: 'ROOM',
        deal: 1,
        bidding: false,
        rules: CardRules(),
        hand: const [PlayingCard(12)],
        wild: const {},
        previous: cardPlays(const [PlayingCard(8)], {}).single,
        leader: 2,
        activeSeat: 1,
        topBid: 1,
        seat: 1,
        landlord: 2,
        players: const [BotSeat(id: 1, cards: 1), BotSeat(id: 2, cards: 2)],
        log: const [],
        playedBySeat: const {
          2: [3, 5],
        },
        publicChat: const [
          (seat: 1, ai: true, text: '欢迎上桌'),
          (seat: 2, ai: false, text: '下局继续吗？'),
        ],
      );
      expect(await bot.replyChat(turn), '下局继续！');
      final prompt = prompts.single;
      expect(prompt, contains('你的手牌（1 张）：6'));
      expect(prompt, contains('桌面当前牌：座位 2 的 单张 5'));
      expect(prompt, contains('座位 2 已出 2 张：3 5'));
      expect(prompt, contains('"seat":2,"role":"玩家","text":"下局继续吗？"'));
      expect(botUserPrompt(turn, const []), contains('本局公开聊天'));
      expect(await bot.replyChat(turn), '可以，下一局见！');
      await expectLater(bot.replyChat(turn), throwsA(isA<BotChatFailure>()));
      await expectLater(bot.replyChat(turn), throwsA(isA<BotChatFailure>()));

      final flexible = ApiBotAdvisor(
        () => _profile(BotProvider.openai, 'https://api.openai.com/v1'),
        transport: (_, _, _) async =>
            '<think>思考中</think>\n```\n{"message":"这把稳了"}\n```',
      );
      expect(await flexible.replyChat(turn), '这把稳了');
    },
  );

  test('a winning play bypasses the model', () async {
    var called = false;
    final engine = ApiBotAdvisor(
      () => _profile(BotProvider.deepseek, BotProvider.deepseek.defaultBase),
      transport: (_, _, _) async {
        called = true;
        return '{"i":0}';
      },
    );
    final advice = await engine.choose(
      BotTurn(
        room: 'ROOM',
        deal: 1,
        bidding: false,
        rules: CardRules(),
        hand: const [PlayingCard(4)],
        wild: const {},
        previous: const CardPlay(PlayKind.single, 3, 1, 0, [], {}),
        topBid: 0,
        seat: 1,
        landlord: null,
        players: const [],
        log: const [],
      ),
    );
    expect(advice.play?.cards.single.id, 4);
    expect(called, isFalse);
  });

  testWidgets(
    'discarded answers do not delay a new deal or apply old results',
    (tester) async {
      final turns = <BotTurn>[];
      final pending = <Completer<BotAdvice>>[];
      final rooms = CardRooms(
        random: Random(11),
        botDelay: const Duration(milliseconds: 10),
        advisor: (turn) {
          turns.add(turn);
          final reply = Completer<BotAdvice>();
          pending.add(reply);
          return reply.future;
        },
      );
      addTearDown(rooms.dispose);
      final seat = rooms.create(
        CardRules(players: 2, landlord: false, bottom: 0),
        name: '用户昵称不发给模型',
      );
      rooms.action(seat, 'bot', {});
      Future<void> startAndReachBot() async {
        var state = rooms.action(seat, 'start', {});
        if (state['turn'] == state['you']) {
          state = rooms.action(seat, 'play', {
            'turnVersion': state['turnVersion'],
            'cards': [(state['hand'] as List).first],
          });
        }
        await tester.pump(const Duration(milliseconds: 10));
        final revised = rooms.state(seat, since: state['version'] as int);
        expect(revised['botThinking'], isTrue);
      }

      await startAndReachBot();
      expect(turns, hasLength(1));
      expect(
        botUserPrompt(turns.single, const []),
        isNot(contains('用户昵称不发给模型')),
      );
      rooms.action(seat, 'chat', {'text': '这条聊天只留在牌桌'});
      final aborted = rooms.action(seat, 'abort', {});
      expect(aborted['botThinking'], isFalse);
      await startAndReachBot();
      expect(turns, hasLength(2));
      expect(turns.last.deal, turns.first.deal + 1);
      final history = rooms.state(seat)['events'] as List;
      expect(history.where((event) => event['kind'] == 'deal'), hasLength(2));
      expect(turns.last.log.length, lessThanOrEqualTo(1));
      expect(botUserPrompt(turns.last, const []), isNot(contains('这条聊天只留在牌桌')));
      final current = rooms.state(seat);
      pending.first.complete(const BotAdvice.failed('过期回复', timedOut: true));
      await tester.pump();
      expect(rooms.state(seat), equals(current));
      pending.last.complete(const BotAdvice.failed('测试回退'));
      await tester.pump();
      var after = rooms.state(seat);
      expect(after['botThinking'], isFalse);
      expect(after['turn'], after['you']);
      expect(
        (after['events'] as List).lastWhere(
          (event) => event['kind'] == 'botTurnFallback',
        )['text'],
        contains('测试回退'),
      );
      if (after['last'] != null) {
        after = rooms.action(seat, 'pass', {
          'turnVersion': after['turnVersion'],
        });
      } else {
        after = rooms.action(seat, 'play', {
          'turnVersion': after['turnVersion'],
          'cards': [(after['hand'] as List).first],
        });
      }
      expect(after['turn'], isNot(after['you']));
      await tester.pump(const Duration(milliseconds: 10));
      expect(turns, hasLength(3));
      expect(rooms.state(seat)['botThinking'], isTrue);
      expect(rooms.state(seat)['apiTimeouts'], 0);
      rooms.action(seat, 'abort', {});
      await tester.pump();
    },
  );

  testWidgets(
    'only the third timeout suspends API play for the current round',
    (tester) async {
      const botDelay = Duration(milliseconds: 10);
      final pending = <Completer<BotAdvice>>[];
      final rooms = CardRooms(
        random: Random(11),
        botDelay: botDelay,
        advisor: (_) {
          final reply = Completer<BotAdvice>();
          pending.add(reply);
          return reply.future;
        },
      );
      addTearDown(rooms.dispose);
      final seat = rooms.create(
        CardRules(
          players: 2,
          decks: 2,
          chainBombs: false,
          landlord: false,
          bottom: 0,
        ),
      );
      rooms.action(seat, 'bot', {'mode': 'api'});

      Future<void> reachBot() async {
        final state = rooms.state(seat);
        if (state['turn'] == state['you']) {
          final input = {'turnVersion': state['turnVersion']};
          if (state['last'] == null) {
            rooms.action(seat, 'play', {
              ...input,
              'cards': [(state['hand'] as List).first],
            });
          } else {
            rooms.action(seat, 'pass', input);
          }
        }
        await tester.pump(botDelay);
      }

      rooms.action(seat, 'start', {});
      for (var attempt = 1; attempt <= botTimeoutLimit; attempt++) {
        await reachBot();
        expect(pending, hasLength(attempt));
        await tester.pump(botDecisionTimeout - const Duration(seconds: 1));
        expect(rooms.state(seat)['botThinking'], isTrue);
        expect(rooms.state(seat)['apiTimeouts'], attempt - 1);
        await tester.pump(const Duration(seconds: 1));
        expect(rooms.state(seat)['apiTimeouts'], attempt);
        expect(rooms.state(seat)['apiSuspended'], attempt == botTimeoutLimit);
      }
      await reachBot();
      expect(pending, hasLength(botTimeoutLimit));
      expect(rooms.state(seat)['botThinking'], isFalse);
      final fallback = (rooms.state(seat)['events'] as List).where(
        (event) => event['kind'] == 'botFallback',
      );
      expect(fallback, hasLength(1));

      rooms.action(seat, 'abort', {});
      rooms.action(seat, 'start', {});
      await reachBot();
      expect(rooms.state(seat)['apiTimeouts'], 0);
      expect(rooms.state(seat)['botThinking'], isTrue);
      expect(pending, hasLength(botTimeoutLimit + 1));
      rooms.action(seat, 'abort', {});
      await tester.pump();
    },
  );

  test('credentials stay tied to the provider and normalized address', () {
    final current = _profile(
      BotProvider.openai,
      'https://api.example.test/v1/',
    );
    expect(
      current.sameDestination(
        _profile(
          BotProvider.openai,
          'https://api.example.test/v1/chat/completions',
        ),
      ),
      isTrue,
    );
    expect(
      current.sameDestination(
        _profile(BotProvider.openai, 'https://api.example.test/other/v1'),
      ),
      isFalse,
    );
    expect(
      current.sameDestination(
        _profile(BotProvider.anthropic, 'https://api.example.test/v1'),
      ),
      isFalse,
    );
    for (final url in [
      'http://api.example.test/v1',
      'https://someone:secret@api.example.test/v1',
      'https://api.example.test/v1?key=secret',
    ]) {
      expect(_profile(BotProvider.openai, url).validate(), isNotNull);
    }
    expect(
      _profile(BotProvider.openai, 'http://127.0.0.1:8000/v1').validate(),
      isNull,
    );
  });

  test('HTTP sends provider-specific payloads and hides authentication error bodies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received =
        <
          ({
            String path,
            String? bearer,
            String? apiKey,
            Map<String, dynamic> body,
          })
        >[];
    server.listen((request) async {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      final path = request.uri.path;
      received.add((
        path: path,
        bearer: request.headers.value('authorization'),
        apiKey: request.headers.value('x-api-key'),
        body: body,
      ));
      final response = request.response;
      if (path.startsWith('/reject')) {
        response.statusCode = HttpStatus.unauthorized;
        response.write('fake-key raw service message');
      } else {
        response.write(
          jsonEncode(
            path.endsWith('/messages')
                ? {
                    'content': [
                      {'type': 'thinking', 'thinking': 'ignore'},
                      {'type': 'text', 'text': '{"bid":2}'},
                    ],
                  }
                : {
                    'choices': [
                      {
                        'message': {'content': '{"bid":2}'},
                      },
                    ],
                  },
          ),
        );
      }
      await response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    for (final provider in BotProvider.values) {
      final bot = ApiBotAdvisor(
        () => _profile(
          provider,
          '$base/v1/',
          model: provider == BotProvider.openai ? 'gpt-4.1' : null,
        ),
      );
      expect((await _chooseOverHttp(bot)).bid, 2);
    }
    expect(received[0].path, '/v1/chat/completions');
    expect(received[0].bearer, 'Bearer fake-key');
    expect(received[0].body['thinking'], {'type': 'enabled'});
    expect(received[0].body['reasoning_effort'], 'high');
    expect(received[1].path, '/v1/chat/completions');
    expect(received[1].body.containsKey('reasoning_effort'), isFalse);
    expect(received[2].path, '/v1/messages');
    expect(received[2].apiKey, 'fake-key');
    expect(received[2].bearer, isNull);
    expect(received[2].body['thinking'], {'type': 'adaptive'});
    expect(received[2].body['output_config'], {'effort': 'high'});
    final legacyClaude = ApiBotAdvisor(
      () => _profile(
        BotProvider.anthropic,
        '$base/v1/',
        model: 'claude-sonnet-4-5',
      ),
    );
    expect((await _chooseOverHttp(legacyClaude)).bid, 2);
    expect(received[3].body['thinking']['budget_tokens'], 2048);
    final error = await _chooseOverHttp(
      ApiBotAdvisor(() => _profile(BotProvider.deepseek, '$base/reject')),
    );
    expect(error.failure, '电脑 API 鉴权失败（HTTP 401）');
  });

  test(
    'empty hints retry with reduced thinking and reuse the HTTP connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      final ports = <int?>[];
      server.listen((request) async {
        final payload = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        requests.add(payload);
        ports.add(request.connectionInfo?.remotePort);
        final retry = payload['thinking']['type'] == 'disabled';
        final response = utf8.encode(
          jsonEncode({
            'choices': [
              {
                'finish_reason': retry ? 'stop' : 'length',
                'message': retry
                    ? {'content': '{"i":0,"reason":"这张牌可以直接出完。"}'}
                    : {'content': '  ', 'reasoning_content': '只有思考内容'},
              },
            ],
          }),
        );
        request.response
          ..headers.contentType = ContentType.json
          ..contentLength = response.length
          ..add(response);
        await request.response.close();
      });
      final engine = ApiBotAdvisor(
        () => _profile(BotProvider.deepseek, 'http://127.0.0.1:${server.port}'),
      );
      addTearDown(engine.dispose);
      final stages = <BotProgress>[];
      final advice = await HttpOverrides.runWithHttpOverrides(
        () => engine.coach(_hintTurn(stages.add), []),
        _RealHttp(),
      );
      expect(advice.play?.cards.single.id, 4);
      expect(advice.explanation, '这张牌可以直接出完。');
      expect(requests, hasLength(2));
      expect(
        stages,
        containsAllInOrder([
          BotProgress.connecting,
          BotProgress.waiting,
          BotProgress.receiving,
          BotProgress.retrying,
          BotProgress.waiting,
          BotProgress.receiving,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final automatic = await _chooseOverHttp(engine);
      expect(automatic.failure, '模型耗尽输出额度，未给出答案');
      expect(requests, hasLength(3));
      expect(ports.take(2), contains(ports.last));
    },
  );

  test('an incomplete response fails on the body idle timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.bufferOutput = false;
      request.response.write('{');
      await request.response.flush();
    });
    final engine = ApiBotAdvisor(
      () => _profile(BotProvider.deepseek, 'http://127.0.0.1:${server.port}'),
      timeout: const Duration(seconds: 2),
      bodyIdleTimeout: const Duration(milliseconds: 80),
    );
    addTearDown(engine.dispose);
    final advice = await _chooseOverHttp(engine);
    expect(advice.timedOut, isTrue);
    expect(advice.failure, '电脑 API 响应传输中断');
  });

  test('one timeout covers a response that never finishes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final listening = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      request.response.bufferOutput = false;
      request.response.write('{');
      await request.response.flush();
      listening.complete();
    });
    final bot = ApiBotAdvisor(
      () => _profile(BotProvider.deepseek, 'http://127.0.0.1:${server.port}'),
      timeout: const Duration(milliseconds: 300),
    );
    addTearDown(bot.dispose);
    final pending = _chooseOverHttp(bot);
    await listening.future.timeout(const Duration(seconds: 3));
    final advice = await pending;
    expect(advice.failure, '电脑 API 响应超时');
    expect(advice.timedOut, isTrue);
  });

  test(
    'table context reports exact seat count, roles, neighbors and phase',
    () {
      final prompt = botChatPrompt(
        BotTurn(
          room: '6P-ROOM',
          deal: 2,
          bidding: false,
          phase: 'playing',
          rules: CardRules(players: 6, decks: 2, bottom: 6, landlord: true),
          hand: const [PlayingCard(0), PlayingCard(4)],
          wild: const {},
          previous: cardPlays(const [PlayingCard(8)], {}).single,
          leader: 3,
          topBid: 3,
          seat: 2,
          landlord: 1,
          players: const [
            BotSeat(id: 1, cards: 12, bot: false, autoplay: false),
            BotSeat(id: 2, cards: 15, bot: true, botMode: 'api'),
            BotSeat(id: 3, cards: 10, bot: true, botMode: 'local'),
            BotSeat(id: 4, cards: 14, bot: false, autoplay: true),
          ],
          log: const ['座位 1 叫 3 分成为地主'],
          publicChat: const [(seat: 1, ai: false, text: '现在几个人在打？')],
        ),
      );
      expect(prompt, contains('当前状态：出牌阶段'));
      expect(prompt, contains('在桌人数：已入座 4 / 6 人（真人 2 位，电脑 2 位，空位 2 个）'));
      expect(prompt, contains('座位 1[真人·地主·对手] 余 12 张'));
      expect(prompt, contains('座位 2（你）[API电脑·农民] 余 15 张'));
      expect(prompt, contains('座位 3[本地电脑·农民·队友] 余 10 张'));
      expect(prompt, contains('座位 4[真人·托管·农民·队友] 余 14 张'));
      expect(prompt, contains('上家座位 1（余 12 张），下家座位 3（余 10 张）'));
      expect(prompt, contains('桌面当前牌：座位 3 的 单张 5（队友）'));
    },
  );
}

class _RealHttp extends HttpOverrides {}

Future<BotAdvice> _chooseOverHttp(ApiBotAdvisor bot) =>
    HttpOverrides.runWithHttpOverrides(
      () => bot.choose(_bidTurn()),
      _RealHttp(),
    );

BotProfile _profile(BotProvider provider, String base, {String? model}) =>
    BotProfile(
      enabled: true,
      provider: provider,
      baseUrl: base,
      model: model ?? provider.defaultModel,
      effort: BotEffort.high,
      apiKey: 'fake-key',
    );

BotTurn _hintTurn(void Function(BotProgress) progress) => BotTurn(
  room: 'ROOM',
  deal: 1,
  bidding: false,
  rules: CardRules(),
  hand: const [PlayingCard(4)],
  wild: const {},
  previous: null,
  topBid: 0,
  seat: 1,
  landlord: null,
  players: const [],
  log: const [],
  onProgress: progress,
);

BotTurn _bidTurn() => BotTurn(
  room: 'ROOM',
  deal: 1,
  bidding: true,
  rules: CardRules(),
  hand: const [PlayingCard(0)],
  wild: const {},
  previous: null,
  topBid: 0,
  seat: 1,
  landlord: null,
  players: const [],
  log: const [],
);
