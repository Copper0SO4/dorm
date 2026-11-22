import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'bot_profile.dart';
import 'cards.dart';

typedef BotTransport = Future<String> Function(
  BotProfile profile,
  String system,
  String user,
);

const botDecisionTimeout = Duration(seconds: 8);

/// Stateless requests contain only the current deal. The room owns the
/// turn revision and decides whether a completed answer can still be used.
class ApiBotAdvisor {
  ApiBotAdvisor(
    this._profile, {
    BotTransport? transport,
    Duration timeout = botDecisionTimeout,
  }) : _transport =
           transport ??
           ((profile, system, user) =>
               _complete(profile, system, user, timeout));

  final BotProfile Function() _profile;
  final BotTransport _transport;

  Future<BotAdvice> choose(BotTurn turn) => _decide(turn);

  Future<BotAdvice> coach(BotTurn turn, List<String> history) =>
      _decide(turn, history: history);

  Future<BotAdvice> _decide(BotTurn turn, {List<String>? history}) async {
    final explain = history != null;
    final profile = _profile();
    if (!profile.usable) {
      return explain
          ? const BotAdvice.failed('请房主先启用电脑 API')
          : const BotAdvice.off();
    }
    final problem = profile.validate();
    if (problem != null) return BotAdvice.failed(problem);
    if (!turn.bidding) {
      final finish = legalCardPlays(
        turn.hand,
        turn.wild,
        turn.previous,
        rules: turn.rules,
      ).firstOrNull;
      if (finish != null) {
        return BotAdvice.play(finish, explain ? '这手牌可以一次出完，直接打出即可赢下牌局。' : null);
      }
    }
    final options = turn.bidding ? <CardPlay>[] : botCandidates(turn);
    if (!turn.bidding && options.isEmpty) {
      return turn.previous == null
          ? const BotAdvice.off()
          : BotAdvice.pass(explain ? '你的手牌没有能压过当前牌的组合，建议不出，保留手牌。' : null);
    }
    try {
      final text = await _transport(
        profile,
        explain ? botCoachPrompt : botSystemPrompt,
        botUserPrompt(turn, options, coachingHistory: history),
      );
      return interpretBotText(text, turn, options, explain: explain);
    } on BotHttpException catch (error) {
      return BotAdvice.failed(error.message);
    } catch (_) {
      return const BotAdvice.failed('电脑 API 暂时不可用');
    }
  }
}

class BotHttpException implements Exception {
  const BotHttpException(this.message);
  final String message;
}

class BotApiSettings {
  const BotApiSettings();

  Future<List<BotModel>> listModels(BotProfile profile) {
    final problem = profile.validate(needModel: false);
    if (problem != null || profile.apiKey.isEmpty) {
      throw BotHttpException(problem ?? '请先填写 API 密钥');
    }
    return _withClient(const Duration(seconds: 12), (client) async {
      final endpoint = botModelsEndpoint(profile);
      final models = <String, BotModel>{};
      final cursors = <String>{};
      String? after;
      for (var page = 0; page < 12; page++) {
        final uri = profile.provider == BotProvider.anthropic
            ? endpoint.replace(
                queryParameters: {'limit': '100', 'after_id': ?after},
              )
            : endpoint;
        final payload = await _jsonRequest(client, profile, uri, catalog: true);
        final data = payload['data'];
        if (data is! List) throw const BotHttpException('模型列表格式无效');
        for (final item in data.whereType<Map<String, dynamic>>()) {
          final model = BotModel.fromApi(
            item,
            anthropic: profile.provider == BotProvider.anthropic,
            deepseek: profile.provider == BotProvider.deepseek,
          );
          if (model != null) models[model.id] = model;
        }
        if (profile.provider != BotProvider.anthropic ||
            payload['has_more'] != true) {
          return models.values.toList(growable: false);
        }
        final cursor = payload['last_id'];
        if (cursor is! String || cursor.isEmpty || !cursors.add(cursor)) {
          throw const BotHttpException('模型列表分页信息无效');
        }
        after = cursor;
      }
      throw const BotHttpException('模型列表超过可加载的页数');
    });
  }

  Future<Duration> testConnection(BotProfile profile) async {
    final problem = profile.validate();
    if (problem != null || profile.apiKey.isEmpty) {
      throw BotHttpException(problem ?? '请先填写 API 密钥');
    }
    final time = Stopwatch()..start();
    final answer = await _complete(
      profile,
      '这是连接测试，请只返回一个 JSON 对象。',
      '请回复 {"ok":true}。',
      botDecisionTimeout,
    );
    final Object? decoded;
    try {
      decoded = decodeBotJson(answer);
    } on FormatException {
      throw const BotHttpException('接口已连接，模型回复格式不符合要求');
    }
    if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
      throw const BotHttpException('接口已连接，模型回复格式不符合要求');
    }
    return time.elapsed;
  }
}

Future<T> _withClient<T>(
  Duration timeout,
  Future<T> Function(HttpClient) work,
) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await work(client).timeout(timeout);
  } on TimeoutException {
    throw const BotHttpException('电脑 API 响应超时');
  } on SocketException {
    throw const BotHttpException('无法连接电脑 API');
  } on HandshakeException {
    throw const BotHttpException('无法验证 API 的 HTTPS 证书');
  } on FormatException {
    throw const BotHttpException('电脑 API 响应格式无效');
  } finally {
    client.close(force: true);
  }
}

Future<String> _complete(
  BotProfile profile,
  String system,
  String user,
  Duration timeout,
) => _withClient(timeout, (client) async {
  final decoded = await _jsonRequest(
    client,
    profile,
    botEndpoint(profile),
    body: _body(profile, system, user),
  );
  final text = _answer(decoded, profile.provider);
  if (text.trim().isEmpty) throw const BotHttpException('电脑 API 没有返回文本内容');
  return text;
});

Future<Map<String, dynamic>> _jsonRequest(
  HttpClient client,
  BotProfile profile,
  Uri endpoint, {
  Map<String, Object?>? body,
  bool catalog = false,
}) async {
  final request = await client.openUrl(body == null ? 'GET' : 'POST', endpoint);
  request.followRedirects = false;
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  if (profile.provider == BotProvider.anthropic) {
    request.headers.set('x-api-key', profile.apiKey);
    request.headers.set(
      'anthropic-version',
      endpoint.host == 'api.anthropic.com' ? '2026-10-21' : '2023-06-01',
    );
  } else {
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${profile.apiKey}',
    );
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
  }
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    if (catalog &&
        const {
          HttpStatus.notFound,
          HttpStatus.methodNotAllowed,
        }.contains(response.statusCode)) {
      throw const BotHttpException('当前地址未提供模型列表接口，可手动填写模型');
    }
    throw BotHttpException(_httpFailure(response.statusCode));
  }
  final maxBytes = catalog ? 1024 * 1024 : 256 * 1024;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const BotHttpException('电脑 API 响应过大');
    }
    bytes.add(chunk);
  }
  final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
  if (decoded is! Map<String, dynamic>) {
    throw const BotHttpException('电脑 API 响应格式无效');
  }
  return decoded;
}

Map<String, Object?> _body(BotProfile profile, String system, String user) {
  final effort = profile.effectiveEffort;
  if (profile.provider == BotProvider.anthropic) {
    final adaptive = profile.thinkingStyle == BotThinking.adaptive;
    final budget = !adaptive
        ? switch (effort) {
            BotEffort.low || BotEffort.minimal => 1024,
            BotEffort.high || BotEffort.medium => 2048,
            BotEffort.max || BotEffort.xhigh => 4096,
            _ => 0,
          }
        : 0;
    return {
      'model': profile.model,
      'system': system,
      'messages': [
        {'role': 'user', 'content': user},
      ],
      'max_tokens': adaptive && effort != BotEffort.off ? 4096 : budget + 512,
      if (adaptive &&
          effort == BotEffort.off &&
          profile.thinkingOffMode != null)
        'thinking': {'type': profile.thinkingOffMode}
      else if (adaptive && effort != BotEffort.off)
        'thinking': {'type': 'adaptive'}
      else if (budget > 0)
        'thinking': {'type': 'enabled', 'budget_tokens': budget},
      if (adaptive && effort != BotEffort.automatic && effort != BotEffort.off)
        'output_config': {'effort': effort.wire},
    };
  }
  return {
    'model': profile.model,
    'messages': [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ],
    if (profile.provider == BotProvider.deepseek) ...{
      if (effort != BotEffort.automatic)
        'thinking': {'type': effort == BotEffort.off ? 'disabled' : 'enabled'},
      'response_format': {'type': 'json_object'},
      'max_tokens': effort == BotEffort.off ? 384 : 4096,
    } else if (botEndpoint(profile).host == 'api.openai.com')
      'max_completion_tokens':
          profile.supportsReasoning && effort != BotEffort.off ? 4096 : 384,
    if (effort != BotEffort.automatic &&
        (profile.provider != BotProvider.deepseek || effort != BotEffort.off))
      'reasoning_effort': effort.wire,
  };
}

String _answer(Map<dynamic, dynamic> decoded, BotProvider provider) {
  if (provider == BotProvider.anthropic) {
    final content = decoded['content'];
    if (content is! List) return '';
    return [
      for (final block in content)
        if (block is Map && block['type'] == 'text' && block['text'] is String)
          block['text'] as String,
    ].join('\n');
  }
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty || choices.first is! Map) return '';
  final message = (choices.first as Map)['message'];
  if (message is! Map) return '';
  final content = message['content'];
  if (content is String) return content;
  if (content is List) {
    return [
      for (final part in content)
        if (part is Map && part['text'] is String) part['text'] as String,
    ].join('\n');
  }
  return '';
}

String _httpFailure(int status) => switch (status) {
  401 || 403 => '电脑 API 鉴权失败（HTTP $status）',
  400 || 404 || 422 => '电脑 API 地址、模型或参数有误（HTTP $status）',
  429 => '电脑 API 请求受限（HTTP $status）',
  _ => '电脑 API 返回 HTTP $status',
};
