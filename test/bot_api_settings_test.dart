import 'dart:convert';
import 'dart:io';

import 'package:dormos/data/sqlite_repository.dart';
import 'package:dormos/domain/preferences.dart';
import 'package:dormos/game/bot_api.dart';
import 'package:dormos/game/bot_profile.dart';
import 'package:dormos/ui/bot_api_dialog.dart';
import 'package:dormos/ui/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

BotProfile profile(
  BotProvider provider,
  String base, {
  String? model,
  BotModel? info,
}) => BotProfile(
  enabled: false,
  provider: provider,
  baseUrl: base,
  model: model ?? provider.defaultModel,
  effort: BotEffort.medium,
  apiKey: 'fixture-key',
  modelInfo: info,
);

class _RealHttp extends HttpOverrides {}

Future<T> _connect<T>(Future<T> Function() callback) =>
    HttpOverrides.runWithHttpOverrides(callback, _RealHttp());

void main() {
  test('provider defaults resolve to the documented endpoints and legacy custom models remain intact', () {
    expect(BotProvider.deepseek.defaultModel, 'deepseek-flash');
    expect(BotProvider.openai.defaultModel, 'gpt-6-luna');
    expect(BotProvider.anthropic.defaultModel, 'claude-sonnet-5-5');
    expect(
      botEndpoint(profile(BotProvider.openai, 'https://api.openai.com')).path,
      '/v1/chat/completions',
    );
    expect(
      botModelsEndpoint(
        profile(BotProvider.deepseek, 'https://api.deepseek.com'),
      ).path,
      '/models',
    );
    expect(
      botModelsEndpoint(
        profile(BotProvider.anthropic, 'https://api.anthropic.com'),
      ).path,
      '/v1/models',
    );
    expect(
      botModelsEndpoint(
        profile(
          BotProvider.openai,
          'https://proxy.example/team/v1/chat/completions',
        ),
      ).path,
      '/team/v1/models',
    );
    final old = const DormPreferences(
      botProvider: 'anthropic',
      botApiModel: 'claude-sonnet-4-5',
    );
    expect(BotProfile.fromPreferences(old).model, 'claude-sonnet-5-5');
    expect(
      BotProfile.fromPreferences(
        old.copyWith(botApiBase: 'https://proxy.example'),
      ).model,
      'claude-sonnet-4-5',
    );
  });

  test('reads provider capability metadata and preserves reported levels on reload', () {
    final model = BotModel.fromApi(
      {
        'id': 'deepseek-supplied',
        'name': 'Provider Flash',
        'effort': {
          'supported_levels': ['low', 'medium', 'xhigh'],
          'default_level': 'medium',
        },
      },
      anthropic: false,
      deepseek: true,
    )!;
    expect(model.efforts, [
      BotEffort.off,
      BotEffort.low,
      BotEffort.medium,
      BotEffort.xhigh,
    ]);
    final restored = BotProfile.fromPreferences(
      DormPreferences(
        botApiModel: model.id,
        botEffort: 'xhigh',
        botModelMetadata: model.encode(),
      ),
    );
    expect(restored.modelInfo?.name, 'Provider Flash');
    expect(restored.effectiveEffort, BotEffort.xhigh);
    expect(restored.modelInfo?.defaultEffort, BotEffort.medium);
    final compatibility = BotModel.fromApi(
      {'id': 'fixture-model'},
      anthropic: false,
      deepseek: false,
    );
    expect(compatibility?.efforts, isNull);
  });

  test('lists models with appropriate authentication and follows Anthropic model pagination', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final captured =
        <
          ({
            String method,
            String path,
            String? after,
            String? bearer,
            String? key,
          })
        >[];
    server.listen((request) async {
      final after = request.uri.queryParameters['after_id'];
      captured.add((
        method: request.method,
        path: request.uri.path,
        after: after,
        bearer: request.headers.value('authorization'),
        key: request.headers.value('x-api-key'),
      ));
      final Object body;
      if (request.uri.path.startsWith('/claude')) {
        body = after == null
            ? {
                'has_more': true,
                'last_id': 'one',
                'data': [
                  {
                    'id': 'one',
                    'display_name': 'First Claude',
                    'capabilities': {
                      'effort': {
                        'low': {'supported': true},
                        'high': {'supported': false},
                      },
                      'thinking': {
                        'supported': true,
                        'types': {
                          'adaptive': {'supported': true},
                          'between_tools': {'supported': true},
                        },
                      },
                    },
                  },
                ],
              }
            : {
                'has_more': false,
                'data': [
                  {'id': 'two', 'display_name': 'Second Claude'},
                ],
              };
      } else {
        body = {
          'data': [
            {
              'id': 'deepseek-fixture',
              'effort': {
                'supported_levels': ['high', 'max'],
                'default_level': 'high',
              },
            },
            {
              'id': 'image-only',
              'output_modalities': ['image'],
            },
          ],
        };
      }
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    const settings = BotApiSettings();
    final deepseek = await _connect(
      () => settings.listModels(
        profile(BotProvider.deepseek, '$base/v1/chat/completions'),
      ),
    );
    expect(deepseek.single.efforts, [
      BotEffort.off,
      BotEffort.high,
      BotEffort.max,
    ]);
    final claude = await _connect(
      () => settings.listModels(
        profile(BotProvider.anthropic, '$base/claude/v1/messages'),
      ),
    );
    expect(claude.map((model) => model.id), ['one', 'two']);
    expect(claude.first.thinking, BotThinking.adaptive);
    expect(claude.first.efforts, [BotEffort.off, BotEffort.low]);
    expect(claude.first.offMode, 'between_tools');
    expect(captured.map((entry) => entry.method), ['GET', 'GET', 'GET']);
    expect(captured[0].path, '/v1/models');
    expect(captured[0].bearer, 'Bearer fixture-key');
    expect(captured[1].path, '/claude/v1/models');
    expect(captured[1].key, 'fixture-key');
    expect(captured[1].bearer, isNull);
    expect(captured[2].after, 'one');
  });

  test('connection test sends a real minimal completion and checks reply and errors', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      requests.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      if (request.uri.path.startsWith('/denied')) {
        request.response.statusCode = 401;
        request.response.write(
          'fixture-key should never appear in the display',
        );
      } else {
        final reply = request.uri.path.startsWith('/wrong')
            ? '{"ok":false}'
            : '{"ok":true}';
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': reply},
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    const settings = BotApiSettings();
    await _connect(
      () => settings.testConnection(profile(BotProvider.openai, '$base/v1')),
    );
    expect(requests.single['model'], 'gpt-6-luna');
    expect(requests.single['reasoning_effort'], 'medium');
    expect(
      (requests.single['messages'] as List).last['content'],
      contains('{"ok":true}'),
    );
    await expectLater(
      _connect(
        () =>
            settings.testConnection(profile(BotProvider.openai, '$base/wrong')),
      ),
      throwsA(
        isA<BotHttpException>().having(
          (error) => error.message,
          'message',
          contains('回复格式'),
        ),
      ),
    );
    await expectLater(
      _connect(
        () => settings.testConnection(
          profile(BotProvider.openai, '$base/denied'),
        ),
      ),
      throwsA(
        isA<BotHttpException>().having(
          (error) => error.message,
          'message',
          '电脑 API 鉴权失败（HTTP 401）',
        ),
      ),
    );
  });

  testWidgets(
    'fetches a model, selects an advertised level, tests and saves the profile',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1050));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = SqliteDormRepository.open(':memory:');
      final controller = DormController(repo);
      addTearDown(() {
        controller.dispose();
        repo.close();
      });
      final api = _FixtureApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showBotApiDialog(context, controller, api: api),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      final key = find.widgetWithText(TextField, 'API 密钥');
      await tester.enterText(key, 'fixture-key');
      await tester.tap(find.text('获取模型'));
      await tester.pumpAndSettle();
      expect(find.text('从 API 选择模型'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '搜索模型'), 'round');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Round model'));
      await tester.pumpAndSettle();
      final medium = find.widgetWithText(ChoiceChip, '中');
      expect(tester.widget<ChoiceChip>(medium).selected, true);
      expect(find.widgetWithText(ChoiceChip, '高'), findsNothing);
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(find.text('测试通过 · 125 毫秒'), findsOneWidget);
      expect(api.tested?.model, 'round-model');
      expect(api.tested?.effectiveEffort, BotEffort.medium);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = BotProfile.fromPreferences(repo.preferences);
      expect(saved.model, 'round-model');
      expect(saved.modelInfo?.efforts, [BotEffort.medium]);
      expect(saved.effectiveEffort, BotEffort.medium);
    },
  );
}

class _FixtureApi extends BotApiSettings {
  BotProfile? tested;

  @override
  Future<List<BotModel>> listModels(BotProfile profile) async {
    expect(profile.apiKey, 'fixture-key');
    return const [
      BotModel(id: 'other'),
      BotModel(
        id: 'round-model',
        name: 'Round model',
        efforts: [BotEffort.medium],
        defaultEffort: BotEffort.medium,
      ),
    ];
  }

  @override
  Future<Duration> testConnection(BotProfile profile) async {
    tested = profile;
    return const Duration(milliseconds: 125);
  }
}
