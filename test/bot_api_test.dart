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
        CardRules(players: 2, decks: 2, landlord: false, bottom: 0),
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
    final pending = _chooseOverHttp(bot);
    await listening.future.timeout(const Duration(seconds: 3));
    final advice = await pending;
    expect(advice.failure, '电脑 API 响应超时');
    expect(advice.timedOut, isTrue);
  });
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
